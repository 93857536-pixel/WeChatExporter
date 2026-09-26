import Foundation

/// 导出方式
enum ExportMode: String, CaseIterable, Identifiable {
    /// 按分类把图片、视频、文字放在文件夹里
    case categorized = "categorized"
    /// 只导出文字
    case textOnly = "textOnly"
    /// 全部导出（文字 + 媒体内嵌到 HTML）
    case all = "all"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .categorized: return "分类导出"
        case .textOnly: return "只导出文字"
        case .all: return "全部导出"
        }
    }

    var description: String {
        switch self {
        case .categorized: return "文字、图片、视频分别归档到独立文件夹"
        case .textOnly: return "仅导出聊天文字（txt / json / csv / HTML）"
        case .all: return "导出全部文字与媒体文件（不生成内嵌 HTML）"
        }
    }

    var icon: String {
        switch self {
        case .categorized: return "folder.fill"
        case .textOnly: return "doc.text.fill"
        case .all: return "photo.on.rectangle.fill"
        }
    }

    /// 是否包含媒体内容
    var includesMedia: Bool { self != .textOnly }
}

/// 导出方式偏好（持久化到 UserDefaults）
enum ExportModePreferences {
    private enum Keys {
        static let mode = "export.mode"
        static let voiceTranscription = "export.voiceTranscription"
        static let imageOCR = "export.imageOCR"
        static let statsReport = "export.statsReport"
        static let incremental = "export.incremental"
        static let indexPage = "export.indexPage"
        static let customWxCliPath = "export.customWxCliPath"
        static let ebookEpub = "export.ebookEpub"
        static let ebookDocument = "export.ebookDocument"
        static let watermarkEnabled = "export.watermarkEnabled"
        static let watermarkText = "export.watermarkText"
        static let searchIndex = "export.searchIndex"
        static let autoSyncEnabled = "export.autoSync.enabled"
        static let autoSyncInterval = "export.autoSync.intervalMinutes"
        static let autoSyncExportDir = "export.autoSync.exportDir"
        static let autoSyncContacts = "export.autoSync.contactIDs"
        static let autoSyncLastRun = "export.autoSync.lastRun"
        static let anonEnabled = "export.anon.enabled"
        static let anonMaskPii = "export.anon.maskPii"
        static let anonKeepMapping = "export.anon.keepMapping"
        static let filterEnabled = "export.filter.enabled"
        static let filterFrom = "export.filter.fromDate"
        static let filterTo = "export.filter.toDate"
        static let filterKeywords = "export.filter.keywords"
        static let annualReport = "export.annualReport"
        static let calendarExtract = "export.calendarExtract"
        static let lastExportDir = "export.lastDir"
    }

    static var mode: ExportMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.mode) ?? ExportMode.categorized.rawValue
            return ExportMode(rawValue: raw) ?? .categorized
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.mode)
        }
    }

    /// 导出媒体时是否顺带做本地语音转文字（whisper.cpp，默认开启；缺少工具时自动跳过）
    static var voiceTranscriptionEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.voiceTranscription) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.voiceTranscription)
        }
    }

    /// 导出媒体时是否顺带做图片 OCR（Vision 框架，默认开启）
    static var imageOCREnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.imageOCR) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.imageOCR)
        }
    }

    /// 导出时是否顺带生成统计报告（消息量/时段/排行，默认开启）
    static var statsReportEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.statsReport) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.statsReport)
        }
    }

    /// 导出是否只保留新增消息（增量导出，默认关闭）
    static var incrementalExportEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.incremental) as? Bool
            return v ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.incremental)
        }
    }

    /// 自定义 wx-cli 路径（设置面板填写，默认空=自动搜索内置/用户目录/Homebrew）。
    /// 用户可用自己构建的 wx-cli（含上游新版或自有 fork）覆盖默认行为。
    static var customWxCliPath: String {
        get {
            UserDefaults.standard.string(forKey: Keys.customWxCliPath) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.customWxCliPath)
        }
    }

    /// 导出后是否生成目录导航页 index.html（含全文检索框，默认开启）
    static var indexPageEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.indexPage) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.indexPage)
        }
    }

    /// 导出时是否顺带生成 EPUB 电子书（默认开启）
    static var ebookEpubEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.ebookEpub) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.ebookEpub)
        }
    }

    /// 导出时是否顺带生成文档版 PDF / XPS（macOS 生成 PDF，Windows 生成 XPS，默认开启）
    static var ebookDocumentEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.ebookDocument) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.ebookDocument)
        }
    }

    /// 导出产物是否平铺视觉水印（默认开启；关闭即无水印版本）
    static var watermarkEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.watermarkEnabled) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.watermarkEnabled)
        }
    }

    /// 水印文字（设置面板可改，默认「林琝淏科技集团有限公司」）
    static var watermarkText: String {
        get {
            UserDefaults.standard.string(forKey: Keys.watermarkText) ?? "林琝淏科技集团有限公司"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.watermarkText)
        }
    }

    // MARK: - v2.19 新功能设置（见 docs/MULTIPLATFORM_SPEC.md）

    /// 导出时在根目录生成 wce-search.sqlite 全文搜索索引（默认开启）
    static var searchIndexEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.searchIndex) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.searchIndex)
        }
    }

    /// 定时增量导出总开关（默认关闭）
    static var autoSyncEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.autoSyncEnabled) as? Bool
            return v ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoSyncEnabled)
        }
    }

    /// 定时间隔分钟数（默认 60，最小 5）
    static var autoSyncIntervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.autoSyncInterval)
            return v == 0 ? 60 : v
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoSyncInterval)
        }
    }

    /// 定时任务目标目录（默认=导出根目录）
    static var autoSyncExportDir: String {
        get {
            UserDefaults.standard.string(forKey: Keys.autoSyncExportDir) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoSyncExportDir)
        }
    }

    /// 定时任务会话子集（JSON 数组字符串；空=全部）
    static var autoSyncContactIDs: String {
        get {
            UserDefaults.standard.string(forKey: Keys.autoSyncContacts) ?? "[]"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoSyncContacts)
        }
    }

    /// 上次定时运行时间（ISO 本地格式）
    static var autoSyncLastRun: String {
        get {
            UserDefaults.standard.string(forKey: Keys.autoSyncLastRun) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoSyncLastRun)
        }
    }

    /// 脱敏导出总开关（默认关闭）
    static var anonEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.anonEnabled) as? Bool
            return v ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.anonEnabled)
        }
    }

    /// 脱敏时是否同时模糊化 PII（手机号/身份证/邮箱，默认开启）
    static var anonMaskPii: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.anonMaskPii) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.anonMaskPii)
        }
    }

    /// 脱敏后是否保留映射文件（可逆；关闭=导出后销毁）
    static var anonKeepMapping: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.anonKeepMapping) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.anonKeepMapping)
        }
    }

    /// 过滤导出总开关（默认关闭）
    static var filterEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.filterEnabled) as? Bool
            return v ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.filterEnabled)
        }
    }

    /// 过滤起始日期 yyyy-MM-dd（含；空=不限）
    static var filterFromDate: String {
        get {
            UserDefaults.standard.string(forKey: Keys.filterFrom) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.filterFrom)
        }
    }

    /// 过滤结束日期 yyyy-MM-dd（含；空=不限）
    static var filterToDate: String {
        get {
            UserDefaults.standard.string(forKey: Keys.filterTo) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.filterTo)
        }
    }

    /// 过滤关键词（逗号分隔，不区分大小写；空=不过滤内容）
    static var filterKeywords: String {
        get {
            UserDefaults.standard.string(forKey: Keys.filterKeywords) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.filterKeywords)
        }
    }

    /// 生成年度可视化报告 HTML（默认开启）
    static var annualReportEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.annualReport) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.annualReport)
        }
    }

    /// 提取日历事件 .ics/.json（默认开启）
    static var calendarExtractEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.calendarExtract) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.calendarExtract)
        }
    }

    /// 最近一次导出目录（搜索面板用它定位 wce-search.sqlite）
    static var lastExportDir: String {
        get {
            UserDefaults.standard.string(forKey: Keys.lastExportDir) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.lastExportDir)
        }
    }
}
