import CryptoKit
import Foundation
import SQLite3

enum ContactStore {
    static func loadContacts(from decryptedDir: URL) throws -> [ContactItem] {
        let sessionDB = decryptedDir.appendingPathComponent("session/session.db")
        let contactDB = decryptedDir.appendingPathComponent("contact/contact.db")
        guard FileManager.default.fileExists(atPath: sessionDB.path) else {
            throw AppError.decryptFailed("会话数据库不存在")
        }

        let existingTables = try existingMessageTables(decryptedDir: decryptedDir)
        let contacts = try contactMap(from: contactDB)

        let db = try SQLiteDatabase.openReadOnly(at: sessionDB)
        defer { sqlite3_close(db) }

        guard SQLiteDatabase.tableExists(db, name: "SessionTable") else {
            throw AppError.decryptFailed("session.db 缺少 SessionTable，请点击「准备数据」重新解密")
        }

        var items: [ContactItem] = []
        let columns = SQLiteDatabase.columnNames(db, table: "SessionTable")
        let summaryCol = columns.contains("summary") ? "summary" : "''"
        let lastTSCol = columns.contains("last_timestamp") ? "last_timestamp" : "0"
        let sortTSCol = columns.contains("sort_timestamp") ? "sort_timestamp" : lastTSCol
        let sql = """
        SELECT username, type, \(summaryCol), \(lastTSCol), \(sortTSCol)
        FROM SessionTable
        ORDER BY \(sortTSCol) DESC
        """
        let stmt = try SQLiteDatabase.prepare(db, sql: sql, context: "读取会话列表失败")
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let usernameC = sqlite3_column_text(stmt, 0) else { continue }
            let username = String(cString: usernameC)
            let type = Int(sqlite3_column_int(stmt, 1))
            let summary = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let lastTS = Int(sqlite3_column_int64(stmt, 3))
            let sortTS = Int(sqlite3_column_int64(stmt, 4))
            let table = "Msg_\(Insecure.MD5.hash(data: Data(username.utf8)).map { String(format: "%02x", $0) }.joined())"
            guard existingTables.contains(table) else { continue }

            let meta = contacts[username]
            let nick = meta?.nick ?? ""
            let remark = meta?.remark ?? ""
            let display = !remark.isEmpty ? remark : (!nick.isEmpty ? nick : username)
            let ts = sortTS > 0 ? sortTS : lastTS
            let kind: ContactKind = username.hasSuffix("@chatroom") || type == 2 ? .group : (username.hasPrefix("gh_") ? .official : .friend)

            items.append(ContactItem(
                id: username,
                displayName: display,
                nickName: nick,
                remark: remark,
                kind: kind,
                lastTime: formatTime(ts),
                lastTimestamp: ts,
                summary: summary.replacingOccurrences(of: "\n", with: " ")
            ))
        }
        return items.sorted { $0.lastTimestamp > $1.lastTimestamp }
    }

    private static func existingMessageTables(decryptedDir: URL) throws -> Set<String> {
        var tables: Set<String> = []
        let messageDir = decryptedDir.appendingPathComponent("message", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil) else { return tables }
        for file in files where file.pathExtension == "db" && !file.lastPathComponent.contains("fts") {
            guard let db = try? SQLiteDatabase.openReadOnly(at: file) else { continue }
            defer { sqlite3_close(db) }
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
            guard let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "扫描消息表失败") else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let nameC = sqlite3_column_text(stmt, 0) {
                    tables.insert(String(cString: nameC))
                }
            }
        }
        return tables
    }

    static func contactMap(from contactDB: URL) throws -> [String: (nick: String, remark: String)] {
        var map: [String: (nick: String, remark: String)] = [:]
        guard FileManager.default.fileExists(atPath: contactDB.path) else { return map }
        guard let db = try? SQLiteDatabase.openReadOnly(at: contactDB) else { return map }
        defer { sqlite3_close(db) }
        guard SQLiteDatabase.tableExists(db, name: "contact") else { return map }

        let columns = SQLiteDatabase.columnNames(db, table: "contact")
        let nickCol = columns.contains("nick_name") ? "nick_name" : (columns.contains("nickName") ? "nickName" : "''")
        let remarkCol = columns.contains("remark") ? "remark" : "''"
        let sql = "SELECT username, \(nickCol), \(remarkCol) FROM contact"
        guard let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "读取联系人失败") else { return map }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let usernameC = sqlite3_column_text(stmt, 0) else { continue }
            let username = String(cString: usernameC)
            let nick = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let remark = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            map[username] = (nick, remark)
        }
        return map
    }

    static func displayName(for username: String, map: [String: (nick: String, remark: String)]) -> String {
        let meta = map[username]
        if let remark = meta?.remark, !remark.isEmpty { return remark }
        if let nick = meta?.nick, !nick.isEmpty { return nick }
        return username
    }

    private static func formatTime(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}
