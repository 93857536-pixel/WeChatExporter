import SwiftUI

/// 更新设置面板
struct UpdateSettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                Text("更新设置")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            // 当前版本信息
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
                            Text("上次检查")
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

            // 更新模式选择
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

            // 手动检查按钮
            HStack(spacing: 12) {
                Button {
                    model.checkForUpdatesManually()
                } label: {
                    Label("检查更新", systemImage: "magnifyingglass.circle.fill")
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

                Button("前往 Release 页面") {
                    model.openReleaseInBrowser()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 460, height: 460)
    }
}

/// 单选按钮组件
struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// 更新通知弹窗
struct UpdateNotificationSheet: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let info = model.availableUpdate {
                // 发现新版本
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .font(.title)
                            .foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现新版本")
                                .font(.title2.weight(.semibold))
                            Text("v\(info.version)（当前 v\(model.currentVersion)）")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }

                    // 发布日期
                    Text("发布于 \(info.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)

                    // 更新说明
                    if !info.releaseNotes.isEmpty && info.releaseNotes != "无更新说明" {
                        ScrollView {
                            Text(info.releaseNotes)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                        .padding(8)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 8))
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

                    // 安装中
                    if model.isInstallingUpdate {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在安装更新，应用将自动重启…")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                }

                // 操作按钮
                if !model.isDownloadingUpdate && !model.isInstallingUpdate {
                    HStack(spacing: 12) {
                        Button("下载并安装") {
                            Task { await model.downloadAndInstallUpdate(info) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)

                        Button("浏览器打开") {
                            model.openReleaseInBrowser()
                        }

                        Spacer()

                        Button("跳过此版本") {
                            model.skipUpdate()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppTheme.subtleText)

                        Button("稍后") {
                            model.showUpdateSheet = false
                        }
                    }
                }
            } else if let message = model.updateCheckMessage {
                // 已是最新版本 / 检查失败
                VStack(spacing: 16) {
                    Image(systemName: message.contains("最新") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(message.contains("最新") ? AppTheme.accent : .orange)

                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)

                    Button("好的") {
                        model.showUpdateSheet = false
                        model.updateCheckMessage = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
