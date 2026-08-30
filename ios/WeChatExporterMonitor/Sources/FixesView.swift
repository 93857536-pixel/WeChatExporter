import SwiftUI

struct FixesView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationStack {
            List {
                currentFixSection
                ciSection
                recentSection
            }
            .navigationTitle("修复进度")
            .refreshable { await store.loadFixes() }
            .task {
                if store.fixes == nil {
                    await store.loadFixes()
                }
            }
        }
    }

    // MARK: - 当前修复

    @ViewBuilder
    private var currentFixSection: some View {
        Section("当前修复") {
            if let current = store.fixes?.current {
                currentFixCard(current)
            } else if store.fixes == nil && store.fixesLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let err = store.fixesError, store.fixes == nil {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("暂无进行中的修复")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func currentFixCard(_ current: FixStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if current.status == "processing" {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("修复中…")
                        .font(.headline)
                        .foregroundColor(.blue)
                } else if current.status == "completed" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已完成")
                        .font(.headline)
                        .foregroundColor(.green)
                } else {
                    Text(current.status)
                        .font(.headline)
                }
                Spacer()
            }

            if !current.logIds.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("涉及日志: \(current.logIds.joined(separator: ", "))")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
            }

            infoRow("开始", current.startedAt)
            infoRow("更新", current.updatedAt)
            if let finished = current.finishedAt, !finished.isEmpty {
                infoRow("完成", finished)
            }

            if let summary = current.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func infoRow(_ label: String, _ iso: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(DateFormat.friendly(iso))
                .font(.caption)
                .foregroundColor(.primary)
        }
    }

    // MARK: - GitHub Actions CI

    @ViewBuilder
    private var ciSection: some View {
        Section("GitHub Actions CI") {
            if let ci = store.fixes?.ci {
                ciCard(ci)
            } else if store.fixes == nil && store.fixesLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Text("暂无 CI 信息")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func ciCard(_ ci: CIInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if ci.status == "in_progress" || ci.status == "queued" {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                ciBadge(ci)
                Text(ci.name)
                    .font(.headline)
                Spacer()
                if let url = ci.htmlUrl, !url.isEmpty, let link = URL(string: url) {
                    Link(destination: link) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.body)
                    }
                }
            }

            if let sha = ci.headSha, !sha.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(sha)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }

            if let created = ci.createdAt, !created.isEmpty {
                Text("更新时间 \(DateFormat.friendly(created))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func ciBadge(_ ci: CIInfo) -> some View {
        let (text, color): (String, Color) = {
            if ci.status == "completed" {
                switch ci.conclusion {
                case "success": return ("构建成功", .green)
                case "failure": return ("构建失败", .red)
                default: return ("已完成", .gray)
                }
            }
            if ci.status == "in_progress" || ci.status == "queued" {
                return ("构建中", .blue)
            }
            return (ci.status, .gray)
        }()
        return Text(text)
            .font(.caption).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - 最近修复历史

    @ViewBuilder
    private var recentSection: some View {
        Section("最近修复历史") {
            if let fixes = store.fixes {
                if fixes.recent.isEmpty {
                    Text("暂无修复记录")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(fixes.recent) { fix in
                        fixRow(fix)
                    }
                }
            } else if store.fixesLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Text("无法加载修复记录")
                    .foregroundColor(.secondary)
            }
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
