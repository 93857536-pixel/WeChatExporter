import Foundation

/// 定时增量导出（SPEC §2）：macOS 用 launchd 用户级 agent。
/// 安装 = 写 ~/Library/LaunchAgents/com.wce.autosync.plist + launchctl bootstrap；
/// 卸载 = launchctl bootout + 删 plist。
/// 任务执行体 = 本 App 可执行文件的无头模式 `<exe> wce --auto-sync`（读 UserDefaults 设置，
/// 对会话子集做增量导出，日志追加写 ~/Library/Logs/wce-autosync.log）。
enum AutoSyncScheduler {
    static let label = "com.wce.autosync"
    static let plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/wce-autosync.log")

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 安装/更新定时任务。intervalMinutes 为定时间隔；exportDir 为空则用当前导出根目录。
    /// 返回安装成功与否与提示文本。
    @discardableResult
    static func install(intervalMinutes: Int, exportDir: String, contactIDsJSON: String, log: @escaping (String) -> Void) -> Bool {
        let minutes = max(5, intervalMinutes)
        let dir = exportDir.isEmpty
            ? ExportModePreferences.lastExportDir
            : exportDir
        let exe = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? ""
        guard !exe.isEmpty else {
            log("定时任务安装失败：找不到可执行文件路径")
            return false
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "wce", "--auto-sync"],
            "StartInterval": minutes * 60,
            "EnvironmentVariables": [
                "WCE_AUTO_SYNC_DIR": dir,
                "WCE_AUTO_SYNC_CONTACTS": contactIDsJSON,
            ],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "Nice": 10,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            // 若已加载先卸载再装
            _ = run(["launchctl", "bootout", "gui/\(getuid())", label])
            let bootstrap = run(["launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
            if bootstrap.exit != 0 {
                // 旧版系统可能不支持 bootout/bootstrap，回退 load/unload
                _ = run(["launchctl", "unload", plistURL.path])
                let legacy = run(["launchctl", "load", "-w", plistURL.path])
                if legacy.exit != 0 {
                    log("定时任务安装失败：launchctl 拒绝（exit \(bootstrap.exit) / \(legacy.exit)）")
                    return false
                }
            }
            log("定时任务已安装：每 \(minutes) 分钟增量导出 → \(dir)")
            return true
        } catch {
            log("定时任务安装失败：\(error.localizedDescription)")
            return false
        }
    }

    static func uninstall(log: @escaping (String) -> Void) {
        _ = run(["launchctl", "bootout", "gui/\(getuid())", label])
        _ = run(["launchctl", "unload", plistURL.path])
        if isInstalled {
            try? FileManager.default.removeItem(at: plistURL)
            log("定时任务已卸载")
        } else {
            log("定时任务未安装")
        }
    }

    /// 追加一行运行日志（无头模式使用）
    static func appendRunLog(_ line: String) {
        let stamp = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Date())
        }()
        let entry = "[\(stamp)] \(line)\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: logURL)
        }
        if let fh = FileHandle(forWritingAtPath: logURL.path) {
            fh.seekToEndOfFile()
            fh.write(Data(entry.utf8))
            try? fh.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }

    private struct RunResult { let exit: Int32; let output: String }

    private static func run(_ args: [String]) -> RunResult {
        let p = Process()
        p.launchPath = "/bin/sh"
        p.arguments = ["-c", args.joined(separator: " ")]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return RunResult(exit: 1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(exit: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}
