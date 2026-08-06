import Foundation

/// 将导出目录中的文件按类型归档到 文字 / 图片 / 视频 / 其他 文件夹。
enum MediaOrganizer {

    struct Result {
        let textCount: Int
        let imageCount: Int
        let videoCount: Int
        let otherCount: Int
    }

    /// 文字类扩展名
    private static let textExts: Set<String> = ["txt", "json", "csv", "md"]
    /// 图片类扩展名
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"]
    /// 视频类扩展名
    private static let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "3gp", "flv", "wmv", "m4v"]

    /// 把 sourceDir 下的文件按类型移动到 destDir/<contactName>/ 下的分类文件夹。
    /// 返回各分类文件数。
    static func organize(
        sourceDir: URL,
        into destDir: URL,
        contactName: String,
        log: @escaping (String) -> Void
    ) throws -> Result {
        let fm = FileManager.default
        let safeName = sanitizeFilename(contactName.isEmpty ? "聊天记录" : contactName)
        let contactDir = destDir.appendingPathComponent(safeName, isDirectory: true)
        let textDir = contactDir.appendingPathComponent("文字", isDirectory: true)
        let imageDir = contactDir.appendingPathComponent("图片", isDirectory: true)
        let videoDir = contactDir.appendingPathComponent("视频", isDirectory: true)
        let otherDir = contactDir.appendingPathComponent("其他", isDirectory: true)

        for dir in [textDir, imageDir, videoDir, otherDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var textCount = 0
        var imageCount = 0
        var videoCount = 0
        var otherCount = 0

        // 递归收集所有文件
        let files = collectFiles(in: sourceDir)
        for file in files {
            let ext = file.pathExtension.lowercased()
            let dest: URL
            if textExts.contains(ext) {
                dest = textDir.appendingPathComponent(file.lastPathComponent)
                textCount += 1
            } else if imageExts.contains(ext) {
                dest = imageDir.appendingPathComponent(file.lastPathComponent)
                imageCount += 1
            } else if videoExts.contains(ext) {
                dest = videoDir.appendingPathComponent(file.lastPathComponent)
                videoCount += 1
            } else {
                dest = otherDir.appendingPathComponent(file.lastPathComponent)
                otherCount += 1
            }

            // 目标已存在同名文件时加序号
            let uniqueDest = uniqueDestination(for: dest)
            do {
                try fm.moveItem(at: file, to: uniqueDest)
            } catch {
                log("归档失败：\(file.lastPathComponent)（\(error.localizedDescription)）")
            }
        }

        // 清理空目录
        removeEmptyDirs(in: sourceDir)
        removeIfEmpty(otherDir)

        let result = Result(
            textCount: textCount,
            imageCount: imageCount,
            videoCount: videoCount,
            otherCount: otherCount
        )
        log("归档完成：文字 \(textCount) 个、图片 \(imageCount) 个、视频 \(videoCount) 个、其他 \(otherCount) 个 → \(contactDir.path)")
        return result
    }

    // MARK: - Helpers

    private static func collectFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { files.append(url) }
        }
        return files
    }

    private static func removeEmptyDirs(in dir: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 自底向上删除空目录
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                dirs.append(url)
            }
        }
        for d in dirs.reversed() {
            if let contents = try? fm.contentsOfDirectory(atPath: d.path), contents.isEmpty {
                try? fm.removeItem(at: d)
            }
        }
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        let parent = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? parent.appendingPathComponent("\(stem)_\(n)")
                : parent.appendingPathComponent("\(stem)_\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}
