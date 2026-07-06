using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

/// <summary>
/// 调用内置或系统 wx-cli（jackwener/wx-cli）完成密钥提取、解密与导出。
/// </summary>
public sealed class WxCliService
{
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

    public async Task PrepareDataAsync(Action<string> log, CancellationToken cancellationToken = default)
    {
        log("检查 wx-cli 环境…");
        var status = await RunAsync(["daemon", "status"], 30, log, cancellationToken);
        var needsInit = !status.Contains("ready", StringComparison.OrdinalIgnoreCase)
                        && !status.Contains("running", StringComparison.OrdinalIgnoreCase);

        if (needsInit || !File.Exists(GetConfigPath()))
        {
            log("正在初始化（扫描密钥并解密数据库，约 1-3 分钟）…");
            log("提示：若失败，请以管理员身份重新打开本程序。");
            await RunAsync(["init", "--force"], 300, log, cancellationToken);
        }
        else
        {
            log("使用已保存的密钥与缓存");
            await RunAsync(["init"], 180, log, cancellationToken);
        }

        log("数据准备完成");
    }

    public async Task<IReadOnlyList<ContactItem>> LoadSessionsAsync(
        Action<string> log,
        CancellationToken cancellationToken = default)
    {
        log("正在加载会话列表…");
        var output = await RunAsync(["sessions", "--json", "--limit", "10000"], 120, log, cancellationToken);
        var items = ParseSessions(output);
        log($"已加载 {items.Count} 个会话");
        return items;
    }

    public async Task<int> ExportAsync(
        ContactItem contact,
        string outputDir,
        Action<string> log,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(outputDir);
        var query = string.IsNullOrWhiteSpace(contact.DisplayName) ? contact.Id : contact.DisplayName;
        log($"导出：{contact.DisplayName}");

        var txtPath = Path.Combine(outputDir, "chat.txt");
        var jsonPath = Path.Combine(outputDir, "chat.json");
        var csvPath = Path.Combine(outputDir, "chat.csv");

        await RunAsync([
            "export", query,
            "--format", "txt",
            "-o", txtPath,
            "--limit", "999999"
        ], 600, log, cancellationToken);

        await RunAsync([
            "export", query,
            "--format", "json",
            "-o", jsonPath,
            "--limit", "999999"
        ], 600, log, cancellationToken);

        var count = await WriteCsvFromJsonAsync(jsonPath, csvPath);
        if (count == 0 && File.Exists(txtPath))
            count = CountTxtMessages(txtPath);

        return count;
    }

    private static string GetConfigPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".wx-cli", "config.json");
    }

    private async Task<string> RunAsync(
        IReadOnlyList<string> args,
        int timeoutSeconds,
        Action<string> log,
        CancellationToken cancellationToken)
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
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { /* ignore */ }
            throw new InvalidOperationException($"wx-cli 执行超时（>{timeoutSeconds}s）");
        }

        var combined = stdout + "\n" + stderr;
        if (process.ExitCode != 0)
            throw new InvalidOperationException(TrimFailureOutput(combined));

        return combined.ToString();
    }

    private static string TrimFailureOutput(string text)
    {
        var lines = text
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(l => !l.StartsWith("note:", StringComparison.OrdinalIgnoreCase))
            .ToList();
        return lines.Count > 0 ? lines[^1] : "wx-cli 执行失败";
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

    private static int CountTxtMessages(string txtPath)
    {
        return File.ReadLines(txtPath).Count(line => line.StartsWith('['));
    }
}
