import Foundation

enum APIError: LocalizedError {
    case badURL
    case serverUnreachable
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "无效的请求地址"
        case .serverUnreachable:
            return "无法连接服务器，请检查网络或稍后重试"
        case .http(let code):
            return "服务器返回错误 (HTTP \(code))"
        case .decoding(let message):
            return "数据解析失败: \(message)"
        }
    }
}

enum APIClient {
    static let baseURL = URL(string: "https://linminhao.top")!
    static let token = "wxexporter-diag-2026"

    /// 泛型 GET 请求，自动附带 x-diag-token 鉴权头，超时 10s。
    static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "x-diag-token")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverUnreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}
