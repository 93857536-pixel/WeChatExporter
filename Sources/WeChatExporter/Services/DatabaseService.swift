import Foundation

enum DatabaseService {
    static func loadSavedRawKey(from url: URL, dbRoot: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? Data(contentsOf: url), raw.count == 32 else { return nil }
        let messageDB = dbRoot.appendingPathComponent("message/message_0.db")
        return CryptoService.validateRawKey(raw, dbURL: messageDB) ? raw : nil
    }

    static func saveRawKey(_ rawKey: Data, to url: URL) throws {
        try rawKey.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func decryptAll(dbRoot: URL, decryptedDir: URL, rawKey: Data, log: @escaping (String) -> Void) throws {
        let keys = try CryptoService.buildKeys(rawKey: rawKey, dbRoot: dbRoot)
        guard !keys.isEmpty else { throw AppError.decryptFailed("未匹配到任何数据库密钥") }
        log("匹配 \(keys.count) 个数据库密钥")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let keyObjects = keys.mapValues { ["enc_key": $0] }
        let keysURL = decryptedDir.deletingLastPathComponent().appendingPathComponent("all_keys.json")
        try encoder.encode(keyObjects).write(to: keysURL)

        let enumerator = FileManager.default.enumerator(at: dbRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "db", !url.lastPathComponent.hasSuffix("-wal"), !url.lastPathComponent.hasSuffix("-shm") else { continue }
            let rel = url.path.replacingOccurrences(of: dbRoot.path + "/", with: "")
            guard let encHex = keys[rel], let encKey = Data(hexString: encHex) else { continue }
            let outURL = decryptedDir.appendingPathComponent(rel)
            log("解密：\(rel)")
            try CryptoService.decryptDatabase(input: url, output: outURL, encKey: encKey)
            removeSidecarFiles(near: outURL)
        }
    }

    private static func removeSidecarFiles(near dbURL: URL) {
        let base = dbURL.deletingPathExtension().lastPathComponent
        let dir = dbURL.deletingLastPathComponent()
        for suffix in ["-wal", "-shm"] {
            let sidecar = dir.appendingPathComponent("\(base)\(suffix)")
            try? FileManager.default.removeItem(at: sidecar)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}
