using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

/// <summary>
/// 调用内置或系统 wx-cli 完成密钥提取、解密与导出。
/// </summary>
public sealed class WxCliService
{
    // 各命令超时（秒）：wx-cli 对部分微信版本可能挂起（#35），超时后自动 kill 进程，
    // 抛出的异常会触发应用层数据目录检测 + 内存密钥提取兜底，避免界面卡死在准备阶段。
    private const int InitTimeoutSeconds = 240;      // init / init --force（扫描密钥 + 解密数据库）
    private const int SessionsTimeoutSeconds = 300;  // sessions --json -n 999999
    private const int ExportTimeoutSeconds = 600;    // export --limit 999999（超大聊天记录）

    // wx.exe（闭源）内部 daemon 启动失败标记：wx-cli 每次执行命令前自动拉起 wx-daemon 子进程，
    // N 秒内连不上 named pipe \\.\pipe\wx-cli-daemon 即报「启动超时」并退出（残留 pid / 杀软拦截 / 预热慢）。
    private const string DaemonStartTimeoutMarker = "wx-daemon 启动超时";
    private const string DaemonStartFailedMarker = "无法启动 daemon 进程";

    // daemon status 输出为中文（"wx-daemon 运行中 (PID x)" / "wx-daemon 未运行"），
    // 旧代码用 Contains("ready"/"running") 对真实输出永远为 false，导致每次强制 init --force。
    private static bool IsDaemonRunning(string status) =>
        status.Contains("运行中", StringComparison.Ordinal)
        || status.Contains("ready", StringComparison.OrdinalIgnoreCase)
        || status.Contains("running", StringComparison.OrdinalIgnoreCase);

    public string ExecutablePath { get; }
    public bool IsBundled { get; }

    private WxCliService(string executablePath, bool isBundled)
    {
        ExecutablePath = executablePath;
        IsBundled = isBundled;
    }

    public static WxCliService? TryCreate()
    {
        var path = LocateExecutable();
        return path is null ? null : new WxCliService(path, IsBundledPath(path));
    }

    public static string? LocateExecutable()
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "wx.exe");
        if (File.Exists(bundled))
            return bundled;

        var local = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "bin", "wx.exe");
        if (File.Exists(local))
            return local;

        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir.Trim(), "wx.exe");
            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }

    private static bool IsBundledPath(string path)
    {
        var baseDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalized = Path.GetFullPath(path);
        return normalized.StartsWith(baseDir, StringComparison.OrdinalIgnoreCase);
    }

    public async Task<bool> IsPreparedForQueryAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(GetConfigPath()))
            return false;

        try
        {
            var status = await RunAsync(["daemon", "status"], 30, _ => { }, cancellationToken);
            return IsDaemonRunning(status);
        }
        catch
        {
            return false;
        }
    }

    public async Task PrepareDataAsync(
        Action<string> log,
        Action<LoadProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var tracker = new LoadProgressTracker();
        tracker.Reset();
        progress?.Invoke(tracker.Estimated("正在检查 wx-cli 环境…"));
        log("检查 wx-cli 环境…");

        var status = await RunAsync(["daemon", "status"], 30, log, cancellationToken);
        var needsInit = !IsDaemonRunning(status);

        // 读取已有 config.json 中的 db_dir，防止 init --force 覆盖用户自定义配置
        var configPath = GetConfigPath();
        string? savedDbDir = null;
        if (File.Exists(configPath))
        {
            try
            {
                var configJson = await File.ReadAllTextAsync(configPath, cancellationToken);
                using var configDoc = JsonDocument.Parse(configJson);
                if (configDoc.RootElement.TryGetProperty("db_dir", out var dbDirEl)
                    && dbDirEl.ValueKind == JsonValueKind.String)
                {
                    savedDbDir = dbDirEl.GetString();
                    if (!string.IsNullOrWhiteSpace(savedDbDir))
                        log($"检测到自定义数据目录：{savedDbDir}");
                }
            }
            catch
            {
                // 读取失败则忽略，继续使用默认流程
            }
        }

        using var tickCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _ = RunProgressTicker(tickCts.Token, tracker, progress, "正在初始化数据…");

        try
        {
            if (needsInit || !File.Exists(configPath))
            {
                await InitFreshAsync(configPath, savedDbDir, log, progress, tracker, cancellationToken);
            }
            else
            {
                log("使用已保存的密钥与缓存");
                progress?.Invoke(tracker.Warmup("正在同步本地缓存…"));
                var cachedOutput = await RunAsync(["init"], null, log, cancellationToken);
                if (HasZeroKeysExtracted(cachedOutput))
                {
                    // 缓存密钥失效（微信重装 / 升级 / 换号导致 rawKey 变化）：清除失效密钥后重新完整初始化（#33）
                    log("已保存的密钥已失效（wx-cli 提取到 0 个数据库密钥），正在重新初始化…");
                    try { await ClearSavedKeysAsync(configPath, log); }
                    catch (Exception ex) { log($"清除失效密钥失败：{ex.Message}"); }
                    await InitFreshAsync(configPath, savedDbDir, log, progress, tracker, cancellationToken);
                }
            }

            progress?.Invoke(tracker.Complete("数据准备完成"));
            log("数据准备完成");
        }
        finally
        {
            tickCts.Cancel();
        }
    }

    /// <summary>
    /// 完整初始化流程（init --force 等）。
    /// #33：wx-cli 在「提取到 0 个数据库密钥」时仍返回退出码 0（误判成功），
    /// 此处解析其输出并拦截，转应用层数据目录检测 + 密钥提取兜底（#31 / #32）。
    /// </summary>
    private async Task InitFreshAsync(string configPath, string? savedDbDir, Action<string> log,
        Action<LoadProgressUpdate>? progress, LoadProgressTracker tracker, CancellationToken cancellationToken)
    {
        progress?.Invoke(tracker.Warmup("正在初始化（扫描密钥并解密数据库）…"));
        log("正在初始化（扫描密钥并解密数据库，约 1-3 分钟）…");
        log("提示：若失败，请以管理员身份重新打开本程序。");
        try
        {
            var output = await RunAsync(["init", "--force"], InitTimeoutSeconds, log, cancellationToken);
            ThrowIfInitFailedToExtractKeys(output);
        }
        catch (Exception ex)
        {
            // init --force 失败或误报成功：先应用层自动检测数据目录（#31），再尝试应用层提取密钥（#32/#33，兼容微信 4.1.12+）
            log($"init --force 失败：{ex.Message}");

            var dataDir = savedDbDir;
            if (string.IsNullOrWhiteSpace(dataDir) || !Directory.Exists(dataDir))
            {
                log("正在自动检测微信数据目录…");
                progress?.Invoke(tracker.Warmup("正在自动检测微信数据目录…"));
                dataDir = DetectWeChatDataDir(log);
            }

            if (!string.IsNullOrWhiteSpace(dataDir) && Directory.Exists(dataDir))
            {
                log($"使用数据目录：{dataDir}");
                await WriteDataDirToConfigAsync(configPath, dataDir, log);
                try
                {
                    progress?.Invoke(tracker.Warmup("正在使用数据目录重新初始化…"));
                    var output2 = await RunAsync(["init", "--force", "--data-dir", dataDir], InitTimeoutSeconds, log, cancellationToken);
                    ThrowIfInitFailedToExtractKeys(output2);
                }
                catch (Exception ex2)
                {
                    log($"使用数据目录初始化失败：{ex2.Message}");
                    // 检测到目录但初始化仍失败（通常是密钥提取失败）→ 应用层密钥提取
                    var recovered = await TryRecoverKeyAsync(configPath, dataDir, log, progress, tracker, cancellationToken);
                    if (!recovered)
                    {
                        log("尝试不使用 --force 重新初始化…");
                        progress?.Invoke(tracker.Warmup("正在重新初始化…"));
                        var output3 = await RunAsync(["init"], InitTimeoutSeconds, log, cancellationToken);
                        ThrowIfInitFailedToExtractKeys(output3);
                    }
                }
            }
            else
            {
                log("未能自动检测到微信数据目录，尝试不使用 --force 重新初始化…");
                progress?.Invoke(tracker.Warmup("正在重新初始化…"));
                var output4 = await RunAsync(["init"], InitTimeoutSeconds, log, cancellationToken);
                ThrowIfInitFailedToExtractKeys(output4);
            }
        }

        // init --force 可能覆盖了 config.json，恢复用户自定义的 db_dir
        if (!string.IsNullOrWhiteSpace(savedDbDir) && File.Exists(configPath))
        {
            try { await RestoreDbDirToConfigAsync(configPath, savedDbDir, log); }
            catch (Exception ex) { log($"警告：恢复 db_dir 配置失败：{ex.Message}"); }
        }
    }

    /// <summary>清除已保存的密钥（删除 all_keys.json，并移除 config.json 中的 keys_file / your_wxid 字段）。</summary>
    private static async Task ClearSavedKeysAsync(string configPath, Action<string> log)
    {
        var keysFile = Path.Combine(Path.GetDirectoryName(configPath)!, "all_keys.json");
        if (File.Exists(keysFile))
        {
            File.Delete(keysFile);
            log($"已删除失效密钥文件：{keysFile}");
        }

        using var doc = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
        var writer = new MemoryStream();
        using (var jsonWriter = new Utf8JsonWriter(writer, new JsonWriterOptions { Indented = true }))
        {
            jsonWriter.WriteStartObject();
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.NameEquals("keys_file") || prop.NameEquals("your_wxid"))
                    continue;
                prop.WriteTo(jsonWriter);
            }
            jsonWriter.WriteEndObject();
        }
        await File.WriteAllBytesAsync(configPath, writer.ToArray());
        log("已清除 config.json 中的 keys_file / your_wxid");
    }

    /// <summary>
    /// 判断 wx-cli init 输出是否为「0 个密钥却返回成功」的误判（#33）。
    /// 匹配其输出中的 “成功提取 N 个数据库密钥”；输出不含该模式时不拦截（fail-open）。
    /// </summary>
    private static bool HasZeroKeysExtracted(string output)
    {
        var match = Regex.Match(output, @"成功提取\s*(\d+)\s*个数据库密钥");
        return match.Success && int.Parse(match.Groups[1].Value) == 0;
    }

    /// <summary>wx-cli 误报成功（提取到 0 个密钥）时抛错，触发应用层兜底流程。</summary>
    private static void ThrowIfInitFailedToExtractKeys(string output)
    {
        if (!HasZeroKeysExtracted(output)) return;
        throw new InvalidOperationException(
            "wx-cli 返回成功但未提取到任何数据库密钥（成功提取 0 个数据库密钥）。常见原因：未以管理员身份运行（无法读取微信进程内存）、微信未登录、或微信版本过新。正在切换应用层密钥提取兜底…");
    }

    /// <summary>
    /// 将用户自定义的 db_dir 写回 config.json（init --force 可能覆盖了它）。
    /// </summary>
    private static async Task RestoreDbDirToConfigAsync(string configPath, string dbDir, Action<string> log)
    {
        var configJson = await File.ReadAllTextAsync(configPath);
        using var doc = JsonDocument.Parse(configJson);
        var writer = new MemoryStream();
        using (var jsonWriter = new Utf8JsonWriter(writer, new JsonWriterOptions { Indented = true }))
        {
            jsonWriter.WriteStartObject();
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.NameEquals("db_dir"))
                {
                    jsonWriter.WriteString("db_dir", dbDir);
                }
                else
                {
                    prop.WriteTo(jsonWriter);
                }
            }
            // 如果原 config 没有 db_dir 字段，追加它
            if (!doc.RootElement.TryGetProperty("db_dir", out _))
                jsonWriter.WriteString("db_dir", dbDir);
            jsonWriter.WriteEndObject();
        }
        await File.WriteAllBytesAsync(configPath, writer.ToArray());
        log($"已恢复自定义数据目录配置：{dbDir}");
    }

    /// <summary>UI 手动设置微信数据目录（写入 config.json 的 db_dir）。</summary>
    public async Task SetCustomDataDirAsync(string dbDir)
    {
        var configPath = GetConfigPath();
        await WriteDataDirToConfigAsync(configPath, dbDir, _ => { });
    }

    /// <summary>
    /// 自动检测微信 4.x 数据目录（返回含数据库的 db_storage 目录完整路径）。
    /// 依次检查：默认 Documents、OneDrive 重定向、注册表真实 Documents、微信旧版注册表、全盘扫描。
    /// </summary>
    public static string? DetectWeChatDataDir(Action<string>? log = null)
    {
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        // 1) 默认 Documents\xwechat_files
        roots.Add(Path.Combine(userProfile, "Documents", "xwechat_files"));
        // 2) OneDrive 重定向的 Documents
        foreach (var env in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
        {
            var od = Environment.GetEnvironmentVariable(env);
            if (!string.IsNullOrWhiteSpace(od))
                roots.Add(Path.Combine(od, "Documents", "xwechat_files"));
        }
        // 3) 注册表 User Shell Folders\Personal（真实 Documents 路径，兼容 OneDrive 重定向）
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");
            var personal = key?.GetValue("Personal") as string;
            if (!string.IsNullOrWhiteSpace(personal))
            {
                var expanded = Environment.ExpandEnvironmentVariables(personal);
                roots.Add(Path.Combine(expanded, "xwechat_files"));
            }
        }
        catch { /* 忽略注册表读取失败 */ }

        // 4) 微信旧版注册表 FileSavePath
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Tencent\WeChat");
            var savePath = key?.GetValue("FileSavePath") as string;
            if (!string.IsNullOrWhiteSpace(savePath))
            {
                var expanded = Environment.ExpandEnvironmentVariables(savePath);
                roots.Add(Path.Combine(expanded, "xwechat_files"));
                roots.Add(Path.Combine(expanded, "WeChat Files"));
            }
        }
        catch { /* 忽略 */ }

        // 5) 全盘扫描 xwechat_files（固定盘，深度 ≤ 3）
        try
        {
            foreach (var drive in DriveInfo.GetDrives()
                         .Where(d => d.IsReady && d.DriveType == DriveType.Fixed))
            {
                foreach (var root in ScanForXwechatFiles(drive.RootDirectory.FullName, 0, 3))
                    roots.Add(root);
            }
        }
        catch { /* 忽略枚举失败 */ }

        var existing = roots.Where(Directory.Exists).ToList();
        if (existing.Count == 0)
        {
            log?.Invoke("常见位置与全盘扫描均未发现 xwechat_files 目录");
            return null;
        }

        // 在候选根目录下找账号目录（含 db_storage 且内有 .db），取最新
        string? best = null;
        var bestTime = DateTime.MinValue;
        foreach (var root in existing)
        {
            foreach (var accountDir in SafeEnumerateDirectories(root))
            {
                if (string.Equals(Path.GetFileName(accountDir), "all_users", StringComparison.OrdinalIgnoreCase))
                    continue;
                var dbStorage = Path.Combine(accountDir, "db_storage");
                if (!Directory.Exists(dbStorage)) continue;
                try
                {
                    if (!Directory.EnumerateFiles(dbStorage, "*.db", SearchOption.AllDirectories).Any())
                        continue;
                }
                catch { continue; }

                var t = Directory.GetLastWriteTime(accountDir);
                if (t > bestTime) { bestTime = t; best = dbStorage; }
            }
        }

        if (best is null)
        {
            log?.Invoke("找到 xwechat_files 目录，但未发现含数据库的账号目录");
            return null;
        }
        log?.Invoke($"检测到微信数据目录：{best}");
        return best;
    }

    /// <summary>
    /// 密钥提取失败时尝试应用层恢复（兼容微信 4.1.12+）：
    /// 内存扫描提取 rawKey → 写入 all_keys.json/config → 重试 init → 失败则应用层解密到缓存目录。
    /// 返回 true 表示已完成初始化。
    /// </summary>
    private async Task<bool> TryRecoverKeyAsync(string configPath, string dataDir, Action<string> log,
        Action<LoadProgressUpdate>? progress, LoadProgressTracker tracker, CancellationToken cancellationToken)
    {
        var dbStorage = ResolveDbStorageDir(dataDir);
        var verifyDb = FindVerifyDb(dbStorage);
        if (verifyDb is null)
        {
            log("数据目录中未找到可校验的加密数据库");
            return false;
        }

        log("正在扫描微信进程内存提取密钥（兼容微信 4.1.12+）…");
        progress?.Invoke(tracker.Warmup("正在扫描内存提取密钥…"));
        var rawKey = WeChatKeyExtractor.ExtractRawKey(verifyDb, log, cancellationToken);
        if (rawKey is null)
        {
            log("未能从内存提取密钥。请确认：微信已登录并保持运行；已以管理员身份运行本程序；若仍失败，可能是微信版本过新（>4.1.11）。");
            return false;
        }

        await WriteKeysAsync(configPath, dbStorage!, rawKey, log);

        // 重新初始化（不带 --force，期望 wx-cli 读取已写入的密钥）
        log("密钥已写入，重新初始化…");
        try
        {
            await RunAsync(["init"], InitTimeoutSeconds, log, cancellationToken);
            return true;
        }
        catch (Exception ex)
        {
            log($"带密钥初始化失败：{ex.Message}");
        }

        // 兜底：应用层解密全部数据库到 wx-cli 缓存目录
        log("正在尝试应用层解密数据库到缓存目录…");
        progress?.Invoke(tracker.Warmup("正在应用层解密数据库…"));
        var cacheDir = Path.Combine(
            Path.GetDirectoryName(configPath)!,
            "cache", AccountNameFromDir(dbStorage!), "db_storage");
        try
        {
            var count = DecryptAllTo(rawKey, dbStorage!, cacheDir, log, cancellationToken);
            log($"已解密 {count} 个数据库到 {cacheDir}");
        }
        catch (Exception ex)
        {
            log($"应用层解密失败：{ex.Message}");
            return false;
        }

        try
        {
            await RunAsync(["init"], InitTimeoutSeconds, log, cancellationToken);
            return true;
        }
        catch (Exception ex)
        {
            log($"缓存解密后初始化仍失败：{ex.Message}");
            return false;
        }
    }

    /// <summary>将 rawKey 派生的各库加密密钥写入 all_keys.json，并更新 config.json 的 keys_file/your_wxid。</summary>
    private static async Task WriteKeysAsync(string configPath, string dbStorageDir, byte[] rawKey, Action<string> log)
    {
        var keys = new Dictionary<string, object>();
        foreach (var dbPath in Directory.EnumerateFiles(dbStorageDir, "*.db", SearchOption.AllDirectories))
        {
            var salt = WeChatDbCrypto.ReadSalt(dbPath);
            if (salt is null) continue;
            var encKey = WeChatDbCrypto.DeriveEncKey(rawKey, salt);
            var rel = Path.GetRelativePath(dbStorageDir, dbPath).Replace('\\', '/');
            keys[rel] = new { enc_key = Convert.ToHexString(encKey).ToLowerInvariant() };
        }

        var keysFile = Path.Combine(Path.GetDirectoryName(configPath)!, "all_keys.json");
        await File.WriteAllTextAsync(keysFile,
            JsonSerializer.Serialize(keys, new JsonSerializerOptions { WriteIndented = true }));
        log($"应用层密钥已写入：{keysFile}（{keys.Count} 个库）");

        await UpdateConfigFieldsAsync(configPath, new Dictionary<string, string>
        {
            ["keys_file"] = keysFile,
            ["your_wxid"] = AccountNameFromDir(dbStorageDir),
        }, log);
    }

    /// <summary>应用层解密 db_storage 下全部数据库到目标目录（保持相对结构）。</summary>
    private static int DecryptAllTo(byte[] rawKey, string dbStorageDir, string destDir, Action<string> log, CancellationToken ct)
    {
        var count = 0;
        foreach (var dbPath in Directory.EnumerateFiles(dbStorageDir, "*.db", SearchOption.AllDirectories))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var rel = Path.GetRelativePath(dbStorageDir, dbPath);
                var dest = Path.Combine(destDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                var plain = WeChatDbCrypto.DecryptDatabase(rawKey, dbPath);
                File.WriteAllBytes(dest, plain);
                count++;
            }
            catch (Exception ex)
            {
                log($"解密失败：{Path.GetFileName(dbPath)}（{ex.Message}）");
            }
        }
        return count;
    }

    private static string? ResolveDbStorageDir(string dataDir)
    {
        if (Directory.Exists(Path.Combine(dataDir, "db_storage")))
            return Path.Combine(dataDir, "db_storage");
        if (Path.GetFileName(dataDir).Equals("db_storage", StringComparison.OrdinalIgnoreCase)
            && Directory.Exists(dataDir))
            return dataDir;
        foreach (var account in SafeEnumerateDirectories(dataDir))
        {
            var dbStorage = Path.Combine(account, "db_storage");
            if (Directory.Exists(dbStorage)) return dbStorage;
        }
        return Directory.Exists(dataDir) ? dataDir : null;
    }

    /// <summary>选择用于密钥校验的数据库（优先消息库，其次任意最大的 .db）。</summary>
    private static string? FindVerifyDb(string? dbStorageDir)
    {
        if (string.IsNullOrEmpty(dbStorageDir) || !Directory.Exists(dbStorageDir)) return null;
        foreach (var rel in new[]
                 {
                     @"message\message_0.db",
                     @"session\session.db",
                     @"favorite\favorite_fts.db",
                     @"head_image\head_image.db",
                 })
        {
            var p = Path.Combine(dbStorageDir, rel);
            if (File.Exists(p) && new FileInfo(p).Length >= WeChatDbCrypto.PageSize) return p;
        }
        try
        {
            return Directory.EnumerateFiles(dbStorageDir, "*.db", SearchOption.AllDirectories)
                .Where(f => new FileInfo(f).Length >= WeChatDbCrypto.PageSize)
                .OrderByDescending(f => new FileInfo(f).Length)
                .FirstOrDefault();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>从 db_storage 路径提取账号目录名（如 wxid_xxx_xxxx）。</summary>
    private static string AccountNameFromDir(string dbStorageDir)
    {
        var dir = dbStorageDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Path.GetFileName(dir).Equals("db_storage", StringComparison.OrdinalIgnoreCase))
            dir = Path.GetDirectoryName(dir) ?? dir;
        return Path.GetFileName(dir);
    }

    /// <summary>写 db_dir 到 config.json（不存在则创建）。</summary>
    private static async Task WriteDataDirToConfigAsync(string configPath, string dbDir, Action<string> log)
    {
        var dir = Path.GetDirectoryName(configPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        if (!File.Exists(configPath))
        {
            await File.WriteAllTextAsync(configPath,
                JsonSerializer.Serialize(new { db_dir = dbDir },
                    new JsonSerializerOptions { WriteIndented = true }));
            log($"已创建配置并写入数据目录：{configPath}");
            return;
        }
        await UpdateConfigFieldsAsync(configPath, new Dictionary<string, string> { ["db_dir"] = dbDir }, log);
    }

    /// <summary>合并更新 config.json 中的字符串字段（保留其他字段）。</summary>
    private static async Task UpdateConfigFieldsAsync(string configPath, IReadOnlyDictionary<string, string> updates, Action<string> log)
    {
        using var doc = JsonDocument.Parse(await File.ReadAllTextAsync(configPath));
        var writer = new MemoryStream();
        using (var jsonWriter = new Utf8JsonWriter(writer, new JsonWriterOptions { Indented = true }))
        {
            jsonWriter.WriteStartObject();
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (updates.TryGetValue(prop.Name, out var newValue))
                    jsonWriter.WriteString(prop.Name, newValue);
                else
                    prop.WriteTo(jsonWriter);
            }
            foreach (var (name, value) in updates)
            {
                if (!doc.RootElement.TryGetProperty(name, out _))
                    jsonWriter.WriteString(name, value);
            }
            jsonWriter.WriteEndObject();
        }
        await File.WriteAllBytesAsync(configPath, writer.ToArray());
        log($"已更新配置：{string.Join("、", updates.Keys)}");
    }

    /// <summary>深度受限地枚举目录，权限错误静默跳过。</summary>
    private static IEnumerable<string> ScanForXwechatFiles(string dir, int depth, int maxDepth)
    {
        if (depth > maxDepth) yield break;
        IEnumerable<string> subDirs;
        try { subDirs = Directory.EnumerateDirectories(dir); }
        catch { yield break; }

        foreach (var sub in subDirs)
        {
            var name = Path.GetFileName(sub);
            if (name.Equals("xwechat_files", StringComparison.OrdinalIgnoreCase))
            {
                yield return sub;
                continue;
            }
            if (name is "Windows" or "$Recycle.Bin" or "System Volume Information" or "Recovery" or "Program Files" or "Program Files (x86)")
                continue;
            foreach (var found in ScanForXwechatFiles(sub, depth + 1, maxDepth))
                yield return found;
        }
    }

    private static IEnumerable<string> SafeEnumerateDirectories(string dir)
    {
        try { return Directory.EnumerateDirectories(dir); }
        catch { return []; }
    }

    public async Task<IReadOnlyList<ContactItem>> LoadSessionsAsync(
        Action<string> log,
        Action<LoadProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var tracker = new LoadProgressTracker();
        tracker.Reset();
        progress?.Invoke(tracker.Estimated("正在连接 wx-cli…"));
        log("正在加载会话列表（数据量大时请耐心等待）…");

        using var tickCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _ = RunProgressTicker(tickCts.Token, tracker, progress, "正在读取会话数据…");

        try
        {
            // Windows wx-cli sessions 仅支持 limit，无 offset；使用超大 limit 且带超时兜底
            var output = await RunAsync(
                ["sessions", "--json", "-n", "999999"],
                SessionsTimeoutSeconds,
                log,
                cancellationToken);

            tickCts.Cancel();

            var items = ParseSessions(output);
            var count = items.Count;
            progress?.Invoke(tracker.Actual(count, count, $"已加载 {count} 个会话"));
            progress?.Invoke(tracker.Complete($"已加载 {count} 个会话"));
            log($"已加载 {count} 个会话");
            return items;
        }
        finally
        {
            tickCts.Cancel();
        }
    }

    public async Task<int> ExportAsync(
        ContactItem contact,
        string outputDir,
        bool includeMedia = false,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        log ??= _ => { };
        Directory.CreateDirectory(outputDir);
        // 始终使用唯一的 wxid/username 作为查询条件，避免 DisplayName 不唯一导致导出错位
        var query = contact.Id;
        log($"导出：{contact.DisplayName}（{contact.Id}）{(includeMedia ? "（含媒体）" : "")}");

        var txtPath = Path.Combine(outputDir, "chat.txt");
        var jsonPath = Path.Combine(outputDir, "chat.json");
        var csvPath = Path.Combine(outputDir, "chat.csv");

        await RunAsync([
            "export", query,
            "--format", "txt",
            "-o", txtPath,
            "--limit", "999999"
        ], ExportTimeoutSeconds, log, cancellationToken);

        await RunAsync([
            "export", query,
            "--format", "json",
            "-o", jsonPath,
            "--limit", "999999"
        ], ExportTimeoutSeconds, log, cancellationToken);

        if (includeMedia)
        {
            var mdPath = Path.Combine(outputDir, "chat.md");
            try
            {
                await RunAsync([
                    "export", query,
                    "--format", "markdown",
                    "-o", mdPath,
                    "--limit", "999999"
                ], ExportTimeoutSeconds, log, cancellationToken);
            }
            catch (Exception ex)
            {
                log($"媒体导出提示：Markdown/附件导出未完成（{ex.Message}）");
            }

            await EmojiExporter.ExportEmojisAsync(outputDir, log, cancellationToken);
            await ImageExporter.ExportImagesAsync(outputDir, log, cancellationToken);
        }

        var count = await WriteCsvFromJsonAsync(jsonPath, csvPath);
        if (count == 0)
            count = CountMessagesInJsonFile(jsonPath);
        if (count == 0 && File.Exists(txtPath))
            count = CountTxtMessages(txtPath);

        if (count > 0)
            log($"共导出 {count} 条消息");
        else
            log("警告：导出目录中未找到消息记录，请查看上方 wx-cli 日志");

        return count;
    }

    private static async Task RunProgressTicker(
        CancellationToken cancellationToken,
        LoadProgressTracker tracker,
        Action<LoadProgressUpdate>? progress,
        string message)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                progress?.Invoke(tracker.Estimated(message));
                await Task.Delay(500, cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
            // expected
        }
    }

    private static string GetConfigPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".wx-cli", "config.json");
    }

    private async Task<string> RunAsync(
        IReadOnlyList<string> args,
        int? timeoutSeconds,
        Action<string> log,
        CancellationToken cancellationToken)
        => await RunAsyncCore(args, timeoutSeconds, log, cancellationToken, allowDaemonRecovery: true);

    private async Task<string> RunAsyncCore(
        IReadOnlyList<string> args,
        int? timeoutSeconds,
        Action<string> log,
        CancellationToken cancellationToken,
        bool allowDaemonRecovery)
    {
        var psi = new ProcessStartInfo
        {
            FileName = ExecutablePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in args)
            psi.ArgumentList.Add(arg);

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stdout.AppendLine(e.Data);
            log(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stderr.AppendLine(e.Data);
            if (!string.IsNullOrWhiteSpace(e.Data))
                log(e.Data);
        };

        if (!process.Start())
            throw new InvalidOperationException("无法启动 wx-cli");

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeoutSeconds is int seconds)
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(seconds));

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            try { process.Kill(entireProcessTree: true); } catch { /* ignore */ }
            // daemon 拉起失败时 wx.exe 可能不退出（挂起），超时 kill 后同样清理残留并重试一次
            if (allowDaemonRecovery && IsDaemonStartupFailure(stdout + "\n" + stderr))
            {
                log("检测到 wx-daemon 启动异常（命令挂起），正在清理残留 daemon 并重试…");
                await RecoverDaemonAsync(log, cancellationToken);
                return await RunAsyncCore(args, timeoutSeconds, log, cancellationToken, allowDaemonRecovery: false);
            }
            throw new InvalidOperationException(
                timeoutSeconds is int s
                    ? $"wx-cli 执行超时（>{s} 秒）。若尚未准备数据，请先点击「准备数据」；数据库较大时请耐心等待后重试。"
                    : "wx-cli 执行已取消。");
        }

        var combined = stdout + "\n" + stderr;
        if (process.ExitCode != 0)
        {
            // wx.exe 内部拉起 wx-daemon 失败（启动超时/无法启动）：清理残留后重试一次
            if (allowDaemonRecovery && IsDaemonStartupFailure(combined))
            {
                log("检测到 wx-daemon 启动异常，正在清理残留 daemon 并重试…");
                await RecoverDaemonAsync(log, cancellationToken);
                return await RunAsyncCore(args, timeoutSeconds, log, cancellationToken, allowDaemonRecovery: false);
            }
            throw new InvalidOperationException(TrimFailureOutput(combined) + BuildDaemonLogHint(combined));
        }

        return combined.ToString();
    }

    /// <summary>判断 wx-cli 输出是否为「wx-daemon 启动失败」（闭源 wx.exe 内部错误，非应用层文案）。</summary>
    private static bool IsDaemonStartupFailure(string output) =>
        output.Contains(DaemonStartTimeoutMarker, StringComparison.Ordinal)
        || output.Contains(DaemonStartFailedMarker, StringComparison.Ordinal);

    /// <summary>
    /// 清理残留 wx-daemon：先 wx.exe daemon stop（干净停止），再删除 %APPDATA%\Tencent\xwechat\config\ 下
    /// 的 daemon.pid / daemon.sock 残留（pid 残留会让新 daemon 误判"已运行"而连不上管道），最后等待管道释放。
    /// </summary>
    private async Task RecoverDaemonAsync(Action<string> log, CancellationToken cancellationToken)
    {
        try
        {
            log("正在停止残留 wx-daemon…");
            await RunAsyncCore(["daemon", "stop"], 20, log, cancellationToken, allowDaemonRecovery: false);
        }
        catch (Exception ex)
        {
            log($"停止残留 wx-daemon 失败（忽略）：{ex.Message}");
        }

        var cfgDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Tencent", "xwechat", "config");
        foreach (var name in new[] { "daemon.pid", "daemon.sock" })
        {
            try
            {
                var p = Path.Combine(cfgDir, name);
                if (File.Exists(p))
                {
                    File.Delete(p);
                    log($"已清理残留文件：{p}");
                }
            }
            catch (Exception ex)
            {
                log($"清理残留文件失败：{name}（{ex.Message}）");
            }
        }

        await Task.Delay(1500, cancellationToken);
    }

    /// <summary>daemon 启动失败时附加 %APPDATA%\Tencent\xwechat\config\daemon.log 尾部，便于用户直接定位根因。</summary>
    private static string BuildDaemonLogHint(string failureOutput)
    {
        if (!IsDaemonStartupFailure(failureOutput))
            return "";
        var logPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Tencent", "xwechat", "config", "daemon.log");
        try
        {
            if (!File.Exists(logPath))
                return $"\n\n提示：wx-daemon 日志不存在（{logPath}）。常见原因：残留 daemon.pid 或杀毒软件拦截 wx-daemon 子进程。";
            var lines = File.ReadAllLines(logPath)
                .Where(l => !string.IsNullOrWhiteSpace(l))
                .TakeLast(12);
            var tail = string.Join("\n", lines);
            return $"\n\n—— wx-daemon 日志尾部（{logPath}）——\n{tail}";
        }
        catch (Exception ex)
        {
            return $"\n\n提示：读取 wx-daemon 日志失败（{ex.Message}）。日志位置：{logPath}";
        }
    }

    private static string TrimFailureOutput(string text)
    {
        var lines = text
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(l => !l.StartsWith("note:", StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (lines.Count == 0)
            return "wx-cli 执行失败";

        // 显示最后 3 行错误信息，便于定位问题
        var tail = lines.Count > 3 ? lines[^3..] : lines;
        return string.Join(" | ", tail);
    }

    private static List<ContactItem> ParseSessions(string output)
    {
        var json = ExtractJson(output);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        IEnumerable<JsonElement> rows = root.ValueKind switch
        {
            JsonValueKind.Array => root.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("results", out var results) => results.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("items", out var items) => items.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("sessions", out var sessions) => sessions.EnumerateArray(),
            JsonValueKind.Object => [root],
            _ => []
        };

        var list = new List<ContactItem>();
        foreach (var row in rows)
        {
            var username = GetString(row, "username", "id", "wxid") ?? "";
            if (string.IsNullOrWhiteSpace(username) || username == "@placeholder_foldgroup")
                continue;

            var display = GetString(row, "display", "display_name", "name", "title") ?? username;
            display = CleanDisplayName(display, username);
            var summary = (GetString(row, "summary", "last_message", "preview") ?? "")
                .Replace('\n', ' ');
            var ts = GetLong(row, "sort_timestamp", "last_timestamp", "timestamp", "time") ?? 0;
            var chatType = GetString(row, "chat_type", "type") ?? "";

            list.Add(new ContactItem
            {
                Id = username,
                DisplayName = display,
                NickName = display,
                Remark = "",
                Kind = ResolveKind(username, chatType),
                LastTime = FormatTime(ts),
                LastTimestamp = ts,
                Summary = summary
            });
        }

        return list.OrderByDescending(c => c.LastTimestamp).ToList();
    }

    private static ContactKind ResolveKind(string username, string chatType)
    {
        if (username.EndsWith("@chatroom", StringComparison.OrdinalIgnoreCase)
            || chatType.Equals("group", StringComparison.OrdinalIgnoreCase))
            return ContactKind.Group;

        if (username.StartsWith("gh_", StringComparison.OrdinalIgnoreCase)
            || chatType.Equals("official_account", StringComparison.OrdinalIgnoreCase))
            return ContactKind.Official;

        return ContactKind.Friend;
    }

    private static string CleanDisplayName(string raw, string username)
    {
        var suffixes = new[] { $"（{username}）", $"({username})" };
        foreach (var suffix in suffixes)
        {
            var idx = raw.IndexOf(suffix, StringComparison.Ordinal);
            if (idx >= 0)
                return raw[..idx].Trim();
        }
        return raw.Trim();
    }

    private static string FormatTime(long ts)
    {
        if (ts <= 0) return "";
        var seconds = ts > 9999999999 ? ts / 1000 : ts;
        var dt = DateTimeOffset.FromUnixTimeSeconds(seconds).ToOffset(TimeSpan.FromHours(8));
        return dt.ToString("yyyy-MM-dd HH:mm:ss");
    }

    private static string ExtractJson(string output)
    {
        var startObj = output.IndexOf('{');
        var startArr = output.IndexOf('[');
        int start;
        char endChar;
        if (startObj >= 0 && (startArr < 0 || startObj < startArr))
        {
            start = startObj;
            endChar = '}';
        }
        else if (startArr >= 0)
        {
            start = startArr;
            endChar = ']';
        }
        else
        {
            throw new InvalidOperationException("wx-cli 返回的数据格式无效");
        }

        var end = output.LastIndexOf(endChar);
        if (end < start)
            throw new InvalidOperationException("wx-cli 返回的数据格式无效");

        return output[start..(end + 1)];
    }

    private static string? GetString(JsonElement el, params string[] names)
    {
        foreach (var name in names)
        {
            if (el.TryGetProperty(name, out var prop) && prop.ValueKind == JsonValueKind.String)
                return prop.GetString();
        }
        return null;
    }

    private static long? GetLong(JsonElement el, params string[] names)
    {
        foreach (var name in names)
        {
            if (!el.TryGetProperty(name, out var prop)) continue;
            if (prop.ValueKind == JsonValueKind.Number && prop.TryGetInt64(out var n))
                return n;
            if (prop.ValueKind == JsonValueKind.String && long.TryParse(prop.GetString(), out var parsed))
                return parsed;
        }
        return null;
    }

    private static async Task<int> WriteCsvFromJsonAsync(string jsonPath, string csvPath)
    {
        if (!File.Exists(jsonPath))
            return 0;

        var json = await File.ReadAllTextAsync(jsonPath);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        IEnumerable<JsonElement> messages = root.ValueKind switch
        {
            JsonValueKind.Array => root.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("items", out var items) => items.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("results", out var results) => results.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("messages", out var messagesProp) => messagesProp.EnumerateArray(),
            _ => []
        };

        var rows = messages.ToList();
        if (rows.Count == 0)
            return 0;

        var sb = new StringBuilder();
        sb.Append('\uFEFF');
        sb.AppendLine("时间,发送者,类型,内容");

        foreach (var msg in rows)
        {
            var time = GetString(msg, "time", "timestamp_str") ?? FormatTime(GetLong(msg, "timestamp", "create_time") ?? 0);
            var sender = GetString(msg, "sender", "sender_display", "from") ?? "";
            var type = GetString(msg, "type", "msg_type", "type_name") ?? "";
            var content = GetString(msg, "content", "text", "message") ?? "";
            content = content.Replace("\"", "\"\"");
            sb.AppendLine($"\"{time}\",\"{sender}\",\"{type}\",\"{content}\"");
        }

        await File.WriteAllTextAsync(csvPath, sb.ToString(), Encoding.UTF8);
        return rows.Count;
    }

    private static int CountMessagesInJsonFile(string jsonPath)
    {
        if (!File.Exists(jsonPath))
            return 0;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
            var root = doc.RootElement;

            if (root.ValueKind == JsonValueKind.Array)
                return root.GetArrayLength();

            if (root.TryGetProperty("conversation", out var conversation)
                && conversation.TryGetProperty("message_count", out var mc)
                && mc.TryGetInt32(out var messageCount))
                return messageCount;

            foreach (var key in new[] { "items", "messages", "results" })
            {
                if (root.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                    return arr.GetArrayLength();
            }

            if (root.TryGetProperty("paging", out var paging)
                && paging.TryGetProperty("returned", out var returned)
                && returned.TryGetInt32(out var n))
                return n;
        }
        catch
        {
            // ignore parse errors
        }

        return 0;
    }

    private static int CountTxtMessages(string txtPath)
    {
        var lines = File.ReadLines(txtPath).ToList();
        var bracketCount = lines.Count(line => line.StartsWith('['));
        if (bracketCount > 0)
            return bracketCount;

        var header = lines.FirstOrDefault(l => l.Contains('条') && l.Contains("消息"));
        if (header is not null)
        {
            var digits = new string(header.Where(char.IsDigit).ToArray());
            if (int.TryParse(digits, out var count) && count > 0)
                return count;
        }

        return 0;
    }
}
