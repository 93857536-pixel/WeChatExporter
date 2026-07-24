using System.Text;

namespace WeChatExporter.Services;

public static class PdfExporter
{
    public static string Write(string sourceDir, string contactName, string destinationDir)
    {
        System.IO.Directory.CreateDirectory(destinationDir);
        var safe = MarkdownExporter.Sanitize(contactName);
        var stamp = MarkdownExporter.FileStamp();
        var outPath = System.IO.Path.Combine(destinationDir, $"{safe}_{stamp}.pdf");
        var sidecarPath = System.IO.Path.Combine(destinationDir, $"{safe}_{stamp}_pdf内容.txt");

        var lines = LoadLines(sourceDir, contactName);
        System.IO.File.WriteAllBytes(outPath, BuildSimplePdf(lines));
        // The minimal PDF uses built-in Helvetica; keep a UTF-8 sidecar so Chinese text is preserved losslessly.
        System.IO.File.WriteAllText(sidecarPath, string.Join(Environment.NewLine, lines), Encoding.UTF8);
        return outPath;
    }

    private static List<string> LoadLines(string sourceDir, string contactName)
    {
        var lines = new List<string> { contactName, "由 WeChatExporter 导出", "" };
        var jsonPath = System.IO.Path.Combine(sourceDir, "chat.json");
        var txtPath = System.IO.Path.Combine(sourceDir, "chat.txt");
        if (System.IO.File.Exists(jsonPath))
        {
            foreach (var row in MarkdownExporter.ReadRows(jsonPath))
            {
                var source = row.TryGetProperty("message", out var nested) && nested.ValueKind == System.Text.Json.JsonValueKind.Object
                    ? nested
                    : row;
                var time = MarkdownExporter.GetString(row, "time", "timestamp_str")
                           ?? MarkdownExporter.GetString(source, "time", "timestamp_str")
                           ?? "";
                var sender = MarkdownExporter.GetString(row, "sender_display_name", "sender", "from")
                             ?? MarkdownExporter.GetString(source, "sender_display_name", "sender")
                             ?? "";
                var content = MarkdownExporter.GetString(row, "snippet", "content", "text")
                              ?? MarkdownExporter.GetString(source, "snippet", "content", "text")
                              ?? "";
                lines.Add($"[{time}] {sender}: {content}");
            }
        }
        else if (System.IO.File.Exists(txtPath))
        {
            lines.AddRange(System.IO.File.ReadAllLines(txtPath));
        }
        else
        {
            throw new InvalidOperationException("未找到聊天记录文件，无法生成 PDF");
        }
        return lines;
    }

    private static byte[] BuildSimplePdf(IReadOnlyList<string> lines)
    {
        const int pageWidth = 612;
        const int pageHeight = 792;
        const int margin = 48;
        const int lineHeight = 14;
        var linesPerPage = Math.Max(1, (pageHeight - margin * 2) / lineHeight);

        var pages = new List<List<string>>();
        for (var i = 0; i < Math.Max(lines.Count, 1); i += linesPerPage)
            pages.Add(lines.Skip(i).Take(linesPerPage).ToList());
        if (pages.Count == 0) pages.Add([]);

        var objects = new List<byte[]>();
        void Add(string text) => objects.Add(Encoding.ASCII.GetBytes(text));
        void AddBytes(byte[] data) => objects.Add(data);

        Add("<< /Type /Catalog /Pages 2 0 R >>\n");
        Add("PLACEHOLDER\n");
        Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\n");

        var contentIds = new List<int>();
        foreach (var pageLines in pages)
        {
            var stream = new StringBuilder();
            stream.Append($"BT /F1 10 Tf {margin} {pageHeight - margin} Td {lineHeight} TL\n");
            for (var i = 0; i < pageLines.Count; i++)
            {
                var text = EscapePdf(AsciiOnly(pageLines[i]));
                stream.Append(i == 0 ? $"({text}) Tj\n" : $"T* ({text}) Tj\n");
            }
            stream.Append("ET");
            var body = Encoding.ASCII.GetBytes(stream.ToString());
            var obj = new List<byte>();
            obj.AddRange(Encoding.ASCII.GetBytes($"<< /Length {body.Length} >>\nstream\n"));
            obj.AddRange(body);
            obj.AddRange(Encoding.ASCII.GetBytes("\nendstream\n"));
            AddBytes(obj.ToArray());
            contentIds.Add(objects.Count);
        }

        var pageIds = new List<int>();
        foreach (var cid in contentIds)
        {
            Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pageWidth} {pageHeight}] /Contents {cid} 0 R /Resources << /Font << /F1 3 0 R >> >> >>\n");
            pageIds.Add(objects.Count);
        }

        var kids = string.Join(" ", pageIds.Select(id => $"{id} 0 R"));
        objects[1] = Encoding.ASCII.GetBytes($"<< /Type /Pages /Kids [{kids}] /Count {pageIds.Count} >>\n");

        using var ms = new System.IO.MemoryStream();
        void WriteAscii(string text) => ms.Write(Encoding.ASCII.GetBytes(text));
        WriteAscii("%PDF-1.4\n");
        var offsets = new List<long> { 0 };
        for (var i = 0; i < objects.Count; i++)
        {
            offsets.Add(ms.Position);
            WriteAscii($"{i + 1} 0 obj\n");
            ms.Write(objects[i]);
            if (objects[i].Length == 0 || objects[i][^1] != (byte)'\n')
                WriteAscii("\n");
            WriteAscii("endobj\n");
        }

        var xref = ms.Position;
        WriteAscii($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets.Skip(1))
            WriteAscii($"{offset:0000000000} 00000 n \n");
        WriteAscii($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return ms.ToArray();
    }

    private static string AsciiOnly(string text)
    {
        var chars = text
            .Take(110)
            .Select(ch => ch is '\\' or '(' or ')' ? ' ' : ch <= 0x7F ? ch : '?')
            .ToArray();
        return new string(chars);
    }

    private static string EscapePdf(string text) =>
        text.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
}
