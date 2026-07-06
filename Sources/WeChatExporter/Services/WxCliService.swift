import Foundation

/// 通过 wx-cli 自动检测微信路径、解密并导出，避免硬编码路径。
final class WxCliService {
    let executable: URL
    let isBundled: Bool

    init?(executable: URL? = nil) {
        if let executable, FileManager.default.isExecutableFile(atPath: executable.path) {
            self.executable = executable
            self.isBundled = Self.isBundledExecutable(executable)
            return
        }
        guard let found = Self.locateExecutable() else { return nil }
        self.executable = found
        self.isBundled = Self.isBundledExecutable(found)
    }

    /// 应用包内随附的 wx-cli（安装即用，无需单独安装 CLI）。
    static func bundledExecutable() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("wx-cli"),
            Bundle.main.bundleURL.appendingPathComponent("MacOS/wx-cli"),
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    static func locateExecutable() -> URL? {
        if let bundled = bundledExecutable() { return bundled }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/wx-cli"),
            URL(fileURLWithPath: "/opt/homebrew/bin/wx-cli"),
            URL(fileURLWithPath: "/usr/local/bin/wx-cli"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func isBundledExecutable(_ url: URL) -> Bool {
        let bundleRoot = Bundle.main.bundleURL.path
        return url.path.hasPrefix(bundleRoot + "/")
    }

    func statusText() async throws -> String {
        try await run(["status"])
    }

    func doctorOK() async -> Bool {
        guard let output = try? await run(["doctor"]) else { return false }
        return output.contains("All checks passed")
    }

    /// 密钥已保存且解密缓存可用，才适合查询会话列表。
    func isPreparedForQuery() async -> Bool {
        guard let status = try? await run(["status"], timeout: 30) else { return false }
        guard status.contains("key ✅") else { return false }
        guard !status.contains("no cache"), !status.contains("cache empty") else { return false }
        return true
    }

    func prepareData(
        log: @escaping (String) -> Void,
        progress: @escaping @Sendable (LoadProgressUpdate) -> Void
    ) async throws {
        let tracker = LoadProgressTracker()
        tracker.reset()
        progress(tracker.estimated(message: "正在检查运行环境…"))
        log("检查运行环境…")
        guard await doctorOK() else {
            throw AppError.decryptFailed("wx-cli 环境检查未通过。请确认 SIP 已关闭且微信已登录。")
        }

        progress(tracker.estimated(message: "正在读取账号状态…"))
        let status = try await run(["status"], timeout: 30, log: log)
        let needsKey = !status.contains("key ✅")
        if needsKey {
            progress(tracker.estimated(message: "正在捕获解密密钥（会重启微信）…"))
            log("正在捕获解密密钥（会重启微信，约 1-2 分钟）…")
            _ = try await run(["key", "extract", "--timeout", "120"], timeout: nil, log: log, onActivity: { line in
                if line.contains("Password") || line.contains("PBKDF2") {
                    progress(tracker.estimated(message: "等待微信登录并捕获密钥…"))
                }
            })
        } else {
            log("使用已保存的密钥")
        }

        progress(tracker.estimated(message: "正在解密本地数据库…"))
        log("正在解密本地数据库…")
        let decryptTick = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
                progress(tracker.estimated(message: "正在解密本地数据库…"))
            }
        }
        defer { decryptTick.cancel() }
        _ = try await run(["decrypt"], timeout: nil, log: log, onActivity: { line in
            if let count = Self.parseDecryptTotal(from: line) {
                progress(tracker.decryptWarmup(totalDBs: count, message: "正在解密 \(count) 个数据库…"))
            } else if line.contains("decrypted") || line.contains("Cache:") {
                progress(tracker.decryptWarmup(totalDBs: 1, message: "数据库解密进行中…"))
            }
        })
        progress(tracker.complete(message: "数据库解密完成"))
        log("数据库解密完成")
    }

    func loadSessions(
        log: @escaping (String) -> Void,
        progress: @escaping @Sendable (LoadProgressUpdate) -> Void
    ) async throws -> [ContactItem] {
        let tracker = LoadProgressTracker()
        tracker.reset()
        progress(tracker.estimated(message: "正在连接 wx-cli…"))
        log("正在加载会话列表（数据量大时将自动分页，请耐心等待）…")

        var allItems: [ContactItem] = []
        var offset = 0
        let pageSize = 500
        var knownTotal: Int?
        var pageIndex = 0

        let tickTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
                if knownTotal == nil {
                    progress(tracker.estimated(message: "正在读取会话数据（第 \(max(pageIndex, 1)) 批）…"))
                }
            }
        }
        defer { tickTask.cancel() }

        while true {
            pageIndex += 1
            if knownTotal == nil {
                progress(tracker.estimated(message: "正在读取会话数据（第 \(pageIndex) 批）…"))
            }

            let output = try await run(
                [
                    "sessions", "--format", "json",
                    "--limit", "\(pageSize)",
                    "--offset", "\(offset)",
                    "--no-server",
                ],
                timeout: nil,
                log: log,
                onActivity: { line in
                    if let count = Self.parseDecryptTotal(from: line) {
                        progress(tracker.decryptWarmup(
                            totalDBs: count,
                            message: "正在解密 \(count) 个数据库…"
                        ))
                    }
                }
            )

            let response = try Self.decodeSessionsResponse(from: output)
            let pageItems = Self.mapSessions(response.items)
            allItems.append(contentsOf: pageItems)

            let paging = response.paging
            let returned = paging?.returned ?? pageItems.count
            let total = paging?.total ?? knownTotal ?? allItems.count
            knownTotal = max(total, allItems.count)
            tickTask.cancel()

            let loaded = offset + returned
            progress(tracker.actual(
                loaded: loaded,
                total: knownTotal ?? loaded,
                message: "已加载 \(allItems.count) / \(knownTotal ?? allItems.count) 个会话"
            ))

            let hasMore = paging?.hasMore ?? (returned >= pageSize)
            guard hasMore, returned > 0 else { break }
            offset += returned
        }

        let sorted = allItems.sorted { $0.lastTimestamp > $1.lastTimestamp }
        progress(tracker.complete(message: "已加载 \(sorted.count) 个会话"))
        log("已加载 \(sorted.count) 个会话")
        return sorted
    }

    func export(contact: ContactItem, outputDir: URL, includeMedia: Bool = false, log: @escaping (String) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let query = !contact.displayName.isEmpty ? contact.displayName : contact.id
        log("导出：\(contact.displayName)\(includeMedia ? "（含媒体）" : "")")

        var txtArgs = ["export", query, "--output", outputDir.path, "--format", "txt", "--all"]
        var jsonArgs = ["export", query, "--output", outputDir.path, "--format", "json", "--all"]
        if !includeMedia {
            txtArgs.append("--no-media")
            jsonArgs.append("--no-media")
        }

        _ = try await run(txtArgs, timeout: 600, log: log)
        _ = try await run(jsonArgs, timeout: 600, log: log)

        let jsonURL = outputDir.appendingPathComponent("chat.json")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let data = try? Data(contentsOf: jsonURL),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.count
        }
        let txtURL = outputDir.appendingPathComponent("chat.txt")
        if FileManager.default.fileExists(atPath: txtURL.path),
           let text = try? String(contentsOf: txtURL, encoding: .utf8) {
            return text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count
        }
        return 0
    }

    private func run(
        _ args: [String],
        timeout: TimeInterval? = 120,
        log: ((String) -> Void)? = nil,
        onActivity: ((String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnMain: (Result<String, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            let collector = OutputCollector()
            let emitLine: (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onActivity?(trimmed)
                guard let log else { return }
                DispatchQueue.main.async { log(trimmed) }
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in
                group.leave()
            }

            func consume(_ handle: FileHandle, isErr: Bool) {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collector.append(chunk, isErr: isErr)
                guard let text = String(data: chunk, encoding: .utf8) else { return }
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    emitLine(line)
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                consume(handle, isErr: false)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                consume(handle, isErr: true)
            }

            do {
                try process.run()
            } catch {
                resumeOnMain(.failure(AppError.exportFailed("无法启动 wx-cli：\(error.localizedDescription)")))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let waitResult: DispatchTimeoutResult
                if let timeout {
                    waitResult = group.wait(timeout: .now() + timeout)
                } else {
                    group.wait()
                    waitResult = .success
                }

                if waitResult == .timedOut {
                    process.terminate()
                    let seconds = Int(timeout ?? 0)
                    resumeOnMain(.failure(AppError.exportFailed(
                        "wx-cli 执行超时（>\(seconds) 秒）。若尚未准备数据，请先点击「准备数据」；数据库较大时请耐心等待后重试。"
                    )))
                    return
                }

                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                collector.append(stdout.fileHandleForReading.readDataToEndOfFile(), isErr: false)
                collector.append(stderr.fileHandleForReading.readDataToEndOfFile(), isErr: true)

                let out = String(data: collector.stdout, encoding: .utf8) ?? ""
                let err = String(data: collector.stderr, encoding: .utf8) ?? ""

                if Self.procExitOK(process.terminationStatus) {
                    resumeOnMain(.success(out + err))
                } else {
                    let message = Self.trimFailureOutput(out + "\n" + err)
                    resumeOnMain(.failure(AppError.exportFailed(message)))
                }
            }
        }
    }

    private static func procExitOK(_ status: Int32) -> Bool {
        status == 0
    }

    private static func trimFailureOutput(_ text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("note:") }
        if let last = lines.last { return last }
        return "wx-cli 执行失败"
    }

    private static func extractJSON(from output: String) throws -> Data {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else {
            throw AppError.exportFailed("wx-cli 返回的数据格式无效")
        }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8) else {
            throw AppError.exportFailed("无法解析 wx-cli JSON 输出")
        }
        return data
    }

    private static func decodeSessionsResponse(from output: String) throws -> WxCliSessionsResponse {
        let payload = try extractJSON(from: output)
        return try JSONDecoder().decode(WxCliSessionsResponse.self, from: payload)
    }

    private static func mapSessions(_ sessions: [WxCliSession]) -> [ContactItem] {
        sessions
            .filter { !$0.username.isEmpty && $0.username != "@placeholder_foldgroup" }
            .map { session in
                let username = session.username
                let display = cleanDisplayName(session.displayName ?? username, username: username)
                let kind: ContactKind
                if username.hasSuffix("@chatroom") {
                    kind = .group
                } else if username.hasPrefix("gh_") {
                    kind = .official
                } else {
                    kind = .friend
                }
                let ts = session.sortTimestamp ?? 0
                return ContactItem(
                    id: username,
                    displayName: display,
                    nickName: display,
                    remark: "",
                    kind: kind,
                    lastTime: formatTime(ts),
                    lastTimestamp: ts,
                    summary: (session.summary ?? "").replacingOccurrences(of: "\n", with: " ")
                )
            }
    }

    private static func parseDecryptTotal(from line: String) -> Int? {
        guard line.contains("Decrypting") else { return nil }
        let digits = line.split(whereSeparator: { !$0.isNumber })
        return digits.compactMap { Int($0) }.first
    }

    private static func cleanDisplayName(_ raw: String, username: String) -> String {
        if let range = raw.range(of: "（\(username)）") {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = raw.range(of: "(\(username))") {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
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

private final class OutputCollector {
    private let lock = NSLock()
    private(set) var stdout = Data()
    private(set) var stderr = Data()

    func append(_ data: Data, isErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isErr { stderr.append(data) } else { stdout.append(data) }
        lock.unlock()
    }
}

private struct WxCliSessionsResponse: Decodable {
    let items: [WxCliSession]
    let paging: WxCliPaging?
}

private struct WxCliPaging: Decodable {
    let limit: Int
    let offset: Int
    let returned: Int
    let hasMore: Bool
    let total: Int

    enum CodingKeys: String, CodingKey {
        case limit, offset, returned, total
        case hasMore = "has_more"
    }
}

private struct WxCliSession: Decodable {
    let username: String
    let summary: String?
    let sortTimestamp: Int?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case username
        case summary
        case sortTimestamp = "sort_timestamp"
        case displayName = "display_name"
    }
}
