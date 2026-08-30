import SwiftUI

struct FixesView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationStack {
            List {
                Section("日志解决状态") {
                    if store.logs.isEmpty {
                        if store.logsLoading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("暂无日志")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(store.logs) { log in
                            HStack(spacing: 10) {
                                Text(log.id)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .foregroundColor(.secondary)
                                Spacer()
                                StatusBadge(status: log.status)
                            }
                        }
                    }
                }

                Section("Hermes 修复记录") {
                    if let hermes = store.hermes {
                        if hermes.recentFixes.isEmpty {
                            Text("暂无修复记录")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(hermes.recentFixes) { fix in
                                fixRow(fix)
                            }
                        }
                    } else if store.hermesLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Text("无法加载修复记录")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("修复进度")
            .refreshable { await store.loadAll() }
        }
    }

    private func fixRow(_ fix: FixRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: fix.source == "hermes" ? "brain" : "wand.and.stars")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text(fix.source)
                    .font(.caption)
                    .bold()
                Spacer()
                Text(fix.time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(fix.text)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }
}
