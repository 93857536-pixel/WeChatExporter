import SwiftUI

/// App 内全文搜索面板（SPEC §1）：检索最近导出目录的 wce-search.sqlite，
/// 结果按时间倒序；点击结果用系统程序打开对应会话的 chat.txt。
struct SearchPanel: View {
    @ObservedObject var model: AppViewModel
    var onClose: () -> Void

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return f
    }

    private func hitTime(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        return timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 34, height: 34)
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                Text("全文搜索")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 搜索输入
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.subtleText)
                TextField("输入关键词（全文检索，不区分大小写）…", text: $model.searchKeyword)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit { model.runSearch() }
                    .focused($isFocused)
                Button {
                    model.rebuildSearchIndex()
                } label: {
                    Label("重建", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("重新扫描导出目录并重建 wce-search.sqlite")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // 结果区
            if model.searched && !model.searchHits.isEmpty {
                resultListView
            } else if model.searched {
                emptyView(indexAvailable: model.searchIndexAvailable)
            } else {
                promptView
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            isFocused = true
        }
    }

    @FocusState private var isFocused: Bool

    private var promptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.accent.opacity(0.5))
            Text("输入关键词开始检索")
                .font(.headline)
            Text("数据来源：最近一次导出目录的 wce-search.sqlite")
                .font(.caption)
                .foregroundStyle(AppTheme.subtleText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func emptyView(indexAvailable: Bool) -> some View {
        VStack(spacing: 8) {
            Text(indexAvailable ? "无命中" : "尚未生成搜索索引")
                .font(.headline)
            if !indexAvailable {
                Text("请先导出聊天记录并在设置中开启「全文搜索」，或点击右上「重建」。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.subtleText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resultListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.searchHits.enumerated()), id: \.offset) { idx, hit in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(hit.chat)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                            Text(hitTime(hit.ts))
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text("#\(idx + 1)")
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Text(hit.sender.isEmpty ? "—" : hit.sender)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                            Text(hit.snippet)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                        Button {
                            model.openSearchHit(hit)
                        } label: {
                            Label("打开对应聊天记录", systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppTheme.accent)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(AppTheme.accent.opacity(0.1), lineWidth: 1)
                            )
                    )
                }
            }
            .padding(16)
        }
    }
}
