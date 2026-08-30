import Foundation
import SwiftUI

/// 集中管理三个数据源: status / logs / hermes。
@MainActor
final class MonitorStore: ObservableObject {
    @Published var status: StatusResponse?
    @Published var logs: [DiagnosticLog] = []
    @Published var hermes: HermesResponse?

    @Published var statusLoading = false
    @Published var logsLoading = false
    @Published var hermesLoading = false

    @Published var statusError: String?
    @Published var logsError: String?
    @Published var hermesError: String?

    func loadAll() async {
        async let s: Void = loadStatus()
        async let l: Void = loadLogs()
        async let h: Void = loadHermes()
        _ = await (s, l, h)
    }

    func loadStatus() async {
        statusLoading = true
        statusError = nil
        defer { statusLoading = false }
        do {
            status = try await APIClient.get("/api/status")
        } catch {
            statusError = (error as? APIError)?.errorDescription ?? "无法连接服务器"
        }
    }

    func loadLogs() async {
        logsLoading = true
        logsError = nil
        defer { logsLoading = false }
        do {
            let resp: LogsResponse = try await APIClient.get("/api/logs?limit=50")
            logs = resp.logs
        } catch {
            logsError = (error as? APIError)?.errorDescription ?? "无法连接服务器"
        }
    }

    func loadHermes() async {
        hermesLoading = true
        hermesError = nil
        defer { hermesLoading = false }
        do {
            hermes = try await APIClient.get("/api/hermes")
        } catch {
            hermesError = (error as? APIError)?.errorDescription ?? "无法连接服务器"
        }
    }

    func fetchLogDetail(id: String) async throws -> DiagnosticLog {
        let resp: LogDetailResponse = try await APIClient.get("/api/logs/\(id)")
        return resp.data
    }

    /// 概览页 30s 定时刷新。
    func autoRefreshStatus() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await loadStatus()
        }
    }
}
