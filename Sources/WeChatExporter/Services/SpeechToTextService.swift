import Foundation
#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// 可选语音转文字：优先本机 Speech 框架；不可用时跳过。
enum SpeechToTextService {
    static func transcribeVoiceFiles(
        in sourceDir: URL,
        enabled: Bool,
        log: @escaping (String) -> Void
    ) async -> [String: String] {
        guard enabled else { return [:] }
        let mediaRoot = sourceDir.appendingPathComponent("media", isDirectory: true)
        let searchRoots = [mediaRoot, sourceDir]
        var audioFiles: [URL] = []
        let exts: Set<String> = ["mp3", "m4a", "wav", "caf", "aac"]
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator {
                if exts.contains(file.pathExtension.lowercased()) {
                    audioFiles.append(file)
                }
            }
        }
        guard !audioFiles.isEmpty else {
            log("语音转写：未找到可识别的音频（需 mp3/m4a/wav；SILK 请先由系统转码）")
            return [:]
        }

        #if canImport(Speech)
        guard SFSpeechRecognizer.authorizationStatus() != .denied else {
            log("语音转写：未授权语音识别")
            return [:]
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let ok = await requestAuth()
            guard ok else {
                log("语音转写：用户未授权")
                return [:]
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer() else {
            log("语音转写：当前系统不支持语音识别")
            return [:]
        }
        var result: [String: String] = [:]
        for file in audioFiles.prefix(40) {
            if let text = await recognize(file: file, recognizer: recognizer) {
                result[file.lastPathComponent] = text
                log("语音转写完成：\(file.lastPathComponent)")
            }
        }
        return result
        #else
        log("语音转写：当前平台未启用 Speech 框架，已跳过")
        return [:]
        #endif
    }

    #if canImport(Speech)
    private static func requestAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private static func recognize(file: URL, recognizer: SFSpeechRecognizer) async -> String? {
        await withCheckedContinuation { cont in
            let request = SFSpeechURLRecognitionRequest(url: file)
            request.shouldReportPartialResults = false
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !settled else { return }
                if let error {
                    settled = true
                    cont.resume(returning: nil)
                    _ = error
                    return
                }
                guard let result, result.isFinal else { return }
                settled = true
                cont.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
    #endif
}
