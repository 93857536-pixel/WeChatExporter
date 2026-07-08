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
        html.Append($"<title>{title}</title><style>{ExportStyles}</style></head><body>");
        html.Append("<div class=\"bg-scene\" aria-hidden=\"true\">");
        html.Append("<div class=\"aurora aurora-a\"></div><div class=\"aurora aurora-b\"></div><div class=\"aurora aurora-c\"></div>");
        html.Append("<div class=\"grid-floor\"></div></div>");
        html.Append("<header><div class=\"header-glow\"></div>");
        html.Append("<p class=\"eyebrow\">WeChatExporter · 单文件导出</p>");
        html.Append($"<h1>{title}</h1><div class=\"stats\">");
        html.Append($"<span class=\"pill pill-cyan\">{rows.Count} 条消息</span>");
        html.Append("<span class=\"pill pill-purple\">媒体已内嵌</span>");
        html.Append($"<span class=\"pill pill-muted\">{stamp}</span></div></header><main>");
        html.Append(body);
        html.Append("</main><footer><span class=\"footer-brand\">WeChatExporter</span>");
        html.Append("<span class=\"footer-dot\">·</span><span>深空霓虹主题 · 浏览器离线可阅</span></footer></body></html>");

        File.WriteAllText(outPath, html.ToString(), Encoding.UTF8);
        return outPath;
    }

    public static string? WriteStickerGallery(string sourceDir, string destinationDir)
    {
        var manifestPath = Path.Combine(sourceDir, "stickers-manifest.json");
        if (!File.Exists(manifestPath)) return null;

        var manifest = JsonSerializer.Deserialize<StickerPackExporter.Manifest>(
            File.ReadAllText(manifestPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        if (manifest is null || manifest.Packs.Count == 0) return null;

        var stamp = FileStamp();
        Directory.CreateDirectory(destinationDir);
        var outPath = Path.Combine(destinationDir, $"全部表情包_{stamp}.html");

        var body = new StringBuilder();
        foreach (var pack in manifest.Packs)
            body.Append(RenderStickerPack(pack, sourceDir));

        var html = new StringBuilder();
        html.Append("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"/>");
        html.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>");
        html.Append("<title>全部表情包</title><style>");
        html.Append(ExportStyles);
        html.Append(GalleryStyles);
        html.Append("</style></head><body>");
        html.Append("<div class=\"bg-scene\" aria-hidden=\"true\">");
        html.Append("<div class=\"aurora aurora-a\"></div><div class=\"aurora aurora-b\"></div><div class=\"aurora aurora-c\"></div>");
        html.Append("<div class=\"grid-floor\"></div></div>");
        html.Append("<header><div class=\"header-glow\"></div>");
        html.Append("<p class=\"eyebrow\">WeChatExporter · 表情包库</p>");
        html.Append("<h1>全部表情包</h1><div class=\"stats\">");
        html.Append($"<span class=\"pill pill-cyan\">{manifest.TotalCount} 张表情</span>");
        html.Append($"<span class=\"pill pill-purple\">{manifest.Packs.Count} 个分组</span>");
        html.Append($"<span class=\"pill pill-muted\">{stamp}</span></div></header><main>");
        html.Append(body);
        html.Append("</main><footer><span class=\"footer-brand\">WeChatExporter</span>");
        html.Append("<span class=\"footer-dot\">·</span><span>收藏与商店表情包 · 浏览器离线可阅</span></footer></body></html>");

        File.WriteAllText(outPath, html.ToString(), Encoding.UTF8);
        return outPath;
    }

    private static string RenderStickerPack(StickerPackExporter.StickerPack pack, string sourceDir)
    {
        var tiles = new StringBuilder();
        foreach (var sticker in pack.Stickers)
        {
            var block = EmbedMedia(sticker.Path, sourceDir);
            if (block is null) continue;
            var caption = EscapeHtml(sticker.Caption);
            tiles.Append("<figure class=\"sticker-tile\">");
            tiles.Append(block);
            if (!string.IsNullOrEmpty(caption))
                tiles.Append($"<figcaption>{caption}</figcaption>");
            tiles.Append("</figure>");
        }
        if (tiles.Length == 0) return "";
        return $"""
            <section class="sticker-pack">
              <h2>{EscapeHtml(pack.Name)} <span class="pack-count">{pack.Stickers.Count}</span></h2>
              <div class="sticker-grid">{tiles}</div>
            </section>

            """;
    }

    private const string GalleryStyles = """
        .sticker-pack{margin-bottom:36px}
        .sticker-pack h2{margin:0 0 14px;font-size:18px;color:var(--cyan);text-shadow:0 0 12px rgba(0,245,255,.35);display:flex;align-items:center;gap:8px}
        .pack-count{font-size:12px;color:var(--subtext);padding:2px 8px;border-radius:999px;border:1px solid rgba(123,97,255,.35);background:rgba(123,97,255,.12)}
        .sticker-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(92px,1fr));gap:12px}
        .sticker-tile{margin:0;background:rgba(12,20,48,.55);border:1px solid rgba(0,245,255,.18);border-radius:12px;padding:8px;box-shadow:0 0 16px rgba(123,97,255,.08);transition:border-color .2s ease,transform .2s ease}
        .sticker-tile:hover{border-color:rgba(0,245,255,.42);transform:translateY(-2px)}
        .sticker-tile img{width:100%;height:auto;display:block;border-radius:8px;border:none;box-shadow:none}
        .sticker-tile figcaption{margin-top:6px;font-size:11px;color:var(--subtext);text-align:center;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        """;

    /// <summary>与 DMG 安装界面一致的深空霓虹 HUD 样式。</summary>
    private const string ExportStyles = """
        :root{--cyan:#00f5ff;--purple:#7b61ff;--magenta:#ff4dd2;--green:#07ffa0;--text:#f0f8ff;--subtext:#8caad2;--glass:rgba(12,20,48,0.78);--glass-strong:rgba(8,14,36,0.92);--line:rgba(0,245,255,0.22)}
        *{box-sizing:border-box}html{scroll-behavior:smooth}
        body{margin:0;min-height:100vh;font-family:"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;color:var(--text);background:linear-gradient(145deg,#080a20 0%,#120830 38%,#06122a 72%,#1c0626 100%);background-attachment:fixed;position:relative;overflow-x:hidden}
        body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:0;opacity:.55;background-image:radial-gradient(1px 1px at 8% 14%,rgba(240,248,255,.95) 50%,transparent 51%),radial-gradient(1px 1px at 22% 38%,rgba(0,245,255,.85) 50%,transparent 51%),radial-gradient(1.5px 1.5px at 35% 8%,rgba(123,97,255,.9) 50%,transparent 51%),radial-gradient(1px 1px at 48% 62%,rgba(240,248,255,.75) 50%,transparent 51%),radial-gradient(1px 1px at 61% 24%,rgba(0,245,255,.7) 50%,transparent 51%),radial-gradient(1.5px 1.5px at 74% 72%,rgba(255,77,210,.8) 50%,transparent 51%),radial-gradient(1px 1px at 86% 18%,rgba(240,248,255,.8) 50%,transparent 51%),radial-gradient(1px 1px at 92% 48%,rgba(123,97,255,.75) 50%,transparent 51%),radial-gradient(2px 2px at 16% 82%,rgba(0,245,255,.65) 50%,transparent 51%),radial-gradient(1px 1px at 54% 88%,rgba(240,248,255,.7) 50%,transparent 51%)}
        .bg-scene{position:fixed;inset:0;pointer-events:none;z-index:0;overflow:hidden}
        .aurora{position:absolute;border-radius:50%;filter:blur(72px);opacity:.42;animation:drift 18s ease-in-out infinite alternate}
        .aurora-a{width:420px;height:180px;top:-40px;left:12%;background:radial-gradient(circle,rgba(0,180,255,.55),transparent 70%)}
        .aurora-b{width:380px;height:160px;top:60px;right:8%;background:radial-gradient(circle,rgba(140,60,255,.5),transparent 70%);animation-delay:-6s}
        .aurora-c{width:500px;height:200px;bottom:18%;left:28%;background:radial-gradient(circle,rgba(255,60,200,.35),transparent 70%);animation-delay:-12s}
        .grid-floor{position:absolute;left:0;right:0;bottom:0;height:42vh;background:linear-gradient(to bottom,transparent 0%,rgba(0,245,255,.04) 100%),repeating-linear-gradient(90deg,transparent,transparent 39px,rgba(0,245,255,.06) 39px,rgba(0,245,255,.06) 40px),repeating-linear-gradient(0deg,transparent,transparent 13px,rgba(123,97,255,.05) 13px,rgba(123,97,255,.05) 14px);transform:perspective(480px) rotateX(62deg);transform-origin:center bottom;mask-image:linear-gradient(to top,rgba(0,0,0,.55),transparent);opacity:.35}
        @keyframes drift{from{transform:translate3d(-12px,0,0) scale(1)}to{transform:translate3d(18px,14px,0) scale(1.06)}}
        header,main,footer{position:relative;z-index:1}
        header{padding:32px 24px 28px;background:linear-gradient(180deg,rgba(12,20,48,.88),rgba(8,14,36,.72));backdrop-filter:blur(18px) saturate(140%);-webkit-backdrop-filter:blur(18px) saturate(140%);border-bottom:1px solid var(--line);box-shadow:0 12px 40px rgba(0,0,0,.35),inset 0 1px 0 rgba(255,255,255,.06)}
        .header-glow{position:absolute;top:0;left:50%;width:min(680px,90vw);height:2px;transform:translateX(-50%);background:linear-gradient(90deg,transparent,var(--cyan),var(--purple),var(--magenta),transparent);box-shadow:0 0 24px rgba(0,245,255,.55)}
        .eyebrow{margin:0 0 10px;font-size:11px;letter-spacing:.22em;text-transform:uppercase;color:var(--subtext)}
        header h1{margin:0 0 16px;font-size:clamp(24px,4vw,34px);font-weight:700;line-height:1.2;background:linear-gradient(92deg,var(--cyan) 0%,#9ae8ff 35%,var(--purple) 68%,var(--magenta) 100%);-webkit-background-clip:text;background-clip:text;color:transparent;filter:drop-shadow(0 0 18px rgba(0,245,255,.35))}
        .stats{display:flex;flex-wrap:wrap;gap:8px}
        .pill{display:inline-flex;align-items:center;padding:5px 12px;border-radius:999px;font-size:12px;letter-spacing:.02em;border:1px solid transparent}
        .pill-cyan{color:var(--cyan);background:rgba(0,245,255,.1);border-color:rgba(0,245,255,.35);box-shadow:0 0 16px rgba(0,245,255,.18)}
        .pill-purple{color:#c4b5ff;background:rgba(123,97,255,.14);border-color:rgba(123,97,255,.38);box-shadow:0 0 16px rgba(123,97,255,.18)}
        .pill-muted{color:var(--subtext);background:rgba(140,170,210,.08);border-color:rgba(140,170,210,.22)}
        main{max-width:880px;margin:0 auto;padding:28px 16px 56px}
        .msg{position:relative;background:var(--glass);backdrop-filter:blur(14px) saturate(130%);-webkit-backdrop-filter:blur(14px) saturate(130%);border:1px solid rgba(123,97,255,.28);border-radius:16px;padding:16px 18px 18px;margin-bottom:14px;box-shadow:0 8px 32px rgba(0,0,0,.32),inset 0 1px 0 rgba(255,255,255,.05),0 0 24px rgba(123,97,255,.08);transition:border-color .25s ease,box-shadow .25s ease,transform .25s ease}
        .msg::before{content:"";position:absolute;top:12px;left:12px;width:18px;height:18px;border-top:2px solid rgba(0,245,255,.55);border-left:2px solid rgba(0,245,255,.55);border-radius:4px 0 0 0;pointer-events:none}
        .msg::after{content:"";position:absolute;bottom:12px;right:12px;width:18px;height:18px;border-bottom:2px solid rgba(123,97,255,.45);border-right:2px solid rgba(123,97,255,.45);border-radius:0 0 4px 0;pointer-events:none}
        .msg:hover{border-color:rgba(0,245,255,.42);box-shadow:0 10px 36px rgba(0,0,0,.38),0 0 28px rgba(0,245,255,.12),inset 0 1px 0 rgba(255,255,255,.07);transform:translateY(-1px)}
        .meta{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:10px;font-size:12px}
        .sender{font-weight:600;color:var(--cyan);text-shadow:0 0 10px rgba(0,245,255,.45)}
        .type{display:inline-flex;align-items:center;padding:2px 9px;border-radius:999px;font-size:11px;color:#d5c8ff;background:rgba(123,97,255,.18);border:1px solid rgba(123,97,255,.42);box-shadow:0 0 12px rgba(123,97,255,.2)}
        .time{color:var(--subtext);margin-left:auto;font-variant-numeric:tabular-nums}
        .text{white-space:pre-wrap;word-break:break-word;line-height:1.65;color:rgba(240,248,255,.94)}
        .media{margin-top:12px}
        .media img{max-width:min(100%,440px);border-radius:12px;display:block;border:1px solid rgba(0,245,255,.32);box-shadow:0 0 24px rgba(0,245,255,.18),0 8px 24px rgba(0,0,0,.35)}
        .media video,.media audio{max-width:100%;margin-top:8px;display:block;border-radius:12px;border:1px solid rgba(123,97,255,.28);box-shadow:0 0 20px rgba(123,97,255,.15);background:var(--glass-strong)}
        footer{text-align:center;color:var(--subtext);font-size:12px;padding:28px 16px 36px;border-top:1px solid rgba(123,97,255,.15);background:linear-gradient(180deg,transparent,rgba(8,14,36,.55))}
        .footer-brand{color:var(--cyan);font-weight:600;text-shadow:0 0 10px rgba(0,245,255,.35)}
        .footer-dot{margin:0 8px;opacity:.5}
        @media (max-width:640px){header{padding:24px 16px 22px}.time{margin-left:0;width:100%}.msg{padding:14px 14px 16px}}
        """;

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
              <div class="meta">
                <span class="sender">{EscapeHtml(row.Sender)}</span>
                <span class="type">{EscapeHtml(row.Type)}</span>
                <span class="time">{EscapeHtml(row.Time)}</span>
              </div>
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
                  <div class="meta">
                    <span class="sender">媒体附件</span>
                    <span class="type">文件</span>
                    <span class="time">{EscapeHtml(Path.GetFileName(filePath))}</span>
                  </div>
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
