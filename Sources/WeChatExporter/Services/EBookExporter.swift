import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 电子书/文档导出：直接从 chat.json 生成 EPUB 与 PDF（不依赖单文件 HTML，离线、零第三方依赖）。
/// - EPUB：自实现 stored-ZIP（EPUB 规范要求 mimetype 条目必须 stored 且为第一个条目）
/// - PDF：CGPDFContext + CoreText（系统 PingFang SC，中文离线渲染，A4）
enum EBookExporter {
    enum EBookError: LocalizedError {
        case pdfContextFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .pdfContextFailed: return "PDF 上下文创建失败"
            case .writeFailed(let msg): return "写入失败：\(msg)"
            }
        }
    }

    /// 一条聊天消息（chat.json 解析结果）
    struct ChatMessage {
        var timestamp: Date?
        var sender: String
        var text: String
    }

    // MARK: - chat.json 解析（字段兼容与 WxCliService / ChatStatsReport 一致）

    /// 读取 sourceDir 下 chat.json，按时间升序返回消息；读不到或为空返回 nil
    static func loadMessages(from sourceDir: URL) -> [ChatMessage]? {
        let chatJSON = sourceDir.appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: chatJSON),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var rows: [[String: Any]] = []
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let dict = root as? [String: Any] {
            for key in ["items", "results", "messages"] {
                if let items = dict[key] as? [[String: Any]] {
                    if !items.isEmpty { rows = items; break }
                }
                if let items = dict[key] as? [[AnyHashable: Any]] {
                    let converted = items.compactMap { $0 as? [String: Any] }
                    if !converted.isEmpty { rows = converted; break }
                }
            }
        }
        guard !rows.isEmpty else { return nil }

        var out: [ChatMessage] = []
        for row in rows {
            // wx-cli 行可能是扁平或嵌套（row["message"] / row["source"]）
            let nested = row["message"] as? [String: Any] ?? row["source"] as? [String: Any]
            let source = nested ?? row

            let text = stringField(row, keys: ["snippet", "content", "text", "summary"])
                ?? stringField(source, keys: ["snippet", "content", "text"]) ?? ""
            let ts = intField(source, keys: ["create_time", "timestamp"])
                ?? intField(row, keys: ["create_time", "timestamp"])
            let date: Date? = ts.map { value in
                let seconds = value > 100_000_000_000 ? value / 1000 : value  // 毫秒/秒自适应
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            let sender = stringField(row, keys: ["sender_display_name", "sender", "from", "display_name"])
                ?? stringField(source, keys: ["sender_display_name", "sender"]) ?? "未知"
            out.append(ChatMessage(timestamp: date, sender: sender, text: text))
        }

        let sorted = out.sorted { a, b in
            (a.timestamp ?? .distantPast) < (b.timestamp ?? .distantPast)
        }
        return sorted.isEmpty ? nil : sorted
    }

    private static func stringField(_ d: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let v = d[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static func intField(_ d: [String: Any], keys: [String]) -> Int? {
        for k in keys {
            guard let v = d[k] else { continue }
            if let n = v as? Int { return n }
            if let n = v as? Double { return Int(n) }
            if let s = v as? String, let n = Int(s) { return n }
        }
        return nil
    }

    // MARK: - EPUB

    /// 由 chat.json 生成 EPUB，返回输出路径；无数据/失败 nil
    static func writeEpub(from sourceDir: URL, contactName: String, into destDir: URL, log: @escaping (String) -> Void) -> URL? {
        guard let messages = loadMessages(from: sourceDir) else {
            log("电子书：未找到 chat.json 或无消息，已跳过 EPUB")
            return nil
        }
        do {
            let outURL = try makeEpub(messages: messages, contactName: contactName, into: destDir)
            log("EPUB 已生成：\(outURL.lastPathComponent)（\(messages.count) 条）")
            return outURL
        } catch {
            log("EPUB 生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeEpub(messages: [ChatMessage], contactName: String, into destDir: URL) throws -> URL {
        let title = contactName.isEmpty ? "微信聊天记录" : contactName
        let stamp = ISO8601DateFormatter().string(from: Date())

        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXml.utf8)),
            ("OEBPS/content.opf", Data(opfXML(title: title, stamp: stamp).utf8)),
            ("OEBPS/nav.xhtml", Data(navXhtml.utf8)),
            ("OEBPS/toc.ncx", Data(ncxXML(title: title).utf8)),
            ("OEBPS/style.css", Data(epubCSS.utf8)),
            ("OEBPS/chapter1.xhtml", Data(epubChapterXhtml(messages: messages, title: title).utf8)),
        ]
        let outURL = destDir.appendingPathComponent("\(sanitizeForFilename(title))_聊天记录.epub")
        try StoredZip.write(entries: entries, to: outURL)
        return outURL
    }

    // MARK: - PDF（CGPDFContext + CoreText 逐行排版，A4）

    /// 由 chat.json 生成 A4 PDF。返回输出路径；无数据/失败 nil
    static func writePdf(from sourceDir: URL, contactName: String, into destDir: URL, log: @escaping (String) -> Void) -> URL? {
        guard let messages = loadMessages(from: sourceDir) else {
            log("电子书：未找到 chat.json 或无消息，已跳过 PDF")
            return nil
        }
        do {
            let outURL = try makePdf(messages: messages, contactName: contactName, into: destDir)
            log("PDF 已生成：\(outURL.lastPathComponent)（\(messages.count) 条）")
            return outURL
        } catch {
            log("PDF 生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static let pdfPageW: CGFloat = 595
    private static let pdfPageH: CGFloat = 842
    private static let pdfMargin: CGFloat = 56

    private static func makePdf(messages: [ChatMessage], contactName: String, into destDir: URL) throws -> URL {
        let title = contactName.isEmpty ? "微信聊天记录" : contactName

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let outURL = destDir.appendingPathComponent("\(sanitizeForFilename(title))_聊天记录.pdf")

        guard let consumer = CGDataConsumer(url: outURL as CFURL) else {
            throw EBookError.pdfContextFailed
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pdfPageW, height: pdfPageH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw EBookError.pdfContextFailed
        }

        // 字体（macOS 内置中文；缺失时 NSFont 会回落到系统默认）
        let messageFont = NSFont(name: "PingFang SC", size: 10.5) ?? NSFont.systemFont(ofSize: 10.5)
        let titleFont = NSFont(name: "PingFangSC-Semibold", size: 16) ?? NSFont.boldSystemFont(ofSize: 16)
        let headingFont = NSFont(name: "PingFangSC-Medium", size: 12.5) ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        let subColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        let headingColor = NSColor(calibratedRed: 0, green: 0.35, blue: 0.42, alpha: 1)

        var y: CGFloat = 0
        var pageOpen = false

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = CGAffineTransform.identity
            // 翻转为「左上原点」坐标系（CoreText 习惯：y 向下增长）
            ctx.translateBy(x: 0, y: pdfPageH)
            ctx.scaleBy(x: 1, y: -1)
            y = pdfMargin
            pageOpen = true
            drawWatermark()
        }
        /// 每页对角平铺水印（低透明度，正文绘制在其上）
        func drawWatermark() {
            let wm = Watermark.current
            guard wm.active else { return }
            ctx.saveGState()
            ctx.setAlpha(0.08)
            let wmFont = NSFont(name: "PingFang SC", size: 26) ?? NSFont.systemFont(ofSize: 26)
            let attr = NSAttributedString(string: wm.text, attributes: [.font: wmFont, .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)])
            let cfAttr = attr as CFAttributedString
            let framesetter = CTFramesetterCreateWithAttributedString(cfAttr)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: pdfPageW, height: 60), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            let c = CGPoint(x: pdfPageW / 2, y: pdfPageH / 2)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: -18 * .pi / 180)
            ctx.translateBy(x: -c.x, y: -c.y)
            for line in lines {
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: c.x - width / 2, y: c.y - 20)
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
        }
        func endPage() {
            if pageOpen {
                ctx.endPDFPage()
                pageOpen = false
            }
        }
        /// 绘制一段自动折行文本，返回总行数
        @discardableResult
        func drawText(_ text: String, font: NSFont, color: NSColor, lineH: CGFloat) -> Int {
            if text.isEmpty { return 0 }
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let cfAttr = attr as CFAttributedString
            let framesetter = CTFramesetterCreateWithAttributedString(cfAttr)
            let usableW = pdfPageW - pdfMargin * 2
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: usableW, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard !lines.isEmpty else { return 0 }
            // 预计算各折行起点（用于换页时按行累计）
            for line in lines {
                if y + lineH > pdfPageH - pdfMargin {
                    endPage()
                    beginPage()
                }
                ctx.textPosition = CGPoint(x: pdfMargin, y: y)
                CTLineDraw(line, ctx)
                y += lineH
            }
            return lines.count
        }

        beginPage()

        // 标题 + 元信息
        drawText("\(title)（共 \(messages.count) 条）", font: titleFont, color: textColor, lineH: 26)
        let genTime = Date()
        drawText("WeChatExporter 本地离线导出 · 生成时间 \(genTime.formatted(date: .abbreviated, time: .shortened))",
                  font: messageFont, color: subColor, lineH: 15)
        y += 8

        // 正文：按月分节 + 逐条消息（长消息折行）
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "MM-dd HH:mm"
        timeFmt.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "yyyy-MM"
        monthFmt.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        var lastMonth = ""
        for m in messages {
            if let ts = m.timestamp {
                let month = monthFmt.string(from: ts)
                if month != lastMonth {
                    y += 6
                    drawText(month, font: headingFont, color: headingColor, lineH: 22)
                    y += 2
                    lastMonth = month
                }
            }
            let timeStr = m.timestamp.map { timeFmt.string(from: $0) } ?? ""
            var text = m.text
            if text.isEmpty { text = "（非文本消息）" }
            text = (timeStr.isEmpty ? "\(m.sender)：" : "\(timeStr) \(m.sender)：") + text
            drawText(text, font: messageFont, color: textColor, lineH: 16)
            y += 3
        }

        endPage()
        ctx.closePDF()

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw EBookError.writeFailed("PDF 文件未生成")
        }
        return outURL
    }

    // MARK: - EPUB 内容模板

    private static let containerXml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:opendata:storage">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private static func opfXML(title: String, stamp: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2008/epub/package" version="3.0" xml:lang="zh-CN" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">wxexport-\(stamp)</dc:identifier>
            <dc:title>\(esc(title))</dc:title>
            <dc:language>zh-CN</dc:language>
            <dc:creator>WeChatExporter</dc:creator>
            <meta property="dcterms:modified">\(stamp)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
    }

    private static let navXhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2009/epub">
      <head><title>目录</title></head>
      <body><nav epub:type="toc"><h1>目录</h1><ol><li><a href="chapter1.xhtml">聊天记录</a></li></ol></nav></body>
    </html>
    """

    private static func ncxXML(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/zbook/2005/ncx/" version="2005-1">
          <head><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>
          <docTitle><text>\(esc(title))</text></docTitle>
          <navMap><navPoint id="np1" playOrder="1"><navLabel><text>聊天记录</text></navLabel><content src="chapter1.xhtml"/></navPoint></navMap>
        </ncx>
        """
    }

    private static let epubCSS = """
    body{font-family:serif;line-height:1.7}h1{font-size:1.4em}h2{font-size:1.15em;border-bottom:1px solid #ccc;padding-bottom:4px}p{margin:0.4em 0}.sender{font-weight:bold}.time{color:#666;font-size:0.85em}.meta{color:#666;font-size:0.85em}
    """

    /// 消息按月份分节，生成阅读器友好的 XHTML 章节
    private static func epubChapterXhtml(messages: [ChatMessage], title: String) -> String {
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "yyyy-MM"
        monthFmt.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "MM-dd HH:mm"
        timeFmt.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        var body = "<h1>\(esc(title))</h1>"
        body += "<p class=\"meta\">共 \(messages.count) 条消息 · 由 WeChatExporter 本地生成</p>"
        if !Watermark.plainLine().isEmpty {
            body += "<p class=\"meta\" style=\"text-align:center;opacity:.6\">\(esc(Watermark.plainLine()))</p>"
        }
        var lastMonth = ""
        for m in messages {
            let month = m.timestamp.map { monthFmt.string(from: $0) } ?? "其他"
            if month != lastMonth {
                body += "<h2>\(esc(month))</h2>"
                lastMonth = month
            }
            let timeStr = m.timestamp.map { timeFmt.string(from: $0) } ?? ""
            if m.text.isEmpty {
                body += "<p><span class=\"sender\">\(esc(m.sender))</span><span class=\"time\">[\(esc(timeStr))] </span><em>（非文本消息）</em></p>"
            } else {
                let safe = esc(m.text).replacingOccurrences(of: "\n", with: "<br/>")
                body += "<p><span class=\"sender\">\(esc(m.sender))</span><span class=\"time\">[\(esc(timeStr))] </span>\(safe)</p>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2009/epub">
        <head><title>\(esc(title))</title></head>
        <body>\(body)
        </body>
        </html>
        """
    }

    // MARK: - 工具

    /// XML 转义
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 文件名清洗（保留中文，去掉非法字符）
    static func sanitizeForFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var out = s.unicodeScalars
            .filter { $0.value >= 32 && !bad.contains($0) }
            .map { Character($0) }
            .reduce(into: "") { $0.append($1) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "聊天记录" : out
    }

    // MARK: - 自实现 stored-ZIP（EPUB mimetype 规范必须 stored 且为第一个条目）

    enum StoredZip {
        enum ZipError: LocalizedError {
            case writeFailed(String)
            var errorDescription: String? {
                switch self {
                case .writeFailed(let m): return m
                }
            }
        }

        /// 全部条目用 stored（method 0）写入；条目顺序即写入顺序。
        static func write(entries: [(name: String, data: Data)], to url: URL) throws {
            var out = Data()
            var central = Data()
            let table = Self.makeCrcTable()
            let (dosTime, dosDate) = Self.dosDateTime(Date())

            for e in entries {
                let nameBytes = Data(e.name.utf8)
                let crc = Self.crc32(e.data, table: table)
                let localStart = UInt32(out.count)

                // 本地文件头（30 字节定长）
                out.appendLE(UInt32(0x04034B50))
                out.appendLE(UInt16(20))                       // version needed
                out.appendLE(UInt16(0x0800))                   // flags：bit11 UTF-8 文件名
                out.appendLE(UInt16(0))                         // method 0 stored
                out.appendLE(dosTime)
                out.appendLE(dosDate)
                out.appendLE(crc)
                out.appendLE(UInt32(e.data.count))
                out.appendLE(UInt32(e.data.count))
                out.appendLE(UInt16(nameBytes.count))
                out.appendLE(UInt16(0))                         // extra len
                out.append(nameBytes)
                out.append(e.data)

                // 中央目录条目（46 字节定长）
                central.appendLE(UInt32(0x02014B50))
                central.appendLE(UInt16(20))                     // made by
                central.appendLE(UInt16(20))                      // version needed
                central.appendLE(UInt16(0x0800))
                central.appendLE(UInt16(0))
                central.appendLE(dosTime)
                central.appendLE(dosDate)
                central.appendLE(crc)
                central.appendLE(UInt32(e.data.count))
                central.appendLE(UInt32(e.data.count))
                central.appendLE(UInt16(nameBytes.count))
                central.appendLE(UInt16(0))                       // extra
                central.appendLE(UInt16(0))                       // comment
                central.appendLE(UInt16(0))                       // disk
                central.appendLE(UInt16(0))                       // internal attrs
                central.appendLE(UInt32(0))                       // external attrs
                central.appendLE(localStart)
                central.append(nameBytes)
            }

            let centralStart = UInt32(out.count)
            out.append(central)

            // EOCD
            out.appendLE(UInt32(0x06054B50))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(entries.count))
            out.appendLE(UInt16(entries.count))
            out.appendLE(UInt32(central.count))
            out.appendLE(centralStart)
            out.appendLE(UInt16(0))                               // comment len

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try out.write(to: url, options: .atomic)
            } catch {
                throw ZipError.writeFailed(error.localizedDescription)
            }
        }

        // CRC32（反射多项式 0xEDB88320，基于未压缩数据）
        private static func makeCrcTable() -> [UInt32] {
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var crc = UInt32(i)
                for _ in 0..<8 {
                    crc = (crc & 1 == 1) ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
                }
                table[i] = crc
            }
            return table
        }

        private static func crc32(_ data: Data, table: [UInt32]) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFFFFFF
        }

        private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
            let cal = Calendar.current
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let time: UInt16 = (UInt16(c.hour ?? 0) << 11) | (UInt16(c.minute ?? 0) << 5) | UInt16((c.second ?? 0) / 2)
            let dateV: UInt16 = (UInt16(max(1980, c.year ?? 2026) - 1980) << 9) | (UInt16(c.month ?? 1) << 5) | UInt16(c.day ?? 1)
            return (time, dateV)
        }
    }
}

// 小端字节追加 helper（文件作用域）
private extension Data {
    @inline(__always)
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    @inline(__always)
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
