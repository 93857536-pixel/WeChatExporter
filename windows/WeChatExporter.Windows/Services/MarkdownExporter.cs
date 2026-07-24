using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

public static class MarkdownExporter
{
    public static string Write(string sourceDir, string contactName, string destinationDir)
    {
        System.IO.Directory.CreateDirectory(destinationDir);
        var safe = Sanitize(contactName);
        var stamp = FileStamp();
        var outPath = System.IO.Path.Combine(destinationDir, $"{safe}_{stamp}.md");
        var jsonPath = System.IO.Path.Combine(sourceDir, "chat.json");
        var txtPath = System.IO.Path.Combine(sourceDir, "chat.txt");

        var lines = new List<string>
        {
            $"# {contactName}",
            "",
            "> 由 WeChatExporter 导出",
            ""
        };

        if (System.IO.File.Exists(jsonPath))
        {
            foreach (var row in ReadRows(jsonPath))
            {
                var source = row.TryGetProperty("message", out var nested) && nested.ValueKind == JsonValueKind.Object
                    ? nested
                    : row;
                var time = GetString(row, "time", "timestamp_str") ?? GetString(source, "time", "timestamp_str") ?? "";
                var sender = GetString(row, "sender_display_name", "sender", "from")
                             ?? GetString(source, "sender_display_name", "sender")
                             ?? "未知";
                var content = GetString(row, "snippet", "content", "text")
                              ?? GetString(source, "snippet", "content", "text")
                              ?? "";
                lines.Add($"### {time} · {sender}");
                if (!string.IsNullOrWhiteSpace(content))
                    lines.Add(content);
                foreach (var media in MediaFiles(row, source))
                    lines.Add($"- 附件：`{System.IO.Path.GetFileName(media)}`");
                lines.Add("");
            }
        }
        else if (System.IO.File.Exists(txtPath))
        {
            lines.Add("```");
            lines.Add(System.IO.File.ReadAllText(txtPath));
            lines.Add("```");
        }
        else
        {
            throw new InvalidOperationException("未找到聊天记录文件，无法生成 Markdown");
        }

        System.IO.File.WriteAllText(outPath, string.Join(Environment.NewLine, lines), Encoding.UTF8);
        return outPath;
    }

    internal static List<JsonElement> ReadRows(string jsonPath)
    {
        using var doc = JsonDocument.Parse(System.IO.File.ReadAllText(jsonPath));
        var root = doc.RootElement;
        IEnumerable<JsonElement> rows = root.ValueKind switch
        {
            JsonValueKind.Array => root.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("items", out var items) => items.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("messages", out var messages) => messages.EnumerateArray(),
            JsonValueKind.Object when root.TryGetProperty("results", out var results) => results.EnumerateArray(),
            _ => []
        };
        return rows.Select(r => r.Clone()).ToList();
    }

    internal static string? GetString(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (!element.TryGetProperty(key, out var value)) continue;
            if (value.ValueKind == JsonValueKind.String)
            {
                var s = value.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
            else if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n))
            {
                return n.ToString();
            }
        }
        return null;
    }

    internal static IEnumerable<string> MediaFiles(JsonElement row, JsonElement source)
    {
        if (row.TryGetProperty("media_files", out var media) && media.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in media.EnumerateArray())
            {
                var s = item.GetString();
                if (!string.IsNullOrWhiteSpace(s)) yield return s;
            }
        }
        else if (source.TryGetProperty("media_files", out media) && media.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in media.EnumerateArray())
            {
                var s = item.GetString();
                if (!string.IsNullOrWhiteSpace(s)) yield return s;
            }
        }
    }

    internal static string FileStamp() =>
        DateTime.UtcNow.AddHours(8).ToString("yyyyMMdd_HHmmss");

    internal static string Sanitize(string name)
    {
        var cleaned = Regex.Replace(name, "[/\\\\:\\?%\\*\\|\"<>]", "_");
        return string.IsNullOrWhiteSpace(cleaned) ? "chat" : cleaned;
    }
}
