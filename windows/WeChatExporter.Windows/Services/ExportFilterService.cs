using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 过滤导出（SPEC §4）：对导出根目录下每个会话的 chat.json/txt/csv 做行级过滤，
/// 保留 [fromDate, toDate] 区间内且命中任一关键词（不区分大小写，空=不过滤内容）的消息。
/// 与 macOS Services/ExportFilterService.swift 对称实现。
/// </summary>
public static class ExportFilterService
{
    public sealed record Result(int Kept, int Total);

    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    // MARK: - 单会话过滤（dir 下 chat.json/txt/csv 原地重写）

    public static Result FilterContactDir(
        string dir,
        string contactName,
        string fromDate,
        string toDate,
        string keywords,
        Action<string>? log)
    {
        var kw = ParseKeywords(keywords);
        var fromTs = DateToStartTimestamp(fromDate);
        var toTs = DateToEndTimestamp(toDate);
        if (fromTs is null && toTs is null && kw.Count == 0)
        {
            log?.Invoke("过滤未生效（无日期区间与关键词）");
            return new Result(0, 0);
        }

        var jsonPath = Path.Combine(dir, "chat.json");
        var rows = LoadRows(jsonPath);
        var total = rows.Count;
        var kept = FilterRows(rows, fromTs, toTs, kw);
        if (kept.Count == 0)
        {
            log?.Invoke($"过滤：{contactName} 0 / {total} 条保留（无命中）");
            return new Result(0, total);
        }

        WriteArtifacts(kept, contactName, dir, jsonPath, rows, total);
        log?.Invoke($"过滤：{contactName} 保留 {kept.Count} / {total} 条（{(fromDate.Length == 0 ? "不限起" : fromDate)} ~ {(toDate.Length == 0 ? "不限止" : toDate)}，关键词 {kw.Count} 个）");
        return new Result(kept.Count, total);
    }

    /// <summary>对导出根目录做递归过滤（无头模式 / 重跑用）。</summary>
    public static Dictionary<string, Result> Apply(
        string baseDir,
        string fromDate,
        string toDate,
        string keywords,
        Action<string>? log)
    {
        var jsonFiles = new List<string>();
        if (Directory.Exists(baseDir))
        {
            try { jsonFiles = Directory.EnumerateFiles(baseDir, "chat.json", SearchOption.AllDirectories).ToList(); }
            catch { /* ignore */ }
        }
        var results = new Dictionary<string, Result>(StringComparer.Ordinal);
        foreach (var jsonPath in jsonFiles)
        {
            var dir = Path.GetDirectoryName(jsonPath) ?? baseDir;
            var sessionName = Path.GetFileName(dir);
            if (string.IsNullOrWhiteSpace(sessionName)) sessionName = dir;
            results[sessionName] = FilterContactDir(dir, sessionName, fromDate, toDate, keywords, log);
        }
        var keptTotal = results.Values.Sum(r => r.Kept);
        var totalAll = results.Values.Sum(r => r.Total);
        log?.Invoke($"过滤完成：保留 {keptTotal} / {totalAll} 条（共 {results.Count} 个会话目录）");
        return results;
    }

    // MARK: - 核心

    public static List<string> ParseKeywords(string s)
    {
        return s.Split([',', '，', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Select(k => k.Trim().ToLowerInvariant())
            .Where(k => k.Length > 0)
            .ToList();
    }

    private static List<JsonNode> FilterRows(List<JsonNode> rows, long? fromTs, long? toTs, List<string> kw)
    {
        return rows.Where(row =>
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
            if (ts is { } t)
            {
                t = NormalizeTs(t);
                if (fromTs is { } ft && t < ft) return false;
                if (toTs is { } tt && t > tt) return false;
            }
            if (kw.Count == 0) return true;
            var content = (GetString(row, "snippet", "content", "text")
                ?? GetString(source, "content", "text") ?? "").ToLowerInvariant();
            return kw.Any(content.Contains);
        }).ToList();
    }

    // MARK: - 装载与重写

    private static List<JsonNode> LoadRows(string jsonPath)
    {
        if (!File.Exists(jsonPath)) return [];
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(jsonPath));
            if (root is JsonArray arr) return arr.Select(n => n!).ToList();
            if (root is JsonObject obj)
            {
                foreach (var key in new[] { "items", "messages", "results" })
                {
                    if (obj[key] is JsonArray a) return a.Select(n => n!).ToList();
                }
            }
        }
        catch { /* ignore */ }
        return [];
    }

    private static void WriteArtifacts(List<JsonNode> kept, string contactName, string dir, string jsonPath, List<JsonNode> original, int total)
    {
        // chat.json：保留原结构（直接数组则重写数组；外层 dict 则更新对应键）
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(jsonPath));
            if (root is JsonArray)
            {
                File.WriteAllText(jsonPath, new JsonArray([.. kept]).ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            }
            else if (root is JsonObject obj)
            {
                foreach (var key in new[] { "items", "messages", "results" })
                {
                    if (obj[key] is JsonArray)
                    {
                        obj[key] = new JsonArray([.. kept]);
                        break;
                    }
                }
                File.WriteAllText(jsonPath, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            }
        }
        catch { /* 重写失败不阻塞 */ }

        var txtPath = Path.Combine(dir, "chat.txt");
        if (File.Exists(txtPath))
        {
            try { File.WriteAllText(txtPath, RenderTxt(kept, contactName), new UTF8Encoding(false)); } catch { /* ignore */ }
        }
        var csvPath = Path.Combine(dir, "chat.csv");
        if (File.Exists(csvPath))
        {
            try { File.WriteAllText(csvPath, RenderCsv(kept), new UTF8Encoding(false)); } catch { /* ignore */ }
        }
    }

    // MARK: - 渲染（与 macOS ExportFilterService 产物格式同口径）

    private static string RenderTxt(List<JsonNode> rows, string sessionName)
    {
        var sb = new StringBuilder();
        sb.Append("微信聊天记录: ").Append(sessionName).Append("（过滤导出）\n");
        sb.Append("总消息数: ").Append(rows.Count).Append('\n');
        sb.Append("时间范围: ").Append(Fmt(FirstTimestamp(rows))).Append(" ~ ").Append(Fmt(LastTimestamp(rows))).Append('\n');
        sb.Append(new string('=', 60)).Append("\n\n");
        foreach (var row in rows)
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var time = Fmt(GetInt(source, "create_time", "timestamp"));
            var sender = GetString(row, "sender_display_name", "sender")
                ?? GetString(source, "sender_display_name", "sender") ?? "未知";
            var content = GetString(row, "snippet", "content")
                ?? GetString(source, "content") ?? "";
            sb.Append('[').Append(time).Append("] ").Append(sender).Append(": ").Append(content).Append('\n');
        }
        return sb.ToString();
    }

    private static string RenderCsv(List<JsonNode> rows)
    {
        var sb = new StringBuilder("\uFEFF时间,发送者,内容\n");
        foreach (var row in rows)
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var time = Fmt(GetInt(source, "create_time", "timestamp"));
            var sender = (GetString(row, "sender_display_name", "sender")
                ?? GetString(source, "sender_display_name", "sender") ?? "未知").Replace("\"", "\"\"");
            var content = (GetString(row, "snippet", "content")
                ?? GetString(source, "content") ?? "").Replace("\"", "\"\"");
            sb.Append('"').Append(time).Append("\",\"").Append(sender).Append("\",\"").Append(content).Append("\"\n");
        }
        return sb.ToString();
    }

    // MARK: - 工具

    private static long? DateToStartTimestamp(string s)
    {
        if (s.Length == 0) return null;
        if (!DateOnly.TryParseExact(s, "yyyy-MM-dd", out var d)) return null;
        return new DateTimeOffset(d.Year, d.Month, d.Day, 0, 0, 0, TimeSpan.FromHours(8)).ToUnixTimeSeconds();
    }

    private static long? DateToEndTimestamp(string s)
    {
        if (s.Length == 0) return null;
        if (!DateOnly.TryParseExact(s, "yyyy-MM-dd", out var d)) return null;
        return new DateTimeOffset(d.Year, d.Month, d.Day, 23, 59, 59, TimeSpan.FromHours(8)).ToUnixTimeSeconds();
    }

    private static long NormalizeTs(long ts) => ts > 100_000_000_000L ? ts / 1000 : ts;

    private static string Fmt(long? ts)
    {
        if (ts is not { } v || v <= 0) return "";
        var seconds = NormalizeTs(v);
        var utc = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
        return TimeZoneInfo.ConvertTimeFromUtc(utc, Shanghai).ToString("yyyy-MM-dd HH:mm:ss");
    }

    private static long? FirstTimestamp(List<JsonNode> rows)
    {
        long? min = null;
        foreach (var row in rows)
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
            if (ts is { } t && (min is null || t < min)) min = t;
        }
        return min;
    }

    private static long? LastTimestamp(List<JsonNode> rows)
    {
        long? max = null;
        foreach (var row in rows)
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
            if (ts is { } t && (max is null || t > max)) max = t;
        }
        return max;
    }

    private static long? GetInt(JsonNode node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            if (obj[key] is not JsonValue v) continue;
            if (v.TryGetValue<long>(out var n)) return n;
            if (v.TryGetValue<int>(out var i)) return i;
            if (v.TryGetValue<string>(out var s) && long.TryParse(s, out var p)) return p;
        }
        return null;
    }

    private static string? GetString(JsonNode node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            if (obj[key] is JsonValue v && v.TryGetValue<string>(out var s) && !string.IsNullOrEmpty(s))
                return s;
        }
        return null;
    }
}
