import Foundation

enum MarkdownExporter {
    static func write(from sourceDir: URL, contactName: String, into destinationDir: URL) throws -> URL {
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        let safe = sanitize(contactName)
        let stamp = timestamp()
        let out = destinationDir.appendingPathComponent("\(safe)_\(stamp).md")
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var lines: [String] = [
            "# \(contactName)",
            "",
            "> 由 WeChatExporter 导出",
            "",
        ]

        if FileManager.default.fileExists(atPath: jsonURL.path),
           let data = try? Data(contentsOf: jsonURL),
           let root = try? JSONSerialization.jsonObject(with: data) {
            let rows = messageRows(from: root)
            for row in rows {
                let source = (row["message"] as? [String: Any]) ?? row
                let time = stringField(row, keys: ["time", "timestamp_str"])
                    ?? stringField(source, keys: ["time", "timestamp_str"])
                    ?? ""
                let sender = stringField(row, keys: ["sender_display_name", "sender", "from"])
                    ?? stringField(source, keys: ["sender_display_name", "sender"])
                    ?? "未知"
                let content = stringField(row, keys: ["snippet", "content", "text"])
                    ?? stringField(source, keys: ["snippet", "content", "text"])
                    ?? ""
                let media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
                lines.append("### \(time) · \(sender)")
                if !content.isEmpty {
                    lines.append(content)
                }
                for path in media {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    lines.append("- 附件：`\(name)`")
                }
                lines.append("")
            }
        } else {
            let txt = sourceDir.appendingPathComponent("chat.txt")
            if let text = try? String(contentsOf: txt, encoding: .utf8) {
                lines.append("```")
                lines.append(text)
                lines.append("```")
            }
        }

        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
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
