import Foundation
import SQLite3

struct AppPaths {
    let accountID: String
    let dbRoot: URL
    let workDir: URL
    let decryptedDir: URL
    let keysFile: URL
    let rawKeyFile: URL
    let exportDir: URL

    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatExporter", isDirectory: true)

    static func detect() throws -> AppPaths {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)

        guard FileManager.default.fileExists(atPath: container.path) else {
            throw AppError.weChatDataNotFound
        }

        let entries = try FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var candidates: [(String, URL, Date)] = []
        for entry in entries where entry.hasDirectoryPath && entry.lastPathComponent != "all_users" {
            let dbRoot = entry.appendingPathComponent("db_storage", isDirectory: true)
            let messageDB = dbRoot.appendingPathComponent("message/message_0.db")
            if FileManager.default.fileExists(atPath: messageDB.path) {
                let date = (try? messageDB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((entry.lastPathComponent, dbRoot, date))
            }
        }

        guard let best = candidates.max(by: { $0.2 < $1.2 }) else {
            throw AppError.weChatDataNotFound
        }

        let workDir = appSupport.appendingPathComponent(best.0, isDirectory: true)
        let paths = AppPaths(
            accountID: best.0,
            dbRoot: best.1,
            workDir: workDir,
            decryptedDir: workDir.appendingPathComponent("decrypted", isDirectory: true),
            keysFile: workDir.appendingPathComponent("all_keys.json"),
            rawKeyFile: workDir.appendingPathComponent("raw_key.bin"),
            exportDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
        )
        try paths.ensureDirectories()
        try paths.migrateLegacyIfNeeded()
        return paths
    }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decryptedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        cleanupSidecarFiles(in: decryptedDir)
    }

    var isDecrypted: Bool {
        let sessionDB = decryptedDir.appendingPathComponent("session/session.db")
        let contactDB = decryptedDir.appendingPathComponent("contact/contact.db")
        let messageDB = decryptedDir.appendingPathComponent("message/message_0.db")
        guard FileManager.default.fileExists(atPath: sessionDB.path),
              FileManager.default.fileExists(atPath: contactDB.path),
              FileManager.default.fileExists(atPath: messageDB.path) else {
            return false
        }
        guard let db = try? SQLiteDatabase.openReadOnly(at: sessionDB) else { return false }
        defer { sqlite3_close(db) }
        return SQLiteDatabase.tableExists(db, name: "SessionTable")
    }

    private func migrateLegacyIfNeeded() throws {
        guard !isDecrypted else { return }
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("wechat-export", isDirectory: true)
        let legacyDecrypted = legacy.appendingPathComponent("decrypted", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDecrypted.path) else { return }
        if !FileManager.default.fileExists(atPath: decryptedDir.path) {
            try FileManager.default.createDirectory(at: decryptedDir, withIntermediateDirectories: true)
        }
        for item in try FileManager.default.contentsOfDirectory(at: legacyDecrypted, includingPropertiesForKeys: nil) {
            let dest = decryptedDir.appendingPathComponent(item.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: item, to: dest)
            }
        }
        cleanupSidecarFiles(in: decryptedDir)
        let legacyKey = legacy.appendingPathComponent("all_keys.json")
        if FileManager.default.fileExists(atPath: legacyKey.path) && !FileManager.default.fileExists(atPath: keysFile.path) {
            try FileManager.default.copyItem(at: legacyKey, to: keysFile)
        }
        let legacyRaw = legacy.appendingPathComponent("raw_key.bin")
        if FileManager.default.fileExists(atPath: legacyRaw.path) && !FileManager.default.fileExists(atPath: rawKeyFile.path) {
            try FileManager.default.copyItem(at: legacyRaw, to: rawKeyFile)
        }
    }

    private func cleanupSidecarFiles(in root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum AppError: LocalizedError {
    case weChatDataNotFound
    case keyCaptureFailed
    case decryptFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .weChatDataNotFound:
            return "未找到微信数据目录，请确认微信已在 Mac 上登录并同步过聊天记录。"
        case .keyCaptureFailed:
            return "密钥捕获失败。请确认微信已登录，且 SIP 已关闭。"
        case .decryptFailed(let msg):
            return "数据库解密失败：\(msg)"
        case .exportFailed(let msg):
            return "导出失败：\(msg)"
        }
    }
}
