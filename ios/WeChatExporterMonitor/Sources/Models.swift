import Foundation

// MARK: - /api/status

struct StatusResponse: Codable {
    let ok: Bool
    let fetchedAt: String
    let system: SystemStatus
    let services: ServicesStatus
    let counts: CountsStatus

    enum CodingKeys: String, CodingKey {
        case ok, system, services, counts
        case fetchedAt = "fetched_at"
    }
}

struct SystemStatus: Codable {
    let cpu: Double
    let memory: MemoryStatus
    let disk: DiskStatus
}

struct MemoryStatus: Codable {
    let usedMB: Int
    let totalMB: Int
}

struct DiskStatus: Codable {
    let usedGB: Double
    let freeGB: Double
}

struct ServicesStatus: Codable {
    let diagServer: Bool
    let monitorApi: Bool
    let node3000: Bool
    let nginx: Bool
    let cloudflared: Bool
    let hermes: Bool

    static let allServiceKeys: [String] = [
        "diagServer", "monitorApi", "node3000", "nginx", "cloudflared", "hermes",
    ]

    func value(for key: String) -> Bool {
        switch key {
        case "diagServer": return diagServer
        case "monitorApi": return monitorApi
        case "node3000": return node3000
        case "nginx": return nginx
        case "cloudflared": return cloudflared
        case "hermes": return hermes
        default: return false
        }
    }
}

struct CountsStatus: Codable {
    let inbox: Int
    let processing: Int
    let resolved: Int
    let failed: Int
}

// MARK: - /api/logs

struct LogsResponse: Codable {
    let ok: Bool
    let total: Int
    let logs: [DiagnosticLog]
}

struct DiagnosticLog: Codable, Identifiable {
    let id: String
    let filename: String?
    let status: String
    let receivedAt: String
    let app: String
    let platform: String
    let version: String
    let build: String
    let osName: String
    let stage: String
    let error: String
    let errorFull: String
    let logsTail: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case id, filename, status, app, platform, version, build, stage, error, timestamp
        case receivedAt = "received_at"
        case osName = "os"
        case errorFull = "error_full"
        case logsTail = "logs_tail"
    }
}

struct LogDetailResponse: Codable {
    let ok: Bool
    let status: String
    let data: DiagnosticLog
}

// MARK: - /api/hermes

struct HermesResponse: Codable {
    let ok: Bool
    let process: String
    let model: String
    let install: String
    let venv: String
    let lastFixLog: String
    let recentFixes: [FixRecord]

    enum CodingKeys: String, CodingKey {
        case ok, process, model, install, venv
        case lastFixLog = "last_fix_log"
        case recentFixes = "recent_fixes"
    }
}

struct FixRecord: Codable, Identifiable {
    let source: String
    let time: String
    let text: String

    var id: String { source + time + text }
}
