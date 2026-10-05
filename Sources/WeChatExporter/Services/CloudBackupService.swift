import Foundation
import CryptoKit
import os.log

// MARK: - 云备份
//
// 与 Windows 端对齐的「云备份」后端对接层。Base: https://wce.linminhao.top/api
//   - 认证: OTP 登录/注册（邮箱或手机 + 6 位验证码），JWT 存 UserDefaults
//   - 备份: 明文导出目录 → 复用 EncryptedExport 加密为单个 .wxenc → 分块上传 → commit
//   - 管理: manifest 列表 / 删除 / 用量
//   - 下载: 分块拉回组装 .wxenc → 本地输密码解密
// 密码永不上送服务器；所有重活(加密/哈希/分块)跑在后台线程，UI 由调用方 @MainActor 更新。

// MARK: - 错误

enum CloudBackupError: LocalizedError, Sendable {
    case notLoggedIn
    case invalidInput(String)
    case network(String)
    case http(Int, String)
    case rateLimited(retryAfterSec: Int)
    case quotaExceeded(String)
    case invalidCode
    case fileNotFound
    case fileNotPending
    case chunksMissing
    case sizeMismatch
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登录云备份"
        case .invalidInput(let m): return m
        case .network(let m): return "网络错误：\(m)"
        case .http(let code, let m): return "服务器返回 \(code)：\(m)"
        case .rateLimited(let s): return "操作过于频繁，请 \(s) 秒后再试"
        case .quotaExceeded(let m): return "云端空间不足：\(m)"
        case .invalidCode: return "验证码错误"
        case .fileNotFound: return "文件不存在"
        case .fileNotPending: return "文件状态异常（未处于待上传状态）"
        case .chunksMissing: return "分块缺失，上传不完整"
        case .sizeMismatch: return "文件大小校验不一致"
        case .server(let m): return "服务器错误：\(m)"
        }
    }
}

// MARK: - 认证类型

enum CloudAuthType: String, CaseIterable, Identifiable, Sendable {
    case email = "email"
    case sms = "sms"

    var id: String { rawValue }
    var displayName: String { self == .email ? "邮箱" : "手机号" }
}

// MARK: - 数据模型

struct CloudBackupUser: Codable, Equatable, Sendable {
    let id: String
    let handle: String
}

struct CloudAuthResult: Codable, Sendable {
    let ok: Bool
    let token: String
    let sessionId: String
    let user: CloudBackupUser
}

struct CloudBackupFile: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let category: String
    let sha256: String
    let totalSize: Int64
    let chunkCount: Int
    let chunkSize: Int
    let state: String
    let createdAt: String
    let updatedAt: String

    var id: String { name }
}

struct CloudUsage: Codable, Equatable, Sendable {
    let usedBytes: Int64
    let quotaBytes: Int64
    let fileCount: Int
}

// MARK: - 字节格式化

enum CloudByteSize {
    static func string(_ bytes: Int64) -> String {
        let f = Double(bytes)
        if f >= 1_073_741_824 { return String(format: "%.1f GB", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.1f MB", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.0f KB", f / 1024) }
        return "\(bytes) B"
    }
}

// MARK: - 凭据持久化（UserDefaults）

enum CloudBackupStore {
    private enum Keys {
        static let token = "cloudbackup.token"
        static let sessionId = "cloudbackup.sessionId"
        static let userId = "cloudbackup.userId"
        static let handle = "cloudbackup.handle"
    }

    static var token: String? {
        get { UserDefaults.standard.string(forKey: Keys.token) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.token) }
    }
    static var sessionId: String? {
        get { UserDefaults.standard.string(forKey: Keys.sessionId) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionId) }
    }
    static var userId: String? {
        get { UserDefaults.standard.string(forKey: Keys.userId) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userId) }
    }
    static var handle: String? {
        get { UserDefaults.standard.string(forKey: Keys.handle) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.handle) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: Keys.token)
        UserDefaults.standard.removeObject(forKey: Keys.sessionId)
        UserDefaults.standard.removeObject(forKey: Keys.userId)
        UserDefaults.standard.removeObject(forKey: Keys.handle)
    }
}

// MARK: - 后端 API 客户端

enum CloudBackupAPI {
    static let baseURL = URL(string: "https://wce.linminhao.top/api")!
    static let deviceId = "mac-wce"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WeChatExporter",
        category: "cloudbackup"
    )

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    // MARK: 请求体

    struct ManifestFileEntry: Encodable {
        let name: String
        let category: String
        let sha256: String
        let totalSize: Int64
        let chunkCount: Int
        let chunkSize: Int
    }

    private struct SendCodeRequest: Encodable { let type: String; let target: String }
    private struct AuthRequest: Encodable {
        let type: String; let target: String; let code: String
        let handle: String?; let deviceId: String?
    }
    private struct ManifestSubmitRequest: Encodable { let files: [ManifestFileEntry] }
    private struct ChunkRequest: Encodable { let name: String; let chunkIdx: Int; let data: String }
    private struct CommitRequest: Encodable { let name: String }
    private struct DeleteRequest: Encodable { let name: String }

    private struct SendCodeResponse: Decodable { let ok: Bool; let expiresInSec: Int }
    private struct ManifestResponse: Decodable { let files: [CloudBackupFile] }
    private struct ManifestSubmitResponse: Decodable {
        let actions: [ManifestAction]
        let usedBytes: Int64
        let quotaBytes: Int64
    }
    private struct ManifestAction: Decodable { let name: String; let action: String }
    private struct CommitResponse: Decodable { let ok: Bool; let size: Int64; let usedBytes: Int64; let quotaBytes: Int64 }
    private struct ErrorBody: Decodable { let error: String?; let message: String?; let retryAfterSec: Int? }

    // MARK: 通用请求

    private static func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + "/" + path)!
    }

    private static func send(
        _ method: String,
        path: String,
        token: String? = nil,
        bodyData: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudBackupError.network("无效响应")
        }
        if (200..<300).contains(http.statusCode) {
            return (data, http)
        }
        try throwHTTPError(http.statusCode, data: data)
    }

    private static func throwHTTPError(_ statusCode: Int, data: Data) throws -> Never {
        var msg = String(data: data, encoding: .utf8) ?? ""
        var retryAfter: Int? = nil
        if let eb = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            msg = eb.error ?? eb.message ?? msg
            retryAfter = eb.retryAfterSec
        }
        switch statusCode {
        case 401: throw CloudBackupError.invalidCode
        case 404: throw CloudBackupError.fileNotFound
        case 409:
            if msg.contains("quota") { throw CloudBackupError.quotaExceeded(msg) }
            if msg.contains("pending") { throw CloudBackupError.fileNotPending }
            if msg.contains("missing") { throw CloudBackupError.chunksMissing }
            if msg.contains("size") { throw CloudBackupError.sizeMismatch }
            throw CloudBackupError.http(statusCode, msg)
        case 429: throw CloudBackupError.rateLimited(retryAfterSec: retryAfter ?? 60)
        case 507: throw CloudBackupError.quotaExceeded("服务器存储已满")
        default: throw CloudBackupError.http(statusCode, msg)
        }
    }

    // MARK: 认证

    static func sendCode(type: String, target: String) async throws -> Int {
        let body = try JSONEncoder().encode(SendCodeRequest(type: type, target: target))
        let (data, _) = try await send("POST", path: "auth/send-code", bodyData: body)
        return (try? JSONDecoder().decode(SendCodeResponse.self, from: data))?.expiresInSec ?? 60
    }

    static func auth(type: String, target: String, code: String, handle: String?, deviceId: String?) async throws -> CloudAuthResult {
        let body = try JSONEncoder().encode(AuthRequest(type: type, target: target, code: code, handle: handle, deviceId: deviceId))
        let (data, _) = try await send("POST", path: "auth/login", bodyData: body)
        return try JSONDecoder().decode(CloudAuthResult.self, from: data)
    }

    // MARK: 备份

    static func manifest(token: String) async throws -> [CloudBackupFile] {
        let (data, _) = try await send("GET", path: "backup/manifest", token: token)
        return (try? JSONDecoder().decode(ManifestResponse.self, from: data))?.files ?? []
    }

    static func submitManifest(token: String, files: [ManifestFileEntry]) async throws -> (actions: [String: String], usedBytes: Int64, quotaBytes: Int64) {
        let body = try JSONEncoder().encode(ManifestSubmitRequest(files: files))
        let (data, _) = try await send("POST", path: "backup/manifest", token: token, bodyData: body)
        let resp = try JSONDecoder().decode(ManifestSubmitResponse.self, from: data)
        let actions = Dictionary(uniqueKeysWithValues: resp.actions.map { ($0.name, $0.action) })
        return (actions, resp.usedBytes, resp.quotaBytes)
    }

    static func uploadChunk(token: String, name: String, chunkIdx: Int, data: Data) async throws {
        let body = try JSONEncoder().encode(ChunkRequest(name: name, chunkIdx: chunkIdx, data: data.base64EncodedString()))
        _ = try await send("POST", path: "backup/chunk", token: token, bodyData: body)
    }

    static func commit(token: String, name: String) async throws -> CloudUsage {
        let body = try JSONEncoder().encode(CommitRequest(name: name))
        let (data, _) = try await send("POST", path: "backup/commit", token: token, bodyData: body)
        let resp = try JSONDecoder().decode(CommitResponse.self, from: data)
        return CloudUsage(usedBytes: resp.usedBytes, quotaBytes: resp.quotaBytes, fileCount: 0)
    }

    static func downloadChunk(token: String, name: String, idx: Int) async throws -> Data {
        var comps = URLComponents(url: url("backup/chunk"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "idx", value: String(idx)),
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try throwHTTPError((response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
        return data
    }

    static func deleteFile(token: String, name: String) async throws {
        let body = try JSONEncoder().encode(DeleteRequest(name: name))
        _ = try await send("DELETE", path: "backup/file", token: token, bodyData: body)
    }

    static func usage(token: String) async throws -> CloudUsage {
        let (data, _) = try await send("GET", path: "backup/usage", token: token)
        return try JSONDecoder().decode(CloudUsage.self, from: data)
    }
}

// MARK: - 传输编排（加密 / 分块上传 / 分块下载组装）

enum CloudBackupTransfer {
    static let backupFileName = "wechat-export.wxenc"
    static let category = "other"
    static let chunkSize = 4 * 1024 * 1024            // 4 MiB，落在契约 [65536, 8388608]
    static let maxConcurrency = 3
    static let maxRetries = 5

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WeChatExporter",
        category: "cloudbackup.transfer"
    )

    // MARK: 加密目录 → 临时 .wxenc，返回 (url, size, sha256Hex)

    private static func encryptDirectory(_ dir: URL, password: String) throws -> (url: URL, size: Int64, sha256: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wce-cloudbackup-\(UUID().uuidString).wxenc")
        _ = try EncryptedExport.encryptDirectory(dir, password: password, to: tmp, log: { _ in })
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try sha256Hex(ofFile: tmp)
        return (tmp, size, sha)
    }

    private static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 上传

    /// 把导出目录加密为 .wxenc 后分块上传并 commit。返回最终用量。
    static func upload(
        directory: URL,
        password: String,
        token: String,
        progress: @escaping @Sendable (Double, String) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        // 1. 加密（PBKDF2 + AES-GCM，重活，本函数已在后台线程）
        log("正在加密导出目录…")
        let enc = try encryptDirectory(directory, password: password)
        defer { try? FileManager.default.removeItem(at: enc.url) }
        let chunkCount = Int((enc.size + Int64(chunkSize) - 1) / Int64(chunkSize))
        log("加密完成：\(CloudByteSize.string(enc.size))，\(chunkCount) 个分块")

        // 2. 提交 manifest
        let submit = try await CloudBackupAPI.submitManifest(
            token: token,
            files: [.init(
                name: backupFileName,
                category: category,
                sha256: enc.sha256,
                totalSize: enc.size,
                chunkCount: chunkCount,
                chunkSize: chunkSize
            )]
        )

        // 3. 分块上传（skip = 服务端已有相同内容）
        if submit.actions[backupFileName] == "skip" {
            log("云端已存在相同备份，跳过上传")
        } else {
            try await uploadChunks(
                token: token,
                file: enc.url,
                totalSize: enc.size,
                chunkCount: chunkCount,
                progress: progress,
                log: log
            )
        }

        // 4. commit
        _ = try await CloudBackupAPI.commit(token: token, name: backupFileName)
        log("云备份提交完成")
    }

    private static func uploadChunks(
        token: String,
        file: URL,
        totalSize: Int64,
        chunkCount: Int,
        progress: @escaping @Sendable (Double, String) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let mapped = try Data(contentsOf: file, options: .mappedIfSafe)
        let reporter = ChunkProgress(total: chunkCount, onProgress: progress)

        try await forEachLimited(Array(0..<chunkCount), limit: maxConcurrency) { idx in
            let offset = Int64(idx) * Int64(chunkSize)
            let length = min(Int64(chunkSize), totalSize - offset)
            let chunk = mapped.subdata(in: Int(offset)..<Int(offset + length))
            try await withRetry {
                try await CloudBackupAPI.uploadChunk(token: token, name: backupFileName, chunkIdx: idx, data: chunk)
            }
            await reporter.markDone(idx)
        }
    }

    // MARK: 下载

    /// 分块拉回组装 .wxenc → 解密到 destDir。返回还原文件数。
    @discardableResult
    static func download(
        file: CloudBackupFile,
        token: String,
        to destDir: URL,
        password: String,
        progress: @escaping @Sendable (Double, String) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wce-cloudbackup-dl-\(UUID().uuidString).wxenc")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let assembler = try ChunkAssembler(url: tmp)
        let reporter = ChunkProgress(total: file.chunkCount, onProgress: progress)

        try await forEachLimited(Array(0..<file.chunkCount), limit: maxConcurrency) { idx in
            let data = try await withRetry {
                try await CloudBackupAPI.downloadChunk(token: token, name: file.name, idx: idx)
            }
            let offset = UInt64(idx) * UInt64(file.chunkSize)
            try await assembler.write(data, at: offset)
            await reporter.markDone(idx)
        }
        await assembler.close()

        // 校验总大小
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size == file.totalSize else {
            throw CloudBackupError.sizeMismatch
        }

        log("下载完成，正在解密…")
        let count = try EncryptedExport.decryptFile(tmp, password: password, to: destDir, log: { log($0) })
        log("解密完成：\(count) 个文件")
        return count
    }

    // MARK: 并发 + 重试

    /// 以最大 `limit` 并发遍历 `items`，任意子任务抛错即取消其余并抛出。
    private static func forEachLimited(
        _ items: [Int],
        limit: Int,
        _ body: @escaping @Sendable (Int) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextIndex = 0
            let total = items.count

            while nextIndex < total && nextIndex < limit {
                let idx = items[nextIndex]
                nextIndex += 1
                group.addTask { try await body(idx); return idx }
            }
            while let _ = try await group.next() {
                if nextIndex < total {
                    let idx = items[nextIndex]
                    nextIndex += 1
                    group.addTask { try await body(idx); return idx }
                }
            }
        }
    }

    /// 指数退避重试：仅网络错误 / 5xx / 429 重试，4xx（除 429）立即抛出。
    private static func withRetry<T: Sendable>(
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await op()
            } catch let e as CloudBackupError {
                switch e {
                case .rateLimited:
                    lastError = e
                case .network:
                    lastError = e
                case .http(let code, _) where code >= 500:
                    lastError = e
                default:
                    throw e
                }
            } catch {
                lastError = error
            }
            if attempt < maxRetries - 1 {
                let seconds = Int(pow(2.0, Double(attempt)))  // 1, 2, 4, 8, 16
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
        throw lastError ?? CloudBackupError.network("未知错误")
    }
}

// MARK: - 分块进度上报（actor 串行累加）

private actor ChunkProgress {
    private let total: Int
    private var done = 0
    private let onProgress: @Sendable (Double, String) -> Void

    init(total: Int, onProgress: @escaping @Sendable (Double, String) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    func markDone(_ idx: Int) {
        done += 1
        onProgress(Double(done) / Double(total), "分块 \(done)/\(total)")
    }
}

// MARK: - 分块组装（actor 串行写入，按偏移随机写）

private actor ChunkAssembler {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}
