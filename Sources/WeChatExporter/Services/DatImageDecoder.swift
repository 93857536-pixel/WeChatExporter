import CommonCrypto
import Foundation

/// 解密微信 .dat 图片，优先调用 wx-cli，失败时尝试简单 XOR 探测。
enum DatImageDecoder {
    static func decodeDatFiles(in outputDir: URL, log: @escaping (String) -> Void) async -> Int {
        let mediaRoot = outputDir.appendingPathComponent("media", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mediaRoot.path) else { return 0 }

        var datFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if fileURL.pathExtension.lowercased() == "dat" {
                    datFiles.append(fileURL)
                }
            }
        }

        guard !datFiles.isEmpty else { return 0 }

        var decoded = 0
        let accountDir = locateWeChatAccountDir()
        let wxCli = WxCliService.locateExecutable()

        for dat in datFiles {
            let base = dat.deletingPathExtension().lastPathComponent
            let outDir = dat.deletingLastPathComponent()
            if existingDecodedImage(base: base, in: outDir) != nil {
                decoded += 1
                continue
            }

            if let accountDir, let wxCli,
               await decodeWithWxCli(dat: dat, accountDir: accountDir, wxCli: wxCli, log: log) {
                decoded += 1
                continue
            }

            if decodeWithXor(dat: dat) {
                decoded += 1
                log("已解密图片（XOR）：\(dat.lastPathComponent)")
            }
        }

        if decoded > 0 {
            log("已解密 \(decoded) 张 .dat 图片")
        }
        return decoded
    }

    static func tryDecodeInline(_ data: Data) -> Data? {
        for key in 0...255 {
            let sample = xorDecode(data, key: UInt8(key))
            if ImageExporter.sniffImageMIME(sample) != nil {
                return sample
            }
        }
        return nil
    }

    private static func existingDecodedImage(base: String, in dir: URL) -> URL? {
        for ext in ["jpg", "jpeg", "png", "gif", "webp"] {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func decodeWithWxCli(
        dat: URL,
        accountDir: URL,
        wxCli: URL,
        log: @escaping (String) -> Void
    ) async -> Bool {
        let outBase = dat.deletingPathExtension().lastPathComponent
        let outURL = dat.deletingLastPathComponent().appendingPathComponent("\(outBase).jpg")
        let process = Process()
        process.executableURL = wxCli
        process.arguments = ["decode-image", dat.path, "-d", accountDir.path, "-o", outURL.path]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            if FileManager.default.fileExists(atPath: outURL.path),
               (try? Data(contentsOf: outURL))?.isEmpty == false {
                log("已解密图片：\(dat.lastPathComponent)")
                return true
            }
        } catch {
            return false
        }
        return false
    }

    @discardableResult
    private static func decodeWithXor(dat: URL) -> Bool {
        guard let data = try? Data(contentsOf: dat), !data.isEmpty else { return false }
        guard let decoded = tryDecodeInline(data),
              let mime = ImageExporter.sniffImageMIME(decoded) else { return false }
        let ext: String
        switch mime {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        let outURL = dat.deletingLastPathComponent().appendingPathComponent("\(dat.deletingPathExtension().lastPathComponent).\(ext)")
        do {
            try decoded.write(to: outURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func xorDecode(_ data: Data, key: UInt8) -> Data {
        Data(data.map { $0 ^ key })
    }

    static func locateWeChatAccountDir() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true),
            home.appendingPathComponent("Documents/xwechat_files", isDirectory: true),
            home.appendingPathComponent("xwechat_files", isDirectory: true),
        ]

        var candidates: [(URL, Date)] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.hasDirectoryPath && entry.lastPathComponent != "all_users" {
                let msgDir = entry.appendingPathComponent("msg", isDirectory: true)
                if FileManager.default.fileExists(atPath: msgDir.path) {
                    let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    candidates.append((entry, date))
                }
            }
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}
