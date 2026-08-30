import SwiftUI

struct HermesView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationStack {
            Group {
                if let hermes = store.hermes {
                    content(hermes)
                } else if store.hermesLoading {
                    ProgressView("加载中…")
                } else {
                    ErrorStateView(message: store.hermesError ?? "无法连接服务器") {
                        Task { await store.loadHermes() }
                    }
                }
            }
            .navigationTitle("Hermes")
            .refreshable { await store.loadHermes() }
        }
    }

    private func content(_ hermes: HermesResponse) -> some View {
        List {
            Section("进程") {
                HStack {
                    Circle()
                        .fill(hermes.process == "running" ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(hermes.process == "running" ? "运行中" : "已停止")
                        .font(.headline)
                    Spacer()
                    Text(hermes.process)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("配置") {
                LabeledContent("模型") {
                    Text(hermes.model)
                        .font(.callout)
                        .foregroundColor(.primary)
                }
                LabeledContent("安装路径") {
                    Text(hermes.install)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("虚拟环境") {
                    Text(hermes.venv)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("修复日志") {
                    Text(hermes.lastFixLog)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("最近活动") {
                if hermes.recentFixes.isEmpty {
                    Text("暂无活动")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(hermes.recentFixes.prefix(20)) { fix in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(fix.source)
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.blue)
                                Spacer()
                                Text(fix.time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(fix.text)
                                .font(.caption)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
