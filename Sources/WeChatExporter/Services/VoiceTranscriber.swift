import Foundation

/// 语音消息转文字（本地离线）：SILK → WAV(silk2wav 内置解码) → whisper.cpp 转写。
/// 结果写入与语音同目录的 `<name>.transcript.txt` 侧车文件，HTML/文本导出时可展示。
enum VoiceTranscriber {
    /// 侧车文件后缀（与语音文件名同目录、同名 + 后缀）
    static let sidecarSuffix = ".transcript.txt"

    struct ToolStatus {
        let silk2wav: URL?
        let whisperCli: URL?
        let whisperModel: URL?

        /// 具备转写能力（whisper-cli + 模型；silk 文件还需 silk2wav）
        var ready: Bool { whisperCli != nil && whisperModel != nil }
        var silkReady: Bool { silk2wav != nil }

        var detail: String {
            var parts: [String] = []
            parts.append("silk2wav：\(silk2wav.map { $0.lastPathComponent } ?? "未找到")")
            parts.append("whisper：\(whisperCli.map { $0.lastPathComponent } ?? "未找到")")
            parts.append("模型：\(whisperModel.map { $0.lastPathComponent } ?? "未找到")")
            return parts.joined(separator: " · ")
        }

        var modelDownloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-multi.bin")!
        }
    }

    // MARK: - 工具定位

    static func toolStatus() -> ToolStatus {
        ToolStatus(
            silk2wav: locateSilk2wav(),
            whisperCli: locateWhisperCli(),
            whisperModel: locateWhisperModel()
        )
    }

    private static let audioExtensions: Set<String> = ["silk", "pcm", "wav", "m4a", "mp3", "aac", "amr", "ogg"]

    private static func locateSilk2wav() -> URL? {
        // 1) app 内置 Resources/silk2wav
        if let res = Bundle.main.resourceURL?.appendingPathComponent("silk2wav"),
           FileManager.default.isExecutableFile(atPath: res.path) {
            return res
        }
        // 2) 开发态与用户安装态
        let candidates = [
            URL(fileURLWithPath: "vendor/tools/silk/silk2wav", relativeTo: URL(fileURLWithPath: NSHomeDirectory())),
            URL(fileURLWithPath: "\(NSHomeDirectory())/.local/share/WeChatExporter/silk2wav"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c
        }
        return which("silk2wav")
    }

    private static func locateWhisperCli() -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/share/WeChatExporter"] {
            let p = URL(fileURLWithPath: dir).appendingPathComponent("whisper-cli")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return which("whisper-cli")
    }

    private static func locateWhisperModel() -> URL? {
        let preferred = ["ggml-base-multi.bin", "ggml-small-multi.bin", "ggml-small.bin",
                         "ggml-base.en.bin", "ggml-medium.bin", "ggml-base.bin"]
        let dirs = [
            URL(fileURLWithPath: "\(NSHomeDirectory())/.cache/whisper-cpp"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/.local/share/WeChatExporter/whisper-models"),
        ]
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for name in preferred {
                if files.contains(where: { $0.lastPathComponent == name }) {
                    return dir.appendingPathComponent(name)
                }
            }
        }
        return nil
    }

    private static func which(_ name: String) -> URL? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard task.terminationStatus == 0, !text.isEmpty else { return nil }
            return URL(fileURLWithPath: text)
        } catch {
            return nil
        }
    }

    // MARK: - 批量转写（幂等：已有侧车文件的自动跳过）

    /// 扫描目录内全部语音文件并转写。返回 (成功数, 跳过数)。
    @discardableResult
    static func transcribeAll(in dir: URL, log: @escaping (String) -> Void) async -> (Int, Int) {
        let status = toolStatus()
        guard status.ready, let cli = status.whisperCli, let model = status.whisperModel else {
            log("跳过语音转写：未检测到 whisper.cpp（whisper-cli 或模型缺失）")
            return (0, 0)
        }
        let unique = Self.collectAudioFiles(in: dir)
        guard !unique.isEmpty else {
            log("未发现语音文件，跳过转写")
            return (0, 0)
        }

        log("开始语音转写 \(unique.count) 条（本地离线：\(model.lastPathComponent)）…")
        var ok = 0
        var skipped = 0
        var index = 0
        for file in unique {
            index += 1
            // 幂等：已有转写结果则跳过
            if transcript(for: file) != nil {
                skipped += 1
                continue
            }
            log("转写 \(index)/\(unique.count)：\(file.lastPathComponent)")
            do {
                let text = try await transcribe(file, cli: cli, model: model, silk2wav: status.silk2wav)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    log("  无可识别语音内容：\(file.lastPathComponent)")
                    continue
                }
                try trimmed.write(to: sidecarURL(for: file), atomically: true, encoding: .utf8)
                ok += 1
                log("  → 已生成 \(sidecarURL(for: file).lastPathComponent)")
            } catch {
                log("  转写失败：\(file.lastPathComponent)（\(error.localizedDescription)）")
            }
        }
        log("语音转写完成：成功 \(ok) 条、跳过 \(skipped) 条（已有结果）")
        return (ok, skipped)
    }

    /// 单文件转写：silk 先解码为 24kHz WAV，其余音频直接给 whisper.cpp
    static func transcribe(_ file: URL, cli: URL, model: URL, silk2wav: URL?) async throws -> String {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("wxe-asr-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let source: URL
        if file.pathExtension.lowercased() == "silk" {
            guard let s2w = silk2wav else {
                throw AppError.exportFailed("缺少内置 silk2wav 解码器，无法解码 SILK 语音")
            }
            let wav = workDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".wav")
            _ = try await runTool(s2w, args: [file.path, wav.path])
            guard fm.fileExists(atPath: wav.path) else {
                throw AppError.exportFailed("SILK 解码失败：\(file.lastPathComponent)")
            }
            source = wav
        } else {
            source = file
        }

        let stdout = try await runTool(cli, args: ["-m", model.path, "-l", "auto", "-f", source.path, "-nt"])
        // whisper-cli -nt 的 stdout 为纯文本（进度信息走 stderr），过滤空行
        let lines = stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("read_audio_data") && !$0.hasPrefix("main:") && !$0.hasPrefix("whisper_") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 侧车文件
    /// 递归收集目录内全部语音文件（去重）
    private static func collectAudioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let mediaRoot = dir.appendingPathComponent("media", isDirectory: true)
        let roots = [mediaRoot, dir].filter { fm.fileExists(atPath: $0.path) }
        for root in roots {
            guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            var collected: [URL] = []
            for case let url as URL in it {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                if isFile, Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                    collected.append(url)
                }
            }
            files.append(contentsOf: collected)
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 语音文件对应的转写侧车路径：同目录 `<原文件名>.transcript.txt`
    static func sidecarURL(for audioFile: URL) -> URL {
        audioFile.deletingLastPathComponent()
            .appendingPathComponent(audioFile.lastPathComponent + sidecarSuffix)
    }

    /// 读取侧车内容（不存在或空返回 nil）
    static func transcript(for audioFile: URL) -> String? {
        let url = sidecarURL(for: audioFile)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 模型下载（约 141MB，HuggingFace ggml 官方）

    @discardableResult
    static func downloadModel(progress: @escaping (Double, String) -> Void, log: @escaping (String) -> Void) async -> URL? {
        let status = toolStatus()
        if let model = status.whisperModel {
            log("whisper 模型已存在：\(model.path)")
            return model
        }
        guard let url = status.modelDownloadURL as URL?, let dataTask = await downloadData(from: url, progress: progress) else {
            log("模型下载失败：无法连接 HuggingFace（ggml-base-multi.bin，约 141MB）")
            return nil
        }
        let destDir = URL(fileURLWithPath: "\(NSHomeDirectory())/.cache/whisper-cpp")
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent("ggml-base-multi.bin")
            try dataTask.write(to: dest, options: .atomic)
            log("whisper 模型已下载：\(dest.path)")
            return dest
        } catch {
            log("模型写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func downloadData(from url: URL, progress: @escaping (Double, String) -> Void) async -> Data? {
        await withCheckedContinuation { cont in
            URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let tempURL, error == nil {
                    if let data = try? Data(contentsOf: tempURL) {
                        _ = response
                        progress(1.0, "完成")
                        cont.resume(returning: data)
                        return
                    }
                }
                progress(0, "失败")
                cont.resume(returning: nil)
            }.resume()
        }
    }

    // MARK: - 子进程

    private static func runTool(_ executable: URL, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let task = Process()
            task.executableURL = executable
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            task.standardInput = FileHandle.nullDevice

            do {
                try task.run()
            } catch {
                cont.resume(throwing: AppError.exportFailed("无法启动 \(executable.lastPathComponent)：\(error.localizedDescription)"))
                return
            }

            task.terminationHandler = { finished in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    cont.resume(returning: outText)
                } else {
                    cont.resume(throwing: AppError.exportFailed(
                        "\(finished.executableURL?.lastPathComponent ?? "工具") 退出码 \(finished.terminationStatus)：\((errText + outText).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
                    ))
                }
            }
        }
    }
}
