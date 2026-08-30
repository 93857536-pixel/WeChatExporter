import SwiftUI
import Charts

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("历史趋势(24h)")
                        .font(.headline)
                        .padding(.horizontal)
                    historyContent
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .refreshable { await store.loadAll() }
    }

    // MARK: - 历史趋势

    @ViewBuilder
    private var historyContent: some View {
        if store.historyLoading && store.history.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(height: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if store.history.isEmpty || trendData.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("暂无历史数据")
                    .font(.subheadline)
                Text("采集器每5分钟记录一次")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            historyChart
        }
    }

    private var historyChart: some View {
        Chart(trendData) { point in
            LineMark(
                x: .value("时间", point.date),
                y: .value("值", point.value)
            )
            .foregroundStyle(by: .value("指标", point.series))
        }
        .chartLegend(.visible)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .padding(12)
        .frame(height: 180)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 把 history 点按系列拆成三组（CPU % / 内存 MB / 磁盘 GB），供 Swift Charts 画三条线。
    private var trendData: [TrendPoint] {
        var points: [TrendPoint] = []
        for p in store.history {
            guard let date = p.date else { continue }
            points.append(TrendPoint(series: "CPU %", date: date, value: p.cpu))
            points.append(TrendPoint(series: "内存 MB", date: date, value: Double(p.memUsed)))
            points.append(TrendPoint(series: "磁盘 GB", date: date, value: p.diskUsed))
        }
        return points
    }
}

/// 图表用的数据点（按系列拆分）。
private struct TrendPoint: Identifiable {
    let id = UUID()
    let series: String
    let date: Date
    let value: Double
}
