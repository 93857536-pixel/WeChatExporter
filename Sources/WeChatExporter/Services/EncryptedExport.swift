import Foundation
import CryptoKit

/// 加密导出：把导出目录整体加密为单个 .wxenc 文件（AES-256-GCM，PBKDF2-SHA256 派生密钥）。
///
/// 与 Windows 端 (Services/EncryptedExport.cs) 字节级互通，同一密码两端可互相加解密。
/// 密码只在内存中持有，不落盘。
///
/// 文件格式（.wxenc）：
///   [0..5)    魔数 "WXENC"
///   [5]      版本 0x01
///   [6..8)    保留 0x00 0x00
///   [8..40)   salt (32)
///   [40..52)  nonce (12, AES-GCM)
///   [52..n)   ciphertext || tag16 (AES-256-GCM 密文后拼 16 字节认证标签)
///
/// 密钥：key32 = PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)
/// 明文 blob：
///   count (8 bytes LE)
///   每项：dataLen (8 bytes LE) | pathUTF8 + 0x00 | data
///   相对路径统一用 "/" 分隔（跨平台），按路径排序保证确定性
public enum EncryptedExport {

    public struct Error: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    static let magic = Array("WXENC".utf8)
    static let version: UInt8 = 0x01
    static let saltLen = 32
    static let nonceLen = 12
    static let gcmTagLen = 16
    static let pbkdf2Rounds = 100_000
    static let headerLen = 5 + 1 + 2 + 32 + 12   // = 52

    // MARK: - 加密

    /// 将目录整体加密写入 .wxenc 文件（不删除原目录，由调用方决定）
    @discardableResult
    public static func encryptDirectory(
        _ dir: URL,
        password: String,
        to destFile: URL,
        log: @escaping (String) -> Void
    ) throws -> URL {
        guard !password.isEmpty else { throw Error(message: "密码不能为空") }

        // 收集文件（手工递归组相对路径，统一 / 分隔，不依赖符号链接解析；按路径排序保证确定性）
        var entries: [(relPath: String, data: Data)] = []
        try collectFiles(at: dir.standardizedFileURL, prefix: "", into: &entries)
        entries.sort { $0.relPath < $1.relPath }
        guard !entries.isEmpty else { throw Error(message: "导出目录为空，无法加密") }

        // 明文 blob
        var blob = Data()
        blob.appendLittleEndian(UInt64(entries.count))
        for e in entries {
            blob.appendLittleEndian(UInt64(e.data.count))
            blob.append(contentsOf: Array(e.relPath.utf8))
            blob.append(0x00)
            blob.append(e.data)
        }

        // 密钥派生 + GCM 加密
        let salt = randomBytes(saltLen)
        let nonce = randomBytes(nonceLen)
        let key = deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(blob, using: key, nonce: AES.GCM.Nonce(data: nonce))
        let gcm = sealed.ciphertext + sealed.tag   // ciphertext || tag16

        var file = Data()
        file.append(contentsOf: magic)
        file.append(version)
        file.append(contentsOf: [0x00, 0x00])
        file.append(salt)
        file.append(nonce)
        file.append(gcm)

        try file.write(to: destFile)
        log("加密导出：\(entries.count) 个文件 → \(destFile.lastPathComponent)（\(ByteSize.string(file.count))）")
        return destFile
    }

    // MARK: - 解密

    /// 解密 .wxenc 到目标目录，返回还原的文件数
    @discardableResult
    public static func decryptFile(
        _ file: URL,
        password: String,
        to destDir: URL,
        log: @escaping (String) -> Void
    ) throws -> Int {
        let entries = try readEntries(file, password: password)
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for (path, data) in entries {
            // blob 内路径统一用 /，转成当前平台分隔符（macOS 下为 /，no-op）
            let native = path.replacingOccurrences(of: "/", with: nativeSeparator)
            let url = destDir.appendingPathComponent(native)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        log("解密完成：\(entries.count) 个文件 → \(destDir.path)")
        return entries.count
    }

    /// 只解密并解析归档条目（不落盘），返回 相对路径 → 字节数。
    /// 用于「加密后、删除明文前」的完整性校验：校验不过就不删明文，避免用户两头空。
    public static func inspect(_ file: URL, password: String) throws -> [String: Int] {
        let entries = try readEntries(file, password: password)
        return entries.mapValues { $0.count }
    }

    /// 读取并解密 .wxenc，返回 相对路径 → 内容（内存，不落盘）。
    private static func readEntries(_ file: URL, password: String) throws -> [String: Data] {
        guard !password.isEmpty else { throw Error(message: "密码不能为空") }
        let raw = try Data(contentsOf: file)
        guard raw.count > headerLen + gcmTagLen else { throw Error(message: "不是有效的 .wxenc 文件（过短）") }
        guard Array(raw.prefix(5)) == magic else { throw Error(message: "不是有效的 .wxenc 文件（魔数不符）") }
        guard raw[5] == version else { throw Error(message: "不支持的 .wxenc 版本：\(raw[5])") }

        let salt = raw.subdata(in: 8..<(8 + saltLen))
        let nonce = raw.subdata(in: 40..<(40 + nonceLen))
        let gcm = raw.subdata(in: headerLen..<raw.count)
        guard gcm.count > gcmTagLen else { throw Error(message: ".wxenc 内容过短") }

        let key = deriveKey(password: password, salt: salt)
        let cipher = gcm.prefix(gcm.count - gcmTagLen)
        let tag = gcm.suffix(gcmTagLen)
        guard let sealed = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: Data(cipher),
            tag: Data(tag)
        ) else {
            throw Error(message: ".wxenc 结构无效")
        }
        guard let plain = try? AES.GCM.open(sealed, using: key) else {
            throw Error(message: "密码错误或文件已损坏（解密认证失败）")
        }

        // 还原 blob
        var entries: [String: Data] = [:]
        var cursor = 0
        func readUInt64() -> UInt64 {
            defer { cursor += 8 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(plain[cursor + i]) << (8 * i) }
            return v
        }
        let count = readUInt64()
        for _ in 0..<count {
            let dataLen = Int(readUInt64())
            guard cursor + 8 <= plain.count else { break }
            // 路径以 0x00 结束
            var nul: Int? = nil
            for i in cursor..<plain.count where plain[i] == 0 { nul = i; break }
            guard let nul else { break }
            let pathData = plain[cursor..<nul]
            cursor = nul + 1
            guard let path = String(bytes: pathData, encoding: .utf8), !path.isEmpty else { continue }
            guard cursor + dataLen <= plain.count else { break }
            let data = plain[cursor..<(cursor + dataLen)]
            cursor += dataLen
            entries[path] = data
        }
        return entries
    }

    // MARK: - 密钥派生（纯 CryptoKit，与 .NET Rfc2898DeriveBytes.Pbkdf2 字节一致）

    /// key32 = PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)
    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        return SymmetricKey(data: pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: pbkdf2Rounds,
            outputLength: 32
        ))
    }

    /// RFC 2898 §5.2，块索引用 4 字节大端（与 .NET 实现一致）
    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, outputLength: Int) -> Data {
        let hLen = 32
        let numBlocks = max(1, (outputLength + hLen - 1) / hLen)
        var out = Data()
        for blockIndex in 1...numBlocks {
            var prfInput = salt
            let iv = UInt32(blockIndex)
            prfInput.append(contentsOf: [
                UInt8((iv >> 24) & 0xFF),
                UInt8((iv >> 16) & 0xFF),
                UInt8((iv >> 8) & 0xFF),
                UInt8(iv & 0xFF),
            ])
            var u = hmacSHA256(key: password, message: prfInput)
            var block = u
            for _ in 2...max(2, iterations) {
                u = hmacSHA256(key: password, message: u)
                for j in 0..<block.count { block[j] ^= u[j] }
            }
            out.append(block)
        }
        return out.prefix(outputLength)
    }

    /// HMAC-SHA256（RFC 2104），纯 CryptoKit 实现，输出与 CommonCrypto CCHmac 字节一致
    static func hmacSHA256(key: Data, message: Data) -> Data {
        let blockSize = 64
        var k = key.count > blockSize ? Array(SHA256.hash(data: key).prefix(32)) : Array(key)
        while k.count < blockSize { k.append(0) }
        func xor(_ a: [UInt8], _ b: UInt8) -> [UInt8] { a.map { $0 ^ b } }
        let innerXor = xor(k, 0x36)
        let outerXor = xor(k, 0x5C)
        let innerHash = SHA256.hash(data: Data(innerXor + message))
        return Data(SHA256.hash(data: Data(outerXor + Array(innerHash))))
    }

    /// 手工递归收集文件，相对路径统一用 / 分隔（跨平台可移植），不依赖符号链接解析
    static func collectFiles(at dir: URL, prefix: String, into entries: inout [(relPath: String, data: Data)]) throws {
        let fm = FileManager.default
        let subdirs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for sub in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let subName = sub.lastPathComponent
            try collectFiles(at: sub, prefix: prefix.isEmpty ? subName : prefix + "/" + subName, into: &entries)
        }
        for file in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let name = file.lastPathComponent
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            entries.append((rel, try Data(contentsOf: file)))
        }
    }

    static func randomBytes(_ n: Int) -> Data {
        // 系统 CSPRNG（macOS 底层 getentropy）
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    /// 跨平台路径分隔符（Windows 用 \，macOS 用 /）
    static var nativeSeparator: String {
        #if os(Windows)
        return "\\\\"
        #else
        return "/"
        #endif
    }

    enum ByteSize {
        static func string(_ bytes: Int) -> String {
            let f = Double(bytes)
            if f >= 1_073_741_824 { return String(format: "%.1f GB", f / 1_073_741_824) }
            if f >= 1_048_576 { return String(format: "%.1f MB", f / 1_048_576) }
            if f >= 1024 { return String(format: "%.0f KB", f / 1024) }
            return "\(bytes) B"
        }
    }
}

extension Data {
    @discardableResult
    mutating func appendLittleEndian(_ v: UInt64) -> Self {
        for i in 0..<8 { append(UInt8((v >> (8 * i)) & 0xFF)) }
        return self
    }
}
