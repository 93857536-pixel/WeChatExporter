import Foundation

enum ContactKind: String, CaseIterable {
    case friend = "好友"
    case group = "群聊"
    case official = "公众号"

    var icon: String {
        switch self {
        case .friend: return "person.circle.fill"
        case .group: return "person.3.fill"
        case .official: return "megaphone.fill"
        }
    }
}

struct ContactItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let nickName: String
    let remark: String
    let kind: ContactKind
    let lastTime: String
    let lastTimestamp: Int
    let summary: String

    var subtitle: String {
        if summary.isEmpty { return lastTime }
        return "\(lastTime) · \(summary)"
    }
}

struct ExportResult: Identifiable {
    let id = UUID()
    let contact: ContactItem
    let messageCount: Int
    let outputURL: URL
}
