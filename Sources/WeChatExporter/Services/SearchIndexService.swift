import Foundation
import SQLite3

/// 全文搜索索引（SPEC §1）：导出根目录生成 wce-search.sqlite。
/// 优先 FTS5 虚拟表 wce_fts；不支持时降级普通表 wce_rows + LIKE 查询。
/// 每行 = 一条消息：chat(会话显示名) / ts(Unix秒) / sender / content。
enum SearchIndexService {
    static let fileName = "wce-search.sqlite"

    struct Hit {
        let chat: String
        let ts: Int
        let sender: String
        let content: String

        var snippet: String {
            let limit = 40
            let start = content.index(content.startIndex, offsetBy: min(limit, content.count / 2))
            return String(content.suffix(from: start).prefix(limit * 2))
        }
    }

    // MARK: - 构建

    /// 扫描 base 下所有 chat.json，重建索引。返回入库行数。
    @discardableResult
    static func build(in base: URL, log: @escaping (String) -> Void) -> Int {
        let indexURL = base.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: indexURL)
        var db: OpaquePointer?
        let code = sqlite3_open(indexURL.path, &db)
        guard code == SQLITE_OK, let db else {
            log("搜索索引创建失败：\(String(cString: sqlite3_errstr(code)))")
            return 0
        }
        defer { sqlite3_close(db) }

        let fts5OK = exec(db, "CREATE VIRTUAL TABLE wce_fts USING fts5(chat TEXT, ts UNINDEXED, sender TEXT, content TEXT)")
        if fts5OK {
            _ = exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
            _ = exec(db, "CREATE TABLE chat_sessions(chat TEXT PRIMARY KEY)")
        } else {
            _ = exec(db, "CREATE TABLE wce_rows(chat TEXT, ts INTEGER, sender TEXT, content TEXT)")
            _ = exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
            log("FTS5 不可用，已降级为 LIKE 查询模式")
        }
        setMeta(db, key: "schema_version", value: fts5OK ? "fts5" : "like")

        var files = findChatJSONs(in: base)
        files.sort { $0.path < $1.path }
        var total = 0
        let basePath = base.resolvingSymlinksInPath().path
        for f in files {
            // 会话名 = 相对 base 的第一层目录（categorized: <会话>/文字/chat.json；textOnly: <会话>/chat.json）
            // resolvingSymlinksInPath 统一解析 /tmp→/private/tmp 等符号链接，保证层级一致
            let fPath = f.resolvingSymlinksInPath().path
            let rel = String(fPath.replacingOccurrences(of: basePath + "/", with: ""))
            let firstComponent = rel.split(separator: "/").first.map { String($0) } ?? ""
            let rows = loadRows(from: f)
            guard !rows.isEmpty else { continue }
            let session = firstComponent.isEmpty ? "未命名" : firstComponent
            for r in rows {
                var s: OpaquePointer?
                let prepared = fts5OK
                    ? prepare(db, "INSERT INTO wce_fts VALUES(?,?,?,?)", out: &s)
                    : prepare(db, "INSERT INTO wce_rows VALUES(?,?,?,?)", out: &s)
                guard prepared, let s else { break }
                sqlite3_bind_text(s, 1, session, -1, destructor)
                sqlite3_bind_int64(s, 2, Int64(r.ts))
                sqlite3_bind_text(s, 3, r.sender, -1, destructor)
                sqlite3_bind_text(s, 4, r.content, -1, destructor)
                if sqlite3_step(s) != SQLITE_DONE { break }
                sqlite3_finalize(s)
                total += 1
            }
            if fts5OK {
                var s: OpaquePointer?
                if prepare(db, "INSERT OR IGNORE INTO chat_sessions(chat) VALUES(?)", out: &s), let s {
                    sqlite3_bind_text(s, 1, session, -1, destructor)
                    sqlite3_step(s)
                    sqlite3_finalize(s)
                }
            }
        }
        setMeta(db, key: "generated_at", value: iso8601(Date()))
        setMeta(db, key: "message_count", value: String(total))
        if total > 0 {
            log("搜索索引已生成：\(fileName)（\(total) 条消息，\(files.count) 个会话）")
        } else {
            log("搜索索引已生成：\(fileName)（无消息数据）")
        }
        return total
    }

    // MARK: - 查询

    /// 打开索引（只读）；不存在返回 nil。
    static func open(indexAt: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: indexAt.path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(indexAt.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// 关键词搜索（不区分大小写；FTS5 按短语匹配，降级 LIKE），按时间倒序取 limit 条。
    static func query(db: OpaquePointer, keyword: String, limit: Int = 200) -> [Hit] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let useFTS = tableExists(db, name: "wce_fts")
        let sql: String
        var phrase = ""
        if useFTS {
            // FTS5 短语：整体加双引号，内部双引号翻倍
            phrase = "\"\(kw.replacingOccurrences(of: "\"", with: "\"\""))\""
            sql = "SELECT chat, ts, sender, content FROM wce_fts WHERE wce_fts MATCH ? ORDER BY ts DESC LIMIT ?"
        } else {
            sql = "SELECT chat, ts, sender, content FROM wce_rows WHERE lower(content) LIKE lower(?) OR lower(sender) LIKE lower(?) ORDER BY ts DESC LIMIT ?"
        }
        var s: OpaquePointer?
        guard prepare(db, sql, out: &s), let s else { return [] }
        if useFTS {
            sqlite3_bind_text(s, 1, phrase, -1, destructor)
        } else {
            let pattern = "%\(kw)%"
            sqlite3_bind_text(s, 1, pattern, -1, destructor)
            sqlite3_bind_text(s, 2, pattern, -1, destructor)
        }
        sqlite3_bind_int(s, useFTS ? 2 : 3, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let chat = textCol(s, 0)
            let ts = Int(sqlite3_column_int64(s, 1))
            let sender = textCol(s, 2)
            let content = textCol(s, 3)
            hits.append(Hit(chat: chat, ts: ts, sender: sender, content: content))
        }
        return hits
    }

    // MARK: - 数据装载（与 ChatStatsReport 解析口径一致）

    private static func findChatJSONs(in base: URL) -> [URL] {
        var result: [URL] = []
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in en {
            if url.lastPathComponent == "chat.json" { result.append(url) }
        }
        return result
    }

    private struct Row { let ts: Int; let sender: String; let content: String }

    private static func loadRows(from jsonURL: URL) -> [Row] {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            rows = arr
        } else if let dict = root as? [String: Any] {
            rows = (dict["items"] as? [[String: Any]])
                ?? (dict["messages"] as? [[String: Any]])
                ?? (dict["results"] as? [[String: Any]])
                ?? []
        } else {
            rows = []
        }
        var out: [Row] = []
        for r in rows {
            let nested = r["message"] as? [String: Any]
            let src = nested ?? r
            let ts = intField(src, ["create_time", "timestamp"]) ?? intField(r, ["create_time", "timestamp"]) ?? 0
            let sender = stringField(r, ["sender_display_name", "sender", "from", "display_name"])
                ?? stringField(src, ["sender_display_name", "sender"]) ?? "未知"
            let type = intField(src, ["local_type", "type"]) ?? 0
            let content = stringField(r, ["snippet", "content", "text"])
                ?? stringField(src, ["content", "text"]) ?? ""
            // 媒体类消息用占位符（与 ChatExporter.displayContent 同口径）
            let display: String
            if [3, 34, 43, 47].contains(type) && (content.isEmpty || content.hasPrefix("[")) {
                let names: [Int: String] = [3: "[图片]", 34: "[语音]", 43: "[视频]", 47: "[表情]"]
                display = names[type] ?? "[媒体]"
            } else if type != 1 && content.isEmpty {
                display = "[非文本]"
            } else {
                display = content
            }
            out.append(Row(ts: ts, sender: sender, content: display))
        }
        return out
    }

    // MARK: - 小工具

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

    private static let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func prepare(_ db: OpaquePointer, _ sql: String, out s: inout OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        s = stmt
        return true
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if !ok, let err {
            sqlite3_free(err)
        }
        return ok
    }

    private static func setMeta(_ db: OpaquePointer, key: String, value: String) {
        var s: OpaquePointer?
        guard prepare(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", out: &s) else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, key, -1, destructor)
        sqlite3_bind_text(s, 2, value, -1, destructor)
        sqlite3_step(s)
    }

    private static func tableExists(_ db: OpaquePointer, name: String) -> Bool {
        var s: OpaquePointer?
        guard prepare(db, "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=? LIMIT 1", out: &s) else { return false }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, name, -1, destructor)
        return sqlite3_step(s) == SQLITE_ROW
    }

    private static func textCol(_ s: OpaquePointer, _ i: Int32) -> String {
        if let c = sqlite3_column_text(s, i) { return String(cString: c) }
        return ""
    }

    private static func iso8601(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}
