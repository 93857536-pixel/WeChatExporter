import Foundation
import SwiftUI

/// 集中管理数据源: status / logs / hermes / history。
@MainActor
final class MonitorStore: ObservableObject {
    @Published var status: StatusResponse?
    @Published var logs: [DiagnosticLog] = []
    @Published var hermes: HermesResponse?
    @Published var history: [HistoryPoint] = []
    @Published var fixes: FixesResponse?

    @Published var statusLoading = false
    @Published var logsLoading = false
    @Published var hermesLoading = false
    @Published var historyLoading = false
    @Published var fixesLoading = false

    @Published var statusError: String?
    @Published var logsError: String?
    @Published var hermesError: String?
    @Published var historyError: String?
    @Published var fixesError: String?

    func loadAll() async {
        async let s: Void = loadStatus()
        async let l: Void = loadLogs()
        async let h: Void = loadHermes()
        async let y: Void = loadHistory()
        async let f: Void = loadFixes()
        _ = await (s, l, h, y, f)
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

    func loadHistory(hours: Int = 24) async {
        historyLoading = true
        historyError = nil
        defer { historyLoading = false }
        do {
            let resp: HistoryResponse = try await APIClient.get("/api/history?hours=\(hours)")
            history = resp.points
        } catch {
            historyError = (error as? APIError)?.errorDescription ?? "无法连接服务器"
        }
    }

    func loadFixes() async {
        fixesLoading = true
        fixesError = nil
        defer { fixesLoading = false }
        do {
            fixes = try await APIClient.get("/api/fixes")
        } catch {
            fixesError = (error as? APIError)?.errorDescription ?? "无法连接服务器"
        }
    }

    func fetchLogDetail(id: String) async throws -> DiagnosticLog {
        let resp: LogDetailResponse = try await APIClient.get("/api/logs/\(id)")
        return resp.data
    }

    /// 手动触发修复（POST /api/logs/:id/trigger）。成功返回 true。
    @discardableResult
    func triggerFix(id: String) async -> Bool {
        await performAction("/api/logs/\(id)/trigger")
    }

    /// 标记已处理（POST /api/logs/:id/ack）。成功返回 true。
    @discardableResult
    func ackLog(id: String) async -> Bool {
        await performAction("/api/logs/\(id)/ack")
    }

    /// 一键重启服务（POST /api/service/:name/restart）。name 为白名单名称(diag-server/monitor-api/cloudflared/nginx)。
    @discardableResult
    func restartService(name: String) async -> Bool {
        await performAction("/api/service/\(name)/restart")
    }

    private func performAction(_ path: String) async -> Bool {
        do {
            let data = try await APIClient.post(path)
            let resp = try JSONDecoder().decode(ActionResponse.self, from: data)
            return resp.ok
        } catch {
            return false
        }
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
