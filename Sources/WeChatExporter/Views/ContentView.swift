import SwiftUI
import AppKit

// MARK: - Tech Theme

enum AppTheme {
    // Primary accent: cyan-teal — digital, precise, trustworthy
    static let accent = Color(red: 0.06, green: 0.72, blue: 0.88)
    static let accentDeep = Color(red: 0.03, green: 0.52, blue: 0.72)
    static let accentSoft = Color(red: 0.06, green: 0.72, blue: 0.88).opacity(0.12)
    static let accentGlow = Color(red: 0.06, green: 0.72, blue: 0.88).opacity(0.25)

    // Semantic colors
    static let success = Color(red: 0.06, green: 0.72, blue: 0.50)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let error = Color(red: 0.95, green: 0.25, blue: 0.38)

    // Adaptive surfaces
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtleText = Color.secondary

    // Gradients
    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let headerGradient = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.58, blue: 0.78),
            Color(red: 0.02, green: 0.42, blue: 0.62),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let logGradient = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.08, blue: 0.12),
            Color(red: 0.04, green: 0.06, blue: 0.10),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // Typography helpers
    static let monoFont = Font.system(.caption, design: .monospaced)
    static let monoFontSm = Font.system(.caption2, design: .monospaced)
}

// MARK: - Reusable Components

/// Tech-styled card with subtle border and depth
struct TechCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.accent.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            )
    }
}

/// Accent gradient button style
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.accentGradient)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .foregroundStyle(.white)
            .font(.body.weight(.medium))
            .shadow(color: AppTheme.accentGlow, radius: 6, y: 2)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
        } detail: {
            detailPanel
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("提示", isPresented: $model.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .sheet(isPresented: $model.showUpdateSheet) {
            UpdateNotificationSheet(model: model)
        }
        .sheet(isPresented: $model.showUpdateSettings) {
            UpdateSettingsView(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .task {
            await model.startIfNeeded()
            model.checkUpdateOnStartup()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(16)

            List(selection: $model.selectedIDs) {
                Section {
                    ForEach(model.filteredContacts) { contact in
                        ContactRow(contact: contact)
                            .tag(contact.id)
                    }
                } header: {
                    HStack {
                        Text("会话")
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Spacer()
                        Text("\(model.filteredContacts.count)")
                            .font(AppTheme.monoFontSm.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.accentSoft, in: Capsule())
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $model.searchText, prompt: "搜索联系人、群聊、备注")
        .toolbar { toolbarContent }
        .navigationTitle("微信聊天记录导出")
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                // Tech icon with glow
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: AppTheme.accentGlow, radius: 10, y: 4)

                    Image(systemName: "message.and.waveform.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("WeChat Exporter")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("聊天记录导出工具")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.subtleText)
                }

                Spacer()

                // Version badge
                VStack(alignment: .trailing, spacing: 2) {
                    Text("v\(model.currentVersion)")
                        .font(AppTheme.monoFontSm.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                    Text("Build \(model.currentBuild)")
                        .font(AppTheme.monoFontSm)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }

            if model.isBusy || model.operationProgress != nil {
                operationProgressView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.accent.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        )
    }

    @ViewBuilder
    private var operationProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = model.operationProgress {
                ProgressView(value: value) {
                    HStack {
                        Text(model.operationProgressLabel.isEmpty ? "处理中…" : model.operationProgressLabel)
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("\(Int(value * 100))%")
                            .font(AppTheme.monoFontSm.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                .progressViewStyle(.linear)
                .tint(AppTheme.accent)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("处理中…")
                        .font(AppTheme.monoFontSm)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.prepareData() }
            } label: {
                Label("准备数据", systemImage: "key.fill")
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.refreshContacts() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.exportSelected() }
            } label: {
                Label("导出选中", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(model.isBusy || model.selectedIDs.isEmpty)

            Button {
                model.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape.fill")
            }
            .disabled(model.isBusy)

            if model.isCheckingUpdate {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                readinessBanner

                // Export status quick view
                TechCard {
                    HStack(spacing: 20) {
                        ExportStatusChip(
                            icon: model.includeMedia ? "photo.fill.on.rectangle.fill" : "doc.text.fill",
                            label: model.includeMedia ? "含媒体" : "纯文本",
                            isActive: model.includeMedia
                        )
                        Divider().frame(height: 28)
                        ExportStatusChip(
                            icon: "folder.fill",
                            label: model.exportPath,
                            isActive: false,
                            truncates: true
                        )
                        Spacer()
                        Button {
                            model.showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppTheme.accent)
                    }
                }

                // Instructions
                TechCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("快速指南", systemImage: "book.fill")
                            .font(.headline)

                        GuideStep(number: 1, text: "首次使用点击「准备数据」（会重启微信）")
                        GuideStep(number: 2, text: "在左侧列表中选择一个或多个联系人")
                        GuideStep(number: 3, text: "点击「导出选中」生成 HTML 文件")
                        GuideStep(number: 4, text: "导出路径和媒体选项请在「设置」中调整", highlight: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Log panel — terminal style
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red.opacity(0.7)).frame(width: 10, height: 10)
                            Circle().fill(Color.yellow.opacity(0.7)).frame(width: 10, height: 10)
                            Circle().fill(Color.green.opacity(0.7)).frame(width: 10, height: 10)
                        }
                        Text("console")
                            .font(AppTheme.monoFontSm.weight(.medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(model.statusText)
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.08, green: 0.10, blue: 0.14))

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { idx, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(idx + 1)")
                                        .font(AppTheme.monoFontSm)
                                        .foregroundStyle(.white.opacity(0.25))
                                        .frame(width: 28, alignment: .trailing)
                                    Text(line)
                                        .font(AppTheme.monoFont)
                                        .foregroundStyle(logColor(for: line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(AppTheme.logGradient)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("详情")
    }

    private var readinessBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(model.isDataReady ? AppTheme.success.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: model.isDataReady ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(model.isDataReady ? AppTheme.success : .orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.isDataReady ? "数据就绪" : "等待初始化")
                    .font(.headline)
                Text(model.readinessHint)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.subtleText)
            }

            Spacer()

            if let value = model.operationProgress {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(value * 100))%")
                        .font(AppTheme.monoFont.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                    ProgressView(value: value)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                        .frame(width: 120)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            model.isDataReady ? AppTheme.success.opacity(0.15) : Color.orange.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        )
    }

    private func logColor(for line: String) -> Color {
        if line.contains("错误") || line.contains("失败") || line.contains("警告") {
            return AppTheme.error.opacity(0.9)
        }
        if line.contains("成功") || line.contains("完成") || line.contains("已") {
            return AppTheme.success.opacity(0.9)
        }
        return .white.opacity(0.7)
    }
}

// MARK: - Sub-components

struct GuideStep: View {
    let number: Int
    let text: String
    var highlight: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(highlight ? AppTheme.accent : AppTheme.accent.opacity(0.5))
                )
            Text(text)
                .font(.subheadline)
                .foregroundStyle(highlight ? AppTheme.accent : AppTheme.subtleText)
            Spacer()
        }
    }
}

struct ExportStatusChip: View {
    let icon: String
    let label: String
    let isActive: Bool
    var truncates: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isActive ? AppTheme.accent : AppTheme.subtleText)
            if truncates {
                Text(label)
                    .font(AppTheme.monoFontSm)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(AppTheme.subtleText)
            } else {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isActive ? AppTheme.accent : AppTheme.subtleText)
            }
        }
    }
}

struct ContactRow: View {
    let contact: ContactItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: contact.kind.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(contact.subtitle)
                    .font(AppTheme.monoFontSm)
                    .foregroundStyle(AppTheme.subtleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(contact.kind.rawValue)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.accentSoft, in: Capsule())
        }
        .padding(.vertical, 5)
    }
}
