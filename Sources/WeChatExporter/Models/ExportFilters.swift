import Foundation

/// 消息类型过滤（可多选；全不选视为全部导出）。
enum MessageTypeFilter: String, CaseIterable, Identifiable, Codable {
    case text
    case image
    case voice
    case video
    case emoji
    case app
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "文字"
        case .image: return "图片"
        case .voice: return "语音"
        case .video: return "视频"
        case .emoji: return "表情"
        case .app: return "链接/文件"
        case .system: return "系统"
        }
    }

    /// 微信 msg_type 数值。
    var wechatTypes: Set<Int> {
        switch self {
        case .text: return [1]
        case .image: return [3]
        case .voice: return [34]
        case .video: return [43]
        case .emoji: return [47]
        case .app: return [49]
        case .system: return [10000, 10002]
        }
    }

    /// CLI / 查询用的类型名。
    var cliName: String { rawValue }

    static func matching(msgType: Int?, typeName: String?) -> MessageTypeFilter? {
        if let msgType {
            for filter in allCases where filter.wechatTypes.contains(msgType) {
                return filter
            }
        }
        let name = (typeName ?? "").lowercased()
        if name.contains("text") || name.contains("文本") || name.contains("文字") { return .text }
        if name.contains("image") || name.contains("图片") { return .image }
        if name.contains("voice") || name.contains("语音") || name.contains("audio") { return .voice }
        if name.contains("video") || name.contains("视频") { return .video }
        if name.contains("emoji") || name.contains("表情") || name.contains("sticker") { return .emoji }
        if name.contains("app") || name.contains("链接") || name.contains("文件") || name.contains("link") { return .app }
        if name.contains("system") || name.contains("系统") || name.contains("revoke") { return .system }
        return nil
    }
}

enum DateRangePreset: String, CaseIterable, Identifiable, Codable {
    case all
    case last7Days
    case last30Days
    case last90Days
    case last365Days
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部时间"
        case .last7Days: return "最近 7 天"
        case .last30Days: return "最近 30 天"
        case .last90Days: return "最近 90 天"
        case .last365Days: return "最近 1 年"
        case .custom: return "自定义"
        }
    }

    func resolvedRange(customSince: Date?, customUntil: Date?, now: Date = Date()) -> (since: Int?, until: Int?) {
        let calendar = Calendar.current
        switch self {
        case .all:
            return (nil, nil)
        case .last7Days:
            return (Int(calendar.date(byAdding: .day, value: -7, to: now)!.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .last30Days:
            return (Int(calendar.date(byAdding: .day, value: -30, to: now)!.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .last90Days:
            return (Int(calendar.date(byAdding: .day, value: -90, to: now)!.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .last365Days:
            return (Int(calendar.date(byAdding: .day, value: -365, to: now)!.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        case .custom:
            let since = customSince.map { Int($0.timeIntervalSince1970) }
            let until = customUntil.map { Int($0.timeIntervalSince1970) }
            return (since, until)
        }
    }
}

struct ExportPreviewResult: Equatable {
    var contactCount: Int
    var messageCount: Int
    var mediaCount: Int
    var estimatedBytes: Int64
    var byType: [String: Int]

    var estimatedSizeText: String {
        if estimatedBytes < 1024 { return "\(estimatedBytes) B" }
        if estimatedBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(estimatedBytes) / 1024) }
        if estimatedBytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(estimatedBytes) / (1024 * 1024))
        }
        return String(format: "%.2f GB", Double(estimatedBytes) / (1024 * 1024 * 1024))
    }

    var summaryText: String {
        let typeLine = byType.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        return "会话 \(contactCount) 个 · 消息约 \(messageCount) 条 · 媒体约 \(mediaCount) 个 · 预估 \(estimatedSizeText)"
            + (typeLine.isEmpty ? "" : "\n类型分布：\(typeLine)")
    }
}
