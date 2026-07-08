import Foundation

/// 将导出目录中的聊天记录与媒体打包为单个自包含 HTML 文件（图片/表情/音视频以 base64 内嵌）。
enum SingleFileExporter {
    struct MessageRow {
        let time: String
        let sender: String
        let type: String
        let content: String
        let mediaPaths: [String]
    }

    /// 从已导出的临时目录生成 HTML，写入 `destinationDir`，返回 HTML 文件 URL。
    static func writeHTML(from sourceDir: URL, contactName: String, into destinationDir: URL) throws -> URL {
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw AppError.exportFailed("未找到 chat.json，无法生成单文件导出")
        }

        let rows = try parseMessages(from: jsonURL)
        guard !rows.isEmpty else {
            throw AppError.exportFailed("聊天记录为空，无法生成单文件导出")
        }

        let safeName = sanitizeFilename(contactName.isEmpty ? "聊天记录" : contactName)
        let stamp = Self.fileStamp()
        let outURL = destinationDir.appendingPathComponent("\(safeName)_\(stamp).html")

        let title = escapeHTML(contactName.isEmpty ? "微信聊天记录" : contactName)
        var body = ""
        var embedded = Set<String>()
        for row in rows {
            body += renderMessage(row, sourceDir: sourceDir, embedded: &embedded)
        }
        body += renderOrphanMedia(sourceDir: sourceDir, embedded: &embedded)

        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1"/>
          <title>\(title)</title>
          <style>
            * { box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif; margin: 0; background: #ebebeb; color: #111; }
            header { background: linear-gradient(135deg, #07c160, #06ad56); color: #fff; padding: 20px 24px; }
            header h1 { margin: 0 0 6px; font-size: 22px; }
            header p { margin: 0; opacity: .92; font-size: 13px; }
            main { max-width: 860px; margin: 0 auto; padding: 20px 16px 48px; }
            .msg { background: #fff; border-radius: 10px; padding: 12px 14px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
            .meta { font-size: 12px; color: #666; margin-bottom: 6px; }
            .sender { font-weight: 600; color: #07c160; }
            .type { color: #999; margin-left: 8px; }
            .text { white-space: pre-wrap; word-break: break-word; line-height: 1.55; }
            .media { margin-top: 10px; }
            .media img { max-width: min(100%, 420px); border-radius: 8px; display: block; }
            .media video, .media audio { max-width: 100%; margin-top: 6px; display: block; }
            footer { text-align: center; color: #999; font-size: 12px; padding: 24px; }
          </style>
        </head>
        <body>
          <header>
            <h1>\(title)</h1>
            <p>共 \(rows.count) 条消息 · 单文件导出（媒体已内嵌）· \(stamp)</p>
          </header>
          <main>
        \(body)
          </main>
          <footer>由 WeChatExporter 导出</footer>
        </body>
        </html>
        """

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try html.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    // MARK: - Rendering

    private static func renderMessage(_ row: MessageRow, sourceDir: URL, embedded: inout Set<String>) -> String {
        var mediaHTML = ""
        for rel in row.mediaPaths {
            guard embedded.insert(rel).inserted else { continue }
            if let block = embedMedia(relativePath: rel, sourceDir: sourceDir) {
                mediaHTML += block
            }
        }

        let content = escapeHTML(row.content)
        let showText = !content.isEmpty && content != "[图片]" && content != "[语音]" && content != "[视频]" && content != "[表情]"

        return """
            <article class="msg">
              <div class="meta"><span class="sender">\(escapeHTML(row.sender))</span><span class="type">\(escapeHTML(row.type))</span> · \(escapeHTML(row.time))</div>
              \(showText ? "<div class=\"text\">\(content)</div>" : "")
              \(mediaHTML.isEmpty ? "" : "<div class=\"media\">\(mediaHTML)</div>")
            </article>

        """
    }

    private static func renderOrphanMedia(sourceDir: URL, embedded: inout Set<String>) -> String {
        let mediaRoot = sourceDir.appendingPathComponent("media", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var html = ""
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = "media/" + fileURL.path.replacingOccurrences(of: mediaRoot.path + "/", with: "")
            guard embedded.insert(rel).inserted else { continue }
            guard let block = embedMedia(relativePath: rel, sourceDir: sourceDir) else { continue }
            html += """
                <article class="msg">
                  <div class="meta"><span class="sender">媒体附件</span> · \(escapeHTML(fileURL.lastPathComponent))</div>
                  <div class="media">\(block)</div>
                </article>

            """
        }
        return html
    }

    private static func embedMedia(relativePath: String, sourceDir: URL) -> String? {
        let rel = relativePath.hasPrefix("media/") ? relativePath : "media/\(relativePath)"
        let fileURL = sourceDir.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else { return nil }

        let ext = fileURL.pathExtension.lowercased()
        let b64 = data.base64EncodedString()
        switch ext {
        case "jpg", "jpeg":
            return "<img alt=\"图片\" src=\"data:image/jpeg;base64,\(b64)\"/>"
        case "png":
            return "<img alt=\"图片\" src=\"data:image/png;base64,\(b64)\"/>"
        case "gif":
            return "<img alt=\"表情\" src=\"data:image/gif;base64,\(b64)\"/>"
        case "webp":
            return "<img alt=\"图片\" src=\"data:image/webp;base64,\(b64)\"/>"
        case "wxgf":
            return "<p class=\"text\">[WXGF 图片，请用专用工具查看：\(escapeHTML(fileURL.lastPathComponent))]</p>"
        case "mp3", "m4a", "aac":
            let mime = ext == "mp3" ? "audio/mpeg" : "audio/mp4"
            return "<audio controls src=\"data:\(mime);base64,\(b64)\"></audio>"
        case "mp4", "mov":
            return "<video controls src=\"data:video/mp4;base64,\(b64)\"></video>"
        case "silk":
            return "<p class=\"text\">[语音 SILK 格式：\(escapeHTML(fileURL.lastPathComponent))，大小 \(data.count) 字节]</p>"
        default:
            return "<p class=\"text\">[附件 \(escapeHTML(fileURL.lastPathComponent))，大小 \(data.count) 字节]</p>"
        }
    }

    // MARK: - JSON parsing

    private static func parseMessages(from jsonURL: URL) throws -> [MessageRow] {
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)

        let rawRows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rawRows = array
        } else if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] { rawRows = items }
            else if let messages = dict["messages"] as? [[String: Any]] { rawRows = messages }
            else if let results = dict["results"] as? [[String: Any]] { rawRows = results }
            else { throw AppError.exportFailed("chat.json 中未找到消息列表") }
        } else {
            throw AppError.exportFailed("chat.json 格式不支持")
        }

        return rawRows.map { parseRow($0) }.filter { !$0.sender.isEmpty || !$0.content.isEmpty || !$0.mediaPaths.isEmpty }
    }

    private static func parseRow(_ row: [String: Any]) -> MessageRow {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row

        let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"])
        let time = stringField(row, keys: ["time", "timestamp_str"])
            ?? stringField(source, keys: ["time", "timestamp_str"])
            ?? formatTimestamp(ts)

        let sender = stringField(row, keys: ["sender_display_name", "sender", "from", "display_name"])
            ?? stringField(source, keys: ["sender_display_name", "sender"])
            ?? "未知"

        let msgType = intField(source, keys: ["msg_type", "type"]) ?? intField(row, keys: ["msg_type", "type"])
        let typeName = stringField(row, keys: ["type_name", "type"])
            ?? stringField(source, keys: ["type_name"])
            ?? typeLabel(for: msgType)

        let content = stringField(row, keys: ["snippet", "content", "text", "message", "summary"])
            ?? stringField(source, keys: ["snippet", "content", "text"])
            ?? ""

        var media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
        if media.isEmpty, let array = row["media_files"] as? [Any] {
            media = array.compactMap { $0 as? String }
        }

        return MessageRow(time: time, sender: sender, type: typeName, content: content, mediaPaths: media)
    }

    private static func typeLabel(for type: Int?) -> String {
        guard let type else { return "消息" }
        switch type {
        case 1: return "文本"
        case 3: return "图片"
        case 34: return "语音"
        case 43: return "视频"
        case 47: return "表情"
        case 49: return "链接/文件"
        default: return "类型\(type)"
        }
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
            if let value = row[key] as? Int { return String(value) }
            if let nested = row[key] as? [String: Any] {
                if let text = nested["Text"] as? String { return text }
                if let text = nested["text"] as? String { return text }
                if let emoji = nested["Emoji"] as? String { return "[表情]" }
            }
        }
        return nil
    }

    private static func intField(_ row: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = row[key] as? Int { return value }
            if let value = row[key] as? Int64 { return Int(value) }
            if let value = row[key] as? Double { return Int(value) }
        }
        return nil
    }

    private static func formatTimestamp(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "聊天记录" : cleaned
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
