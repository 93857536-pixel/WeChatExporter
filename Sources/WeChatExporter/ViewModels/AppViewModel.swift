import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    enum Backend {
        case wxCli(WxCliService)
        case native(AppPaths)
    }

    @Published var contacts: [ContactItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var exportPath: String = ""
    @Published var logs: [String] = []
    @Published var isBusy = false
    @Published var statusText = "就绪"
    @Published var isDataReady = false
    @Published var exportMode: ExportMode = ExportModePreferences.mode
    @Published var alertMessage: String?
    @Published var showAlert = false
    @Published var operationProgress: Double?
    @Published var operationProgressLabel = ""

    // 更新相关状态
    @Published var updateMode: UpdateMode = UpdatePreferences.mode
    @Published var isCheckingUpdate = false
    @Published var availableUpdate: UpdateInfo?
    @Published var showUpdateSheet = false
    @Published var updateDownloadProgress: UpdateDownloadProgress?
    @Published var isDownloadingUpdate = false
    @Published var isInstallingUpdate = false
    @Published var updateCheckMessage: String?
    @Published var showUpdateSettings = false
    @Published var showSettings = false
    // 设置面板当前选中的标签页（0=导出 1=更新 2=关于）
    @Published var settingsTab = 0

    // 诊断日志上传条款弹窗（首次启动未选择时显示）
    @Published var showConsent = false

    var currentVersion: String { UpdateService.shared.currentVersion }
    var currentBuild: String { UpdateService.shared.currentBuild }
    var lastCheckDate: Date? { UpdatePreferences.lastCheckDate }

    private let backend: Backend
    private var didBootstrap = false

    init() {
        let defaultExport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
            .path
        exportPath = defaultExport

        // 首次启动且未选择诊断上传条款时，显示条款弹窗
        if !DiagnosticUploader.isConsentDecided {
            showConsent = true
        }

        if let wxCli = WxCliService() {
            backend = .wxCli(wxCli)
            appendLog(wxCli.isBundled ? "使用内置 wx-cli（即装即用）" : "使用系统 wx-cli")
            return
        }

        do {
            let paths = try AppPaths.detect()
            backend = .native(paths)
            exportPath = paths.exportDir.path
            appendLog("账号：\(paths.accountID)")
        } catch {
            backend = .native(
                AppPaths(
                    accountID: "",
                    dbRoot: URL(fileURLWithPath: "/"),
                    workDir: URL(fileURLWithPath: "/"),
                    decryptedDir: URL(fileURLWithPath: "/"),
                    keysFile: URL(fileURLWithPath: "/"),
                    rawKeyFile: URL(fileURLWithPath: "/"),
                    exportDir: URL(fileURLWithPath: defaultExport, isDirectory: true)
                )
            )
            presentError(error.localizedDescription)
        }
    }

    var readinessHint: String {
        if let label = operationProgressLabel.nonEmpty {
            return label
        }
        if isBusy { return "正在处理，请稍候…" }
        if isDataReady { return "已就绪 · 共 \(contacts.count) 个会话，选择后点击「导出选中」" }
        return "首次使用：请先点击「准备数据」（需微信已登录，macOS 需关闭 SIP）"
    }

    var filteredContacts: [ContactItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return contacts }
        return contacts.filter {
            [$0.displayName, $0.nickName, $0.remark, $0.id, $0.summary]
                .joined(separator: " ")
                .lowercased()
                .contains(q)
        }
    }

    func appendLog(_ message: String) {
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        logs.append(line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    /// 供 wx-cli / LLDB 等后台任务回调，始终在主线程更新 UI 状态。
    private func logHandler() -> (String) -> Void {
        { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
    }

    private func progressHandler() -> @Sendable (LoadProgressUpdate) -> Void {
        { [weak self] update in
            let fraction = update.fraction
            let message = update.message
            DispatchQueue.main.async {
                self?.operationProgress = fraction
                self?.operationProgressLabel = message
            }
        }
    }

    private func clearProgress() {
        operationProgress = nil
        operationProgressLabel = ""
    }

    func startIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }

    private func bootstrap() async {
        switch backend {
        case .wxCli(let wxCli):
            if await wxCli.isPreparedForQuery() {
                appendLog("正在自动加载会话列表…")
                await loadContactsSilently(using: wxCli)
            } else {
                appendLog("首次使用请点击「准备数据」。")
            }
        case .native(let paths):
            if paths.isDecryptedHealthy {
                appendLog("检测到已解密数据，正在加载联系人…")
                await refreshContactsNative(paths: paths)
            } else if paths.isDecrypted {
                appendLog("检测到解密数据已损坏，正在尝试修复…")
                await repairNativeData(paths: paths)
            } else if paths.syncFromWxCliCache() {
                appendLog("已从 wx-cli 缓存同步解密数据")
                await refreshContactsNative(paths: paths)
            } else {
                appendLog("首次使用请点击「准备数据」。")
            }
        }
    }

    func prepareData() async {
        guard !isBusy else { return }
        isBusy = true
        statusText = "准备数据中…"
        defer {
            isBusy = false
            statusText = "就绪"
            clearProgress()
        }

        do {
            appendLog("开始准备数据…")
            switch backend {
            case .wxCli(let wxCli):
                try await wxCli.prepareData(log: logHandler(), progress: progressHandler())
                await refreshContacts(using: wxCli, showProgress: true)
            case .native(let paths):
                try await prepareNativeData(paths: paths)
                await refreshContactsNative(paths: paths)
            }
            alertMessage = "数据准备完成，现在可以导出聊天记录了。"
            showAlert = true
            isDataReady = true
        } catch {
            presentError(error.localizedDescription, stage: DiagnosticUploader.stagePrepare)
        }
    }

    func refreshContacts() async {
        switch backend {
        case .wxCli(let wxCli):
            await refreshContacts(using: wxCli, showProgress: true)
        case .native(let paths):
            await refreshContactsNative(paths: paths)
        }
    }

    private func refreshContacts(using wxCli: WxCliService, showProgress: Bool) async {
        if showProgress { isBusy = true }
        do {
            contacts = try await wxCli.loadSessions(
                log: logHandler(),
                progress: progressHandler()
            )
            isDataReady = !contacts.isEmpty
            statusText = "显示 \(filteredContacts.count) / \(contacts.count) 个会话"
        } catch {
            isDataReady = false
            presentError(error.localizedDescription, stage: DiagnosticUploader.stageLoadSessions)
        }
        if showProgress {
            isBusy = false
            clearProgress()
        }
    }

    private func loadContactsSilently(using wxCli: WxCliService) async {
        do {
            contacts = try await wxCli.loadSessions(
                log: logHandler(),
                progress: progressHandler()
            )
            isDataReady = !contacts.isEmpty
            statusText = "显示 \(filteredContacts.count) / \(contacts.count) 个会话"
            clearProgress()
        } catch {
            isDataReady = false
            clearProgress()
            let message = error.localizedDescription
            if message.contains("超时") {
                appendLog("加载超时：请先点击「准备数据」完成解密，或稍后重试。")
            } else {
                appendLog("自动加载失败：\(message)")
            }
            appendLog("首次使用请点击「准备数据」。")
        }
    }

    private func refreshContactsNative(paths: AppPaths) async {
        guard paths.isDecryptedHealthy else {
            presentError("解密数据不可用，请先点击「准备数据」。")
            return
        }
        do {
            contacts = try ContactStore.loadContacts(from: paths.decryptedDir)
            appendLog("已加载 \(contacts.count) 个会话")
            isDataReady = !contacts.isEmpty
            statusText = "显示 \(filteredContacts.count) / \(contacts.count) 个会话"
        } catch {
            presentError(error.localizedDescription, stage: DiagnosticUploader.stageLoadSessions)
        }
    }

    private func repairNativeData(paths: AppPaths) async {
        if paths.syncFromWxCliCache() {
            appendLog("已从 wx-cli 缓存修复解密数据")
            await refreshContactsNative(paths: paths)
            return
        }
        do {
            try await prepareNativeData(paths: paths)
            await refreshContactsNative(paths: paths)
        } catch {
            presentError(error.localizedDescription, stage: DiagnosticUploader.stagePrepare)
        }
    }

    private func prepareNativeData(paths: AppPaths) async throws {
        var rawKey = DatabaseService.loadSavedRawKey(from: paths.rawKeyFile, dbRoot: paths.dbRoot)
        if rawKey == nil {
            rawKey = try await KeyCaptureService.capture(dbRoot: paths.dbRoot, log: logHandler())
            if let rawKey { try DatabaseService.saveRawKey(rawKey, to: paths.rawKeyFile) }
        } else {
            appendLog("使用已保存的密钥")
        }
        guard let rawKey else { throw AppError.keyCaptureFailed }
        try DatabaseService.decryptAll(
            dbRoot: paths.dbRoot,
            decryptedDir: paths.decryptedDir,
            rawKey: rawKey,
            log: logHandler()
        )
    }

    func exportSelected() async {
        guard !isBusy else { return }
        let selected = contacts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else {
            presentError("请先在列表中选择联系人或群聊。")
            return
        }

        isBusy = true
        statusText = "导出中…"
        defer {
            isBusy = false
            statusText = "就绪"
        }

        let mode = exportMode
        let base = URL(fileURLWithPath: exportPath.expandingTildeInPath, isDirectory: true)
        var summary: [String] = []
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            switch backend {
            case .wxCli(let wxCli):
                for contact in selected {
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    let count = try await wxCli.export(
                        contact: contact,
                        outputDir: tempDir,
                        includeMedia: mode.includesMedia,
                        log: logHandler()
                    )

                    switch mode {
                    case .categorized:
                        // 按分类归档：文字 / 图片 / 视频 / 其他
                        let result = try MediaOrganizer.organize(
                            sourceDir: tempDir,
                            into: base,
                            contactName: contact.displayName,
                            log: logHandler()
                        )
                        summary.append("• \(contact.displayName)：\(count) 条（文字 \(result.textCount)、图片 \(result.imageCount)、视频 \(result.videoCount)、其他 \(result.otherCount)）")
                    case .textOnly:
                        // 只导出文字文件
                        let contactDir = base.appendingPathComponent(contact.displayName, isDirectory: true)
                        try FileManager.default.createDirectory(at: contactDir, withIntermediateDirectories: true)
                        try copyTextArtifacts(from: tempDir, to: contactDir)
                        summary.append("• \(contact.displayName)：\(count) 条（仅文字）")
                    case .all:
                        // 全部导出：文字 + 原始媒体文件夹，不内嵌 HTML
                        let contactDir = base.appendingPathComponent(contact.displayName, isDirectory: true)
                        try FileManager.default.createDirectory(at: contactDir, withIntermediateDirectories: true)
                        try copyAllArtifacts(from: tempDir, to: contactDir)
                        summary.append("• \(contact.displayName)：\(count) 条（文字 + 媒体文件）")
                    }
                }

                // 表情包导出（含媒体模式）
                if mode.includesMedia {
                    let stickerTemp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-stickers-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: stickerTemp) }
                    let stickerCount = await StickerPackExporter.exportAllPacks(in: stickerTemp, log: logHandler())
                    if stickerCount > 0 {
                        let stickersDir = base.appendingPathComponent("全部表情包", isDirectory: true)
                        try? FileManager.default.createDirectory(at: stickersDir, withIntermediateDirectories: true)
                        if let files = try? FileManager.default.contentsOfDirectory(at: stickerTemp.appendingPathComponent("media/stickers"), includingPropertiesForKeys: nil) {
                            for f in files {
                                let dest = stickersDir.appendingPathComponent(f.lastPathComponent)
                                if FileManager.default.fileExists(atPath: dest.path) {
                                    try? FileManager.default.removeItem(at: dest)
                                }
                                try? FileManager.default.moveItem(at: f, to: dest)
                            }
                        }
                        summary.append("• 全部表情包：\(stickerCount) 张 → 全部表情包/")
                    }
                }
            case .native(let paths):
                guard paths.isDecryptedHealthy else {
                    throw AppError.exportFailed("请先点击「准备数据」")
                }
                for contact in selected {
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    appendLog("导出：\(contact.displayName)")
                    let count = try ChatExporter.export(
                        contact: contact,
                        decryptedDir: paths.decryptedDir,
                        outputDir: tempDir
                    )
                    let contactDir = base.appendingPathComponent(contact.displayName, isDirectory: true)
                    try FileManager.default.createDirectory(at: contactDir, withIntermediateDirectories: true)
                    try copyTextArtifacts(from: tempDir, to: contactDir)
                    summary.append("• \(contact.displayName)：\(count) 条")
                }
            }
            alertMessage = "已导出 \(selected.count) 个会话到：\n\(base.path)\n\n\(summary.joined(separator: "\n"))\n\n导出方式：\(mode.displayName)"
            showAlert = true
        } catch {
            presentError(error.localizedDescription, stage: DiagnosticUploader.stageExport)
        }
    }

    /// 复制文字类文件（txt/json/csv）到目标目录
    private func copyTextArtifacts(from sourceDir: URL, to destDir: URL) throws {
        let fm = FileManager.default
        let textExts: Set<String> = ["txt", "json", "csv"]
        guard let files = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else { return }
        for file in files where textExts.contains(file.pathExtension.lowercased()) {
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
        }
    }

    /// 复制全部文件（文字 + 媒体原始结构）到目标目录
    private func copyAllArtifacts(from sourceDir: URL, to destDir: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let file as URL in enumerator {
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relPath = file.path.replacingOccurrences(of: sourceDir.path + "/", with: "")
            let dest = destDir.appendingPathComponent(relPath)

            if isDir {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
            }
        }
    }

    func openExportFolder() {
        let url = URL(fileURLWithPath: exportPath.expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: exportPath.expandingTildeInPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            exportPath = url.path
        }
    }

    // MARK: - 更新功能

    func changeUpdateMode(_ mode: UpdateMode) {
        updateMode = mode
        UpdatePreferences.mode = mode
        appendLog("更新模式已切换为：\(mode.displayName)")
    }

    /// 启动时自动检查更新
    func checkUpdateOnStartup() {
        guard UpdateService.shared.shouldCheckOnStartup() else { return }
        Task { await checkForUpdates(silent: true) }
    }

    /// 用户手动检查更新
    func checkForUpdatesManually() {
        Task { await checkForUpdates(silent: false) }
    }

    /// 检查更新
    func checkForUpdates(silent: Bool) async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }

        do {
            let info = try await UpdateService.shared.checkForUpdates()
            UpdatePreferences.lastCheckDate = Date()

            if let info {
                availableUpdate = info
                appendLog("发现新版本：v\(info.version)（当前 v\(currentVersion)）")
                if UpdatePreferences.mode == .automatic {
                    // 自动模式：后台静默下载，完成后发系统通知，不打断用户
                    await downloadUpdateInBackground(info)
                } else {
                    // 通知用户
                    showUpdateSheet = true
                }
            } else {
                if !silent {
                    updateCheckMessage = "当前版本（v\(currentVersion)）已是最新版本。"
                    showUpdateSheet = true
                }
            }
        } catch {
            if !silent {
                updateCheckMessage = "检查更新失败：\(error.localizedDescription)"
                showUpdateSheet = true
            }
            appendLog("检查更新失败：\(error.localizedDescription)")
        }
    }

    /// 后台静默下载更新（自动模式）：下载 ZIP → 解压 → 记录待安装 → 发系统通知
    func downloadUpdateInBackground(_ info: UpdateInfo) async {
        isDownloadingUpdate = true
        updateDownloadProgress = UpdateDownloadProgress(bytesDownloaded: 0, totalBytes: info.zipSize)

        defer {
            isDownloadingUpdate = false
            updateDownloadProgress = nil
        }

        do {
            appendLog("正在后台下载 v\(info.version)（不打断当前操作）…")
            _ = try await UpdateService.shared.prepareSilentUpdate(info: info) { [weak self] progress in
                Task { @MainActor in
                    self?.updateDownloadProgress = progress
                }
            }
            appendLog("v\(info.version) 已下载完成，点击系统通知即可重启安装")
            // 发送系统横幅通知
            NotificationService.postUpdateReady(version: info.version, tagName: info.tagName)
            // 若通知权限未授权，降级为应用内弹窗提示
            if !NotificationService.isAuthorized {
                alertMessage = "新版本 v\(info.version) 已下载完成。\n\n重启应用即可完成更新。\n（可在系统设置中允许本应用发送通知，以便收到更新提醒）"
                showAlert = true
            }
        } catch {
            appendLog("更新下载失败：\(error.localizedDescription)")
            alertMessage = "更新下载失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    /// 用户手动下载并立即安装（DMG 手动模式）
    func downloadAndInstallUpdate(_ info: UpdateInfo) async {
        isDownloadingUpdate = true
        updateDownloadProgress = UpdateDownloadProgress(bytesDownloaded: 0, totalBytes: info.dmgSize)

        defer {
            isDownloadingUpdate = false
            updateDownloadProgress = nil
        }

        do {
            appendLog("正在下载 v\(info.version)…")
            let dmgURL = try await UpdateService.shared.downloadUpdate(
                from: URL(string: info.dmgDownloadURL)!,
                expectedSize: info.dmgSize
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateDownloadProgress = progress
                }
            }
            appendLog("下载完成，正在安装…")
            isInstallingUpdate = true
            try await UpdateService.shared.installUpdate(from: dmgURL)
        } catch {
            isInstallingUpdate = false
            appendLog("更新失败：\(error.localizedDescription)")
            alertMessage = "更新失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    /// 应用待安装更新（用户点击通知或下次启动时调用）
    func applyPendingUpdateIfNeeded() {
        guard UpdatePreferences.hasPendingInstall else { return }
        let version = UpdatePreferences.pendingInstallVersion ?? "新版本"
        appendLog("检测到待安装更新 v\(version)，正在应用…")
        do {
            try UpdateService.shared.applyPendingInstall()
        } catch {
            appendLog("应用更新失败：\(error.localizedDescription)")
            UpdateService.clearPendingInstall()
        }
    }

    /// 跳过此版本
    func skipUpdate() {
        if let info = availableUpdate {
            UpdatePreferences.skippedVersion = info.version
            appendLog("已跳过 v\(info.version)")
        }
        availableUpdate = nil
        showUpdateSheet = false
    }

    /// 在浏览器中打开 Release 页面（手动下载）
    func openReleaseInBrowser() {
        if let info = availableUpdate {
            UpdateService.shared.openReleasePage(url: info.releaseURL)
        } else {
            UpdateService.shared.openReleasePage(url: "https://github.com/93857536-pixel/WeChatExporter/releases/latest")
        }
    }

    private func presentError(_ message: String, stage: String = DiagnosticUploader.stageOther) {
        appendLog("错误：\(message)")
        DiagnosticUploader.reportIfAllowed(stage: stage, error: message, logs: logs)
        alertMessage = message
        showAlert = true
    }

    /// 诊断日志上传同意状态（绑定到 UserDefaults，设置面板开关用）
    var diagnosticsConsented: Bool {
        get { DiagnosticUploader.isConsented }
        set { DiagnosticUploader.setConsented(newValue) }
    }

    /// 记录用户对诊断上传条款的选择（条款弹窗按钮调用）
    func setDiagnosticsConsent(_ consented: Bool) {
        DiagnosticUploader.setConsented(consented)
        showConsent = false
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
