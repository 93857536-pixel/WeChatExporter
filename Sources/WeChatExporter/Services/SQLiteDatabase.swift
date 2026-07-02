import Foundation
import SQLite3

enum SQLiteDatabase {
    static func openReadOnly(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(url.path)?mode=ro&immutable=1"
        let code = sqlite3_open_v2(uri, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw AppError.decryptFailed("无法打开数据库 \(url.lastPathComponent)：\(message)")
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    static func prepare(_ db: OpaquePointer, sql: String, context: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            throw AppError.decryptFailed("\(context)：\(message)")
        }
        return stmt
    }

    static func tableExists(_ db: OpaquePointer, name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    static func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var names: Set<String> = []
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return names }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: c))
            }
        }
        return names
    }
}
