import CommonCrypto
import Foundation
import SQLite3

/// 从 wx-cli 解密缓存中的 emoticon.db 导出全部收藏/商店表情包。
enum StickerPackExporter {
    struct StickerItem: Codable {
        let path: String
        let md5: String
        let caption: String
    }

    struct StickerPack: Codable {
        let id: String
        let name: String
        let stickers: [StickerItem]
    }

    struct Manifest: Codable {
        let packs: [StickerPack]
        let totalCount: Int
    }

    private struct LookupEntry {
        var cdnURL: String
        var encryptURL: String
        var aesKey: String
        var productID: String
        var caption: String
    }

    /// 下载全部表情包到 `outputDir/media/stickers/`，并写入 `stickers-manifest.json`。
    static func exportAllPacks(in outputDir: URL, log: @escaping (String) -> Void) async -> Int {
        guard let dbURL = locateEmoticonDB() else {
            log("未找到 emoticon.db，跳过全部表情包导出（请先点击「准备数据」）")
            return 0
        }

        let lookupResult = loadLookup(from: dbURL)
        let lookup = lookupResult.lookup
        let packNames = lookupResult.packNames
        guard !lookup.isEmpty else {
            log("emoticon.db 中未找到表情包记录")
            return 0
        }

        let stickersRoot = outputDir.appendingPathComponent("media/stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: stickersRoot, withIntermediateDirectories: true)

        var packs: [String: (name: String, items: [StickerItem])] = [:]
        var downloaded = 0

        for (md5, info) in lookup.sorted(by: { $0.key < $1.key }) {
            let packID = info.productID.isEmpty ? "favorites" : info.productID
            let packName = packNames[packID] ?? (packID == "favorites" ? "收藏表情" : packID)
            let packDir = stickersRoot.appendingPathComponent(sanitizeFilename(packID), isDirectory: true)
            try? FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

            guard let filename = await downloadSticker(md5: md5, info: info, to: packDir) else { continue }
            downloaded += 1
            let rel = "media/stickers/\(sanitizeFilename(packID))/\(filename)"
            let item = StickerItem(path: rel, md5: md5, caption: info.caption)
            var bucket = packs[packID] ?? (name: packName, items: [])
            bucket.items.append(item)
            packs[packID] = bucket
        }

        guard downloaded > 0 else {
            log("表情包下载完成：0 个（可能 CDN 链接已过期）")
            return 0
        }

        let manifest = Manifest(
            packs: packs.map { id, bucket in
                StickerPack(id: id, name: bucket.name, stickers: bucket.items)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            totalCount: downloaded
        )

        let manifestURL = outputDir.appendingPathComponent("stickers-manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }

        log("共导出 \(downloaded) 个表情包（\(manifest.packs.count) 个分组）→ media/stickers/")
        return downloaded
    }

    // MARK: - Database

    private static func locateEmoticonDB() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheRoots = [
            home.appendingPathComponent("Library/Caches/wx-cli", isDirectory: true),
            home.appendingPathComponent(".wx-cli/cache", isDirectory: true),
        ]

        var candidates: [URL] = []
        for root in cacheRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.hasDirectoryPath {
                let db = entry
                    .appendingPathComponent("db_storage/emoticon/emoticon.db", isDirectory: false)
                if FileManager.default.fileExists(atPath: db.path) {
                    candidates.append(db)
                }
            }
        }

        return candidates
            .filter { quickCheckOK($0) }
            .max(by: {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 < d1
            })
    }

    private static func quickCheckOK(_ dbURL: URL) -> Bool {
        guard let db = try? SQLiteDatabase.openReadOnly(at: dbURL) else { return false }
        defer { sqlite3_close(db) }
        guard let stmt = try? SQLiteDatabase.prepare(db, sql: "PRAGMA quick_check", context: "quick_check") else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let resultC = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: resultC) == "ok"
    }

    private struct LookupResult {
        let lookup: [String: LookupEntry]
        let packNames: [String: String]
    }

    private static func loadLookup(from dbURL: URL) -> LookupResult {
        guard let db = try? SQLiteDatabase.openReadOnly(at: dbURL) else {
            return LookupResult(lookup: [:], packNames: [:])
        }
        defer { sqlite3_close(db) }

        var lookup: [String: LookupEntry] = [:]
        var pkgTemplates: [String: String] = [:]
        var packNames: [String: String] = [:]

        if SQLiteDatabase.tableExists(db, name: "kStoreEmoticonPackageTable") {
            let sql = "SELECT product_id_, product_name_ FROM kStoreEmoticonPackageTable"
            if let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "package names") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = stringColumn(stmt, 0)
                    let name = stringColumn(stmt, 1)
                    if !id.isEmpty, !name.isEmpty { packNames[id] = name }
                }
            }
        }

        if SQLiteDatabase.tableExists(db, name: "kNonStoreEmoticonTable") {
            let sql = "SELECT md5, aes_key, cdn_url, encrypt_url, product_id FROM kNonStoreEmoticonTable"
            if let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "non-store emoticons") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let md5 = stringColumn(stmt, 0)
                    guard !md5.isEmpty else { continue }
                    let entry = LookupEntry(
                        cdnURL: stringColumn(stmt, 2),
                        encryptURL: stringColumn(stmt, 3),
                        aesKey: stringColumn(stmt, 1),
                        productID: stringColumn(stmt, 4),
                        caption: ""
                    )
                    lookup[md5] = entry
                    let productID = entry.productID
                    if !productID.isEmpty, !entry.cdnURL.isEmpty {
                        pkgTemplates[productID] = entry.cdnURL
                    }
                }
            }
        }

        if SQLiteDatabase.tableExists(db, name: "kStoreEmoticonFilesTable") {
            let sql = "SELECT package_id_, md5_ FROM kStoreEmoticonFilesTable"
            if let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "store emoticons") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let pkgID = stringColumn(stmt, 0)
                    let md5 = stringColumn(stmt, 1)
                    guard !md5.isEmpty, lookup[md5] == nil else { continue }
                    var cdnURL = ""
                    if let template = pkgTemplates[pkgID], template.contains("&") {
                        cdnURL = template.replacingOccurrences(
                            of: "m=[0-9a-fA-F]+",
                            with: "m=\(md5)",
                            options: .regularExpression
                        )
                    }
                    lookup[md5] = LookupEntry(
                        cdnURL: cdnURL,
                        encryptURL: "",
                        aesKey: "",
                        productID: pkgID,
                        caption: ""
                    )
                }
            }
        }

        if SQLiteDatabase.tableExists(db, name: "kStoreEmoticonCaptionsTable") {
            let sql = "SELECT md5_, caption_ FROM kStoreEmoticonCaptionsTable WHERE language_='default'"
            if let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "captions") {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let md5 = stringColumn(stmt, 0)
                    let caption = stringColumn(stmt, 1)
                    if var entry = lookup[md5] {
                        entry.caption = caption
                        lookup[md5] = entry
                    }
                }
            }
        }

        return LookupResult(lookup: lookup, packNames: packNames)
    }

    private static func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    // MARK: - Download

    private static func downloadSticker(md5: String, info: LookupEntry, to dir: URL) async -> String? {
        for ext in ["gif", "png", "jpg", "webp"] {
            let existing = dir.appendingPathComponent("\(md5).\(ext)")
            if FileManager.default.fileExists(atPath: existing.path) {
                return existing.lastPathComponent
            }
        }

        var data = await fetchURL(info.cdnURL)
        if data == nil, !info.encryptURL.isEmpty, !info.aesKey.isEmpty,
           let enc = await fetchURL(info.encryptURL),
           let decrypted = decryptEmoticon(enc, aesKeyHex: info.aesKey) {
            data = decrypted
        }

        guard let data, data.count >= 4 else { return nil }

        let ext = detectExtension(data: data)
        let filename = "\(md5).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func fetchURL(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, urlString != "null",
              let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
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

    private static func decryptEmoticon(_ data: Data, aesKeyHex: String) -> Data? {
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

    private static func detectExtension(data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: Array("GIF".utf8)) { return "gif" }
        if data.starts(with: Array("RIFF".utf8)) { return "webp" }
        if data.starts(with: Array("WXGF".utf8)) { return "bin" }
        return "gif"
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "stickers" : cleaned
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
