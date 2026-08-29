import Foundation
import os.log

/// 诊断日志上传器 —— 报错时静默上传诊断信息到开发者服务器。
/// 上传失败不影响用户操作，不弹错误框，仅写本地日志。
/// consent 状态持久化到 UserDefaults（key: "diagnostics.consented"，未设置 = 未选择）。
enum DiagnosticUploader {
    // MARK: - Consent 存储

    private enum Keys {
        static let consented = "diagnostics.consented"
    }

    /// 用户是否已做出选择（未设置 = 未选择）
    static var isConsentDecided: Bool {
        UserDefaults.standard.object(forKey: Keys.consented) != nil
    }

    /// 用户是否同意自动上传诊断日志
    static var isConsented: Bool {
        UserDefaults.standard.bool(forKey: Keys.consented)
    }

    /// 记录用户选择
    static func setConsented(_ consented: Bool) {
        UserDefaults.standard.set(consented, forKey: Keys.consented)
    }

    // MARK: - Stage 常量

    static let stagePrepare = "prepare"
    static let stageLoadSessions = "load_sessions"
    static let stageExport = "export"
    static let stageOther = "other"

    // MARK: - 上传

    // 经 Cloudflare Tunnel 443 转发到服务器 8082（阿里云云盾拦截非 80/443 端口直连）
    private static let endpoint = URL(string: "https://linminhao.top/diag/v1/diag")!

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WeChatExporter",
        category: "diagnostics"
    )

    /// 应用版本号（从 Info.plist 读取，缺失时回退到契约默认值）
    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.14.0"
    }

    /// 构建号
    private static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "30"
    }

    /// 若用户已同意，则静默上传诊断日志；失败静默，不重试、不阻塞。
    static func reportIfAllowed(stage: String, error: String?, logs: [String]) {
        guard isConsented else { return }

        let payload = buildPayload(stage: stage, error: error, logs: logs)
        guard let body = try? JSONEncoder().encode(payload) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.info("诊断日志上传失败（静默忽略）：\(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.info("诊断日志上传返回非 200 状态码（静默忽略）：\(http.statusCode, privacy: .public)")
            }
        }.resume()
    }

    // MARK: - 请求体

    private struct DiagnosticPayload: Codable {
        let app: String
        let platform: String
        let version: String
        let build: String
        let os: String
        let timestamp: String
        let stage: String
        let error: String
        let logs: String
    }

    private static func buildPayload(stage: String, error: String?, logs: [String]) -> DiagnosticPayload {
        // error 截断 2000 字符；logs 取最后约 50 行、截断 8000 字符，避免超大 body
        let errorText = truncate(error ?? "", to: 2000)
        let logsText = truncate(logs.suffix(50).joined(separator: "\n"), to: 8000)
        return DiagnosticPayload(
            app: "WeChatExporter",
            platform: "macos",
            version: versionString,
            build: buildString,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            timestamp: timestampString,
            stage: stage,
            error: errorText,
            logs: logsText
        )
    }

    /// ISO8601 本地时间
    private static var timestampString: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private static func truncate(_ string: String, to maxLength: Int) -> String {
        string.count <= maxLength ? string : String(string.prefix(maxLength))
    }
}
