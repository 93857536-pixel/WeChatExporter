import CommonCrypto
import Foundation

/// 从 wx-cli 导出的 JSON 中解析图片 XML，下载或解密后在 HTML 中内嵌显示。
enum ImageExporter {
    private static let imgTagPattern = #"<img\b[^>]*(?:/>|>[^<]*</img>)"#
    private static let attrPattern = #"(\w+)="([^"]*)""#

    static func exportImages(in outputDir: URL, log: @escaping (String) -> Void) async -> Int {
        let jsonURL = outputDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              var root = try? JSONSerialization.jsonObject(with: data) else {
            return 0
        }

        guard var items = extractMutableItems(from: &root), !items.isEmpty else { return 0 }

        let imageDir = outputDir.appendingPathComponent("media/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        var processed = 0
        var seenNames = Set<String>()

        for index in items.indices {
            let xmlSources = imageXMLSources(from: items[index])
            guard !xmlSources.isEmpty else { continue }

            for xml in xmlSources {
                let attrs = parseAttributes(from: xml)
                let filename = uniqueFilename(base: makeFilename(attrs: attrs, fallbackIndex: index), seen: &seenNames)
                let dest = imageDir.appendingPathComponent(filename)
                let mediaPath = "media/images/\(filename)"

                if FileManager.default.fileExists(atPath: dest.path) {
                    appendMediaFile(to: &items[index], path: mediaPath)
                    processed += 1
                    continue
                }

                if await downloadImage(attrs: attrs, to: dest) {
                    appendMediaFile(to: &items[index], path: mediaPath)
                    processed += 1
                    log("已下载图片：\(filename)")
                } else {
                    log("图片下载失败：\(filename)")
                }
            }
        }

        let decoded = await DatImageDecoder.decodeDatFiles(in: outputDir, log: log)
        processed += decoded

        guard processed > 0 else { return 0 }

        writeItems(items, to: &root)
        if let newData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: jsonURL)
        }
        log("共处理 \(processed) 张聊天图片")
        return processed
    }

    // MARK: - JSON helpers

    private static func extractMutableItems(from root: inout Any) -> [[String: Any]]? {
        if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] { return items }
            if let messages = dict["messages"] as? [[String: Any]] { return messages }
            if let results = dict["results"] as? [[String: Any]] { return results }
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

    // MARK: - XML

    private static func imageXMLSources(from item: [String: Any]) -> [String] {
        var texts: [String] = []
        collectStrings(from: item, into: &texts)
        var xmls: [String] = []
        for text in texts where text.contains("<img") {
            for match in matches(for: imgTagPattern, in: text) where !xmls.contains(match) {
                xmls.append(match)
            }
        }
        return xmls
    }

    private static func collectStrings(from value: Any, into out: inout [String]) {
        switch value {
        case let s as String:
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
        for key in ["cdnbigimgurl", "cdnmidimgurl", "cdnthumburl", "cdnurl", "tpurl", "encrypturl", "attachurl"] {
            if let value = attrs[key], !value.isEmpty, value != "null" { return value }
        }
        return nil
    }

    private static func makeFilename(attrs: [String: String], fallbackIndex: Int) -> String {
        let md5 = attrs["md5"] ?? attrs["originsourcemd5"] ?? "image_\(fallbackIndex)"
        return sanitizeFilename("\(md5).\(guessExtension(attrs: attrs))")
    }

    private static func guessExtension(attrs: [String: String]) -> String {
        for key in ["cdnbigimgurl", "cdnmidimgurl", "cdnthumburl", "cdnurl"] {
            if let url = attrs[key]?.lowercased() {
                if url.contains(".png") { return "png" }
                if url.contains(".webp") { return "webp" }
                if url.contains(".gif") { return "gif" }
                if url.contains(".jpg") || url.contains(".jpeg") { return "jpg" }
            }
        }
        return "jpg"
    }

    // MARK: - Download

    private static func downloadImage(attrs: [String: String], to dest: URL) async -> Bool {
        guard let urlString = pickURL(from: attrs), !urlString.isEmpty else { return false }
        var data = await fetchURL(urlString)
        if data == nil, let encrypt = attrs["encrypturl"], !encrypt.isEmpty,
           let aesKey = attrs["aeskey"], !aesKey.isEmpty,
           let enc = await fetchURL(encrypt),
           let decrypted = decryptImage(enc, aesKeyHex: aesKey) {
            data = decrypted
        }
        guard let data, let normalized = normalizeImageData(data) else { return false }
        do {
            try normalized.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func fetchURL(_ urlString: String) async -> Data? {
        let cleaned = unescapeXML(urlString)
        guard let url = URL(string: cleaned) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func decryptImage(_ data: Data, aesKeyHex: String) -> Data? {
        guard let key = Data(hexString: aesKeyHex), key.count == 16 else { return nil }
        var outLength = 0
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    key.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLength)
    }

    static func normalizeImageData(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        if sniffImageMIME(data) != nil { return data }
        return DatImageDecoder.tryDecodeInline(data)
    }

    static func sniffImageMIME(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: Array("GIF".utf8)) { return "image/gif" }
        if data.starts(with: Array("RIFF".utf8)), data.count > 12, data[8...11].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
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
}

private extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex else { return nil }
            let byte = hex[index..<next]
            guard let value = UInt8(byte, radix: 16) else { return nil }
            data.append(value)
            index = next
        }
        self = data
    }
}
