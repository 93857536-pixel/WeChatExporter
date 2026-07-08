using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>
/// 将导出目录中的聊天记录与媒体打包为单个自包含 HTML 文件（媒体以 base64 内嵌）。
/// </summary>
internal static class SingleFileExporter
{
    private sealed record MessageRow(string Time, string Sender, string Type, string Content, List<string> MediaPaths);

    public static string WriteHtml(string sourceDir, string contactName, string destinationDir)
    {
        var jsonPath = Path.Combine(sourceDir, "chat.json");
        if (!File.Exists(jsonPath))
            throw new InvalidOperationException("未找到 chat.json，无法生成单文件导出");

        var rows = ParseMessages(jsonPath);
        if (rows.Count == 0)
            throw new InvalidOperationException("聊天记录为空，无法生成单文件导出");

        var safeName = SanitizeFilename(string.IsNullOrWhiteSpace(contactName) ? "聊天记录" : contactName);
        var stamp = FileStamp();
        Directory.CreateDirectory(destinationDir);
        var outPath = Path.Combine(destinationDir, $"{safeName}_{stamp}.html");

        var title = EscapeHtml(string.IsNullOrWhiteSpace(contactName) ? "微信聊天记录" : contactName);
        var body = new StringBuilder();
        var embedded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in rows)
            body.Append(RenderMessage(row, sourceDir, embedded));
        body.Append(RenderOrphanMedia(sourceDir, embedded));

        var html = new StringBuilder();
        html.Append("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"/>");
        html.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>");
        html.Append($"<title>{title}</title><style>");
        html.Append("*{box-sizing:border-box}body{font-family:\"Segoe UI\",\"PingFang SC\",\"Microsoft YaHei\",sans-serif;margin:0;background:#ebebeb;color:#111}");
        html.Append("header{background:linear-gradient(135deg,#07c160,#06ad56);color:#fff;padding:20px 24px}");
        html.Append("header h1{margin:0 0 6px;font-size:22px}header p{margin:0;opacity:.92;font-size:13px}");
        html.Append("main{max-width:860px;margin:0 auto;padding:20px 16px 48px}");
        html.Append(".msg{background:#fff;border-radius:10px;padding:12px 14px;margin-bottom:12px;box-shadow:0 1px 2px rgba(0,0,0,.06)}");
        html.Append(".meta{font-size:12px;color:#666;margin-bottom:6px}.sender{font-weight:600;color:#07c160}");
        html.Append(".type{color:#999;margin-left:8px}.text{white-space:pre-wrap;word-break:break-word;line-height:1.55}");
        html.Append(".media{margin-top:10px}.media img{max-width:min(100%,420px);border-radius:8px;display:block}");
        html.Append(".media video,.media audio{max-width:100%;margin-top:6px;display:block}");
        html.Append("footer{text-align:center;color:#999;font-size:12px;padding:24px}</style></head><body>");
        html.Append($"<header><h1>{title}</h1><p>共 {rows.Count} 条消息 · 单文件导出（媒体已内嵌）· {stamp}</p></header><main>");
        html.Append(body);
        html.Append("</main><footer>由 WeChatExporter 导出</footer></body></html>");

        File.WriteAllText(outPath, html.ToString(), Encoding.UTF8);
        return outPath;
    }

    private static string RenderMessage(MessageRow row, string sourceDir, HashSet<string> embedded)
    {
        var mediaHtml = new StringBuilder();
        foreach (var rel in row.MediaPaths)
        {
            if (!embedded.Add(rel)) continue;
            var block = EmbedMedia(rel, sourceDir);
            if (block is not null) mediaHtml.Append(block);
        }

        var content = EscapeHtml(row.Content);
        var showText = !string.IsNullOrEmpty(content)
            && content is not ("[图片]" or "[语音]" or "[视频]" or "[表情]");

        return $"""
            <article class="msg">
              <div class="meta"><span class="sender">{EscapeHtml(row.Sender)}</span><span class="type">{EscapeHtml(row.Type)}</span> · {EscapeHtml(row.Time)}</div>
              {(showText ? $"<div class=\"text\">{content}</div>" : "")}
              {(mediaHtml.Length > 0 ? $"<div class=\"media\">{mediaHtml}</div>" : "")}
            </article>

            """;
    }

    private static string RenderOrphanMedia(string sourceDir, HashSet<string> embedded)
    {
        var mediaRoot = Path.Combine(sourceDir, "media");
        if (!Directory.Exists(mediaRoot)) return "";

        var html = new StringBuilder();
        foreach (var filePath in Directory.EnumerateFiles(mediaRoot, "*", SearchOption.AllDirectories))
        {
            var rel = "media/" + Path.GetRelativePath(mediaRoot, filePath).Replace('\\', '/');
            if (!embedded.Add(rel)) continue;
            var block = EmbedMedia(rel, sourceDir);
            if (block is null) continue;
            html.Append($"""
                <article class="msg">
                  <div class="meta"><span class="sender">媒体附件</span> · {EscapeHtml(Path.GetFileName(filePath))}</div>
                  <div class="media">{block}</div>
                </article>

                """);
        }
        return html.ToString();
    }

    private static string? EmbedMedia(string relativePath, string sourceDir)
    {
        var rel = relativePath.StartsWith("media/", StringComparison.OrdinalIgnoreCase) ? relativePath : $"media/{relativePath}";
        var filePath = Path.Combine(sourceDir, rel.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(filePath)) return null;
        var data = File.ReadAllBytes(filePath);
        if (data.Length == 0) return null;

        var ext = Path.GetExtension(filePath).TrimStart('.').ToLowerInvariant();
        var b64 = Convert.ToBase64String(data);
        return ext switch
        {
            "jpg" or "jpeg" => $"""<img alt="图片" src="data:image/jpeg;base64,{b64}"/>""",
            "png" => $"""<img alt="图片" src="data:image/png;base64,{b64}"/>""",
            "gif" => $"""<img alt="表情" src="data:image/gif;base64,{b64}"/>""",
            "webp" => $"""<img alt="图片" src="data:image/webp;base64,{b64}"/>""",
            "mp3" => $"""<audio controls src="data:audio/mpeg;base64,{b64}"></audio>""",
            "m4a" or "aac" => $"""<audio controls src="data:audio/mp4;base64,{b64}"></audio>""",
            "mp4" or "mov" => $"""<video controls src="data:video/mp4;base64,{b64}"></video>""",
            "wxgf" => $"""<p class="text">[WXGF 图片：{EscapeHtml(Path.GetFileName(filePath))}]</p>""",
            "silk" => $"""<p class="text">[语音 SILK：{EscapeHtml(Path.GetFileName(filePath))}，{data.Length} 字节]</p>""",
            _ => $"""<p class="text">[附件 {EscapeHtml(Path.GetFileName(filePath))}，{data.Length} 字节]</p>"""
        };
    }

    private static List<MessageRow> ParseMessages(string jsonPath)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
        var rows = new List<MessageRow>();
        IEnumerable<JsonElement> elements = doc.RootElement.ValueKind switch
        {
            JsonValueKind.Array => doc.RootElement.EnumerateArray(),
            JsonValueKind.Object when doc.RootElement.TryGetProperty("items", out var items) => items.EnumerateArray(),
            JsonValueKind.Object when doc.RootElement.TryGetProperty("messages", out var messages) => messages.EnumerateArray(),
            JsonValueKind.Object when doc.RootElement.TryGetProperty("results", out var results) => results.EnumerateArray(),
            _ => []
        };

        foreach (var el in elements)
        {
            var row = ParseRow(el);
            if (!string.IsNullOrEmpty(row.Sender) || !string.IsNullOrEmpty(row.Content) || row.MediaPaths.Count > 0)
                rows.Add(row);
        }
        return rows;
    }

    private static MessageRow ParseRow(JsonElement row)
    {
        var source = row.TryGetProperty("message", out var msg) ? msg : row;

        var time = GetString(row, "time", "timestamp_str")
            ?? GetString(source, "time", "timestamp_str")
            ?? FormatTimestamp(GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp"));

        var sender = GetString(row, "sender_display_name", "sender", "from", "display_name")
            ?? GetString(source, "sender_display_name", "sender")
            ?? "未知";

        var msgType = GetInt(source, "msg_type", "type") ?? GetInt(row, "msg_type", "type");
        var typeName = GetString(row, "type_name", "type")
            ?? GetString(source, "type_name")
            ?? TypeLabel(msgType);

        var content = GetString(row, "snippet", "content", "text", "message", "summary")
            ?? GetString(source, "snippet", "content", "text")
            ?? "";

        var media = new List<string>();
        if (row.TryGetProperty("media_files", out var mf) && mf.ValueKind == JsonValueKind.Array)
            media.AddRange(mf.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0));
        else if (source.TryGetProperty("media_files", out mf) && mf.ValueKind == JsonValueKind.Array)
            media.AddRange(mf.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0));

        return new MessageRow(time, sender, typeName, content, media);
    }

    private static string TypeLabel(int? type) => type switch
    {
        1 => "文本",
        3 => "图片",
        34 => "语音",
        43 => "视频",
        47 => "表情",
        49 => "链接/文件",
        null => "消息",
        _ => $"类型{type}"
    };

    private static string? GetString(JsonElement el, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (!el.TryGetProperty(key, out var v)) continue;
            if (v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
            else if (v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n))
                return n.ToString();
        }
        return null;
    }

    private static int? GetInt(JsonElement el, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (el.TryGetProperty(key, out var v) && v.TryGetInt32(out var n)) return n;
        }
        return null;
    }

    private static string FormatTimestamp(int? ts)
    {
        if (ts is null or <= 0) return "";
        var dt = DateTimeOffset.FromUnixTimeSeconds(ts.Value).ToOffset(TimeSpan.FromHours(8));
        return dt.ToString("yyyy-MM-dd HH:mm:ss");
    }

    private static string FileStamp() =>
        DateTime.UtcNow.AddHours(8).ToString("yyyyMMdd_HHmmss");

    private static string SanitizeFilename(string name)
    {
        var cleaned = Regex.Replace(name, @"[/\\:?*""<>|]", "_");
        return string.IsNullOrWhiteSpace(cleaned) ? "聊天记录" : cleaned;
    }

    private static string EscapeHtml(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
}
