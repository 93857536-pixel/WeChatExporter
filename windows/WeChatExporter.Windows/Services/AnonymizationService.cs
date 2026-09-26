using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>
/// 脱敏导出（SPEC §3）：把导出目录文本产物中的真实名称替换为 用户A/B/… 代号，
/// 可选 PII 模糊化（手机号 138****5678 / 身份证保头6尾2 / 邮箱保首字符+***@域名）。
/// 映射写入 anonymization-map.json；keepMapping=false 时导出完成后删除该文件。
/// 与 macOS Services/AnonymizationService.swift 对称实现（双端行为一致）。
/// </summary>
public static class AnonymizationService
{
    public const string MapFileName = "anonymization-map.json";
    private static readonly HashSet<string> TextExtensions =
        new(StringComparer.OrdinalIgnoreCase) { "txt", "csv", "json", "html", "epub" };

    public sealed record Settings(bool MaskPii = true, bool KeepMapping = true);

    public sealed record MappingFile(int Version, string GeneratedAt, Dictionary<string, string> NameMap, string Note);

    // MARK: - 代号序列（0→A … 25→Z，26→AA …）

    private static string Code(int index)
    {
        var n = index;
        var chars = new Stack<char>();
        while (true)
        {
            chars.Push((char)('A' + n % 26));
            n /= 26;
            if (n == 0) break;
            n -= 1;
        }
        return new string([.. chars]);
    }

    // MARK: - 主流程

    /// <summary>对目录下全部文本产物做脱敏。返回替换表（原名→代号）。</summary>
    public static Dictionary<string, string> Anonymize(
        string baseDir,
        IReadOnlyCollection<string> names,
        Settings settings,
        Action<string>? log)
    {
        // 1) 确定性代号：按名称排序分配 A-Z，超 26 转 AA-AB…
        var sorted = names.Where(n => !string.IsNullOrEmpty(n)).Distinct().OrderBy(n => n, StringComparer.Ordinal).ToList();
        var nameMap = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = 0; i < sorted.Count; i++)
            nameMap[sorted[i]] = "用户" + Code(i);

        // 2) 名称替换：长名优先（防止「林琝淏科技」被「林琝淏」先替换掉）
        var ordered = nameMap.OrderByDescending(kv => kv.Key.Length).ToList();

        var filesTouched = 0;
        var scanned = 0;
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(baseDir, "*", SearchOption.AllDirectories); }
        catch { files = []; }

        foreach (var file in files)
        {
            var ext = Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
            if (!TextExtensions.Contains(ext)) continue;
            string text;
            try { text = File.ReadAllText(file); }
            catch { continue; }
            var before = text.Length;

            // 先 PII（避免与名称替换互相干扰）
            if (settings.MaskPii)
            {
                text = MaskPhone(text);
                text = MaskIdCard(text);
                text = MaskEmail(text);
            }
            foreach (var (original, alias) in ordered)
            {
                text = text.Replace(original, alias);
            }
            if (text.Length != before)
            {
                try
                {
                    File.WriteAllText(file, text, new System.Text.UTF8Encoding(false));
                    filesTouched++;
                }
                catch (Exception ex)
                {
                    log?.Invoke($"脱敏写入失败：{Path.GetFileName(file)}（{ex.Message}）");
                }
            }
            scanned++;
        }

        // 3) 写映射文件
        var mapPath = Path.Combine(baseDir, MapFileName);
        var payload = new MappingFile(
            1,
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            nameMap,
            "删除此文件即不可逆；代号按名称排序确定性分配");
        try
        {
            File.WriteAllText(mapPath,
                JsonSerializer.Serialize(payload, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true }),
                new System.Text.UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            log?.Invoke($"映射文件写入失败：{ex.Message}");
        }
        if (!settings.KeepMapping)
        {
            try { if (File.Exists(mapPath)) File.Delete(mapPath); } catch { /* ignore */ }
        }

        log?.Invoke($"脱敏完成：{filesTouched} 个文件（{scanned} 个文本产物扫描），代号 {nameMap.Count} 个"
            + (settings.MaskPii ? "，PII 已模糊化" : "")
            + (settings.KeepMapping ? "，映射文件已保留（可逆）" : "，映射已销毁（不可逆）"));
        return nameMap;
    }

    // MARK: - 收集目录中出现的名称（从 chat.json 的 sender 字段）

    public static HashSet<string> CollectNames(string baseDir)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(baseDir, "chat.json", SearchOption.AllDirectories); }
        catch { return names; }

        foreach (var file in files)
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                List<JsonElement> rows;
                if (doc.RootElement.ValueKind == JsonValueKind.Array)
                {
                    rows = doc.RootElement.EnumerateArray().ToList();
                }
                else if (doc.RootElement.ValueKind == JsonValueKind.Object)
                {
                    rows = [];
                    foreach (var key in new[] { "items", "messages", "results" })
                    {
                        if (doc.RootElement.TryGetProperty(key, out var a) && a.ValueKind == JsonValueKind.Array)
                        {
                            rows = a.EnumerateArray().ToList();
                            break;
                        }
                    }
                }
                else
                {
                    continue;
                }

                foreach (var row in rows)
                {
                    var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
                    if (GetString(source, "sender") is { } s && s != "系统" && s != "未知")
                        names.Add(s);
                }
                // 会话目录名本身也是名称（单文件 HTML 标题里会出现）
                var dirName = Path.GetFileName(Path.GetDirectoryName(file));
                if (!string.IsNullOrWhiteSpace(dirName)) names.Add(dirName);
            }
            catch { /* ignore */ }
        }
        return names;
    }

    // MARK: - PII 模糊化（正则）

    private static string MaskPhone(string s)
    {
        // 11 位，1[3-9] 开头 → 138****5678
        var re = new Regex(@"(?<!\d)(1[3-9]\d)(\d{4})(\d{4})(?!\d)");
        return re.Replace(s, m => m.Groups[1].Value + "****" + m.Groups[3].Value);
    }

    private static string MaskIdCard(string s)
    {
        // 18 位 → 保留前 6 位 + 后 2 位，中间 *
        var re = new Regex(@"(?<!\d)(\d{6})\d{8}(\d{3}[\dXx])(?!\d)");
        return re.Replace(s, m => m.Groups[1].Value + new string('*', 8) + m.Groups[2].Value);
    }

    private static string MaskEmail(string s)
    {
        // 邮箱 → 保留首字符 + *** + @域名
        var re = new Regex(@"([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)");
        return re.Replace(s, m => m.Groups[1].Value + "***@" + m.Groups[2].Value);
    }

    private static string? GetString(JsonElement el, string key)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        if (el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
        {
            var s = v.GetString();
            if (!string.IsNullOrEmpty(s)) return s;
        }
        return null;
    }
}
