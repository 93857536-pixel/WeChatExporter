import Foundation
#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
#endif

/// 将微信 WXGF 图片提取为 HEVC 首帧，并转成浏览器可显示的 JPEG。
enum WXGFTranscoder {
    static func transcodeIfNeeded(at fileURL: URL, log: ((String) -> Void)? = nil) -> URL? {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "wxgf", FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let base = fileURL.deletingPathExtension()
        if let existing = existingOutput(forBaseURL: base) {
            return existing
        }

        guard let data = try? Data(contentsOf: fileURL),
              let hevc = extractHEVCStream(from: data) else {
            return nil
        }

        if let output = transcodeWithFFmpeg(hevcData: hevc, outputBaseURL: base, log: log) {
            return output
        }

        #if os(macOS)
        if let output = transcodeWithAVFoundation(hevcData: hevc, outputBaseURL: base, log: log) {
            return output
        }
        #endif

        return nil
    }

    static func extractHEVCStream(from data: Data) -> Data? {
        let signatures: [[UInt8]] = [
            [0x00, 0x00, 0x00, 0x01, 0x40, 0x01], // VPS
            [0x00, 0x00, 0x00, 0x01, 0x42, 0x01], // SPS fallback
        ]

        for signature in signatures {
            if let range = data.range(of: Data(signature)) {
                return data.subdata(in: range.lowerBound..<data.count)
            }
        }
        return nil
    }

    private static func existingOutput(forBaseURL base: URL) -> URL? {
        for ext in ["jpg", "jpeg", "png", "gif", "webp"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func transcodeWithFFmpeg(
        hevcData: Data,
        outputBaseURL: URL,
        log: ((String) -> Void)?
    ) -> URL? {
        guard let ffmpeg = locateFFmpeg() else { return nil }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxgf-\(UUID().uuidString)", isDirectory: true)
        let inputURL = tempDir.appendingPathComponent("frame.h265")
        let outputURL = outputBaseURL.appendingPathExtension("jpg")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try hevcData.write(to: inputURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", inputURL.path,
                "-frames:v", "1",
                outputURL.path,
            ]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                return nil
            }
            log?("已转码 WXGF 图片：\(outputURL.lastPathComponent)")
            return outputURL
        } catch {
            return nil
        }
    }

    #if os(macOS)
    private static func transcodeWithAVFoundation(
        hevcData: Data,
        outputBaseURL: URL,
        log: ((String) -> Void)?
    ) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxgf-\(UUID().uuidString).h265")
        let outputURL = outputBaseURL.appendingPathExtension("jpg")

        do {
            try hevcData.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let asset = AVURLAsset(url: tempURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2048, height: 2048)
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
                return nil
            }
            try jpeg.write(to: outputURL, options: .atomic)
            log?("已转码 WXGF 图片：\(outputURL.lastPathComponent)")
            return outputURL
        } catch {
            return nil
        }
    }
    #endif

    private static func locateFFmpeg() -> URL? {
        let fm = FileManager.default
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let candidates = envPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") } + [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/bin/ffmpeg"),
        ]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    }
}
