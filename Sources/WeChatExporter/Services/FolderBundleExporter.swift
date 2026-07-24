import Foundation

/// 将临时导出结果整理为「文字 + 图片/音频/视频分目录」的会话文件夹。
enum FolderBundleExporter {
    struct Result {
        let folderURL: URL
        let messageCount: Int
        let imageCount: Int
        let audioCount: Int
        let videoCount: Int
        let emojiCount: Int
    }

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "tif", "tiff"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "silk", "amr", "mpga"]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    static func write(
        from sourceDir: URL,
        contactName: String,
        into destinationDir: URL,
        log: @escaping (String) -> Void
    ) throws -> Result {
        let fm = FileManager.default
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        let txtURL = sourceDir.appendingPathComponent("chat.txt")
        guard fm.fileExists(atPath: jsonURL.path) || fm.fileExists(atPath: txtURL.path) else {
            throw AppError.exportFailed("未找到聊天记录文件，无法生成分类文件夹")
        }

        let messageCount = countMessages(in: sourceDir)
        guard messageCount > 0 || fm.fileExists(atPath: txtURL.path) else {
            throw AppError.exportFailed("聊天记录为空，无法生成分类文件夹")
        }

        let safeName = sanitizeFilename(contactName.isEmpty ? "聊天记录" : contactName)
        let stamp = fileStamp()
        let folder = destinationDir.appendingPathComponent("\(safeName)_\(stamp)", isDirectory: true)
        let imagesDir = folder.appendingPathComponent("图片", isDirectory: true)
        let audioDir = folder.appendingPathComponent("音频", isDirectory: true)
        let videoDir = folder.appendingPathComponent("视频", isDirectory: true)
        let emojiDir = folder.appendingPathComponent("表情", isDirectory: true)

        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: videoDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: emojiDir, withIntermediateDirectories: true)

        // 文字文档
        let textDest = folder.appendingPathComponent("文字记录.txt")
        if fm.fileExists(atPath: txtURL.path) {
            try? fm.removeItem(at: textDest)
            try fm.copyItem(at: txtURL, to: textDest)
        } else {
            let fallback = try buildTextFromJSON(at: jsonURL, contactName: contactName)
            try fallback.write(to: textDest, atomically: true, encoding: .utf8)
        }

        let csvURL = sourceDir.appendingPathComponent("chat.csv")
        if fm.fileExists(atPath: csvURL.path) {
            let csvDest = folder.appendingPathComponent("聊天记录.csv")
            try? fm.removeItem(at: csvDest)
            try fm.copyItem(at: csvURL, to: csvDest)
        }

        var imageCount = 0
        var audioCount = 0
        var videoCount = 0
        var emojiCount = 0
        var usedNames: [String: Set<String>] = [
            "图片": [], "音频": [], "视频": [], "表情": [],
        ]

        let mediaRoot = sourceDir.appendingPathComponent("media", isDirectory: true)
        let enumerator = fm.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        if let enumerator {
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = fileURL.path.replacingOccurrences(of: mediaRoot.path + "/", with: "")
                let lowerRel = rel.lowercased()
                let isEmoji = lowerRel.contains("/emojis/") || lowerRel.hasPrefix("emojis/")

                // WXGF 先尝试转码
                var source = fileURL
                var ext = fileURL.pathExtension.lowercased()
                if ext == "wxgf", let transcoded = WXGFTranscoder.transcodeIfNeeded(at: fileURL, log: log) {
                    source = transcoded
                    ext = transcoded.pathExtension.lowercased()
                }

                if isEmoji || (imageExts.contains(ext) && isEmoji) {
                    let dest = uniqueDest(in: emojiDir, preferredName: source.lastPathComponent, used: &usedNames["表情"]!)
                    if copyFile(source, to: dest) {
                        emojiCount += 1
                    }
                    continue
                }

                if imageExts.contains(ext) || ext == "wxgf" {
                    let dest = uniqueDest(in: imagesDir, preferredName: source.lastPathComponent, used: &usedNames["图片"]!)
                    if copyFile(source, to: dest) {
                        imageCount += 1
                    }
                    continue
                }

                if audioExts.contains(ext) {
                    if let mp3 = convertAudioToMP3(source, into: audioDir, used: &usedNames["音频"]!, log: log) {
                        audioCount += 1
                        _ = mp3
                    } else {
                        let dest = uniqueDest(in: audioDir, preferredName: source.lastPathComponent, used: &usedNames["音频"]!)
                        if copyFile(source, to: dest) {
                            audioCount += 1
                            if ext == "silk" {
                                log("语音保留为 SILK：\(dest.lastPathComponent)（未检测到可转码的 ffmpeg）")
                            }
                        }
                    }
                    continue
                }

                if videoExts.contains(ext) {
                    if let mp4 = ensureMP4(source, into: videoDir, used: &usedNames["视频"]!, log: log) {
                        videoCount += 1
                        _ = mp4
                    } else {
                        let dest = uniqueDest(in: videoDir, preferredName: source.lastPathComponent, used: &usedNames["视频"]!)
                        if copyFile(source, to: dest) {
                            videoCount += 1
                        }
                    }
                }
            }
        }

        let readme = """
        微信聊天记录分类导出
        ==================
        联系人：\(contactName)
        导出时间：\(stamp)
        消息条数：\(max(messageCount, 0))

        目录说明：
        - 文字记录.txt ：全部文字消息
        - 聊天记录.csv ：表格格式（若已生成）
        - 图片/         ：聊天图片
        - 音频/         ：语音（优先 mp3）
        - 视频/         ：视频（优先 mp4）
        - 表情/         ：表情/贴纸

        统计：图片 \(imageCount) · 音频 \(audioCount) · 视频 \(videoCount) · 表情 \(emojiCount)
        """
        try readme.write(to: folder.appendingPathComponent("导出说明.txt"), atomically: true, encoding: .utf8)

        log("分类文件夹已生成：\(folder.lastPathComponent)（图\(imageCount)/音\(audioCount)/视\(videoCount)/表情\(emojiCount)）")
        return Result(
            folderURL: folder,
            messageCount: max(messageCount, 0),
            imageCount: imageCount,
            audioCount: audioCount,
            videoCount: videoCount,
            emojiCount: emojiCount
        )
    }

    // MARK: - helpers

    private static func countMessages(in sourceDir: URL) -> Int {
        let json = sourceDir.appendingPathComponent("chat.json")
        if let data = try? Data(contentsOf: json),
           let root = try? JSONSerialization.jsonObject(with: data) {
            if let array = root as? [Any] { return array.count }
            if let dict = root as? [String: Any] {
                if let items = dict["items"] as? [Any] { return items.count }
                if let messages = dict["messages"] as? [Any] { return messages.count }
                if let results = dict["results"] as? [Any] { return results.count }
                if let conversation = dict["conversation"] as? [String: Any],
                   let count = conversation["message_count"] as? Int {
                    return count
                }
            }
        }
        let txt = sourceDir.appendingPathComponent("chat.txt")
        if let text = try? String(contentsOf: txt, encoding: .utf8) {
            return text.components(separatedBy: .newlines).filter { $0.hasPrefix("[") }.count
        }
        return 0
    }

    private static func buildTextFromJSON(at jsonURL: URL, contactName: String) throws -> String {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw AppError.exportFailed("无法读取 chat.json")
        }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let dict = root as? [String: Any] {
            rows = (dict["items"] as? [[String: Any]])
                ?? (dict["messages"] as? [[String: Any]])
                ?? (dict["results"] as? [[String: Any]])
                ?? []
        } else {
            rows = []
        }
        var text = "微信聊天记录: \(contactName)\n总消息数: \(rows.count)\n"
        text += String(repeating: "=", count: 60) + "\n\n"
        for row in rows {
            let nested = row["message"] as? [String: Any]
            let source = nested ?? row
            let sender = (row["sender_display_name"] as? String)
                ?? (row["sender"] as? String)
                ?? (source["sender_display_name"] as? String)
                ?? (source["sender"] as? String)
                ?? "未知"
            let content = (row["snippet"] as? String)
                ?? (row["content"] as? String)
                ?? (row["text"] as? String)
                ?? (source["content"] as? String)
                ?? ""
            let time = (row["time"] as? String) ?? ""
            text += "[\(time)] \(sender): \(content)\n"
        }
        return text
    }

    private static func copyFile(_ source: URL, to dest: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            return true
        } catch {
            return false
        }
    }

    private static func uniqueDest(in dir: URL, preferredName: String, used: inout Set<String>) -> URL {
        var name = sanitizeFilename(preferredName)
        if name.isEmpty { name = "file" }
        var candidate = name
        var index = 1
        while used.contains(candidate.lowercased()) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            index += 1
        }
        used.insert(candidate.lowercased())
        return dir.appendingPathComponent(candidate)
    }

    private static func convertAudioToMP3(
        _ source: URL,
        into dir: URL,
        used: inout Set<String>,
        log: (String) -> Void
    ) -> URL? {
        let ext = source.pathExtension.lowercased()
        if ext == "mp3" {
            let dest = uniqueDest(in: dir, preferredName: source.lastPathComponent, used: &used)
            return copyFile(source, to: dest) ? dest : nil
        }
        guard let ffmpeg = locateFFmpeg() else { return nil }
        let base = (source.deletingPathExtension().lastPathComponent)
        let dest = uniqueDest(in: dir, preferredName: "\(base).mp3", used: &used)
        if runFFmpeg(ffmpeg, args: ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path, dest.path]) {
            log("已转码音频为 MP3：\(dest.lastPathComponent)")
            return dest
        }
        return nil
    }

    private static func ensureMP4(
        _ source: URL,
        into dir: URL,
        used: inout Set<String>,
        log: (String) -> Void
    ) -> URL? {
        let ext = source.pathExtension.lowercased()
        if ext == "mp4" {
            let dest = uniqueDest(in: dir, preferredName: source.lastPathComponent, used: &used)
            return copyFile(source, to: dest) ? dest : nil
        }
        guard let ffmpeg = locateFFmpeg() else { return nil }
        let base = source.deletingPathExtension().lastPathComponent
        let dest = uniqueDest(in: dir, preferredName: "\(base).mp4", used: &used)
        if runFFmpeg(ffmpeg, args: [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-c", "copy",
            dest.path,
        ]) || runFFmpeg(ffmpeg, args: [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            dest.path,
        ]) {
            log("已转换为 MP4：\(dest.lastPathComponent)")
            return dest
        }
        return nil
    }

    private static func runFFmpeg(_ ffmpeg: URL, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func locateFFmpeg() -> URL? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = envPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") } + [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/bin/ffmpeg"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "聊天记录" : cleaned
    }
}
