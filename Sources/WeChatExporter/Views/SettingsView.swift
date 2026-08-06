import SwiftUI

/// 统一设置面板 — 科技感设计
struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
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
            .padding(16)

            Divider()

            TabView {
                ExportSettingsTab(model: model)
                    .tabItem {
                        Label("导出", systemImage: "square.and.arrow.down")
                    }
                UpdateSettingsTab(model: model)
                    .tabItem {
                        Label("更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                AboutTab(model: model)
                    .tabItem {
                        Label("关于", systemImage: "info.circle")
                    }
            }
            .padding(20)

            Divider()

            // Footer with version
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.subtleText)
                Text("WeChatExporter v\(model.currentVersion) (\(model.currentBuild))")
                    .font(AppTheme.monoFontSm)
                    .foregroundStyle(AppTheme.subtleText)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 540, height: 580)
    }
}

// MARK: - 导出设置

private struct ExportSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 导出内容
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出内容")
                            .font(.headline)
                    }

                    Toggle(isOn: $model.includeMedia) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("同时导出媒体文件")
                                .font(.body.weight(.medium))
                            Text("包含图片、表情、表情包等媒体并内嵌到 HTML（体积更大，耗时更长）")
                                .font(.caption)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(AppTheme.accent)
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

                    HStack {
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

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 更新设置

private struct UpdateSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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

            // 更新模式
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

            Spacer()

            Button("前往 GitHub Release 页面手动下载") {
                model.openReleaseInBrowser()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.headerGradient)
                    .frame(width: 96, height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.accentGlow, radius: 16, y: 6)

                Image(systemName: "message.and.waveform.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
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

            // Quick guide
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    GuideStep(number: 1, text: "首次使用点击「准备数据」（会重启微信）")
                    GuideStep(number: 2, text: "在左侧列表中选择一个或多个联系人")
                    GuideStep(number: 3, text: "点击「导出选中」生成 HTML 文件")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

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
        }
        .frame(maxWidth: .infinity)
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
            .frame(width: 80, height: 50)
            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
    }
}
