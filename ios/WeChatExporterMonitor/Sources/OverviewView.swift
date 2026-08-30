import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var store: MonitorStore

    @State private var hoursSelection = 24

    // 一键重启服务
    @State private var restartTarget: String?   // 重启 API 名称(diag-server 等)
    @State private var restartDisplay: String = ""
    @State private var showRestartAlert = false
    @State private var restartAlertTitle = ""
    @State private var restartAlertMessage = ""

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
                            let rname = ServicesStatus.restartNames[key]
                            ServiceRow(
                                name: key,
                                running: status.services.value(for: key),
                                onRestart: rname != nil ? {
                                    restartTarget = rname
                                    restartDisplay = key
                                } : nil
                            )
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
                    HStack {
                        Text(historyTitle)
                            .font(.headline)
                        Spacer()
                        Picker("时间范围", selection: $hoursSelection) {
                            Text("24h").tag(24)
                            Text("7d").tag(168)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    .padding(.horizontal)
                    historyContent
                        .padding(.horizontal)
                }
                .onChange(of: hoursSelection) { _, newValue in
                    Task { await store.loadHistory(hours: newValue) }
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            // 非阻塞刷新: 闭包立即返回(指示器快速消失), 数据在后台 Task 中并行加载。
            // 服务器经 CF Tunnel 公网延迟 3-10s, 若 await 完整 loadAll 下拉指示器会一直转,
            // 用户感知为"卡着不更新"。改为后台加载, UI 用旧数据先行 + @Published 自动刷新。
            _ = Task { await store.loadAll() }
        }
        .confirmationDialog(
            "确定重启 \(restartDisplay)?",
            isPresented: Binding(
                get: { restartTarget != nil },
                set: { if !$0 { restartTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("重启 \(restartDisplay)", role: .destructive) {
                if let target = restartTarget {
                    Task { await performRestart(name: target) }
                }
            }
            Button("取消", role: .cancel) { restartTarget = nil }
        } message: {
            Text(restartDisplay == "monitorApi"
                 ? "重启 monitor-api 后服务会短暂不可用(约1分钟), 期间概览数据可能加载失败"
                 : "服务将短暂中断后自动恢复")
        }
        .alert(restartAlertTitle, isPresented: $showRestartAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(restartAlertMessage)
        }
    }

    private var historyTitle: String {
        hoursSelection == 168 ? "历史趋势(7d)" : "历史趋势(24h)"
    }

    private func performRestart(name: String) async {
        let ok = await store.restartService(name: name)
        if ok {
            restartAlertTitle = "已发送重启指令"
            if name == "monitor-api" {
                restartAlertMessage = "服务重启中, 约1分钟后恢复。期间概览可能短暂无法连接。"
            } else {
                restartAlertMessage = "\(restartDisplay) 正在重启, 稍后自动恢复。"
            }
        } else {
            restartAlertTitle = "重启失败"
            restartAlertMessage = "无法重启 \(restartDisplay), 请检查网络或稍后重试。"
        }
        restartTarget = nil
        showRestartAlert = true
        // 重启后稍等再刷新状态(monitor-api 自重启会短暂 502)。
        try? await Task.sleep(for: .seconds(2))
        await store.loadStatus()
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
