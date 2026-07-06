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

    func prepareData(log: @escaping (String) -> Void) async throws {
        log("检查运行环境…")
        guard await doctorOK() else {
            throw AppError.decryptFailed("wx-cli 环境检查未通过。请确认 SIP 已关闭且微信已登录。")
        }

        let status = try await statusText()
        let needsKey = !status.contains("key ✅")
        if needsKey {
            log("正在捕获解密密钥（会重启微信，约 1-2 分钟）…")
            _ = try await run(["key", "extract", "--timeout", "120"], timeout: 180)
        } else {
            log("使用已保存的密钥")
        }

        log("正在解密本地数据库…")
        _ = try await run(["decrypt"], timeout: 300)
        log("数据库解密完成")
    }

    func loadSessions(log: @escaping (String) -> Void) async throws -> [ContactItem] {
        log("正在加载会话列表…")
        let output = try await run(["sessions", "--format", "json", "--all"], timeout: 120)
        let payload = try Self.extractJSON(from: output)
        let response = try JSONDecoder().decode(WxCliSessionsResponse.self, from: payload)
        let items = response.items
            .filter { !$0.username.isEmpty && $0.username != "@placeholder_foldgroup" }
            .map { session in
                let username = session.username
                let display = Self.cleanDisplayName(session.displayName ?? username, username: username)
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
                    lastTime: Self.formatTime(ts),
                    lastTimestamp: ts,
                    summary: (session.summary ?? "").replacingOccurrences(of: "\n", with: " ")
                )
            }
        log("已加载 \(items.count) 个会话")
        return items.sorted { $0.lastTimestamp > $1.lastTimestamp }
    }

    func export(contact: ContactItem, outputDir: URL, log: @escaping (String) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let query = !contact.displayName.isEmpty ? contact.displayName : contact.id
        log("导出：\(contact.displayName)")

        _ = try await run([
            "export", query,
            "--output", outputDir.path,
            "--format", "txt",
            "--all",
            "--no-media",
        ], timeout: 600)

        _ = try await run([
            "export", query,
            "--output", outputDir.path,
            "--format", "json",
            "--all",
            "--no-media",
        ], timeout: 600)

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

    private func run(_ args: [String], timeout: TimeInterval = 120) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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
            process.terminationHandler = { proc in
                group.leave()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AppError.exportFailed("无法启动 wx-cli：\(error.localizedDescription)"))
                return
            }

            DispatchQueue.global().async {
                let deadline = DispatchTime.now() + timeout
                if group.wait(timeout: deadline) == .timedOut {
                    process.terminate()
                    continuation.resume(throwing: AppError.exportFailed("wx-cli 执行超时"))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if Self.procExitOK(process.terminationStatus) {
                    continuation.resume(returning: out + err)
                } else {
                    let message = Self.trimFailureOutput(out + "\n" + err)
                    continuation.resume(throwing: AppError.exportFailed(message))
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

private struct WxCliSessionsResponse: Decodable {
    let items: [WxCliSession]
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
