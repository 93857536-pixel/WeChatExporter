import SwiftUI

struct LogDetailView: View {
    let log: DiagnosticLog
    @EnvironmentObject private var store: MonitorStore

    @State private var detail: DiagnosticLog?
    @State private var loadError: String?

    private var current: DiagnosticLog { detail ?? log }

    private var versionString: String {
        if current.version.isEmpty {
            return current.build.isEmpty ? "—" : "build \(current.build)"
        }
        if current.build.isEmpty {
            return current.version
        }
        return "\(current.version) (build \(current.build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metadata
                MonospaceBlock(title: "完整错误 (error_full)", text: current.errorFull)
                MonospaceBlock(title: "日志尾部 (logs_tail)", text: current.logsTail)
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("日志详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            StatusBadge(status: current.status)
            Spacer()
            Text(current.id)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("应用", current.app)
            row("平台", current.platform)
            row("版本", versionString)
            row("系统", current.osName)
            row("阶段", current.stage)
            row("接收时间", DateFormat.friendly(current.receivedAt))
            row("客户端时间", current.timestamp.isEmpty ? "—" : current.timestamp)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        do {
            detail = try await store.fetchLogDetail(id: log.id)
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "无法加载详情"
        }
    }
}
