import Foundation
import SwiftUI
import AppKit
import os.log

/// 云备份视图模型：认证(OTP) + 备份上传/管理/删除/下载。
/// 所有重活（加密/哈希/分块）在 Task.detached 后台线程执行，@MainActor 只负责 UI 状态。
@MainActor
final class CloudBackupViewModel: ObservableObject {
    // MARK: - 认证
    @Published var authType: CloudAuthType = .email
    @Published var target = ""
    @Published var code = ""
    @Published var handle = ""
    @Published var isSendingCode = false
    @Published var countdown = 0
    @Published var authBusy = false

    // MARK: - 会话
    @Published var isLoggedIn: Bool
    @Published var currentHandle: String

    // MARK: - 用量 & 文件
    @Published var usage: CloudUsage?
    @Published var files: [CloudBackupFile] = []
    @Published var loadingFiles = false

    // MARK: - 上传
    @Published var uploadSourceDir = ""
    @Published var password = ""
    @Published var isUploading = false
    @Published var uploadProgress: Double?
    @Published var uploadLabel = ""

    // MARK: - 下载
    @Published var isDownloading = false
    @Published var downloadProgress: Double?
    @Published var downloadLabel = ""

    // MARK: - 提示
    @Published var statusMessage = ""
    @Published var alertMessage: String?
    @Published var showAlert = false
    @Published var pendingDelete: CloudBackupFile?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WeChatExporter",
        category: "cloudbackup"
    )
    private var countdownTask: Task<Void, Never>?
    private var token: String? { CloudBackupStore.token }

    init() {
        isLoggedIn = CloudBackupStore.token != nil
        currentHandle = CloudBackupStore.handle ?? ""
        if isLoggedIn {
            Task { await refresh() }
        }
    }

    // MARK: - 认证动作

    func sendCode() {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            showError("请输入邮箱或手机号")
            return
        }
        isSendingCode = true
        Task {
            defer { isSendingCode = false }
            do {
                let expires = try await CloudBackupAPI.sendCode(type: authType.rawValue, target: t)
                countdown = max(1, expires)
                startCountdown()
                statusMessage = "验证码已发送（\(expires) 秒内有效）"
                logger.info("验证码已发送到 \(t, privacy: .private)（\(expires) 秒有效）")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func loginOrRegister() {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            showError("请输入邮箱或手机号")
            return
        }
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count == 6, c.allSatisfy(\.isNumber) else {
            showError("请输入 6 位数字验证码")
            return
        }
        authBusy = true
        Task {
            defer { authBusy = false }
            do {
                let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await CloudBackupAPI.auth(
                    type: authType.rawValue,
                    target: t,
                    code: c,
                    handle: trimmedHandle.isEmpty ? nil : trimmedHandle,
                    deviceId: CloudBackupAPI.deviceId
                )
                CloudBackupStore.token = result.token
                CloudBackupStore.sessionId = result.sessionId
                CloudBackupStore.userId = result.user.id
                CloudBackupStore.handle = result.user.handle
                isLoggedIn = true
                currentHandle = result.user.handle
                statusMessage = "登录成功"
                logger.info("云备份登录成功：\(result.user.handle, privacy: .public)")
                await refresh()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func logout() {
        CloudBackupStore.clear()
        isLoggedIn = false
        currentHandle = ""
        usage = nil
        files = []
        statusMessage = "已退出登录"
    }

    // MARK: - 用量 & 列表

    func refresh() async {
        guard let token else { return }
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            async let uTask = CloudBackupAPI.usage(token: token)
            async let mTask = CloudBackupAPI.manifest(token: token)
            let (u, m) = try await (uTask, mTask)
            usage = u
            files = m.sorted { $0.createdAt > $1.createdAt }
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - 上传

    func selectUploadDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择要备份的导出目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            uploadSourceDir = url.path
        }
    }

    func startUpload() {
        guard let token else {
            showError("请先登录")
            return
        }
        guard !uploadSourceDir.isEmpty else {
            showError("请选择要备份的导出目录")
            return
        }
        let pw = password
        guard !pw.isEmpty else {
            showError("请设置备份密码（用于本地加密，永不上传服务器）")
            return
        }
        let dir = URL(fileURLWithPath: (uploadSourceDir as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            showError("导出目录不存在")
            return
        }

        isUploading = true
        uploadProgress = 0
        uploadLabel = "正在加密…"
        statusMessage = ""

        let log = statusLog()
        let progress = uploadProgressHandler()

        Task { [weak self] in
            defer { self?.isUploading = false }
            do {
                try await Task.detached {
                    try await CloudBackupTransfer.upload(
                        directory: dir,
                        password: pw,
                        token: token,
                        progress: progress,
                        log: log
                    )
                }.value
                self?.statusMessage = "上传完成"
                self?.logger.info("云备份上传完成")
                await self?.refresh()
            } catch {
                self?.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - 下载

    func startDownload(_ file: CloudBackupFile) {
        guard let token else {
            showError("请先登录")
            return
        }
        let pw = password
        guard !pw.isEmpty else {
            showError("请输入解密密码")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择解密保存目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        isDownloading = true
        downloadProgress = 0
        downloadLabel = "正在下载…"
        statusMessage = ""

        let log = statusLog()
        let progress = downloadProgressHandler()

        Task { [weak self] in
            defer { self?.isDownloading = false }
            do {
                _ = try await Task.detached {
                    try await CloudBackupTransfer.download(
                        file: file,
                        token: token,
                        to: dest,
                        password: pw,
                        progress: progress,
                        log: log
                    )
                }.value
                self?.statusMessage = "下载并解密完成 → \(dest.path)"
                self?.logger.info("云备份下载完成")
            } catch {
                self?.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - 删除

    func confirmDelete(_ file: CloudBackupFile) {
        pendingDelete = file
    }

    func performDelete() {
        guard let file = pendingDelete else { return }
        pendingDelete = nil
        guard let token else {
            showError("请先登录")
            return
        }
        Task { [weak self] in
            do {
                try await CloudBackupAPI.deleteFile(token: token, name: file.name)
                self?.statusMessage = "已删除 \(file.name)"
                await self?.refresh()
            } catch {
                self?.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - 内部

    private func showError(_ message: String) {
        alertMessage = message
        showAlert = true
        logger.error("\(message, privacy: .public)")
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self {
                if self.countdown <= 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.countdown -= 1
            }
        }
    }

    /// 后台 → 主线程状态日志
    private func statusLog() -> @Sendable (String) -> Void {
        { [self] message in
            Task { @MainActor [self] in self.statusMessage = message }
        }
    }

    private func uploadProgressHandler() -> @Sendable (Double, String) -> Void {
        { [self] fraction, label in
            Task { @MainActor [self] in
                self.uploadProgress = fraction
                self.uploadLabel = label
            }
        }
    }

    private func downloadProgressHandler() -> @Sendable (Double, String) -> Void {
        { [self] fraction, label in
            Task { @MainActor [self] in
                self.downloadProgress = fraction
                self.downloadLabel = label
            }
        }
    }
}
