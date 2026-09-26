import Foundation

/// 过滤导出（SPEC §4）：对导出根目录下每个会话的 chat.json/txt/csv 做行级过滤，
/// 保留 [fromDate, toDate] 区间内且命中任一关键词（不区分大小写，空=不过滤内容）的消息。
/// 返回每个会话 (保留数, 总数)；总数 0 表示该会话无数据。
enum ExportFilterService {
    struct Result: Codable {
        let kept: Int
        let total: Int
    }

    /// 过滤单会话目录（dir 下的 chat.json / chat.txt / chat.csv 原地重写）。
    /// 导出管线在每会话产物生成后调用（SPEC §4：过滤先于脱敏/索引/报告）。
    @discardableResult
    static func filterContactDir(
        _ dir: URL,
        contactName: String,
        fromDate: String,
        toDate: String,
        keywords: String,
        log: @escaping (String) -> Void
    ) -> Result {
        let kw = parseKeywords(keywords)
        let fromTs = dateToStartTimestamp(fromDate)
        let toTs = dateToEndTimestamp(toDate)
        guard fromTs != nil || toTs != nil || !kw.isEmpty else {
            log("过滤未生效（无日期区间与关键词）")
            return Result(kept: 0, total: 0)
        }
        let jsonURL = dir.appendingPathComponent("chat.json")
        let rows = loadRows(jsonURL)
        let total = rows.count
        let keptRows = filterRows(rows, fromTs: fromTs, toTs: toTs, kw: kw)
        guard !keptRows.isEmpty else {
            log("过滤：\(contactName) 0 / \(total) 条保留（无命中）")
            return Result(kept: 0, total: total)
        }
        writeArtifacts(keptRows, sessionName: contactName, in: dir, jsonURL: jsonURL)
        log("过滤：\(contactName) 保留 \(keptRows.count) / \(total) 条（\(fromDate.isEmpty ? "不限起" : fromDate) ~ \(toDate.isEmpty ? "不限止" : toDate)，关键词 \(kw.count) 个）")
        return Result(kept: keptRows.count, total: total)
    }

    /// 对导出根目录做递归过滤（无头模式 / 重跑用）：逐个含 chat.json 的会话目录应用。
    @discardableResult
    static func apply(
        in base: URL,
        fromDate: String,
        toDate: String,
        keywords: String,
        log: @escaping (String) -> Void
    ) -> [String: Result] {
        let fm = FileManager.default
        var jsonFiles: [URL] = []
        if let en = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.lastPathComponent == "chat.json" {
                jsonFiles.append(url)
            }
        }
        var results: [String: Result] = [:]
        for jsonURL in jsonFiles {
            let dir = jsonURL.deletingLastPathComponent()
            let sessionName = dir.lastPathComponent.isEmpty ? dir.path : dir.lastPathComponent
            results[sessionName] = filterContactDir(
                dir, contactName: sessionName,
                fromDate: fromDate, toDate: toDate, keywords: keywords, log: log)
        }
        let keptTotal = results.values.reduce(0) { $0 + $1.kept }
        let totalAll = results.values.reduce(0) { $0 + $1.total }
        log("过滤完成：保留 \(keptTotal) / \(totalAll) 条（共 \(results.count) 个会话目录）")
        return results
    }

    // MARK: - 核心（行级过滤，chat.json 两种结构）

    static func parseKeywords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func filterRows(_ rows: [[String: Any]], fromTs: Int?, toTs: Int?, kw: [String]) -> [[String: Any]] {
        rows.filter { row in
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            let ts = intField(src, ["create_time", "timestamp"]) ?? intField(row, ["create_time", "timestamp"])
            if let fromTs, let ts, ts < fromTs { return false }
            if let toTs, let ts, ts > toTs { return false }
            guard !kw.isEmpty else { return true }
            let content = (stringField(row, ["snippet", "content", "text"])
                ?? stringField(src, ["content", "text"]) ?? "").lowercased()
            return kw.contains { content.contains($0) }
        }
    }

    private static func loadRows(_ jsonURL: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let arr = root as? [[String: Any]] { return arr }
        if let dict = root as? [String: Any] {
            return (dict["items"] as? [[String: Any]])
                ?? (dict["messages"] as? [[String: Any]])
                ?? (dict["results"] as? [[String: Any]])
                ?? []
        }
        return []
    }

    private static func writeArtifacts(_ rows: [[String: Any]], sessionName: String, in dir: URL, jsonURL: URL) {
        if let out = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
            try? out.write(to: jsonURL)
        }
        let txtURL = dir.appendingPathComponent("chat.txt")
        if FileManager.default.fileExists(atPath: txtURL.path) {
            try? renderTxt(rows, sessionName: sessionName).write(to: txtURL, atomically: true, encoding: .utf8)
        }
        let csvURL = dir.appendingPathComponent("chat.csv")
        if FileManager.default.fileExists(atPath: csvURL.path) {
            try? renderCsv(rows).write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 渲染（与 ChatExporter 产物格式同口径）

    private static func renderTxt(_ rows: [[String: Any]], sessionName: String) -> String {
        var out = "微信聊天记录: \(sessionName)（过滤导出）\n"
        out += "总消息数: \(rows.count)\n"
        let first = firstTimestamp(rows)
        let last = lastTimestamp(rows)
        out += "时间范围: \(fmt(first)) ~ \(fmt(last))\n"
        out += String(repeating: "=", count: 60) + "\n\n"
        for row in rows {
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            let time = fmt(intField(src, ["create_time", "timestamp"]))
            let sender = stringField(row, ["sender_display_name", "sender"])
                ?? stringField(src, ["sender_display_name", "sender"]) ?? "未知"
            let content = stringField(row, ["snippet", "content"])
                ?? stringField(src, ["content"]) ?? ""
            out += "[\(time)] \(sender): \(content)\n"
        }
        return out
    }

    private static func renderCsv(_ rows: [[String: Any]]) -> String {
        var out = "\u{FEFF}时间,发送者,内容\n"
        for row in rows {
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            let time = fmt(intField(src, ["create_time", "timestamp"]))
            let sender = (stringField(row, ["sender_display_name", "sender"])
                ?? stringField(src, ["sender_display_name", "sender"]) ?? "未知")
                .replacingOccurrences(of: "\"", with: "\"\"")
            let content = (stringField(row, ["snippet", "content"])
                ?? stringField(src, ["content"]) ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
            out += "\"\(time)\",\"\(sender)\",\"\(content)\"\n"
        }
        return out
    }

    private static func dateToStartTimestamp(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard let d = f.date(from: s) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    private static func dateToEndTimestamp(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard let d = f.date(from: s) else { return nil }
        // 含当日：取 23:59:59
        return Int(d.timeIntervalSince1970) + 86_399
    }

    private static func fmt(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func firstTimestamp(_ rows: [[String: Any]]) -> Int? {
        rows.compactMap { row in
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            return intField(src, ["create_time", "timestamp"]) ?? intField(row, ["create_time", "timestamp"])
        }.min()
    }

    private static func lastTimestamp(_ rows: [[String: Any]]) -> Int? {
        rows.compactMap { row in
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            return intField(src, ["create_time", "timestamp"]) ?? intField(row, ["create_time", "timestamp"])
        }.max()
    }

    private static func intField(_ row: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let v = row[k] {
                if let n = v as? Int { return n }
                if let n = v as? Double { return Int(n) }
                if let s = v as? String, let n = Int(s) { return n }
            }
        }
        return nil
    }

    private static func stringField(_ row: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = row[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}
