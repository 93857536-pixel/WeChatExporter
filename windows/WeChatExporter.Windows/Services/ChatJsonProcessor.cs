using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

public sealed record ExportPreviewResult(
    int ContactCount,
    int MessageCount,
    int MediaCount,
    long EstimatedBytes,
    IReadOnlyDictionary<string, int> ByType)
{
    public string EstimatedSizeText
    {
        get
        {
            if (EstimatedBytes < 1024) return $"{EstimatedBytes} B";
            if (EstimatedBytes < 1024 * 1024) return $"{EstimatedBytes / 1024.0:F1} KB";
            if (EstimatedBytes < 1024L * 1024L * 1024L) return $"{EstimatedBytes / 1024.0 / 1024.0:F1} MB";
            return $"{EstimatedBytes / 1024.0 / 1024.0 / 1024.0:F2} GB";
        }
    }

    public string SummaryText
    {
        get
        {
            var typeLine = string.Join(" · ", ByType.OrderBy(kv => kv.Key).Select(kv => $"{kv.Key} {kv.Value}"));
            var baseLine = $"会话 {ContactCount} 个 · 消息约 {MessageCount} 条 · 媒体约 {MediaCount} 个 · 预估 {EstimatedSizeText}";
            return string.IsNullOrWhiteSpace(typeLine) ? baseLine : $"{baseLine}\n类型分布：{typeLine}";
        }
    }
}

public sealed class ChatJsonFilterOptions
{
    public long? SinceUnix { get; init; }
    public long? UntilUnix { get; init; }
    public HashSet<string> EnabledTypes { get; init; } =
        MessageTypeFilterInfo.AllIds().ToHashSet(StringComparer.OrdinalIgnoreCase);

    public bool FilterTypes
    {
        get
        {
            if (EnabledTypes.Count == 0) return false;
            var all = MessageTypeFilterInfo.AllIds();
            return EnabledTypes.Count < all.Count || all.Any(id => !EnabledTypes.Contains(id));
        }
    }
}

/// <summary>Post-processes wx-cli chat.json exports without changing the talker metadata.</summary>
public static class ChatJsonProcessor
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true
    };

    public static int ApplyFilters(string jsonPath, ChatJsonFilterOptions options, Action<string>? log = null)
    {
        if (!System.IO.File.Exists(jsonPath)) return 0;
        var root = JsonNode.Parse(System.IO.File.ReadAllText(jsonPath));
        if (root is null) return 0;

        var array = ExtractRows(root, out _);
        if (array is null) return 0;

        var original = array.Count;
        var kept = new List<JsonNode?>();
        foreach (var row in array)
        {
            if (row is not null && Passes(row, options))
                kept.Add(row.DeepClone());
        }

        if (kept.Count != original)
        {
            array.Clear();
            foreach (var row in kept)
                array.Add(row);
            System.IO.File.WriteAllText(jsonPath, root.ToJsonString(WriteOptions), Encoding.UTF8);
            log?.Invoke($"已按设置过滤消息：{original} → {kept.Count}");
        }

        RewriteTxt(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(jsonPath) ?? "", "chat.txt"), kept);
        return kept.Count;
    }

    public static void ApplyNicknameMap(string jsonPath, IReadOnlyDictionary<string, string> map, Action<string>? log = null)
    {
        if (map.Count == 0 || !System.IO.File.Exists(jsonPath)) return;
        var root = JsonNode.Parse(System.IO.File.ReadAllText(jsonPath));
        if (root is null) return;
        var array = ExtractRows(root, out _);
        if (array is null) return;

        var changed = 0;
        foreach (var row in array)
        {
            if (row is not JsonObject obj) continue;
            var nested = obj["message"] as JsonObject;
            var raw = GetString(obj, "sender", "from") ?? (nested is null ? null : GetString(nested, "sender", "from"));
            if (string.IsNullOrWhiteSpace(raw)) continue;

            if (!map.TryGetValue(raw, out var name)
                && !map.TryGetValue(raw.ToLowerInvariant(), out name))
                continue;
            if (string.IsNullOrWhiteSpace(name)) continue;

            if (string.IsNullOrWhiteSpace(GetString(obj, "sender_display_name")))
            {
                obj["sender_display_name"] = name;
                changed++;
            }
            if (nested is not null && string.IsNullOrWhiteSpace(GetString(nested, "sender_display_name")))
                nested["sender_display_name"] = name;
        }

        if (changed > 0)
        {
            System.IO.File.WriteAllText(jsonPath, root.ToJsonString(WriteOptions), Encoding.UTF8);
            log?.Invoke($"已应用群成员昵称映射 {changed} 处");
        }
    }

    public static ExportPreviewResult Preview(string jsonPath, string? sourceDir = null)
    {
        if (!System.IO.File.Exists(jsonPath))
            return new ExportPreviewResult(1, 0, 0, 0, new Dictionary<string, int>());

        var dataBytes = new System.IO.FileInfo(jsonPath).Length;
        var root = JsonNode.Parse(System.IO.File.ReadAllText(jsonPath));
        if (root is null)
            return new ExportPreviewResult(1, 0, 0, dataBytes, new Dictionary<string, int>());

        var array = ExtractRows(root, out _);
        if (array is null)
            return new ExportPreviewResult(1, 0, 0, dataBytes, new Dictionary<string, int>());

        var byType = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var mediaCount = 0;
        var bytes = dataBytes;
        var baseDir = sourceDir ?? System.IO.Path.GetDirectoryName(jsonPath) ?? "";

        foreach (var row in array)
        {
            if (row is null) continue;
            var source = (row["message"] as JsonObject) ?? row;
            var msgType = GetInt(source, "msg_type", "type") ?? GetInt(row, "msg_type", "type");
            var typeName = GetString(row, "type_name", "type") ?? GetString(source, "type_name", "type");
            var label = MessageTypeFilterInfo.Matching(msgType, typeName) is { } filter
                ? MessageTypeFilterInfo.Title(filter)
                : "其他";
            byType[label] = byType.TryGetValue(label, out var n) ? n + 1 : 1;

            foreach (var media in MediaFiles(row))
            {
                mediaCount++;
                var path = ResolveMediaPath(media, baseDir);
                bytes += System.IO.File.Exists(path) ? new System.IO.FileInfo(path).Length : 80_000;
            }
        }

        return new ExportPreviewResult(1, array.Count, mediaCount, bytes, byType);
    }

    public static long? LatestCreateTime(string jsonPath)
    {
        if (!System.IO.File.Exists(jsonPath)) return null;
        var root = JsonNode.Parse(System.IO.File.ReadAllText(jsonPath));
        if (root is null) return null;
        var array = ExtractRows(root, out _);
        if (array is null) return null;

        long max = 0;
        foreach (var row in array)
        {
            if (row is null) continue;
            var source = (row["message"] as JsonObject) ?? row;
            var ts = GetLong(source, "create_time", "timestamp") ?? GetLong(row, "create_time", "timestamp");
            if (ts is long value)
                max = Math.Max(max, NormalizeUnix(value));
        }
        return max > 0 ? max : null;
    }

    public static void InjectVoiceTranscripts(string jsonPath, IReadOnlyDictionary<string, string> transcripts, Action<string>? log = null)
    {
        if (transcripts.Count == 0 || !System.IO.File.Exists(jsonPath)) return;
        var root = JsonNode.Parse(System.IO.File.ReadAllText(jsonPath));
        if (root is null) return;
        var array = ExtractRows(root, out _);
        if (array is null) return;

        var hit = 0;
        foreach (var row in array)
        {
            if (row is not JsonObject obj) continue;
            var nested = obj["message"] as JsonObject;
            foreach (var media in MediaFiles(obj))
            {
                var name = System.IO.Path.GetFileName(media);
                if (!transcripts.TryGetValue(media, out var text)
                    && !transcripts.TryGetValue(name, out text))
                    continue;

                var existing = GetString(obj, "content") ?? (nested is null ? null : GetString(nested, "content")) ?? "";
                var prefix = "[语音转写] ";
                var merged = existing.Contains(prefix, StringComparison.Ordinal)
                    ? existing
                    : string.IsNullOrEmpty(existing) ? prefix + text : existing + "\n" + prefix + text;
                obj["content"] = merged;
                obj["snippet"] = merged;
                if (nested is not null)
                    nested["content"] = merged;
                hit++;
                break;
            }
        }

        if (hit > 0)
        {
            System.IO.File.WriteAllText(jsonPath, root.ToJsonString(WriteOptions), Encoding.UTF8);
            log?.Invoke($"已写入 {hit} 条语音转写");
        }
    }

    private static bool Passes(JsonNode row, ChatJsonFilterOptions options)
    {
        var source = (row["message"] as JsonObject) ?? row;
        var ts = GetLong(source, "create_time", "timestamp") ?? GetLong(row, "create_time", "timestamp");
        if (ts is long rawTs)
        {
            var normalized = NormalizeUnix(rawTs);
            if (options.SinceUnix is long since && normalized < since) return false;
            if (options.UntilUnix is long until && normalized > until) return false;
        }

        if (options.FilterTypes)
        {
            var msgType = GetInt(source, "msg_type", "type") ?? GetInt(row, "msg_type", "type");
            var typeName = GetString(row, "type_name", "type") ?? GetString(source, "type_name", "type");
            var matched = MessageTypeFilterInfo.Matching(msgType, typeName);
            if (matched is null)
                return options.EnabledTypes.Contains(MessageTypeFilterInfo.Id(MessageTypeFilter.App));
            return options.EnabledTypes.Contains(MessageTypeFilterInfo.Id(matched.Value));
        }
        return true;
    }

    private static JsonArray? ExtractRows(JsonNode root, out string? container)
    {
        container = null;
        if (root is JsonArray rootArray)
            return rootArray;

        if (root is JsonObject obj)
        {
            foreach (var key in new[] { "items", "messages", "results" })
            {
                if (obj[key] is JsonArray array)
                {
                    container = key;
                    return array;
                }
            }
        }
        return null;
    }

    private static IEnumerable<string> MediaFiles(JsonNode row)
    {
        var source = (row["message"] as JsonObject) ?? row;
        if (row["media_files"] is JsonArray media)
        {
            foreach (var item in media)
            {
                var value = item?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(value)) yield return value;
            }
        }
        else if (source["media_files"] is JsonArray nestedMedia)
        {
            foreach (var item in nestedMedia)
            {
                var value = item?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(value)) yield return value;
            }
        }
    }

    private static void RewriteTxt(string txtPath, IReadOnlyList<JsonNode?> rows)
    {
        if (string.IsNullOrWhiteSpace(txtPath)) return;
        var lines = new List<string>();
        foreach (var row in rows)
        {
            if (row is null) continue;
            var source = (row["message"] as JsonObject) ?? row;
            var time = GetString(row, "time", "timestamp_str")
                       ?? GetString(source, "time", "timestamp_str")
                       ?? "";
            var sender = GetString(row, "sender_display_name", "sender", "from")
                         ?? GetString(source, "sender_display_name", "sender")
                         ?? "";
            var content = GetString(row, "snippet", "content", "text")
                          ?? GetString(source, "snippet", "content", "text")
                          ?? "";
            lines.Add($"[{time}] {sender}: {content}");
        }
        System.IO.File.WriteAllText(txtPath, string.Join(Environment.NewLine, lines), Encoding.UTF8);
    }

    private static string ResolveMediaPath(string media, string baseDir)
    {
        if (System.IO.Path.IsPathRooted(media)) return media;
        return System.IO.Path.Combine(baseDir, media.Replace('/', System.IO.Path.DirectorySeparatorChar));
    }

    private static string? GetString(JsonNode? node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            var value = obj[key];
            if (value is null) continue;
            if (value.GetValueKind() == JsonValueKind.String)
            {
                var s = value.GetValue<string>();
                if (!string.IsNullOrEmpty(s)) return s;
            }
            else if (value.GetValueKind() == JsonValueKind.Number)
            {
                return value.ToJsonString();
            }
        }
        return null;
    }

    private static int? GetInt(JsonNode? node, params string[] keys)
    {
        var value = GetLong(node, keys);
        if (value is null) return null;
        return value > int.MaxValue || value < int.MinValue ? null : (int)value.Value;
    }

    private static long? GetLong(JsonNode? node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            var value = obj[key];
            if (value is null) continue;
            if (value.GetValueKind() == JsonValueKind.Number)
            {
                try { return value.GetValue<long>(); }
                catch { return null; }
            }
            if (value.GetValueKind() == JsonValueKind.String && long.TryParse(value.GetValue<string>(), out var parsed))
                return parsed;
        }
        return null;
    }

    private static long NormalizeUnix(long ts) => ts > 9_999_999_999 ? ts / 1000 : ts;
}
