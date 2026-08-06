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
}
