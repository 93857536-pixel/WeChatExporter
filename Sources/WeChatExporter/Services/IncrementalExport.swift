import Foundation

/// 增量导出：按「联系人 id + 导出目录」维护时间戳游标。
/// 导出产物（chat.json/txt/csv）过滤为只保留 timestamp > 游标的消息；
/// 无新增时清空本次产物并返回 0，调用方跳过该联系人。
enum IncrementalExport {
    struct Cursor: Codable {
        let contactID: String
        let exportDir: String
        let lastTimestamp: Int
        let lastRun: String
    }

    static func cursorFile() -> URL {
        AppPaths.appSupport.appendingPathComponent("export-cursors.json")
    }

    /// 读取游标（不存在返回 nil）
    static func loadCursor(contactID: String, exportDir: String) -> Int? {
        guard let data = try? Data(contentsOf: cursorFile()) else { return nil }
        let all: [Cursor]
        do { all = try JSONDecoder().decode([Cursor].self, from: data) } catch { return nil }
        let m = all.first { $0.contactID == contactID && $0.exportDir == exportDir }
        return m?.lastTimestamp
    }

    /// 回写游标（只保留同一键的最新记录）
    static func saveCursor(contactID: String, exportDir: String, lastTimestamp: Int) {
        var all: [Cursor]
        if let data = try? Data(contentsOf: cursorFile()) {
            do { all = try JSONDecoder().decode([Cursor].self, from: data) } catch { all = [] }
        } else {
            all = []
        }
        all.removeAll { $0.contactID == contactID && $0.exportDir == exportDir }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        all.append(Cursor(
            contactID: contactID,
            exportDir: exportDir,
            lastTimestamp: lastTimestamp,
            lastRun: f.string(from: Date())
        ))
        do {
            let data = try JSONEncoder().encode(all)
            let dir = cursorFile().deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: cursorFile(), options: .atomic)
        } catch {
            NSLog("增量游标写入失败：\(error.localizedDescription)")
        }
    }

    /// 过滤导出产物：chat.json / chat.txt / chat.csv 只保留 timestamp > after 的消息。
    /// 返回保留条数；0 表示无新增（产物已被清空）。
    static func filterArtifacts(
        in outputDir: URL,
        contactID: String,
        after: Int,
        log: @escaping (String) -> Void
    ) -> Int {
        let jsonURL = outputDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            log("增量导出：未找到 chat.json，跳过过滤")
            return 0
        }
        let rows: [[String: Any]]
        do {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL))
            if let array = root as? [[String: Any]] {
                rows = array
            } else if let dict = root as? [String: Any] {
                rows = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else {
                rows = []
            }
        } catch {
            log("增量导出：chat.json 解析失败，跳过过滤")
            return 0
        }

        func tsOf(_ row: [String: Any]) -> Int {
            let nested = row["message"] as? [String: Any]
            let source = nested ?? row
            for el in [source, row] {
                for key in ["timestamp", "create_time"] {
                    if let v = el[key] {
                        if let n = v as? Int { return n }
                        if let n = v as? Double { return Int(n) }
                        if let s = v as? String, let n = Int(s) { return n }
                    }
                }
            }
            return 0
        }

        let kept = rows.filter { tsOf($0) > after }
        guard !kept.isEmpty else {
            // 无新增：清空本次文字产物，避免生成空 HTML
            for name in ["chat.json", "chat.txt", "chat.csv"] {
                try? FileManager.default.removeItem(at: outputDir.appendingPathComponent(name))
            }
            log("增量导出：\(contactID) 无新增消息（上次游标 \(after)），跳过")
            return 0
        }

        // chat.json：保留原结构（直接数组则重写数组；外层 dict 则更新对应键）
        do {
            let root: Any
            if (try? JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL))) is [[String: Any]] {
                root = kept
            } else {
                var dict = (try! JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL))) as! [String: Any]
                if dict["items"] != nil { dict["items"] = kept }
                else if dict["messages"] != nil { dict["messages"] = kept }
                else { dict["results"] = kept }
                root = dict
            }
            let data = try JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
            try data.write(to: jsonURL)
        } catch {
            log("增量导出：chat.json 重写失败（\(error.localizedDescription)），已过滤 JSON 但 txt/csv 保持原样")
        }

        // chat.txt / chat.csv：从过滤后的 kept 重建
        if FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("chat.txt").path) {
            var txt = "微信聊天记录（增量）\n新增消息数: \(kept.count)\n时间起点: \(after)\n"
            txt += String(repeating: "=", count: 60) + "\n\n"
            for row in kept { txt += Self.txtLine(row) + "\n" }
            try? txt.data(using: .utf8)?.write(to: outputDir.appendingPathComponent("chat.txt"))
        }
        if FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("chat.csv").path) {
            var csv = "\u{FEFF}时间,发送者,类型,内容\n"
            for row in kept {
                csv += Self.csvLine(row)
            }
            try? csv.data(using: .utf8)?.write(to: outputDir.appendingPathComponent("chat.csv"))
        }

        log("增量导出：\(contactID) 保留新增 \(kept.count) 条（上次游标 \(after)）")
        return kept.count
    }

    /// 导出产物中 chat.json 的最大时间戳（无数据返回 0）
    static func maxTimestamp(in outputDir: URL) -> Int {
        let jsonURL = outputDir.appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: jsonURL) else { return 0 }
        let rows: [[String: Any]]
        if let root = try? JSONSerialization.jsonObject(with: data) {
            if let array = root as? [[String: Any]] {
                rows = array
            } else if let dict = root as? [String: Any] {
                rows = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else {
                return 0
            }
        } else {
            return 0
        }
        var maxTs = 0
        for row in rows {
            let nested = row["message"] as? [String: Any]
            let source = nested ?? row
            for el in [source, row] {
                var found = false
                for key in ["timestamp", "create_time"] {
                    if let v = el[key] {
                        var n = 0
                        if let iv = v as? Int { n = iv; found = true }
                        else if let dv = v as? Double { n = Int(dv); found = true }
                        else if let s = v as? String, let pv = Int(s) { n = pv; found = true }
                        if found {
                            maxTs = max(maxTs, n)
                            break
                        }
                    }
                }
                if found { break }
            }
        }
        return maxTs
    }

    // MARK: - txt/csv 行重建（与 ChatExporter 输出口径一致）

    private static func displayContent(_ row: [String: Any]) -> String {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row
        func s(_ el: [String: Any], _ keys: [String]) -> String? {
            for k in keys {
                if let v = el[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        return s(row, ["content", "text", "snippet"]) ?? s(source, ["content", "text", "snippet"]) ?? ""
    }

    private static func senderOf(_ row: [String: Any]) -> String {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row
        func s(_ el: [String: Any], _ keys: [String]) -> String? {
            for k in keys {
                if let v = el[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        return s(row, ["sender_display_name", "sender", "from"])
            ?? s(source, ["sender_display_name", "sender"])
            ?? "未知"
    }

    private static func timeOf(_ row: [String: Any]) -> String {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row
        func s(_ el: [String: Any], _ keys: [String]) -> String? {
            for k in keys {
                if let v = el[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        return s(row, ["time", "timestamp_str"]) ?? s(source, ["time", "timestamp_str"]) ?? ""
    }

    private static func typeOf(_ row: [String: Any]) -> String {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row
        func s(_ el: [String: Any], _ keys: [String]) -> String? {
            for k in keys {
                if let v = el[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        return s(row, ["type_name", "type"]) ?? s(source, ["type_name"]) ?? "消息"
    }

    private static func txtLine(_ row: [String: Any]) -> String {
        let time = timeOf(row)
        let sender = senderOf(row)
        let content = displayContent(row)
        return "[\(time)] \(sender): \(content)"
    }

    private static func csvLine(_ row: [String: Any]) -> String {
        let time = timeOf(row)
        let sender = senderOf(row)
        let type = typeOf(row)
        let content = displayContent(row).replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(time)\",\"\(sender)\",\"\(type)\",\"\(content)\"\n"
    }
}
