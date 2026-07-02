import CommonCrypto
import CryptoKit
import Foundation

enum CryptoService {
    static let pageSize = 4096
    static let kdfIter: UInt32 = 256_000
    static let reserve = 80
    static let hmacSize = 64
    static let saltSize = 16
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    static func readSalt(from dbURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: dbURL)
        defer { try? handle.close() }
        return handle.readData(ofLength: saltSize)
    }

    static func deriveEncKey(rawKey: Data, salt: Data) -> Data {
        pbkdf2(password: rawKey, salt: salt, iterations: kdfIter, keyLength: 32)
    }

    static func deriveMacKey(encKey: Data, salt: Data) -> Data {
        let macSalt = Data(salt.map { $0 ^ 0x3A })
        return pbkdf2(password: encKey, salt: macSalt, iterations: 2, keyLength: 32)
    }

    static func validateRawKey(_ rawKey: Data, dbURL: URL) -> Bool {
        guard let page = try? readPage(dbURL, index: 0) else { return false }
        let salt = page.prefix(saltSize)
        let encKey = deriveEncKey(rawKey: rawKey, salt: salt)
        let macKey = deriveMacKey(encKey: encKey, salt: salt)
        return verifyHMAC(page: page, macKey: macKey)
    }

    static func buildKeys(rawKey: Data, dbRoot: URL) throws -> [String: String] {
        var keys: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: dbRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "db", !url.lastPathComponent.hasSuffix("-wal"), !url.lastPathComponent.hasSuffix("-shm") else { continue }
            guard validateRawKey(rawKey, dbURL: url) else { continue }
            let rel = url.path.replacingOccurrences(of: dbRoot.path + "/", with: "")
            let salt = try readSalt(from: url)
            let encKey = deriveEncKey(rawKey: rawKey, salt: salt)
            keys[rel] = encKey.hexString
        }
        return keys
    }

    static func decryptDatabase(input: URL, output: URL, encKey: Data) throws {
        let inputData = try Data(contentsOf: input)
        guard inputData.count >= pageSize else { throw AppError.decryptFailed("文件过小") }
        let salt = inputData.prefix(saltSize)
        let macKey = deriveMacKey(encKey: encKey, salt: salt)
        let firstPage = inputData.prefix(pageSize)
        guard verifyHMAC(page: firstPage, macKey: macKey) else {
            throw AppError.decryptFailed("HMAC 校验失败：\(input.lastPathComponent)")
        }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: output)
        defer { try? outHandle.close() }

        let totalPages = (inputData.count + pageSize - 1) / pageSize
        for pageIndex in 0..<totalPages {
            let start = pageIndex * pageSize
            let end = min(start + pageSize, inputData.count)
            var page = inputData.subdata(in: start..<end)
            if page.count < pageSize {
                page.append(Data(repeating: 0, count: pageSize - page.count))
            }
            let decrypted = try decryptPage(page, encKey: encKey, macKey: macKey, pageNumber: pageIndex)
            outHandle.write(decrypted)
        }
    }

    private static func readPage(_ url: URL, index: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * pageSize))
        return handle.readData(ofLength: pageSize)
    }

    private static func decryptPage(_ page: Data, encKey: Data, macKey: Data, pageNumber: Int) throws -> Data {
        let ivStart = pageSize - reserve
        let iv = page.subdata(in: ivStart..<(ivStart + 16))
        let encryptedStart = pageNumber == 0 ? saltSize : 0
        let encryptedEnd = pageSize - reserve
        let encrypted = page.subdata(in: encryptedStart..<encryptedEnd)
        let decryptedPayload = try aesCBCDecrypt(data: encrypted, key: encKey, iv: iv)

        if pageNumber == 0 {
            var result = Data(capacity: pageSize)
            result.append(sqliteHeader)
            result.append(decryptedPayload.prefix(pageSize - saltSize - reserve))
            result.append(Data(repeating: 0, count: reserve))
            return result
        }

        var result = Data(decryptedPayload.prefix(pageSize - reserve))
        result.append(Data(repeating: 0, count: reserve))
        return result
    }

    private static func verifyHMAC(page: Data, macKey: Data) -> Bool {
        let hmacDataEnd = pageSize - reserve + 16
        let hmacData = page.subdata(in: saltSize..<hmacDataEnd)
        let stored = page.subdata(in: hmacDataEnd..<(hmacDataEnd + hmacSize))
        let computed = HMAC<SHA512>.authenticationCode(for: hmacData + pageNumberData(1), using: SymmetricKey(data: macKey))
        return Data(computed.prefix(hmacSize)) == stored
    }

    private static func pageNumberData(_ n: UInt32) -> Data {
        var le = n.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func aesCBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
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
        guard status == kCCSuccess else { throw AppError.decryptFailed("AES 解密失败") }
        return out.prefix(outLength)
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: UInt32, keyLength: Int) -> Data {
        var derived = Data(repeating: 0, count: keyLength)
        _ = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        return derived
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
