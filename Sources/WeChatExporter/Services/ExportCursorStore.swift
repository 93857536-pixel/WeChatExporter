import Foundation

/// 每个会话上次成功导出的最后消息时间（Unix 秒），用于增量续导。
enum ExportCursorStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WeChatExporter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("export_cursors.json")
    }

    private static func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return dict
    }

    private static func save(_ dict: [String: Int]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func lastExportedTime(for talker: String) -> Int? {
        let key = talker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return load()[key]
    }

    static func remember(talker: String, lastCreateTime: Int) {
        guard lastCreateTime > 0 else { return }
        let key = talker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var dict = load()
        dict[key] = max(dict[key] ?? 0, lastCreateTime)
        save(dict)
    }

    static func clear(talker: String? = nil) {
        if let talker {
            var dict = load()
            dict.removeValue(forKey: talker)
            save(dict)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
