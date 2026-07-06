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
    @Published var alertMessage: String?
    @Published var showAlert = false

    private let backend: Backend

    init() {
        let defaultExport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
            .path
        exportPath = defaultExport

        if let wxCli = WxCliService() {
            backend = .wxCli(wxCli)
            appendLog(wxCli.isBundled ? "使用内置 wx-cli（即装即用）" : "使用系统 wx-cli")
            Task { await bootstrap() }
            return
        }

        do {
            let paths = try AppPaths.detect()
            backend = .native(paths)
            exportPath = paths.exportDir.path
            appendLog("账号：\(paths.accountID)")
            Task { await bootstrap() }
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

    private func bootstrap() async {
        switch backend {
        case .wxCli(let wxCli):
            appendLog("正在自动加载会话列表…")
            await refreshContacts(using: wxCli)
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
        }

        do {
            appendLog("开始准备数据…")
            switch backend {
            case .wxCli(let wxCli):
                try await wxCli.prepareData(log: { self.appendLog($0) })
                await refreshContacts(using: wxCli)
            case .native(let paths):
                try await prepareNativeData(paths: paths)
                await refreshContactsNative(paths: paths)
            }
            alertMessage = "数据准备完成，现在可以导出聊天记录了。"
            showAlert = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func refreshContacts() async {
        switch backend {
        case .wxCli(let wxCli):
            await refreshContacts(using: wxCli)
        case .native(let paths):
            await refreshContactsNative(paths: paths)
        }
    }

    private func refreshContacts(using wxCli: WxCliService) async {
        do {
            contacts = try await wxCli.loadSessions(log: { self.appendLog($0) })
            statusText = "显示 \(filteredContacts.count) / \(contacts.count) 个会话"
        } catch {
            presentError(error.localizedDescription)
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
            rawKey = try await KeyCaptureService.capture(dbRoot: paths.dbRoot) { self.appendLog($0) }
            if let rawKey { try DatabaseService.saveRawKey(rawKey, to: paths.rawKeyFile) }
        } else {
            appendLog("使用已保存的密钥")
        }
        guard let rawKey else { throw AppError.keyCaptureFailed }
        try DatabaseService.decryptAll(
            dbRoot: paths.dbRoot,
            decryptedDir: paths.decryptedDir,
            rawKey: rawKey,
            log: { self.appendLog($0) }
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

        let base = URL(fileURLWithPath: exportPath.expandingTildeInPath, isDirectory: true)
        var summary: [String] = []
        do {
            switch backend {
            case .wxCli(let wxCli):
                for contact in selected {
                    let safeName = contact.displayName.replacingOccurrences(of: "/", with: "_")
                    let outDir = base.appendingPathComponent(safeName, isDirectory: true)
                    let count = try await wxCli.export(contact: contact, outputDir: outDir, log: { self.appendLog($0) })
                    summary.append("• \(contact.displayName)：\(count) 条")
                }
            case .native(let paths):
                guard paths.isDecryptedHealthy else {
                    throw AppError.exportFailed("请先点击「准备数据」")
                }
                for contact in selected {
                    let safeName = contact.displayName.replacingOccurrences(of: "/", with: "_")
                    let outDir = base.appendingPathComponent(safeName, isDirectory: true)
                    appendLog("导出：\(contact.displayName)")
                    let count = try ChatExporter.export(
                        contact: contact,
                        decryptedDir: paths.decryptedDir,
                        outputDir: outDir
                    )
                    summary.append("• \(contact.displayName)：\(count) 条")
                }
            }
            alertMessage = "已导出 \(selected.count) 个会话到：\n\(base.path)\n\n\(summary.joined(separator: "\n"))"
            showAlert = true
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
}
