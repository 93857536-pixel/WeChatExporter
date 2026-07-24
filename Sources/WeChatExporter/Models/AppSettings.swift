import Foundation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 应用设置（持久化到 UserDefaults）。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let creditLine = "@林琝淏科技集团有限公司出品"

    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var exportStyle: ExportStyle {
        didSet { defaults.set(exportStyle.rawValue, forKey: Keys.exportStyle) }
    }

    @Published var includeMedia: Bool {
        didSet { defaults.set(includeMedia, forKey: Keys.includeMedia) }
    }

    @Published var includeStickerGallery: Bool {
        didSet { defaults.set(includeStickerGallery, forKey: Keys.includeStickerGallery) }
    }

    @Published var folderIncludeCSV: Bool {
        didSet { defaults.set(folderIncludeCSV, forKey: Keys.folderIncludeCSV) }
    }

    @Published var folderIncludeJSON: Bool {
        didSet { defaults.set(folderIncludeJSON, forKey: Keys.folderIncludeJSON) }
    }

    @Published var openFolderAfterExport: Bool {
        didSet { defaults.set(openFolderAfterExport, forKey: Keys.openFolderAfterExport) }
    }

    @Published var exportPath: String {
        didSet { defaults.set(exportPath, forKey: Keys.exportPath) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "settings.appearance"
        static let exportStyle = "settings.exportStyle"
        static let includeMedia = "settings.includeMedia"
        static let includeStickerGallery = "settings.includeStickerGallery"
        static let folderIncludeCSV = "settings.folderIncludeCSV"
        static let folderIncludeJSON = "settings.folderIncludeJSON"
        static let openFolderAfterExport = "settings.openFolderAfterExport"
        static let exportPath = "settings.exportPath"
    }

    private init() {
        let defaultExport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/微信聊天记录导出", isDirectory: true)
            .path

        if let raw = defaults.string(forKey: Keys.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            appearance = mode
        } else {
            appearance = .system
        }

        if let raw = defaults.string(forKey: Keys.exportStyle),
           let style = ExportStyle(rawValue: raw) {
            exportStyle = style
        } else {
            exportStyle = .singleHTML
        }

        includeMedia = defaults.object(forKey: Keys.includeMedia) as? Bool ?? false
        includeStickerGallery = defaults.object(forKey: Keys.includeStickerGallery) as? Bool ?? true
        folderIncludeCSV = defaults.object(forKey: Keys.folderIncludeCSV) as? Bool ?? true
        folderIncludeJSON = defaults.object(forKey: Keys.folderIncludeJSON) as? Bool ?? false
        openFolderAfterExport = defaults.object(forKey: Keys.openFolderAfterExport) as? Bool ?? false
        exportPath = defaults.string(forKey: Keys.exportPath) ?? defaultExport
    }
}
