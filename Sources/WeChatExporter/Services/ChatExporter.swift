import CryptoKit
import Foundation
import SQLite3

enum ChatExporter {
    private static let msgTypes: [Int: String] = [
        1: "文本", 3: "图片", 34: "语音", 42: "名片", 43: "视频",
        47: "表情", 48: "位置", 49: "链接/文件/小程序", 50: "语音/视频通话",
        51: "系统消息", 10000: "系统提示", 10002: "撤回消息",
    ]
    private static let mediaTypes: Set<Int> = [3, 34, 43, 47]

    struct Message: Codable {
        let time: String
        let timestamp: Int
        let sender: String
        let type: Int
        let typeName: String
        let content: String
    }

    static func export(contact: ContactItem, decryptedDir: URL, outputDir: URL) throws -> Int {
        let table = "Msg_\(Insecure.MD5.hash(data: Data(contact.id.utf8)).map { String(format: "%02x", $0) }.joined())"
        let contactDB = decryptedDir.appendingPathComponent("contact/contact.db")
        let contactMap = try ContactStore.contactMap(from: contactDB)
        let messageDir = decryptedDir.appendingPathComponent("message", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "db" && !$0.lastPathComponent.contains("fts") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var messages: [Message] = []
        for file in files {
            messages.append(contentsOf: try loadMessages(from: file, table: table, contactMap: contactMap))
        }
        messages.sort { $0.timestamp < $1.timestamp }
        guard !messages.isEmpty else { throw AppError.exportFailed("未找到与 \(contact.displayName) 的聊天记录") }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let txtURL = outputDir.appendingPathComponent("chat.txt")
        var txt = "微信聊天记录: \(contact.displayName) (\(contact.id))\n"
        txt += "总消息数: \(messages.count)\n"
        txt += "时间范围: \(messages.first!.time) ~ \(messages.last!.time)\n"
        txt += String(repeating: "=", count: 60) + "\n\n"
        for msg in messages {
            let content = displayContent(msg)
            txt += "[\(msg.time)] \(msg.sender): \(content)\n"
        }
        try txt.write(to: txtURL, atomically: true, encoding: .utf8)

        let jsonURL = outputDir.appendingPathComponent("chat.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(messages).write(to: jsonURL)

        let csvURL = outputDir.appendingPathComponent("chat.csv")
        var csv = "\u{FEFF}时间,发送者,类型,内容\n"
        for msg in messages {
            let content = displayContent(msg).replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(msg.time)\",\"\(msg.sender)\",\"\(msg.typeName)\",\"\(content)\"\n"
        }
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        return messages.count
    }

    private static func loadMessages(from dbURL: URL, table: String, contactMap: [String: (nick: String, remark: String)]) throws -> [Message] {
        let db = try SQLiteDatabase.openReadOnly(at: dbURL)
        defer { sqlite3_close(db) }

        guard SQLiteDatabase.tableExists(db, name: table) else { return [] }

        var nameMap: [Int: String] = [:]
        if let stmt = try? SQLiteDatabase.prepare(db, sql: "SELECT rowid, user_name FROM Name2Id", context: "读取 Name2Id 失败") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowid = Int(sqlite3_column_int(stmt, 0))
                if let nameC = sqlite3_column_text(stmt, 1) {
                    nameMap[rowid] = String(cString: nameC)
                }
            }
        }

        let columns = SQLiteDatabase.columnNames(db, table: table)
        let contentCol = columns.contains("message_content") ? "message_content" : (columns.contains("compress_content") ? "compress_content" : "''")
        let sql = "SELECT local_type, create_time, real_sender_id, \(contentCol) FROM \(table) ORDER BY create_time ASC"
        let stmt = try SQLiteDatabase.prepare(db, sql: sql, context: "读取消息失败 (\(table))")
        defer { sqlite3_finalize(stmt) }

        var result: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let type = Int(sqlite3_column_int(stmt, 0))
            let ts = Int(sqlite3_column_int64(stmt, 1))
            let senderID = Int(sqlite3_column_int(stmt, 2))
            let content = decodeContent(stmt: stmt, index: 3)
            let senderWxid = nameMap[senderID] ?? ""
            let sender: String
            if type == 10000 || type == 10002 {
                sender = "系统"
            } else {
                sender = ContactStore.displayName(for: senderWxid, map: contactMap)
            }
            result.append(Message(
                time: formatTime(ts),
                timestamp: ts,
                sender: sender,
                type: type,
                typeName: msgTypes[type] ?? "未知(\(type))",
                content: content
            ))
        }
        return result
    }

    private static func decodeContent(stmt: OpaquePointer?, index: Int32) -> String {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, index) { return String(cString: c) }
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return "" }
            let length = Int(sqlite3_column_bytes(stmt, index))
            let data = Data(bytes: bytes, count: length)
            if let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") { return text }
            if let text = String(data: data, encoding: .utf16LittleEndian) { return text }
            return "[压缩内容未解码]"
        default:
            break
        }
        return ""
    }

    private static func displayContent(_ msg: Message) -> String {
        if mediaTypes.contains(msg.type) { return "[\(msg.typeName)]" }
        if msg.type != 1 && msg.content.isEmpty { return "[\(msg.typeName)]" }
        return msg.content
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
