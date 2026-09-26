import Foundation
import Vision
import AppKit

/// 图片消息 OCR（本地离线）：macOS Vision 框架识别图中文字。
/// 结果写入与图片同目录的 `<文件名>.ocr.txt` 侧车文件，HTML 生成时可展示。
enum ImageOCRService {
    /// OCR 侧车文件后缀
    static let sidecarSuffix = ".ocr.txt"

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff", "heif", "dx", "dat"]

    // MARK: - 批量 OCR（幂等：已有侧车的跳过）

    /// 对目录内全部图片做 OCR。返回 (成功数, 跳过数)。
    @discardableResult
    static func ocrAll(in dir: URL, log: @escaping (String) -> Void) async -> (Int, Int) {
        let files = collectImages(in: dir)
        guard !files.isEmpty else {
            log("未发现图片文件，跳过 OCR")
            return (0, 0)
        }
        log("开始图片 OCR \(files.count) 张（本地离线 Vision）…")
        var ok = 0
        var skipped = 0
        for (index, file) in files.enumerated() {
            if ocrText(for: file) != nil {
                skipped += 1
                continue
            }
            let total = files.count
            log("OCR \(index + 1)/\(total)：\(file.lastPathComponent)")
            guard let text = await recognizeText(in: file) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let sidecar = sidecarURL(for: file)
            do {
                try trimmed.write(to: sidecar, atomically: true, encoding: .utf8)
                ok += 1
                log("  → \(sidecar.lastPathComponent)")
            } catch {
                log("  写入失败：\(error.localizedDescription)")
            }
        }
        log("图片 OCR 完成：成功 \(ok) 张、跳过 \(skipped) 张（已有结果）")
        return (ok, skipped)
    }

    // MARK: - 单图识别

    /// Vision 框架识别图中文字（中文优先，含英文），无文字返回 nil
    private static func recognizeText(in url: URL) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let image = NSImage(contentsOf: url),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    cont.resume(returning: nil)
                    return
                }
                let request = VNRecognizeTextRequest { req, _ in
                    guard let results = req.results as? [VNRecognizedTextObservation] else {
                        cont.resume(returning: nil)
                        return
                    }
                    let text = results.compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: text.isEmpty ? nil : text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    // MARK: - 侧车文件

    static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent(imageURL.lastPathComponent + sidecarSuffix)
    }

    static func ocrText(for imageURL: URL) -> String? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 收集

    private static func collectImages(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for root in [dir.appendingPathComponent("media", isDirectory: true), dir] where fm.fileExists(atPath: root.path) {
            guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            var collected: [URL] = []
            for case let url as URL in it {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                let ext = url.pathExtension.lowercased()
                if isFile, Self.imageExtensions.contains(ext), !url.lastPathComponent.hasSuffix(sidecarSuffix) {
                    collected.append(url)
                }
            }
            files.append(contentsOf: collected)
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
