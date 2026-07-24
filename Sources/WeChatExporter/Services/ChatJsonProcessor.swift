import Foundation

/// 对 CLI 导出的 chat.json 做时间/类型过滤、昵称映射、预览统计。
enum ChatJsonProcessor {
    struct FilterOptions {
        var sinceUnix: Int?
        var untilUnix: Int?
        var enabledTypes: Set<MessageTypeFilter>
        /// 空集合 = 不过滤类型。
        var filterTypes: Bool { !enabledTypes.isEmpty && enabledTypes.count < MessageTypeFilter.allCases.count }
    }

    @discardableResult
    static func applyFilters(to jsonURL: URL, options: FilterOptions, log: ((String) -> Void)? = nil) throws -> Int {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return 0 }
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)
        let (container, rows) = try extractRows(from: root)
        let filtered = rows.filter { row in
            passes(row: row, options: options)
        }
        if filtered.count == rows.count { return filtered.count }

        let rewritten = rewrite(root: root, container: container, rows: filtered)
        let out = try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: jsonURL, options: .atomic)
        log?("已按设置过滤消息：\(rows.count) → \(filtered.count)")
        rewriteTxtIfNeeded(alongside: jsonURL, rows: filtered)
        return filtered.count
    }

    static func applyNicknameMap(to jsonURL: URL, map: [String: String], log: ((String) -> Void)? = nil) throws {
        guard !map.isEmpty, FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)
        let (container, rows) = try extractRows(from: root)
        var changed = 0
        let mapped = rows.map { row -> [String: Any] in
            var copy = row
            var nested = row["message"] as? [String: Any]
            let senderKeys = ["sender", "from"]
            for key in senderKeys {
                if let raw = (copy[key] as? String) ?? (nested?[key] as? String),
                   let nice = map[raw] ?? map[raw.lowercased()],
                   !nice.isEmpty {
                    if copy["sender_display_name"] == nil || (copy["sender_display_name"] as? String)?.isEmpty == true {
                        copy["sender_display_name"] = nice
                        changed += 1
                    }
                    if var n = nested {
                        if n["sender_display_name"] == nil {
                            n["sender_display_name"] = nice
                            nested = n
                        }
                    }
                }
            }
            if let nested { copy["message"] = nested }
            return copy
        }
        let rewritten = rewrite(root: root, container: container, rows: mapped)
        let out = try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: jsonURL, options: .atomic)
        if changed > 0 { log?("已应用群成员昵称映射 \(changed) 处") }
    }

    static func preview(from jsonURL: URL, sourceDir: URL? = nil) -> ExportPreviewResult {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data),
              let (_, rows) = try? extractRows(from: root) else {
            return ExportPreviewResult(contactCount: 1, messageCount: 0, mediaCount: 0, estimatedBytes: 0, byType: [:])
        }

        var byType: [String: Int] = [:]
        var mediaCount = 0
        var bytes: Int64 = Int64(data.count)
        for row in rows {
            let source = (row["message"] as? [String: Any]) ?? row
            let msgType = intField(source, keys: ["msg_type", "type"]) ?? intField(row, keys: ["msg_type", "type"])
            let typeName = stringField(row, keys: ["type_name"]) ?? stringField(source, keys: ["type_name"])
            let label = MessageTypeFilter.matching(msgType: msgType, typeName: typeName)?.title ?? "其他"
            byType[label, default: 0] += 1
            let media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
            mediaCount += media.count
            for path in media {
                let url = resolveMedia(path, sourceDir: sourceDir ?? jsonURL.deletingLastPathComponent())
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    bytes += size.int64Value
                } else {
                    bytes += 80_000
                }
            }
        }
        return ExportPreviewResult(
            contactCount: 1,
            messageCount: rows.count,
            mediaCount: mediaCount,
            estimatedBytes: bytes,
            byType: byType
        )
    }

    static func latestCreateTime(in jsonURL: URL) -> Int? {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data),
              let (_, rows) = try? extractRows(from: root) else { return nil }
        var maxTs = 0
        for row in rows {
            let source = (row["message"] as? [String: Any]) ?? row
            if let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"]) {
                maxTs = max(maxTs, ts)
            }
        }
        return maxTs > 0 ? maxTs : nil
    }

    static func injectVoiceTranscripts(in jsonURL: URL, transcripts: [String: String], log: ((String) -> Void)? = nil) throws {
        guard !transcripts.isEmpty else { return }
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)
        let (container, rows) = try extractRows(from: root)
        var hit = 0
        let mapped = rows.map { row -> [String: Any] in
            var copy = row
            var nested = row["message"] as? [String: Any]
            let source = nested ?? row
            let media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
            for path in media {
                let name = URL(fileURLWithPath: path).lastPathComponent
                if let text = transcripts[name] ?? transcripts[path] {
                    let prefix = "[语音转写] "
                    let existing = (copy["content"] as? String) ?? (nested?["content"] as? String) ?? ""
                    let merged = existing.contains(prefix) ? existing : (existing.isEmpty ? prefix + text : existing + "\n" + prefix + text)
                    copy["content"] = merged
                    copy["snippet"] = merged
                    if var n = nested {
                        n["content"] = merged
                        nested = n
                    }
                    hit += 1
                    break
                }
            }
            if let nested { copy["message"] = nested }
            return copy
        }
        let rewritten = rewrite(root: root, container: container, rows: mapped)
        let out = try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: jsonURL, options: .atomic)
        if hit > 0 { log?("已写入 \(hit) 条语音转写") }
    }

    // MARK: - internals

    private static func passes(row: [String: Any], options: FilterOptions) -> Bool {
        let source = (row["message"] as? [String: Any]) ?? row
        if let since = options.sinceUnix, let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"]), ts < since {
            return false
        }
        if let until = options.untilUnix, let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"]), ts > until {
            return false
        }
        if options.filterTypes {
            let msgType = intField(source, keys: ["msg_type", "type"]) ?? intField(row, keys: ["msg_type", "type"])
            let typeName = stringField(row, keys: ["type_name"]) ?? stringField(source, keys: ["type_name"])
            guard let matched = MessageTypeFilter.matching(msgType: msgType, typeName: typeName) else {
                return options.enabledTypes.contains(.app) // 未知类型归入 app/其他时保留若选了链接
            }
            return options.enabledTypes.contains(matched)
        }
        return true
    }

    private static func extractRows(from root: Any) throws -> (container: String?, rows: [[String: Any]]) {
        if let array = root as? [[String: Any]] {
            return (nil, array)
        }
        if let dict = root as? [String: Any] {
            for key in ["items", "messages", "results"] {
                if let items = dict[key] as? [[String: Any]] {
                    return (key, items)
                }
            }
        }
        throw AppError.exportFailed("chat.json 中未找到消息列表")
    }

    private static func rewrite(root: Any, container: String?, rows: [[String: Any]]) -> Any {
        if container == nil { return rows }
        guard var dict = root as? [String: Any], let key = container else { return rows }
        dict[key] = rows
        return dict
    }

    private static func rewriteTxtIfNeeded(alongside jsonURL: URL, rows: [[String: Any]]) {
        let txt = jsonURL.deletingLastPathComponent().appendingPathComponent("chat.txt")
        var lines: [String] = []
        for row in rows {
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
        try? lines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
    }

    private static func resolveMedia(_ path: String, sourceDir: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return sourceDir.appendingPathComponent(path)
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
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
}
