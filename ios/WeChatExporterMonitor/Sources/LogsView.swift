import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: MonitorStore

    @State private var searchText = ""
    @State private var filter: LogFilter = .all

    private var filteredLogs: [DiagnosticLog] {
        store.logs.filter { log in
            if let status = filter.statusValue, log.status != status {
                return false
            }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let query = searchText.lowercased()
                let haystack = [log.error, log.app, log.platform, log.errorFull, log.stage, log.version]
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.contains(query) else { return false }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.logsLoading && store.logs.isEmpty {
                    ProgressView("加载中…")
                } else if store.logs.isEmpty {
                    if let err = store.logsError {
                        ErrorStateView(message: err) {
                            Task { await store.loadLogs() }
                        }
                    } else {
                        ContentUnavailableView(
                            "暂无日志",
                            systemImage: "tray",
                            description: Text("服务器当前没有诊断日志")
                        )
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("状态筛选", selection: $filter) {
                            ForEach(LogFilter.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        if filteredLogs.isEmpty {
                            ContentUnavailableView(
                                "无匹配日志",
                                systemImage: "magnifyingglass",
                                description: Text("没有符合搜索/筛选条件的日志")
                            )
                        } else {
                            List(filteredLogs) { log in
                                NavigationLink {
                                    LogDetailView(log: log)
                                } label: {
                                    LogRow(log: log)
                                }
                                .contextMenu {
                                    ShareLink(item: log.shareText) {
                                        Label("分享日志", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("报错日志")
            .searchable(text: $searchText, prompt: "搜索错误/应用/平台")
            .refreshable { await store.loadLogs() }
        }
    }
}

// MARK: - 状态筛选

private enum LogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待处理"
    case resolved = "已解决"
    case failed = "失败"

    var id: String { rawValue }

    var statusValue: String? {
        switch self {
        case .all: return nil
        case .pending: return "pending"
        case .resolved: return "resolved"
        case .failed: return "failed"
        }
    }
}

private struct LogRow: View {
    let log: DiagnosticLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusBadge(status: log.status)
                Spacer()
                Text(DateFormat.friendly(log.receivedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(log.error.isEmpty ? "(无摘要)" : log.error)
                .font(.subheadline)
                .lineLimit(2)
                .foregroundColor(.primary)
            HStack(spacing: 6) {
                if !log.app.isEmpty { tag(log.app) }
                if !log.platform.isEmpty { tag(log.platform) }
                if !log.version.isEmpty { tag("v\(log.version)") }
                if !log.stage.isEmpty { tag(log.stage) }
            }
        }
        .padding(.vertical, 4)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
    }
}
