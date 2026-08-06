import Foundation
import AppKit

/// 更新检查模式
enum UpdateMode: String, CaseIterable {
    /// 启动时自动检查，发现新版本后自动下载并安装
    case automatic = "automatic"
    /// 启动时自动检查，发现新版本后仅通知用户，由用户手动下载
    case notifyOnly = "notify"
    /// 不自动检查，仅用户手动点击时检查
    case manual = "manual"
    /// 关闭更新检查
    case disabled = "disabled"

    var displayName: String {
        switch self {
        case .automatic: return "自动更新"
        case .notifyOnly: return "仅通知"
        case .manual: return "手动检查"
        case .disabled: return "关闭"
        }
    }

    var description: String {
        switch self {
        case .automatic: return "启动时自动检查并下载安装新版本"
        case .notifyOnly: return "启动时自动检查，发现新版本时通知你"
        case .manual: return "不自动检查，仅在点击「检查更新」时检查"
        case .disabled: return "完全不检查更新"
        }
    }

    var shouldCheckOnStartup: Bool {
        self == .automatic || self == .notifyOnly
    }
}

/// 更新信息
struct UpdateInfo: Codable, Equatable {
    let version: String        // 如 "2.9.0"
    let tagName: String        // 如 "v2.9.0"
    let releaseNotes: String
    let releaseURL: String     // GitHub release 页面
    let publishedAt: Date
    let dmgDownloadURL: String // macOS DMG 下载地址
    let dmgSize: Int64         // DMG 文件大小（字节）
}

/// 下载进度
struct UpdateDownloadProgress: Equatable {
    let bytesDownloaded: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var formattedProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }
}

/// 更新偏好设置（持久化到 UserDefaults）
struct UpdatePreferences {
    private enum Keys {
        static let mode = "update.mode"
        static let lastCheckDate = "update.lastCheckDate"
        static let skippedVersion = "update.skippedVersion"
    }

    static var mode: UpdateMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.mode) ?? UpdateMode.automatic.rawValue
            return UpdateMode(rawValue: raw) ?? .automatic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.mode)
        }
    }

    static var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastCheckDate) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastCheckDate) }
    }

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Keys.skippedVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.skippedVersion) }
    }
}

/// 应用更新服务
final class UpdateService {
    static let shared = UpdateService()

    private let repoOwner = "93857536-pixel"
    private let repoName = "WeChatExporter"
    private let apiURL = "https://api.github.com/repos/93857536-pixel/WeChatExporter/releases/latest"

    /// 当前应用版本（从 Info.plist 读取）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 当前构建号
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private init() {}

    // MARK: - 版本比较

    /// 比较两个语义化版本号，返回 true 表示 remote 比 current 新
    func isRemoteNewer(remote: String, than current: String) -> Bool {
        let remoteParts = parseVersion(remote)
        let currentParts = parseVersion(current)
        return remoteParts.lexicographicallyPrecedes(currentParts) == false
            && remoteParts != currentParts
    }

    private func parseVersion(_ version: String) -> [Int] {
        let cleaned = version
            .replacingOccurrences(of: "v", with: "")
            .split(separator: "-").first.map(String.init) ?? version
        return cleaned.split(separator: ".").compactMap { Int($0) }
    }

    // MARK: - 检查更新

    /// 调用 GitHub API 检查最新版本
    func checkForUpdates() async throws -> UpdateInfo? {
        var request = URLRequest(url: URL(string: apiURL)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WeChatExporter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.networkError("无效的响应")
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateError.networkError("GitHub API 返回状态码 \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct GitHubRelease: Decodable {
            let tagName: String
            let name: String?
            let body: String?
            let htmlURL: String
            let publishedAt: Date
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case name
                case body
                case htmlURL = "html_url"
                case publishedAt = "published_at"
                case assets
            }

            struct Asset: Decodable {
                let name: String
                let size: Int64
                let downloadURL: String

                enum CodingKeys: String, CodingKey {
                    case name
                    case size
                    case downloadURL = "browser_download_url"
                }
            }
        }

        let release = try decoder.decode(GitHubRelease.self, from: data)
        let version = release.tagName.replacingOccurrences(of: "v", with: "")

        // 查找 macOS DMG 资产
        guard let dmgAsset = release.assets.first(where: {
            $0.name.lowercased().contains("macos") && $0.name.lowercased().hasSuffix(".dmg")
        }) else {
            // 没有 DMG，可能是预发布或不完整版本
            return nil
        }

        // 当前版本已经是最新
        guard isRemoteNewer(remote: version, than: currentVersion) else {
            return nil
        }

        // 用户跳过了此版本
        if let skipped = UpdatePreferences.skippedVersion, skipped == version {
            return nil
        }

        return UpdateInfo(
            version: version,
            tagName: release.tagName,
            releaseNotes: release.body ?? "无更新说明",
            releaseURL: release.htmlURL,
            publishedAt: release.publishedAt,
            dmgDownloadURL: dmgAsset.downloadURL,
            dmgSize: dmgAsset.size
        )
    }

    // MARK: - 下载更新

    /// 下载 DMG 到临时目录，返回本地文件路径
    func downloadUpdate(
        from url: URL,
        expectedSize: Int64,
        progress: @escaping (UpdateDownloadProgress) -> Void
    ) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("WeChatExporter-\(UUID().uuidString).dmg")

        var request = URLRequest(url: url)
        request.setValue("WeChatExporter/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed("服务器返回错误状态码")
        }

        var fileHandle: FileHandle?
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: destURL)

        defer {
            try? fileHandle?.close()
        }

        var received: Int64 = 0
        let bufferSize = 64 * 1024
        var buffer = Data()

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                try fileHandle?.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                received += Int64(bufferSize)
                progress(UpdateDownloadProgress(
                    bytesDownloaded: received,
                    totalBytes: expectedSize
                ))
            }
        }

        // 写入剩余数据
        if !buffer.isEmpty {
            try fileHandle?.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress(UpdateDownloadProgress(
                bytesDownloaded: received,
                totalBytes: expectedSize
            ))
        }

        return destURL
    }

    // MARK: - 安装更新

    /// 挂载 DMG 并将新版本 .app 复制到当前应用所在位置
    func installUpdate(from dmgURL: URL) async throws {
        // 1. 挂载 DMG
        let mountTask = Process()
        mountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountTask.arguments = ["attach", dmgURL.path, "-nobrowse", "-quiet"]

        let mountPipe = Pipe()
        mountTask.standardOutput = mountPipe
        mountTask.standardError = mountPipe

        try mountTask.run()
        mountTask.waitUntilExit()

        guard mountTask.terminationStatus == 0 else {
            let output = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.installFailed("无法挂载 DMG：\(output)")
        }

        // 解析挂载点
        let mountOutput = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let mountPoint = parseMountPoint(from: mountOutput)

        guard let mountPoint else {
            throw UpdateError.installFailed("无法解析 DMG 挂载点")
        }

        defer {
            // 卸载 DMG
            let unmountTask = Process()
            unmountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            unmountTask.arguments = ["detach", mountPoint, "-quiet"]
            try? unmountTask.run()
            unmountTask.waitUntilExit()
            try? FileManager.default.removeItem(at: dmgURL)
        }

        // 2. 查找 .app
        let mountedContents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = mountedContents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.installFailed("DMG 中未找到 .app 文件")
        }

        let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        // 3. 获取当前应用路径
        let currentAppPath = Bundle.main.bundleURL
        let parentDir = currentAppPath.deletingLastPathComponent()

        // 4. 写入替换脚本（因为应用运行时不能直接覆盖自身）
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatUpdater-\(UUID().uuidString).sh")

        let newName = currentAppPath.lastPathComponent
        let newPath = parentDir.appendingPathComponent(newName)

        let script = """
        #!/bin/bash
        sleep 1
        # 关闭旧应用
        osascript -e 'quit app "\(Bundle.main.bundleIdentifier ?? "WeChatExporter")"' 2>/dev/null || true
        sleep 1
        # 删除旧版本
        rm -rf "\(newPath.path)"
        # 复制新版本
        cp -R "\(sourceApp.path)" "\(newPath.path)"
        # 清除隔离属性
        xattr -cr "\(newPath.path)" 2>/dev/null || true
        # 重新签名
        codesign --force --deep --sign - "\(newPath.path)" 2>/dev/null || true
        # 启动新版本
        open "\(newPath.path)"
        # 清理脚本自身
        rm -f "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 5. 执行替换脚本
        let installTask = Process()
        installTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        installTask.arguments = [scriptURL.path]
        installTask.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        installTask.standardError = FileHandle(forWritingAtPath: "/dev/null")

        try installTask.run()

        // 6. 退出当前应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.terminate(nil)
        }
    }

    /// 在浏览器中打开 Release 页面（手动下载模式）
    func openReleasePage(url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 辅助方法

    /// 是否需要检查更新（根据模式和上次检查时间）
    func shouldCheckOnStartup() -> Bool {
        guard UpdatePreferences.mode.shouldCheckOnStartup else { return false }

        // 距离上次检查不足 1 小时，跳过
        if let lastCheck = UpdatePreferences.lastCheckDate {
            let interval = Date().timeIntervalSince(lastCheck)
            if interval < 3600 { return false }
        }

        return true
    }

    private func parseMountPoint(from output: String) -> String? {
        let lines = output.split(separator: "\n")
        // hdiutil attach 输出格式：最后一行包含挂载点
        // 例如：/dev/disk4s1  Apple_HFS /Volumes/WeChatExporter
        guard let lastLine = lines.last else { return nil }
        let components = lastLine.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
        // 挂载点是最后一个以 /Volumes/ 开头的部分
        if let mountPoint = components.last(where: { $0.hasPrefix("/Volumes/") }) {
            return mountPoint
        }
        // 尝试用空格分割
        let spaceParts = lastLine.split(separator: " ").map { String($0) }
        if let mountPoint = spaceParts.last(where: { $0.hasPrefix("/Volumes/") }) {
            return mountPoint
        }
        return nil
    }
}

// MARK: - 错误类型

enum UpdateError: LocalizedError {
    case networkError(String)
    case downloadFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "网络错误：\(msg)"
        case .downloadFailed(let msg):
            return "下载失败：\(msg)"
        case .installFailed(let msg):
            return "安装失败：\(msg)"
        }
    }
}
