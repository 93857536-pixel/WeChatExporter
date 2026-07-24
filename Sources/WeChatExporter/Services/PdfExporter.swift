import Foundation
#if canImport(AppKit)
import AppKit
import CoreText
#endif

/// 导出为 PDF（macOS 用 CoreText 排版支持中文；其它环境回退 ASCII PDF + 旁路 TXT）。
enum PdfExporter {
    static func write(from sourceDir: URL, contactName: String, into destinationDir: URL) throws -> URL {
        let lines = loadLines(from: sourceDir, contactName: contactName)
        let safe = sanitize(contactName)
        let stamp = timestamp()
        let out = destinationDir.appendingPathComponent("\(safe)_\(stamp).pdf")
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        #if canImport(AppKit)
        do {
            let data = try coreTextPDF(lines: lines)
            try data.write(to: out, options: .atomic)
            return out
        } catch {
            // fall through
        }
        #endif

        let data = fallbackASCIIPdf(lines: lines)
        try data.write(to: out, options: .atomic)
        let txtSide = destinationDir.appendingPathComponent("\(safe)_\(stamp)_pdf内容.txt")
        try lines.joined(separator: "\n").write(to: txtSide, atomically: true, encoding: .utf8)
        return out
    }

    #if canImport(AppKit)
    private static func coreTextPDF(lines: [String]) throws -> Data {
        let text = lines.joined(separator: "\n")
        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AppError.exportFailed("无法创建 PDF 上下文")
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var textPos = 0
        let total = attributed.length
        while textPos < total {
            context.beginPage(mediaBox: &mediaBox)
            context.textMatrix = .identity
            let frameRect = CGRect(
                x: margin,
                y: margin,
                width: pageWidth - margin * 2,
                height: pageHeight - margin * 2
            )
            let path = CGPath(rect: frameRect, transform: nil)
            let range = CFRange(location: textPos, length: total - textPos)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            textPos += max(visible.length, 1)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
    #endif

    private static func loadLines(from sourceDir: URL, contactName: String) -> [String] {
        var lines: [String] = ["\(contactName)", "由 WeChatExporter 导出", ""]
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        let txtURL = sourceDir.appendingPathComponent("chat.txt")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let data = try? Data(contentsOf: jsonURL),
           let root = try? JSONSerialization.jsonObject(with: data) {
            for row in messageRows(from: root) {
                let source = (row["message"] as? [String: Any]) ?? row
                let time = stringField(row, keys: ["time", "timestamp_str"])
                    ?? stringField(source, keys: ["time", "timestamp_str"])
                    ?? ""
                let sender = stringField(row, keys: ["sender_display_name", "sender", "from"])
                    ?? stringField(source, keys: ["sender_display_name", "sender"])
                    ?? ""
                let content = stringField(row, keys: ["snippet", "content", "text"])
                    ?? stringField(source, keys: ["snippet", "content", "text"])
                    ?? ""
                lines.append("[\(time)] \(sender): \(content)")
            }
        } else if let text = try? String(contentsOf: txtURL, encoding: .utf8) {
            lines.append(contentsOf: text.components(separatedBy: .newlines))
        }
        return lines
    }

    private static func fallbackASCIIPdf(lines: [String]) -> Data {
        let pageWidth = 612
        let pageHeight = 792
        let margin = 48
        let lineHeight = 14
        let linesPerPage = max(1, (pageHeight - margin * 2) / lineHeight)
        let pages = stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map {
            Array(lines[$0..<min($0 + linesPerPage, lines.count)])
        }

        var objects: [Data] = []
        func add(_ s: String) { objects.append(Data(s.utf8)) }
        func add(_ d: Data) { objects.append(d) }

        add("<< /Type /Catalog /Pages 2 0 R >>\n")
        add("PLACEHOLDER")
        add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\n")

        var contentIds: [Int] = []
        for pageLines in pages {
            var stream = "BT /F1 10 Tf \(margin) \(pageHeight - margin) Td \(lineHeight) TL\n"
            for (i, line) in pageLines.enumerated() {
                let t = escapePDF(asciiOnly(line))
                stream += i == 0 ? "(\(t)) Tj\n" : "T* (\(t)) Tj\n"
            }
            stream += "ET"
            let body = Data(stream.utf8)
            var obj = Data("<< /Length \(body.count) >>\nstream\n".utf8)
            obj.append(body)
            obj.append(Data("\nendstream\n".utf8))
            add(obj)
            contentIds.append(objects.count)
        }

        var pageIds: [Int] = []
        for cid in contentIds {
            add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) \(pageHeight)] /Contents \(cid) 0 R /Resources << /Font << /F1 3 0 R >> >> >>\n")
            pageIds.append(objects.count)
        }
        let kids = pageIds.map { "\($0) 0 R" }.joined(separator: " ")
        objects[1] = Data("<< /Type /Pages /Kids [\(kids)] /Count \(pageIds.count) >>\n".utf8)

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (i, obj) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(i + 1) 0 obj\n".utf8))
            pdf.append(obj)
            if obj.last != 0x0A { pdf.append(Data("\n".utf8)) }
            pdf.append(Data("endobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for off in offsets.dropFirst() {
            pdf.append(Data(String(format: "%010d 00000 n \n", off).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return pdf
    }

    private static func asciiOnly(_ text: String) -> String {
        String(text.prefix(110).map { ch -> Character in
            if ch == "\\" || ch == "(" || ch == ")" { return " " }
            return ch.isASCII ? ch : "?"
        })
    }

    private static func escapePDF(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private static func messageRows(from root: Any) -> [[String: Any]] {
        if let array = root as? [[String: Any]] { return array }
        if let dict = root as? [String: Any] {
            for key in ["items", "messages", "results"] {
                if let items = dict[key] as? [[String: Any]] { return items }
            }
        }
        return []
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "chat" : cleaned
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
