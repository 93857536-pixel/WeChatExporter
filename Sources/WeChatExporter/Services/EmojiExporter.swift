import Foundation

/// 从 wx-cli 导出的 JSON 中解析表情 XML，下载 GIF/PNG 到 media/emojis/
enum EmojiExporter {
    private static let emojiTagPattern = #"<emoji\b[^>]*(?:/>|>[^<]*</emoji>)"#
    private static let attrPattern = #"(\w+)="([^"]*)""#

    static func exportEmojis(in outputDir: URL, log: @escaping (String) -> Void) async -> Int {
        let jsonURL = outputDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              var root = try? JSONSerialization.jsonObject(with: data) else {
            return 0
        }

        guard var items = extractMutableItems(from: &root), !items.isEmpty else { return 0 }

        let emojiDir = outputDir.appendingPathComponent("media/emojis", isDirectory: true)
        try? FileManager.default.createDirectory(at: emojiDir, withIntermediateDirectories: true)

        var downloaded = 0
        var seenNames = Set<String>()

        for index in items.indices {
            let xmlSources = emojiXMLSources(from: items[index])
            guard !xmlSources.isEmpty else { continue }

            for xml in xmlSources {
                let attrs = parseAttributes(from: xml)
                guard let urlString = pickURL(from: attrs),
                      let url = URL(string: unescapeXML(urlString)) else { continue }

                let filename = uniqueFilename(base: makeFilename(attrs: attrs, fallbackIndex: index), seen: &seenNames)
                let dest = emojiDir.appendingPathComponent(filename)

                if FileManager.default.fileExists(atPath: dest.path) {
                    appendMediaFile(to: &items[index], path: "media/emojis/\(filename)")
                    downloaded += 1
                    continue
                }

                if await download(url: url, to: dest) {
                    appendMediaFile(to: &items[index], path: "media/emojis/\(filename)")
                    downloaded += 1
                    log("已下载表情：\(filename)")
                } else {
                    log("表情下载失败：\(filename)")
                }
            }
        }

        guard downloaded > 0 else { return 0 }

        writeItems(items, to: &root)
        if let newData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: jsonURL)
        }
        log("共导出 \(downloaded) 个表情文件 → media/emojis/")
        return downloaded
    }

    // MARK: - JSON helpers

    private static func extractMutableItems(from root: inout Any) -> [[String: Any]]? {
        if var dict = root as? [String: Any] {
            if var items = dict["items"] as? [[String: Any]] { return items }
            if var messages = dict["messages"] as? [[String: Any]] { return messages }
            if var results = dict["results"] as? [[String: Any]] { return results }
        }
        if let array = root as? [[String: Any]] { return array }
        return nil
    }

    private static func writeItems(_ items: [[String: Any]], to root: inout Any) {
        guard var dict = root as? [String: Any] else {
            if root is [[String: Any]] { root = items; return }
            return
        }
        if dict["items"] != nil { dict["items"] = items }
        else if dict["messages"] != nil { dict["messages"] = items }
        else if dict["results"] != nil { dict["results"] = items }
        root = dict
    }

    private static func appendMediaFile(to item: inout [String: Any], path: String) {
        var files = item["media_files"] as? [String] ?? []
        if !files.contains(path) { files.append(path) }
        item["media_files"] = files
    }

    // MARK: - XML / URL extraction

    private static func emojiXMLSources(from item: [String: Any]) -> [String] {
        var texts: [String] = []
        collectStrings(from: item, into: &texts)
        var xmls: [String] = []
        for text in texts {
            for match in matches(for: emojiTagPattern, in: text) {
                if !xmls.contains(match) { xmls.append(match) }
            }
        }
        return xmls
    }

    private static func collectStrings(from value: Any, into out: inout [String]) {
        switch value {
        case let s as String where s.contains("<emoji"):
            out.append(s)
        case let dict as [String: Any]:
            for v in dict.values { collectStrings(from: v, into: &out) }
        case let array as [Any]:
            for v in array { collectStrings(from: v, into: &out) }
        default:
            break
        }
    }

    private static func parseAttributes(from xml: String) -> [String: String] {
        var attrs: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: attrPattern) else { return attrs }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: xml),
                  let valRange = Range(match.range(at: 2), in: xml) else { continue }
            attrs[String(xml[keyRange]).lowercased()] = String(xml[valRange])
        }
        return attrs
    }

    private static func pickURL(from attrs: [String: String]) -> String? {
        for key in ["cdnurl", "tpurl", "encrypturl", "externurl", "thumburl", "cdnthumburl"] {
            if let value = attrs[key], !value.isEmpty, value != "null" { return value }
        }
        return nil
    }

    private static func makeFilename(attrs: [String: String], fallbackIndex: Int) -> String {
        let md5 = attrs["md5"] ?? attrs["androidmd5"] ?? attrs["externmd5"] ?? "emoji_\(fallbackIndex)"
        let ext = guessExtension(attrs: attrs)
        return sanitizeFilename("\(md5).\(ext)")
    }

    private static func guessExtension(attrs: [String: String]) -> String {
        if attrs["type"] == "2" { return "gif" }
        for key in ["cdnurl", "tpurl", "externurl", "thumburl"] {
            if let url = attrs[key]?.lowercased() {
                if url.contains(".gif") { return "gif" }
                if url.contains(".png") { return "png" }
                if url.contains(".jpg") || url.contains(".jpeg") { return "jpg" }
                if url.contains(".webp") { return "webp" }
            }
        }
        return "gif"
    }

    private static func uniqueFilename(base: String, seen: inout Set<String>) -> String {
        if seen.insert(base).inserted { return base }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            if seen.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func matches(for pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Download

    private static func download(url: URL, to dest: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return false
            }
            try data.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
