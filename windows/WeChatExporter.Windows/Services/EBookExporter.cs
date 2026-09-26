using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;

namespace WeChatExporter.Services;

/// <summary>
/// 电子书/文档导出：从 chat.json 生成 EPUB 电子书与打印版 HTML（本地离线、零第三方依赖）。
/// - EPUB：自实现 stored-ZIP（EPUB 规范要求 mimetype 条目必须 stored 且为第一个条目）
/// - 文档版：打印优化单文件 HTML（A4 @page 版式、按月分节、发言人/时间戳），浏览器可打印或另存 PDF
/// </summary>
public static class EBookExporter
{
    public struct ChatMessage
    {
        public DateTime? Timestamp;
        public string Sender;
        public string Text;
    }

    // ===== chat.json 解析（字段与 ChatStatsReport / wx-cli 输出一致） =====

    /// <summary>读取 sourceDir 下 chat.json，按时间升序返回消息；读不到或为空返回 null。</summary>
    public static List<ChatMessage>? LoadMessages(string sourceDir)
    {
        var chatJson = Path.Combine(sourceDir, "chat.json");
        if (!File.Exists(chatJson)) return null;

        JsonDocument jsonDoc;
        try { jsonDoc = JsonDocument.Parse(File.ReadAllText(chatJson)); }
        catch { return null; }
        var root = jsonDoc.RootElement;

        var rows = new List<JsonElement>();
        if (root.ValueKind == JsonValueKind.Array)
        {
            foreach (var e in root.EnumerateArray())
                if (e.ValueKind == JsonValueKind.Object) rows.Add(e);
        }
        else if (root.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "items", "results", "messages" })
            {
                if (root.TryGetProperty(key, out var items) && items.ValueKind == JsonValueKind.Array)
                {
                    rows.Clear();
                    foreach (var e in items.EnumerateArray())
                        if (e.ValueKind == JsonValueKind.Object) rows.Add(e);
                    if (rows.Count > 0) break;
                }
            }
        }
        if (rows.Count == 0) return null;

        var result = new List<ChatMessage>(rows.Count);
        foreach (var row in rows)
        {
            // wx-cli 行可能是扁平或嵌套（row["message"] / row["source"]）
            JsonElement source = row;
            JsonElement m1 = default, s1 = default;
            bool nestedMsg = row.ValueKind == JsonValueKind.Object
                && row.TryGetProperty("message", out m1) && m1.ValueKind == JsonValueKind.Object;
            bool nestedSrc = row.ValueKind == JsonValueKind.Object
                && row.TryGetProperty("source", out s1) && s1.ValueKind == JsonValueKind.Object;
            if (nestedMsg) source = m1;
            else if (nestedSrc) source = s1;

            var text = GetString(row, "snippet", "content", "text", "summary")
                       ?? GetString(source, "snippet", "content", "text") ?? "";
            var ts = GetLong(source, "create_time", "timestamp")
                     ?? GetLong(row, "create_time", "timestamp");
            DateTime? date = null;
            if (ts is long unixSeconds)
            {
                if (unixSeconds > 10_000_000_000L) unixSeconds /= 1000; // 毫秒/秒自适应
                try { date = DateTimeOffset.FromUnixTimeSeconds(unixSeconds).LocalDateTime; }
                catch { /* 非法时间戳：无时间戳也可导出 */ }
            }
            var sender = GetString(row, "sender_display_name", "sender", "from", "display_name")
                        ?? GetString(source, "sender_display_name", "sender") ?? "未知";
            result.Add(new ChatMessage { Timestamp = date, Sender = sender, Text = text });
        }
        result.Sort((a, b) => (a.Timestamp ?? DateTime.MinValue).CompareTo(b.Timestamp ?? DateTime.MinValue));
        return result.Count > 0 ? result : null;
    }

    private static string? GetString(JsonElement e, params string[] keys)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        foreach (var k in keys)
        {
            if (e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
        }
        return null;
    }

    private static long? GetLong(JsonElement e, params string[] keys)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        foreach (var k in keys)
        {
            if (!e.TryGetProperty(k, out var v)) continue;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n)) return n;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return (long)d;
            if (v.ValueKind == JsonValueKind.String && long.TryParse(v.GetString(), out var s)) return s;
        }
        return null;
    }

    // ===== EPUB =====

    /// <summary>由 chat.json 生成 EPUB，返回输出路径；无数据/失败 null。</summary>
    public static string? WriteEpub(string sourceDir, string contactName, string destDir, Action<string>? log = null)
    {
        var messages = LoadMessages(sourceDir);
        if (messages is null || messages.Count == 0)
        {
            log?.Invoke("电子书：未找到 chat.json 或无消息，已跳过 EPUB");
            return null;
        }
        try
        {
            var title = string.IsNullOrEmpty(contactName) ? "微信聊天记录" : contactName;
            Directory.CreateDirectory(destDir);
            var outPath = Path.Combine(destDir, SanitizeForFilename(title) + "_聊天记录.epub");
            WriteStoredZip(EpubEntries(title, messages), outPath);
            log?.Invoke($"EPUB 已生成：{Path.GetFileName(outPath)}（{messages.Count} 条）");
            return outPath;
        }
        catch (Exception ex)
        {
            log?.Invoke($"EPUB 生成失败：{ex.Message}");
            return null;
        }
    }

    private static List<(string Name, byte[] Data)> EpubEntries(string title, List<ChatMessage> messages)
    {
        var stamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        return new List<(string, byte[])>
        {
            ("mimetype", Encoding.ASCII.GetBytes("application/epub+zip")),
            ("META-INF/container.xml", Encoding.UTF8.GetBytes(ContainerXml)),
            ("OEBPS/content.opf", Encoding.UTF8.GetBytes(Opcode(title, stamp))),
            ("OEBPS/nav.xhtml", Encoding.UTF8.GetBytes(NavXhtml)),
            ("OEBPS/toc.ncx", Encoding.UTF8.GetBytes(NcxXml(title))),
            ("OEBPS/style.css", Encoding.UTF8.GetBytes(EpubCss)),
            ("OEBPS/chapter1.xhtml", Encoding.UTF8.GetBytes(EpubChapterXhtml(messages, title))),
        };
    }

    // ===== 文档版（打印优化 HTML） =====

    /// <summary>由 chat.json 生成打印版 HTML（A4 版式，浏览器可打印/另存 PDF），返回输出路径；无数据/失败 null。</summary>
    public static string? WriteDocument(string sourceDir, string contactName, string destDir, Action<string>? log = null)
    {
        var messages = LoadMessages(sourceDir);
        if (messages is null || messages.Count == 0)
        {
            log?.Invoke("电子书：未找到 chat.json 或无消息，已跳过文档版");
            return null;
        }
        try
        {
            var title = string.IsNullOrEmpty(contactName) ? "微信聊天记录" : contactName;
            Directory.CreateDirectory(destDir);
            var outPath = Path.Combine(destDir, SanitizeForFilename(title) + "_聊天记录_打印版.html");
            var html = DocumentHtml(messages, title);
            File.WriteAllText(outPath, html, Encoding.UTF8);
            log?.Invoke($"文档版已生成：{Path.GetFileName(outPath)}（{messages.Count} 条，浏览器打印/另存 PDF）");
            return outPath;
        }
        catch (Exception ex)
        {
            log?.Invoke($"文档版生成失败：{ex.Message}");
            return null;
        }
    }

    /// <summary>生成打印优化单文件 HTML（白底、A4 @page、按月分节、发言人/时间戳）。</summary>
    private static string DocumentHtml(List<ChatMessage> messages, string title)
    {
        var sb = new StringBuilder();
        sb.Append("<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n");
        sb.Append($"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>{Esc(title)}</title>\n");
        sb.Append("""
        <style>
        :root{--ink:#1f1f1f;--sub:#777;--accent:#00596b;--line:#ddd}
        *{box-sizing:border-box}
        @page{size:A4;margin:14mm}
        body{font-family:"Microsoft YaHei","PingFang SC","Noto Sans CJK SC",sans-serif;color:var(--ink);
             line-height:1.7;margin:0;padding:24px;background:#fff}
        .wrap{max-width:760px;margin:0 auto}
        h1{font-size:20px;margin:0 0 4px}
        .meta{color:var(--sub);font-size:12px;margin:0 0 18px}
        h2{font-size:14px;color:var(--accent);border-bottom:1px solid var(--line);
           padding-bottom:4px;margin:20px 0 8px}
        .msg{margin:0 0 8px;padding:2px 0}
        .who{font-weight:600}
        .ts{color:var(--sub);font-size:12px;margin-left:8px}
        .text{white-space:pre-wrap;word-break:break-word}
        .non{color:var(--sub);font-style:italic}
        .print-tip{color:var(--sub);font-size:12px;margin-bottom:14px}
        @media print{.print-tip{display:none}body{padding:0}}
        </style>
        """);
        sb.Append("</head>\n<body>\n<div class=\"wrap\">\n");
        sb.Append($"<h1>{Esc(title)}</h1>\n");
        sb.Append($"<p class=\"meta\">共 {messages.Count} 条消息 · 由 WeChatExporter 本地生成 · {DateTime.Now:yyyy-MM-dd HH:mm}</p>\n");
        sb.Append("<p class=\"print-tip\">打印：Ctrl/Cmd+P，A4、缩放 100%；或用浏览器「另存为 PDF」。</p>\n");

        var lastMonth = "";
        foreach (var m in messages)
        {
            var monthKey = m.Timestamp?.ToString("yyyy-MM", CultureInfo.InvariantCulture) ?? "其他";
            if (monthKey != lastMonth)
            {
                sb.Append($"<h2>{Esc(monthKey)}</h2>\n");
                lastMonth = monthKey;
            }
            var timeStr = m.Timestamp?.ToString("MM-dd HH:mm", CultureInfo.InvariantCulture) ?? "";
            sb.Append("<div class=\"msg\">");
            sb.Append($"<span class=\"who\">{Esc(m.Sender)}</span>");
            if (timeStr.Length > 0) sb.Append($"<span class=\"ts\">{Esc(timeStr)}</span>");
            sb.Append("</span>");
            if (m.Text.Length == 0)
                sb.Append("<div class=\"text non\">（非文本消息）</div>");
            else
                sb.Append($"<div class=\"text\">{HtmlEsc(m.Text)}</div>");
            sb.Append("</div>\n");
        }

        sb.Append("</div>\n</body>\n</html>\n");
        return sb.ToString();
    }

    // ===== EPUB 内容模板 =====

    private static readonly string ContainerXml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:opendata:storage">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """;

    private static string Opcode(string title, string stamp) => $"""
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2008/epub/package" version="3.0" xml:lang="zh-CN" unique-identifier="uid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">wxexport-{stamp}</dc:identifier>
        <dc:title>{Esc(title)}</dc:title>
        <dc:language>zh-CN</dc:language>
        <dc:creator>WeChatExporter</dc:creator>
        <meta property="dcterms:modified">{stamp}</meta>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
      </manifest>
      <spine><itemref idref="ch1"/></spine>
    </package>
    """;

    private static readonly string NavXhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2009/epub">
      <head><title>目录</title></head>
      <body><nav epub:type="toc"><h1>目录</h1><ol><li><a href="chapter1.xhtml">聊天记录</a></li></ol></nav></body>
    </html>
    """;

    private static string NcxXml(string title) => $"""
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/zbook/2005/ncx/" version="2005-1">
      <head><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>
      <docTitle><text>{Esc(title)}</text></docTitle>
      <navMap><navPoint id="np1" playOrder="1"><navLabel><text>聊天记录</text></navLabel><content src="chapter1.xhtml"/></navPoint></navMap>
    </ncx>
    """;

    private static readonly string EpubCss =
        "body{font-family:serif;line-height:1.7}h1{font-size:1.4em}h2{font-size:1.15em;border-bottom:1px solid #ccc;padding-bottom:4px}p{margin:0.4em 0}.sender{font-weight:bold}.time{color:#666;font-size:0.85em}.meta{color:#666;font-size:0.85em}";

    /// <summary>消息按月份分节，生成阅读器友好的 XHTML 章节。</summary>
    private static string EpubChapterXhtml(List<ChatMessage> messages, string title)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2009/epub\">\n");
        sb.Append($"<head><title>{Esc(title)}</title></head>\n<body>\n");
        sb.Append($"<h1>{Esc(title)}</h1>\n");
        sb.Append($"<p class=\"meta\">共 {messages.Count} 条消息 · 由 WeChatExporter 本地生成</p>\n");
        var lastMonth = "";
        foreach (var m in messages)
        {
            var monthKey = m.Timestamp?.ToString("yyyy-MM", CultureInfo.InvariantCulture) ?? "其他";
            if (monthKey != lastMonth)
            {
                sb.Append($"<h2>{Esc(monthKey)}</h2>\n");
                lastMonth = monthKey;
            }
            var timeStr = m.Timestamp?.ToString("MM-dd HH:mm", CultureInfo.InvariantCulture) ?? "";
            if (m.Text.Length == 0)
            {
                sb.Append($"<p><span class=\"sender\">{Esc(m.Sender)}</span><span class=\"time\">[{Esc(timeStr)}] </span><em>（非文本消息）</em></p>\n");
            }
            else
            {
                var safe = Esc(m.Text).Replace("\n", "<br/>");
                sb.Append($"<p><span class=\"sender\">{Esc(m.Sender)}</span><span class=\"time\">[{Esc(timeStr)}] </span>{safe}</p>\n");
            }
        }
        sb.Append("</body>\n</html>\n");
        return sb.ToString();
    }

    // ===== 工具 =====

    /// <summary>XML/EPUB 转义（属性/标签通用）。</summary>
    public static string Esc(string s)
    {
        return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
    }

    /// <summary>HTML body 转义（保留换行，pre-wrap 渲染）。</summary>
    private static string HtmlEsc(string s)
    {
        return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
    }

    /// <summary>文件名清洗（保留中文，去掉非法字符）。</summary>
    public static string SanitizeForFilename(string s)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder();
        foreach (var c in s)
            if (c >= 32 && Array.IndexOf(invalid, c) < 0) sb.Append(c);
        var out2 = sb.ToString().Trim();
        return out2.Length == 0 ? "聊天记录" : out2;
    }

    // ===== 自实现 stored-ZIP（EPUB mimetype 规范必须 stored 且为第一个条目） =====

    private static void WriteStoredZip(List<(string Name, byte[] Data)> entries, string outPath)
    {
        var main = new MemoryStream();
        var central = new MemoryStream();
        var cw = new BinaryWriter(central, Encoding.UTF8, true);
        var now = DateTime.Now;
        ushort dosTime = (ushort)((now.Hour << 11) | (now.Minute << 5) | (now.Second / 2));
        ushort dosDate = (ushort)((((Math.Max(1980, now.Year) - 1980) & 0x7F) << 9) | ((now.Month & 0xF) << 5) | (now.Day & 0x1F));
        var crcTable = MakeCrcTable();
        long centralStart;

        using (var w = new BinaryWriter(main, Encoding.UTF8, true))
        {
            foreach (var (name, data) in entries)
            {
                var nameBytes = Encoding.UTF8.GetBytes(name);
                var crc = Crc32(data, crcTable);
                var localStart = main.Position;

                // 本地文件头（30 字节定长）
                w.Write((uint)0x04034B50);
                w.Write((ushort)20);                       // version needed
                w.Write((ushort)0x0800);                   // flags：bit11 UTF-8 文件名
                w.Write((ushort)0);                         // method 0 stored
                w.Write(dosTime);
                w.Write(dosDate);
                w.Write(crc);
                w.Write((uint)data.Length);
                w.Write((uint)data.Length);
                w.Write((ushort)nameBytes.Length);
                w.Write((ushort)0);                         // extra len
                w.Write(nameBytes);
                w.Write(data);

                // 中央目录条目（46 字节定长）
                cw.Write((uint)0x02014B50);
                cw.Write((ushort)20);                        // made by
                cw.Write((ushort)20);                        // version needed
                cw.Write((ushort)0x0800);
                cw.Write((ushort)0);
                cw.Write(dosTime);
                cw.Write(dosDate);
                cw.Write(crc);
                cw.Write((uint)data.Length);
                cw.Write((uint)data.Length);
                cw.Write((ushort)nameBytes.Length);
                cw.Write((ushort)0);                         // extra
                cw.Write((ushort)0);                         // comment
                cw.Write((ushort)0);                         // disk
                cw.Write((ushort)0);                         // internal attrs
                cw.Write((uint)0);                           // external attrs
                cw.Write((uint)localStart);
                cw.Write(nameBytes);
                _ = localStart;
            }

            centralStart = main.Position;
            w.Write(central.ToArray());

            // EOCD
            w.Write((uint)0x06054B50);
            w.Write((ushort)0);
            w.Write((ushort)0);
            w.Write((ushort)entries.Count);
            w.Write((ushort)entries.Count);
            w.Write((uint)central.Length);
            w.Write((uint)centralStart);
            w.Write((ushort)0);                              // comment len
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        main.Position = 0;
        using var fs = File.Create(outPath);
        main.WriteTo(fs);
    }

    // CRC32（反射多项式 0xEDB88320，基于未压缩数据）
    private static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (int i = 0; i < 256; i++)
        {
            uint crc = (uint)i;
            for (int b = 0; b < 8; b++)
                crc = (crc & 1u) == 1u ? (0xEDB88320u ^ (crc >> 1)) : (crc >> 1);
            table[i] = crc;
        }
        return table;
    }

    private static uint Crc32(byte[] data, uint[] table)
    {
        uint crc = 0xFFFFFFFF;
        foreach (var b in data)
            crc = table[(int)((crc ^ b) & 0xFF)] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }
}
