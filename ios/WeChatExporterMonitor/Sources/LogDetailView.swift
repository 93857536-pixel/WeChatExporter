import SwiftUI
import UIKit

struct LogDetailView: View {
    let log: DiagnosticLog
    @EnvironmentObject private var store: MonitorStore

    @State private var detail: DiagnosticLog?
    @State private var loadError: String?

    @State private var showTriggerConfirm = false
    @State private var showAckConfirm = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private var current: DiagnosticLog { detail ?? log }

    private var canTrigger: Bool { current.status != "resolved" }
    private var canAck: Bool { current.status == "pending" || current.status == "failed" }

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
                if canTrigger || canAck {
                    actionButtons
                }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    copyLog()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .confirmationDialog("确认触发修复?", isPresented: $showTriggerConfirm, titleVisibility: .visible) {
            Button("触发修复", role: .destructive) {
                Task { await performTrigger() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将日志重新放入修复队列并立即运行修复任务")
        }
        .confirmationDialog("确认标记已处理?", isPresented: $showAckConfirm, titleVisibility: .visible) {
            Button("标记已处理") {
                Task { await performAck() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将该日志标记为处理完成")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
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

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if canTrigger {
                Button {
                    showTriggerConfirm = true
                } label: {
                    Label("触发修复", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if canAck {
                Button {
                    showAckConfirm = true
                } label: {
                    Label("标记已处理", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
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

    private func copyLog() {
        UIPasteboard.general.string = current.clipboardText
        alertTitle = "已复制"
        alertMessage = "完整日志已复制到剪贴板"
        showAlert = true
    }

    private func performTrigger() async {
        if await store.triggerFix(id: current.id) {
            alertTitle = "已触发修复"
            alertMessage = "修复任务已加入队列，稍后刷新可查看进度"
            await store.loadLogs()
            await load()
        } else {
            alertTitle = "操作失败"
            alertMessage = "无法触发修复，请检查网络或稍后重试"
        }
        showAlert = true
    }

    private func performAck() async {
        if await store.ackLog(id: current.id) {
            alertTitle = "已标记处理"
            alertMessage = "日志已标记为处理完成"
            await store.loadLogs()
            await load()
        } else {
            alertTitle = "操作失败"
            alertMessage = "无法标记处理，请检查网络或稍后重试"
        }
        showAlert = true
    }
}
