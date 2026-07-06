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
        let state = SessionLoadState()
        var pageIndex = 0

        let tickTask = Task {
            while !Task.isCancelled && !state.hasTotal {
                try await Task.sleep(nanoseconds: 500_000_000)
                let batch = max(state.pageIndex, 1)
                progress(tracker.estimated(message: "正在读取会话数据（第 \(batch) 批）…"))
            }
        }
        defer { tickTask.cancel() }

        while true {
            pageIndex += 1
            state.pageIndex = pageIndex
            if !state.hasTotal {
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
            let total = paging?.total ?? state.knownTotal ?? allItems.count
            state.knownTotal = max(total, allItems.count)
            tickTask.cancel()

            let loaded = offset + returned
            progress(tracker.actual(
                loaded: loaded,
                total: state.knownTotal ?? loaded,
                message: "已加载 \(allItems.count) / \(state.knownTotal ?? allItems.count) 个会话"
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

        let exportTimeout: TimeInterval? = includeMedia ? nil : 600
        _ = try await run(txtArgs, timeout: exportTimeout, log: log)
        _ = try await run(jsonArgs, timeout: exportTimeout, log: log)

        Self.normalizeExportArtifacts(in: outputDir, log: log)
        let count = Self.countExportedMessages(in: outputDir)
        if count > 0 {
            log("共导出 \(count) 条消息")
        } else {
            log("警告：导出目录中未找到消息记录，请查看上方 wx-cli 日志")
        }
        return count
    }

    /// wx-cli 实际输出为「联系人_日期.json」，统一复制为 chat.json / chat.txt 便于查看。
    private static func normalizeExportArtifacts(in outputDir: URL, log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let chatJSON = outputDir.appendingPathComponent("chat.json")
        let chatTXT = outputDir.appendingPathComponent("chat.txt")
        let chatCSV = outputDir.appendingPathComponent("chat.csv")

        if !fm.fileExists(atPath: chatJSON.path),
           let source = newestFile(withExtension: "json", in: files) {
            try? fm.copyItem(at: source, to: chatJSON)
            log?("已写入 \(chatJSON.lastPathComponent)（来自 \(source.lastPathComponent)）")
        }

        if !fm.fileExists(atPath: chatTXT.path),
           let source = newestFile(withExtension: "txt", in: files) {
            try? fm.copyItem(at: source, to: chatTXT)
            log?("已写入 \(chatTXT.lastPathComponent)（来自 \(source.lastPathComponent)）")
        }

        if !fm.fileExists(atPath: chatCSV.path), fm.fileExists(atPath: chatJSON.path) {
            if let csv = makeCSV(fromJSONAt: chatJSON), !csv.isEmpty {
                try? csv.write(to: chatCSV, atomically: true, encoding: .utf8)
                log?("已生成 \(chatCSV.lastPathComponent)")
            }
        }
    }

    private static func newestFile(withExtension ext: String, in files: [URL]) -> URL? {
        files
            .filter { $0.pathExtension.lowercased() == ext }
            .max { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate < rDate
            }
    }

    private static func countExportedMessages(in outputDir: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        if fm.fileExists(atPath: outputDir.appendingPathComponent("chat.json").path),
           let count = countMessagesInJSON(at: outputDir.appendingPathComponent("chat.json")), count > 0 {
            return count
        }

        for json in files.filter({ $0.pathExtension.lowercased() == "json" }) {
            if let count = countMessagesInJSON(at: json), count > 0 { return count }
        }

        if fm.fileExists(atPath: outputDir.appendingPathComponent("chat.txt").path),
           let count = countMessagesInTXT(at: outputDir.appendingPathComponent("chat.txt")), count > 0 {
            return count
        }

        for txt in files.filter({ $0.pathExtension.lowercased() == "txt" }) {
            if let count = countMessagesInTXT(at: txt), count > 0 { return count }
        }

        return 0
    }

    private static func countMessagesInJSON(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let array = root as? [[String: Any]] { return array.count }

        guard let dict = root as? [String: Any] else { return nil }

        if let conversation = dict["conversation"] as? [String: Any],
           let count = conversation["message_count"] as? Int, count > 0 {
            return count
        }

        if let items = dict["items"] as? [Any] { return items.count }
        if let results = dict["results"] as? [Any] { return results.count }
        if let messages = dict["messages"] as? [Any] { return messages.count }

        if let paging = dict["paging"] as? [String: Any],
           let returned = paging["returned"] as? Int, returned > 0 {
            return returned
        }

        return nil
    }

    private static func countMessagesInTXT(at url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let bracketLines = lines.filter { $0.hasPrefix("[") }.count
        if bracketLines > 0 { return bracketLines }

        if let header = lines.first(where: { $0.contains("条") && $0.contains("消息") }) {
            let digits = header.filter(\.isNumber)
            if let count = Int(digits), count > 0 { return count }
        }
        return nil
    }

    private static func makeCSV(fromJSONAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] {
                rows = items
            } else if let messages = dict["messages"] as? [[String: Any]] {
                rows = messages
            } else if let results = dict["results"] as? [[String: Any]] {
                rows = results
            } else {
                return nil
            }
        } else {
            return nil
        }

        guard !rows.isEmpty else { return nil }

        var csv = "\u{FEFF}时间,发送者,类型,内容\n"
        for row in rows {
            let time = stringField(row, keys: ["time", "timestamp_str", "create_time"]) ?? ""
            let sender = stringField(row, keys: ["sender", "sender_display", "from", "display_name"]) ?? ""
            let type = stringField(row, keys: ["type", "type_name", "msg_type"]) ?? ""
            let content = (stringField(row, keys: ["content", "text", "message", "summary"]) ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(time)\",\"\(sender)\",\"\(type)\",\"\(content)\"\n"
        }
        return csv
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
            if let value = row[key] as? Int { return String(value) }
            if let nested = row[key] as? [String: Any] {
                if let content = nested["content"] as? String, !content.isEmpty { return content }
                if let text = nested["text"] as? String, !text.isEmpty { return text }
            }
        }
        return nil
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

            @Sendable func consume(_ handle: FileHandle, isErr: Bool) {
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

private final class SessionLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var _pageIndex = 0
    private var _knownTotal: Int?

    var pageIndex: Int {
        get { lock.withLock { _pageIndex } }
        set { lock.withLock { _pageIndex = newValue } }
    }

    var knownTotal: Int? {
        get { lock.withLock { _knownTotal } }
        set { lock.withLock { _knownTotal = newValue } }
    }

    var hasTotal: Bool {
        lock.withLock { _knownTotal != nil }
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
