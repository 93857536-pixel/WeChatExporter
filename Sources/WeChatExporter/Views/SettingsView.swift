import SwiftUI

/// 统一设置面板 — 包含导出设置、更新设置、关于三个标签页
struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                ExportSettingsTab(model: model)
                    .tabItem {
                        Label("导出设置", systemImage: "square.and.arrow.down")
                    }
                UpdateSettingsTab(model: model)
                    .tabItem {
                        Label("更新设置", systemImage: "arrow.triangle.2.circlepath")
                    }
                AboutTab(model: model)
                    .tabItem {
                        Label("关于", systemImage: "info.circle")
                    }
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
            Text("设置")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("完成") {
                model.showSettings = false
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text("v\(model.currentVersion) (Build \(model.currentBuild))")
                .font(.caption)
                .foregroundStyle(AppTheme.subtleText)
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - 导出设置

private struct ExportSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 导出内容
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("导出内容", systemImage: "doc.text")
                        .font(.headline)

                    Toggle(isOn: $model.includeMedia) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("同时导出媒体文件")
                                .font(.body)
                            Text("包含图片、表情、表情包等媒体并内嵌到 HTML（体积更大，耗时更长）")
                                .font(.caption)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(4)
            }

            // 导出目录
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("导出目录", systemImage: "folder.fill")
                        .font(.headline)

                    HStack {
                        TextField("导出路径", text: $model.exportPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { model.chooseExportFolder() }
                        Button("打开") { model.openExportFolder() }
                    }

                    Text("导出的聊天记录将保存到此目录")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }
                .padding(4)
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
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前版本")
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("v\(model.currentVersion) (Build \(model.currentBuild))")
                            .font(.body.weight(.medium))
                    }
                    if let lastCheck = model.lastCheckDate {
                        HStack {
                            Text("上次检查时间")
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text(lastCheck.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                }
                .padding(4)
            }

            // 更新模式
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("更新方式")
                        .font(.headline)

                    ForEach(UpdateMode.allCases, id: \.self) { mode in
                        HStack(alignment: .top, spacing: 12) {
                            RadioButton(
                                isSelected: model.updateMode == mode,
                                action: { model.changeUpdateMode(mode) }
                            )
                            VStack(alignment: .leading, spacing: 2) {
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
                .padding(4)
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
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }

                Spacer()
            }

            // 下载进度
            if model.isDownloadingUpdate, let progress = model.updateDownloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                    HStack {
                        Text(progress.formattedProgress)
                            .font(.caption)
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.subtleText)
                    }
                }
            }

            // 安装中提示
            if model.isInstallingUpdate {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装更新，应用将自动重启…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }

            Spacer()

            // 前往 Release 页面
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

            // 应用图标
            Image(systemName: "message.and.waveform.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(AppTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 8) {
                Text("微信聊天记录导出")
                    .font(.title2.weight(.semibold))
                Text("v\(model.currentVersion) (Build \(model.currentBuild))")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.subtleText)
            }

            VStack(alignment: .leading, spacing: 10) {
                AboutRow(icon: "1.circle.fill", title: "准备数据", desc: "首次使用点击「准备数据」（会重启微信）")
                AboutRow(icon: "2.circle.fill", title: "选择联系人", desc: "在左侧列表中选择一个或多个联系人")
                AboutRow(icon: "3.circle.fill", title: "导出", desc: "点击「导出选中」生成 HTML 文件")
            }
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            // 环境要求提示
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("环境要求", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text("• macOS 需关闭 SIP（恢复模式执行 csrutil disable）")
                    Text("• 需启用 DevToolsSecurity（软件可自动检测并启用）")
                    Text("• 支持微信 4.1.7 – 4.1.11")
                    Text("• Windows 需安装 .NET 8 运行时")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("GitHub 仓库") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)

                Button("问题反馈") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)

                Button("Release 下载") {
                    model.openReleaseInBrowser()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AboutRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(AppTheme.subtleText)
            }
            Spacer()
        }
    }
}
