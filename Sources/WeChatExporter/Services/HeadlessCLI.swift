import Foundation
import SQLite3

/// 无头 CLI（SPEC §7）：本可执行文件支持 `wce <subcmd>` 分支，不启动 GUI。
///   wce --auto-sync                    跑一次定时增量（读 UserDefaults 设置）
///   wce search <kw> [--dir <导出根>]   无头搜索，stdout 打印前 20 条
///   wce index [--dir <导出根>]         重建搜索索引
///   wce report [--dir <导出根>]        重生成年度报告+日历
///   wce --version / wce --help
/// 退出码：0 成功；1 运行失败；2 参数/文件错误。
enum HeadlessCLI {
    static let subCommand = "wce"

    static var shouldRun: Bool {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        return args.first == subCommand
    }

    /// 在 App.init 中调用：同步跑完无头任务后 exit(code)。
    @discardableResult
    static func run() -> Int32 {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        // args.first == "wce"
        let rest = Array(args.dropFirst())
        switch rest.first {
        case "--auto-sync":
            return runAutoSync()
        case "search":
            return runSearch(rest)
        case "index":
            return runIndex(rest)
        case "report":
            return runReport(rest)
        case "--version", "version":
            print("WeChatExporter \(UpdateService.shared.currentVersion) (headless \(subCommand))")
            return 0
        case "--help", "help", "-h":
            printUsage()
            return 0
        case nil:
            printUsage()
            return 2
        default:
            FileHandle.standardError.write(Data("未知子命令：\(rest.first!)\n".utf8))
            printUsage()
            return 2
        }
    }

    static func printUsage() {
        let text = """
        WeChatExporter headless CLI（wce）
          wce --auto-sync                    跑一次定时增量导出（读设置，日志 → ~/Library/Logs/wce-autosync.log）
          wce search <关键词> [--dir <导出根>]  全文搜索（前 20 条，stdout）
          wce index [--dir <导出根>]          重建 wce-search.sqlite 索引
          wce report [--dir <导出根>]         重生成年度报告 + 日历事件
          wce --version / wce --help

        参数说明：
          --dir  指定导出根目录；缺省用最近一次导出目录（设置项 export.lastDir），
                 再缺省 ~/Downloads/微信聊天记录导出
        """
        print(text)
    }

    // MARK: - 目录解析

    private static func expand(_ p: String) -> String {
        p.hasPrefix("~") ? NSString(string: p).expandingTildeInPath : p
    }

    private static func resolveDir(_ rest: [String]) -> URL {
        if let i = rest.firstIndex(of: "--dir"), rest.count > i + 1 {
            return URL(fileURLWithPath: expand(rest[i + 1]))
        }
        let last = ExportModePreferences.lastExportDir
        if !last.isEmpty, FileManager.default.fileExists(atPath: expand(last)) {
            return URL(fileURLWithPath: expand(last))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
    }

    // MARK: - auto-sync

    private static func runAutoSync() -> Int32 {
        let log: (String) -> Void = { line in
            AutoSyncScheduler.appendRunLog(line)
            print(line)
        }

        guard ExportModePreferences.autoSyncEnabled else {
            log("auto-sync skipped: export.autoSync.enabled=false")
            return 0
        }

        let dir = ExportModePreferences.autoSyncExportDir.isEmpty
            ? ExportModePreferences.lastExportDir
            : ExportModePreferences.autoSyncExportDir
        guard !dir.isEmpty else {
            AutoSyncScheduler.appendRunLog("auto-sync failed: 未配置导出目录")
            return 1
        }
        let base = URL(fileURLWithPath: expand(dir), isDirectory: true)

        let wxCli = WxCliService()
        guard let wxCli else {
            AutoSyncScheduler.appendRunLog("auto-sync failed: 找不到 wx-cli（内置/系统均未找到）")
            return 1
        }
        // wx-cli 环境检查（key ✅ 且缓存可用）
        let semaphore = DispatchSemaphore(value: 0)
        var prepared = false
        Task {
            prepared = await wxCli.isPreparedForQuery()
            semaphore.signal()
        }
        semaphore.wait()
        guard prepared else {
            AutoSyncScheduler.appendRunLog("auto-sync skipped: wx-cli 未就绪（密钥/缓存不可用），先运行一次 GUI「准备数据」")
            return 0
        }

        // 会话列表（子集过滤）
        let subset = parseContactIDs(ExportModePreferences.autoSyncContactIDs)
        let semaphore2 = DispatchSemaphore(value: 0)
        var contacts: [ContactItem] = []
        var loadError = ""
        Task {
            do {
                contacts = try await wxCli.loadSessions(log: { _ in }, progress: { _ in })
            } catch {
                loadError = error.localizedDescription
            }
            semaphore2.signal()
        }
        semaphore2.wait()
        guard loadError.isEmpty else {
            AutoSyncScheduler.appendRunLog("auto-sync failed: 会话加载失败（\(loadError)）")
            return 1
        }
        let targets: [ContactItem]
        if subset.isEmpty {
            targets = contacts
        } else {
            targets = contacts.filter { subset.contains($0.id) }
        }

        var totalKept = 0
        var anyChange = false
        let mode: ExportMode = .textOnly
        _ = mode

        for contact in targets {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("WCE-autoSync-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let sem = DispatchSemaphore(value: 0)
            var count = 0
            var exportError = ""
            Task {
                do {
                    count = try await wxCli.export(contact: contact, outputDir: tempDir, includeMedia: false, log: { _ in })
                } catch {
                    exportError = error.localizedDescription
                }
                sem.signal()
            }
            sem.wait()
            guard exportError.isEmpty else {
                AutoSyncScheduler.appendRunLog("auto-sync \(contact.displayName) 导出失败：\(exportError)")
                continue
            }

            // 增量游标（与 GUI 同口径）
            let exportDirPath = base.path
            let lastTs = IncrementalExport.loadCursor(contactID: contact.id, exportDir: exportDirPath)
            if let lastTs {
                count = IncrementalExport.filterArtifacts(in: tempDir, contactID: contact.id, after: lastTs, log: { _ in })
                if count == 0 {
                    AutoSyncScheduler.appendRunLog("no-change \(contact.displayName)（\(contact.id)）")
                    continue
                }
                let maxTs = IncrementalExport.maxTimestamp(in: tempDir)
                if maxTs > lastTs {
                    IncrementalExport.saveCursor(contactID: contact.id, exportDir: exportDirPath, lastTimestamp: maxTs)
                }
            } else {
                IncrementalExport.saveCursor(
                    contactID: contact.id,
                    exportDir: exportDirPath,
                    lastTimestamp: IncrementalExport.maxTimestamp(in: tempDir)
                )
            }

            // 复制文字产物到 base/<会话名>/
            let contactDir = base.appendingPathComponent(contact.displayName, isDirectory: true)
            try? FileManager.default.createDirectory(at: contactDir, withIntermediateDirectories: true)
            copyTextArtifacts(from: tempDir, to: contactDir)
            totalKept += count
            anyChange = true
            AutoSyncScheduler.appendRunLog("changed \(contact.displayName)：\(count) 条新增")
        }

        if !anyChange {
            AutoSyncScheduler.appendRunLog("no-change（无新增，跳过后续产物）")
            ExportModePreferences.autoSyncLastRun = isoNow()
            return 0
        }

        // 后处理管线（顺序 SPEC §3：过滤 → 脱敏 → 索引 → 报告/日历 → 水印）
        if ExportModePreferences.filterEnabled {
            _ = ExportFilterService.apply(
                in: base,
                fromDate: ExportModePreferences.filterFromDate,
                toDate: ExportModePreferences.filterToDate,
                keywords: ExportModePreferences.filterKeywords,
                log: { AutoSyncScheduler.appendRunLog("filter: \($0)") }
            )
        }
        if ExportModePreferences.anonEnabled {
            let names = AnonymizationService.collectNames(in: base)
            _ = AnonymizationService.anonymize(
                in: base,
                names: Array(names),
                settings: .init(maskPii: ExportModePreferences.anonMaskPii, keepMapping: ExportModePreferences.anonKeepMapping),
                log: { AutoSyncScheduler.appendRunLog("anon: \($0)") }
            )
        }
        if ExportModePreferences.indexPageEnabled {
            _ = ExportIndexBuilder.writeIndex(into: base, log: { AutoSyncScheduler.appendRunLog($0) })
        }
        if ExportModePreferences.searchIndexEnabled {
            _ = SearchIndexService.build(in: base, log: { AutoSyncScheduler.appendRunLog($0) })
        }
        if ExportModePreferences.annualReportEnabled {
            _ = AnnualReportService.write(in: base, log: { AutoSyncScheduler.appendRunLog($0) })
        }
        if ExportModePreferences.calendarExtractEnabled {
            _ = CalendarExtractService.extract(in: base, log: { AutoSyncScheduler.appendRunLog($0) })
        }
        if ExportModePreferences.watermarkEnabled {
            Watermark.applyToDirectory(base, log: { _ in })
        }

        ExportModePreferences.autoSyncLastRun = isoNow()
        AutoSyncScheduler.appendRunLog("auto-sync done：\(targets.count) 个会话，共 \(totalKept) 条新增")
        return 0
    }

    private static func parseContactIDs(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    // MARK: - search / index / report

    private static func runSearch(_ rest: [String]) -> Int32 {
        guard rest.count >= 2 else {
            printUsage()
            return 2
        }
        let kw = rest[1]
        let dir = resolveDir(rest)
        let indexURL = dir.appendingPathComponent(SearchIndexService.fileName)
        guard let db = SearchIndexService.open(indexAt: indexURL) else {
            FileHandle.standardError.write(Data("未找到搜索索引 \(indexURL.path)，请先导出并开启「搜索索引」\n".utf8))
            return 2
        }
        defer { sqlite3_close(db) }
        let hits = SearchIndexService.query(db: db, keyword: kw, limit: 20)
        guard !hits.isEmpty else {
            print("（无命中：\(kw)）")
            return 0
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for h in hits {
            let time = h.ts > 0 ? f.string(from: Date(timeIntervalSince1970: TimeInterval(h.ts))) : "-"
            print("[\(time)] \(h.chat) · \(h.sender): \(h.snippet)")
        }
        return 0
    }

    private static func runIndex(_ rest: [String]) -> Int32 {
        let dir = resolveDir(rest)
        let count = SearchIndexService.build(in: dir, log: { print($0) })
        return count >= 0 ? 0 : 1
    }

    private static func runReport(_ rest: [String]) -> Int32 {
        let dir = resolveDir(rest)
        var ok = true
        if AnnualReportService.write(in: dir, log: { print($0) }) == nil { ok = false }
        if CalendarExtractService.extract(in: dir, log: { print($0) }) == 0 { ok = false }
        return ok ? 0 : 1
    }

    // MARK: - 工具

    private static func copyTextArtifacts(from sourceDir: URL, to destDir: URL) {
        let fm = FileManager.default
        let textExts: Set<String> = ["txt", "json", "csv"]
        guard let files = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else { return }
        for file in files where textExts.contains(file.pathExtension.lowercased()) {
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try? fm.copyItem(at: file, to: dest)
        }
    }

    private static func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
