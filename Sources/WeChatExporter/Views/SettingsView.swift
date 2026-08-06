import SwiftUI

/// 统一设置面板 — 左侧导航 + 右侧内容，macOS 系统设置风格
struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    enum SettingsTab: Int, CaseIterable, Identifiable {
        case export = 0, update = 1, about = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .export: return "导出"
            case .update: return "更新"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .export: return "square.and.arrow.down.fill"
            case .update: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 680, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.headerGradient)
                    .frame(width: 34, height: 34)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            Text("设置")
                .font(.title3.weight(.bold))
            Spacer()
            Button("完成") {
                model.showSettings = false
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sidebar

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: model.settingsTab) ?? .export
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.settingsTab = tab.rawValue
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20)
                        Text(tab.title)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? AppTheme.accentSoft : Color.clear)
                    )
                    .foregroundStyle(isSelected ? AppTheme.accent : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedTab {
                case .export:
                    ExportSettingsTab(model: model)
                case .update:
                    UpdateSettingsTab(model: model)
                case .about:
                    AboutTab(model: model)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selectedTab)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.subtleText)
            Text("WeChatExporter v\(model.currentVersion) (\(model.currentBuild))")
                .font(AppTheme.monoFontSm)
                .foregroundStyle(AppTheme.subtleText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

// MARK: - 导出设置

private struct ExportSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 导出方式
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出方式")
                            .font(.headline)
                    }

                    ForEach(ExportMode.allCases) { mode in
                        let isSelected = model.exportMode == mode
                        HStack(alignment: .top, spacing: 12) {
                            RadioButton(
                                isSelected: isSelected,
                                action: { changeMode(mode) }
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .font(.body.weight(.medium))
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.subtleText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { changeMode(mode) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 导出目录
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出目录")
                            .font(.headline)
                    }

                    HStack(spacing: 8) {
                        TextField("导出路径", text: $model.exportPath)
                            .textFieldStyle(.roundedBorder)
                            .font(AppTheme.monoFontSm)
                        Button("选择…") { model.chooseExportFolder() }
                        Button("打开") { model.openExportFolder() }
                    }

                    Text("导出的聊天记录将保存到此目录")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeMode(_ mode: ExportMode) {
        model.exportMode = mode
        ExportModePreferences.mode = mode
    }
}

// MARK: - 更新设置

private struct UpdateSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 版本信息
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("版本信息")
                            .font(.headline)
                    }

                    HStack {
                        Text("当前版本")
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("v\(model.currentVersion)")
                            .font(AppTheme.monoFont.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        Text("(Build \(model.currentBuild))")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                    }
                    if let lastCheck = model.lastCheckDate {
                        HStack {
                            Text("上次检查")
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text(lastCheck.formatted(date: .abbreviated, time: .shortened))
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 更新方式
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(AppTheme.accent)
                        Text("更新方式")
                            .font(.headline)
                    }

                    ForEach(UpdateMode.allCases, id: \.self) { mode in
                        HStack(alignment: .top, spacing: 12) {
                            RadioButton(
                                isSelected: model.updateMode == mode,
                                action: { model.changeUpdateMode(mode) }
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .font(.body.weight(.medium))
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.subtleText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.changeUpdateMode(mode) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 手动检查
            HStack(spacing: 12) {
                Button {
                    model.checkForUpdatesManually()
                } label: {
                    Label("立即检查更新", systemImage: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(model.isCheckingUpdate || model.isDownloadingUpdate)

                if model.isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查…")
                        .font(AppTheme.monoFontSm)
                        .foregroundStyle(AppTheme.subtleText)
                }

                Spacer()

                Button("前往 Release 页面") {
                    model.openReleaseInBrowser()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)
            }

            // 下载进度
            if model.isDownloadingUpdate, let progress = model.updateDownloadProgress {
                TechCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载进度")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.subtleText)
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(AppTheme.accent)
                        HStack {
                            Text(progress.formattedProgress)
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text("\(Int(progress.fraction * 100))%")
                                .font(AppTheme.monoFontSm.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 安装中提示
            if model.isInstallingUpdate {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装更新，应用将自动重启…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 22) {
            // App icon
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: AppTheme.accentGlow, radius: 16, y: 6)

                    Image(systemName: "message.and.waveform.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 4) {
                    Text("微信聊天记录导出")
                        .font(.title2.weight(.bold))
                    HStack(spacing: 6) {
                        Text("v\(model.currentVersion)")
                            .font(AppTheme.monoFont.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        Text("Build \(model.currentBuild)")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // Quick guide
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("快速指南", systemImage: "book.fill")
                        .font(.headline)
                    GuideStep(number: 1, text: "首次使用点击「准备数据」（会重启微信）")
                    GuideStep(number: 2, text: "在左侧列表中选择一个或多个联系人")
                    GuideStep(number: 3, text: "点击「导出选中」生成 HTML 文件")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Environment requirements
            TechCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                        Text("环境要求")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Label("macOS 需关闭 SIP（恢复模式执行 csrutil disable）", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("需启用 DevToolsSecurity（软件可自动检测并启用）", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("支持微信 4.1.7 – 4.1.11", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("Windows 需安装 .NET 8 运行时", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .foregroundStyle(AppTheme.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Links
            HStack(spacing: 20) {
                LinkButton(title: "GitHub 仓库", icon: "star.fill") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter") {
                        NSWorkspace.shared.open(url)
                    }
                }
                LinkButton(title: "问题反馈", icon: "exclamationmark.bubble.fill") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                LinkButton(title: "Release 下载", icon: "arrow.down.circle.fill") {
                    model.openReleaseInBrowser()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 90, height: 52)
            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
    }
}
