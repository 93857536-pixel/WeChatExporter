import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var contacts: [ContactItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var exportPath: String = ""
    @Published var logs: [String] = []
    @Published var isBusy = false
    @Published var statusText = "就绪"
    @Published var alertMessage: String?
    @Published var showAlert = false

    private(set) var paths: AppPaths

    init() {
        do {
            paths = try AppPaths.detect()
            exportPath = paths.exportDir.path
            appendLog("账号：\(paths.accountID)")
            if paths.isDecrypted {
                appendLog("检测到已解密数据，正在加载联系人…")
                Task { await refreshContacts() }
            } else {
                appendLog("首次使用请点击「准备数据」。")
            }
        } catch {
            paths = AppPaths(
                accountID: "",
                dbRoot: URL(fileURLWithPath: "/"),
                workDir: URL(fileURLWithPath: "/"),
                decryptedDir: URL(fileURLWithPath: "/"),
                keysFile: URL(fileURLWithPath: "/"),
                rawKeyFile: URL(fileURLWithPath: "/"),
                exportDir: URL(fileURLWithPath: "/")
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
            var rawKey = DatabaseService.loadSavedRawKey(from: paths.rawKeyFile, dbRoot: paths.dbRoot)
            if rawKey == nil {
                rawKey = try await KeyCaptureService.capture(dbRoot: paths.dbRoot) { self.appendLog($0) }
                if let rawKey { try DatabaseService.saveRawKey(rawKey, to: paths.rawKeyFile) }
            } else {
                appendLog("使用已保存的密钥")
            }
            guard let rawKey else { throw AppError.keyCaptureFailed }
            try DatabaseService.decryptAll(dbRoot: paths.dbRoot, decryptedDir: paths.decryptedDir, rawKey: rawKey, log: { self.appendLog($0) })
            await refreshContacts()
            alertMessage = "数据准备完成，现在可以导出聊天记录了。"
            showAlert = true
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func refreshContacts() async {
        guard paths.isDecrypted else { return }
        do {
            contacts = try ContactStore.loadContacts(from: paths.decryptedDir)
            appendLog("已加载 \(contacts.count) 个会话")
            statusText = "显示 \(filteredContacts.count) / \(contacts.count) 个会话"
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func exportSelected() async {
        guard !isBusy else { return }
        let selected = contacts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else {
            presentError("请先在列表中选择联系人或群聊。")
            return
        }
        guard paths.isDecrypted else {
            presentError("请先点击「准备数据」。")
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
            for contact in selected {
                let safeName = contact.displayName.replacingOccurrences(of: "/", with: "_")
                let outDir = base.appendingPathComponent(safeName, isDirectory: true)
                appendLog("导出：\(contact.displayName)")
                let count = try ChatExporter.export(contact: contact, decryptedDir: paths.decryptedDir, outputDir: outDir)
                summary.append("• \(contact.displayName)：\(count) 条")
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
