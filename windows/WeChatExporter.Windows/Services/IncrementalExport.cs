using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace WeChatExporter.Services;

/// <summary>
/// 增量导出：按「联系人 id + 导出目录」维护时间戳游标。
/// 导出产物（chat.json/txt/csv）过滤为只保留 timestamp > 游标的消息；
/// 无新增时清空本次产物并返回 0，调用方跳过该联系人。
/// </summary>
public static class IncrementalExport
{
    private sealed record Cursor(string ContactID, string ExportDir, long LastTimestamp, string LastRun);

    private static string CursorFile()
    {
        var dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(dir, "WeChatExporter", "export-cursors.json");
    }

    /// <summary>读取游标（不存在返回 null）。</summary>
    public static long? LoadCursor(string contactID, string exportDir)
    {
        var file = CursorFile();
        if (!File.Exists(file)) return null;
        Cursor[] all;
        try { all = JsonSerializer.Deserialize<Cursor[]>(File.ReadAllText(file)) ?? []; }
        catch { return null; }
        return all.FirstOrDefault(c => c.ContactID == contactID && c.ExportDir == exportDir)?.LastTimestamp;
    }

    /// <summary>回写游标（只保留同一键的最新记录）。</summary>
    public static void SaveCursor(string contactID, string exportDir, long lastTimestamp)
    {
        var file = CursorFile();
        Cursor[] all = [];
        if (File.Exists(file))
        {
            try { all = JsonSerializer.Deserialize<Cursor[]>(File.ReadAllText(file)) ?? []; }
            catch { all = []; }
        }
        all = all.Where(c => !(c.ContactID == contactID && c.ExportDir == exportDir)).ToArray();
        var cursor = new Cursor(contactID, exportDir, lastTimestamp, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        all = all.Append(cursor).ToArray();
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        try
        {
            File.WriteAllText(file, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* 游标写入失败不影响导出本身 */ }
    }

    /// <summary>过滤导出产物：chat.json / chat.txt / chat.csv 只保留 timestamp > after 的消息。</summary>
    public static int FilterArtifacts(string outputDir, string contactID, long after, Action<string>? log)
    {
        var jsonPath = Path.Combine(outputDir, "chat.json");
        if (!File.Exists(jsonPath))
        {
            log?.Invoke("增量导出：未找到 chat.json，跳过过滤");
            return 0;
        }

        List<JsonElement> rows = [];
        string? outerKey = null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                rows = doc.RootElement.EnumerateArray().ToList();
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                foreach (var key in new[] { "items", "messages", "results" })
                {
                    if (doc.RootElement.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                    {
                        outerKey = key;
                        rows = arr.EnumerateArray().ToList();
                        break;
                    }
                }
            }
        }
        catch
        {
            log?.Invoke("增量导出：chat.json 解析失败，跳过过滤");
            return 0;
        }

        var kept = rows.Where(r => TimestampOf(r) > after).ToList();
        if (kept.Count == 0)
        {
            // 无新增：清空本次文字产物，避免生成空 HTML
            foreach (var name in new[] { "chat.json", "chat.txt", "chat.csv" })
            {
                var p = Path.Combine(outputDir, name);
                try { if (File.Exists(p)) File.Delete(p); } catch { /* ignore */ }
            }
            log?.Invoke($"增量导出：{contactID} 无新增消息（上次游标 {after}），跳过");
            return 0;
        }

        // chat.json：保留原结构（直接数组则重写数组；外层 dict 则更新对应键）
        try
        {
            if (outerKey is null)
            {
                var json = JsonSerializer.Serialize(kept.Select(e => e.CloneDeep()).ToList());
                File.WriteAllText(jsonPath, json);
            }
            else
            {
                var raw = File.ReadAllText(jsonPath);
                var doc = JsonDocument.Parse(raw);
                // 重建：只保留目标键（过滤后），其余键原样
                var sb = new StringBuilder("{");
                var written = false;
                foreach (var prop in doc.RootElement.EnumerateObject())
                {
                    if (written) sb.Append(',');
                    if (prop.Name == outerKey)
                    {
                        sb.Append($"\"{prop.Name}\":[");
                        var first = true;
                        foreach (var k in kept)
                        {
                            if (!first) sb.Append(',');
                            sb.Append(k.GetRawText());
                            first = false;
                        }
                        sb.Append(']');
                    }
                    else
                    {
                        sb.Append($"\"{prop.Name}\":{prop.Value.GetRawText()}");
                    }
                    written = true;
                }
                sb.Append('}');
                File.WriteAllText(jsonPath, sb.ToString());
            }
        }
        catch (Exception ex)
        {
            log?.Invoke($"增量导出：chat.json 重写失败（{ex.Message}），txt/csv 保持原样");
        }

        // chat.txt / chat.csv：从过滤后的 kept 重建
        var txtPath = Path.Combine(outputDir, "chat.txt");
        if (File.Exists(txtPath))
        {
            var sb = new StringBuilder();
            sb.AppendLine("微信聊天记录（增量）");
            sb.AppendLine($"新增消息数: {kept.Count}");
            sb.AppendLine($"时间起点: {after}");
            sb.Append(new string('=', 60)).AppendLine();
            foreach (var row in kept)
            {
                sb.AppendLine($"[{TimeOf(row)}] {SenderOf(row)}: {ContentOf(row)}");
            }
            File.WriteAllText(txtPath, sb.ToString(), new UTF8Encoding(false));
        }
        var csvPath = Path.Combine(outputDir, "chat.csv");
        if (File.Exists(csvPath))
        {
            var sb = new StringBuilder("\uFEFF时间,发送者,类型,内容\n");
            foreach (var row in kept)
            {
                sb.Append($"\"{TimeOf(row)}\",\"{SenderOf(row)}\",\"{TypeOf(row)}\",\"{ContentOf(row).Replace("\"", "\"\"")}\"")
                  .AppendLine();
            }
            File.WriteAllText(csvPath, sb.ToString(), new UTF8Encoding(false));
        }

        log?.Invoke($"增量导出：{contactID} 保留新增 {kept.Count} 条（上次游标 {after}）");
        return kept.Count;
    }

    /// <summary>导出产物中 chat.json 的最大时间戳（无数据返回 0）。</summary>
    public static long MaxTimestamp(string outputDir)
    {
        var jsonPath = Path.Combine(outputDir, "chat.json");
        if (!File.Exists(jsonPath)) return 0;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
            List<JsonElement> rows = [];
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                rows = doc.RootElement.EnumerateArray().ToList();
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                var matched = false;
                foreach (var key in new[] { "items", "messages", "results" })
                {
                    if (doc.RootElement.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                    {
                        rows = arr.EnumerateArray().ToList();
                        matched = true;
                        break;
                    }
                }
                if (!matched) return 0;
            }
            else return 0;

            long maxTs = 0;
            foreach (var row in rows)
            {
                var ts = TimestampOf(row);
                if (ts > maxTs) maxTs = ts;
            }
            return maxTs;
        }
        catch { return 0; }
    }

    // MARK: - 字段提取（与 SingleFileExporter 口径一致）

    private static long TimestampOf(JsonElement row)
    {
        var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
        foreach (var el in new[] { source, row })
        {
            foreach (var key in new[] { "timestamp", "create_time" })
            {
                if (el.ValueKind != JsonValueKind.Object || !el.TryGetProperty(key, out var v)) continue;
                if (v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n)) return n;
                if (v.ValueKind == JsonValueKind.String && long.TryParse(v.GetString(), out var s)) return s;
            }
        }
        return 0;
    }

    private static string? GetStr(JsonElement el, params string[] keys)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        foreach (var key in keys)
        {
            if (el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
                && !string.IsNullOrEmpty(v.GetString()))
            {
                return v.GetString();
            }
        }
        return null;
    }

    private static string SenderOf(JsonElement row)
    {
        var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
        return GetStr(row, "sender_display_name", "sender", "from")
            ?? GetStr(source, "sender_display_name", "sender")
            ?? "未知";
    }

    private static string TimeOf(JsonElement row)
    {
        var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
        return GetStr(row, "time", "timestamp_str") ?? GetStr(source, "time", "timestamp_str") ?? "";
    }

    private static string TypeOf(JsonElement row)
    {
        var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
        return GetStr(row, "type_name", "type") ?? GetStr(source, "type_name") ?? "消息";
    }

    private static string ContentOf(JsonElement row)
    {
        var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
        return GetStr(row, "content", "text", "snippet") ?? GetStr(source, "content", "text", "snippet") ?? "";
    }
}

/// <summary>JsonElement 克隆辅助（从父文档脱离后独立序列化用）。</summary>
internal static class JsonElementExtensions
{
    public static JsonElement CloneDeep(this JsonElement element)
    {
        var doc = JsonDocument.Parse(element.GetRawText());
        return doc.RootElement.Clone();
    }
}
