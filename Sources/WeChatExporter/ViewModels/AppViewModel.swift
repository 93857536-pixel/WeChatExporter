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
    @Published var includeMedia = false
    @Published var alertMessage: String?
    @Published var showAlert = false
    @Published var operationProgress: Double?
    @Published var operationProgressLabel = ""

    private let backend: Backend
    private var didBootstrap = false

    init() {
        let defaultExport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
            .path
        exportPath = defaultExport

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
            presentError(error.localizedDescription)
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
            presentError(error.localizedDescription)
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
            presentError(error.localizedDescription)
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
            presentError(error.localizedDescription)
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
        // 按当前选中 ID 快照联系人，避免导出过程中列表刷新/选中变化导致串到其他人。
        let selectedIDsSnapshot = selectedIDs
        let selected = contacts.filter { selectedIDsSnapshot.contains($0.id) }
        guard !selected.isEmpty else {
            presentError("请先在列表中选择联系人或群聊。")
            return
        }

        isBusy = true
        statusText = "导出中…"
        defer {
            isBusy = false
            statusText = "就绪"
            clearProgress()
        }

        let base = URL(fileURLWithPath: exportPath.expandingTildeInPath, isDirectory: true)
        var summary: [String] = []
        var failures: [String] = []

        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            switch backend {
            case .wxCli(let wxCli):
                if includeMedia {
                    let stickerTemp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-stickers-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: stickerTemp) }
                    let stickerCount = await StickerPackExporter.exportAllPacks(in: stickerTemp, log: logHandler())
                    if stickerCount > 0, let galleryURL = try SingleFileExporter.writeStickerGallery(from: stickerTemp, into: base) {
                        summary.append("• 全部表情包：\(stickerCount) 张 → \(galleryURL.lastPathComponent)")
                    }
                }

                for (index, contact) in selected.enumerated() {
                    operationProgress = Double(index) / Double(selected.count)
                    operationProgressLabel = "正在导出 \(contact.displayName)（\(index + 1)/\(selected.count)）…"
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    do {
                        let count = try await wxCli.export(
                            contact: contact,
                            outputDir: tempDir,
                            includeMedia: includeMedia,
                            log: logHandler()
                        )
                        let htmlURL = try SingleFileExporter.writeHTML(
                            from: tempDir,
                            contactName: contact.displayName,
                            into: base
                        )
                        summary.append("• \(contact.displayName)：\(count) 条 → \(htmlURL.lastPathComponent)")
                    } catch {
                        let message = error.localizedDescription
                        failures.append("• \(contact.displayName)：\(message)")
                        appendLog("导出失败：\(contact.displayName) — \(message)")
                    }
                }
            case .native(let paths):
                guard paths.isDecryptedHealthy else {
                    throw AppError.exportFailed("请先点击「准备数据」")
                }
                for (index, contact) in selected.enumerated() {
                    operationProgress = Double(index) / Double(selected.count)
                    operationProgressLabel = "正在导出 \(contact.displayName)（\(index + 1)/\(selected.count)）…"
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("WeChatExporter-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    do {
                        appendLog("导出：\(contact.displayName) [\(contact.id)]")
                        let count = try ChatExporter.export(
                            contact: contact,
                            decryptedDir: paths.decryptedDir,
                            outputDir: tempDir
                        )
                        let htmlURL = try SingleFileExporter.writeHTML(
                            from: tempDir,
                            contactName: contact.displayName,
                            into: base
                        )
                        summary.append("• \(contact.displayName)：\(count) 条 → \(htmlURL.lastPathComponent)")
                    } catch {
                        let message = error.localizedDescription
                        failures.append("• \(contact.displayName)：\(message)")
                        appendLog("导出失败：\(contact.displayName) — \(message)")
                    }
                }
            }

            if summary.isEmpty {
                presentError(
                    "全部导出失败（共 \(selected.count) 个会话）：\n\(failures.joined(separator: "\n"))"
                )
            } else if failures.isEmpty {
                alertMessage = "已导出 \(summary.count) 个单文件到：\n\(base.path)\n\n\(summary.joined(separator: "\n"))\n\n用浏览器打开 .html 即可查看全部内容（媒体已内嵌）。"
                showAlert = true
            } else {
                alertMessage = "部分导出完成（成功 \(summary.count)，失败 \(failures.count)）：\n\(base.path)\n\n成功：\n\(summary.joined(separator: "\n"))\n\n失败：\n\(failures.joined(separator: "\n"))"
                showAlert = true
            }
        } catch {
            presentError(error.localizedDescription)
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

    private func presentError(_ message: String) {
        appendLog("错误：\(message)")
        alertMessage = message
        showAlert = true
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
