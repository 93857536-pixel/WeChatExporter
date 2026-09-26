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
}
