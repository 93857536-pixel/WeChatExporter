import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: MonitorStore

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
                    List(store.logs) { log in
                        NavigationLink {
                            LogDetailView(log: log)
                        } label: {
                            LogRow(log: log)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("报错日志")
            .refreshable { await store.loadLogs() }
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
