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

    @Published var dateRangePreset: DateRangePreset {
        didSet { defaults.set(dateRangePreset.rawValue, forKey: Keys.dateRangePreset) }
    }

    @Published var customSince: Date {
        didSet { defaults.set(customSince.timeIntervalSince1970, forKey: Keys.customSince) }
    }

    @Published var customUntil: Date {
        didSet { defaults.set(customUntil.timeIntervalSince1970, forKey: Keys.customUntil) }
    }

    /// 启用的消息类型；空或全选 = 全部。
    @Published var enabledMessageTypes: Set<MessageTypeFilter> {
        didSet {
            defaults.set(enabledMessageTypes.map(\.rawValue).sorted(), forKey: Keys.enabledMessageTypes)
        }
    }

    @Published var incrementalExport: Bool {
        didSet { defaults.set(incrementalExport, forKey: Keys.incrementalExport) }
    }

    @Published var mapGroupNicknames: Bool {
        didSet { defaults.set(mapGroupNicknames, forKey: Keys.mapGroupNicknames) }
    }

    @Published var enableSpeechToText: Bool {
        didSet { defaults.set(enableSpeechToText, forKey: Keys.enableSpeechToText) }
    }

    @Published var favoriteIDs: Set<String> {
        didSet {
            defaults.set(Array(favoriteIDs).sorted(), forKey: Keys.favoriteIDs)
        }
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
        static let dateRangePreset = "settings.dateRangePreset"
        static let customSince = "settings.customSince"
        static let customUntil = "settings.customUntil"
        static let enabledMessageTypes = "settings.enabledMessageTypes"
        static let incrementalExport = "settings.incrementalExport"
        static let mapGroupNicknames = "settings.mapGroupNicknames"
        static let enableSpeechToText = "settings.enableSpeechToText"
        static let favoriteIDs = "settings.favoriteIDs"
    }

    var resolvedDateRange: (since: Int?, until: Int?) {
        dateRangePreset.resolvedRange(customSince: customSince, customUntil: customUntil)
    }

    var filterOptions: ChatJsonProcessor.FilterOptions {
        ChatJsonProcessor.FilterOptions(
            sinceUnix: resolvedDateRange.since,
            untilUnix: resolvedDateRange.until,
            enabledTypes: enabledMessageTypes
        )
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    func toggleFavorite(_ id: String) {
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) }
        else { favoriteIDs.insert(id) }
    }

    func isTypeEnabled(_ type: MessageTypeFilter) -> Bool {
        enabledMessageTypes.isEmpty || enabledMessageTypes.contains(type)
    }

    func toggleType(_ type: MessageTypeFilter) {
        if enabledMessageTypes.isEmpty {
            enabledMessageTypes = Set(MessageTypeFilter.allCases)
        }
        if enabledMessageTypes.contains(type) {
            enabledMessageTypes.remove(type)
        } else {
            enabledMessageTypes.insert(type)
        }
        if enabledMessageTypes.count == MessageTypeFilter.allCases.count {
            // keep as full set for clarity
        }
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

        if let raw = defaults.string(forKey: Keys.dateRangePreset),
           let preset = DateRangePreset(rawValue: raw) {
            dateRangePreset = preset
        } else {
            dateRangePreset = .all
        }

        if defaults.object(forKey: Keys.customSince) != nil {
            customSince = Date(timeIntervalSince1970: defaults.double(forKey: Keys.customSince))
        } else {
            customSince = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        }
        if defaults.object(forKey: Keys.customUntil) != nil {
            customUntil = Date(timeIntervalSince1970: defaults.double(forKey: Keys.customUntil))
        } else {
            customUntil = Date()
        }

        if let raw = defaults.array(forKey: Keys.enabledMessageTypes) as? [String] {
            let set = Set(raw.compactMap(MessageTypeFilter.init(rawValue:)))
            enabledMessageTypes = set.isEmpty ? Set(MessageTypeFilter.allCases) : set
        } else {
            enabledMessageTypes = Set(MessageTypeFilter.allCases)
        }

        incrementalExport = defaults.object(forKey: Keys.incrementalExport) as? Bool ?? false
        mapGroupNicknames = defaults.object(forKey: Keys.mapGroupNicknames) as? Bool ?? true
        enableSpeechToText = defaults.object(forKey: Keys.enableSpeechToText) as? Bool ?? false
        if let ids = defaults.array(forKey: Keys.favoriteIDs) as? [String] {
            favoriteIDs = Set(ids)
        } else {
            favoriteIDs = []
        }
    }
}
