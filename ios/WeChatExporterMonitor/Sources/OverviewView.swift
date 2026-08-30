import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationStack {
            Group {
                if let status = store.status {
                    content(status)
                } else if store.statusLoading {
                    ProgressView("加载中…")
                } else {
                    ErrorStateView(message: store.statusError ?? "无法连接服务器") {
                        Task { await store.loadStatus() }
                    }
                }
            }
            .navigationTitle("概览")
            .refreshable { await store.loadAll() }
            .task { await store.autoRefreshStatus() }
        }
    }

    @ViewBuilder
    private func content(_ status: StatusResponse) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("服务器状态")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("更新于 \(DateFormat.friendly(status.fetchedAt))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                MetricCard(
                    title: "CPU",
                    value: String(format: "%.1f%%", status.system.cpu),
                    detail: "服务器 CPU 使用率",
                    fraction: status.system.cpu / 100.0
                )
                .padding(.horizontal)

                HStack(spacing: 12) {
                    MetricCard(
                        title: "内存",
                        value: "\(status.system.memory.usedMB) MB",
                        detail: "共 \(status.system.memory.totalMB) MB",
                        fraction: Double(status.system.memory.usedMB)
                            / Double(max(status.system.memory.totalMB, 1))
                    )
                    MetricCard(
                        title: "磁盘",
                        value: String(format: "%.1f GB", status.system.disk.usedGB),
                        detail: "剩余 \(String(format: "%.1f", status.system.disk.freeGB)) GB",
                        fraction: status.system.disk.usedGB
                            / max(status.system.disk.usedGB + status.system.disk.freeGB, 0.01)
                    )
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 0) {
                    Text("服务状态")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(ServicesStatus.allServiceKeys, id: \.self) { key in
                            ServiceRow(name: key, running: status.services.value(for: key))
                            if key != ServicesStatus.allServiceKeys.last {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("诊断日志统计")
                        .font(.headline)
                        .padding(.horizontal)
                    HStack(spacing: 12) {
                        CountTile(label: "收件箱", value: status.counts.inbox, color: .gray)
                        CountTile(label: "处理中", value: status.counts.processing, color: .blue)
                        CountTile(label: "已解决", value: status.counts.resolved, color: .green)
                        CountTile(label: "失败", value: status.counts.failed, color: .red)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }
}
