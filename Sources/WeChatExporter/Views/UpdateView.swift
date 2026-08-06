import SwiftUI

/// 更新设置面板（旧版独立面板，保留兼容）
struct UpdateSettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                Text("更新设置")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            TechCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前版本")
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("v\(model.currentVersion) (Build \(model.currentBuild))")
                            .font(AppTheme.monoFont.weight(.medium))
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

            TechCard {
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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

/// 更新通知弹窗 — 科技感设计
struct UpdateNotificationSheet: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let info = model.availableUpdate {
                // 发现新版本
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.headerGradient)
                                .frame(width: 48, height: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                                )
                                .shadow(color: AppTheme.accentGlow, radius: 8, y: 3)
                            Image(systemName: "sparkles")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现新版本")
                                .font(.title2.weight(.bold))
                            HStack(spacing: 6) {
                                Text("v\(info.version)")
                                    .font(AppTheme.monoFont.weight(.bold))
                                    .foregroundStyle(AppTheme.accent)
                                Text("（当前 v\(model.currentVersion)）")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.subtleText)
                            }
                        }
                    }

                    // 发布日期
                    HStack {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text("发布于 \(info.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(AppTheme.monoFontSm)
                    }
                    .foregroundStyle(AppTheme.subtleText)

                    // 更新说明 — terminal style
                    if !info.releaseNotes.isEmpty && info.releaseNotes != "无更新说明" {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                HStack(spacing: 5) {
                                    Circle().fill(Color.red.opacity(0.7)).frame(width: 8, height: 8)
                                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 8, height: 8)
                                    Circle().fill(Color.green.opacity(0.7)).frame(width: 8, height: 8)
                                }
                                Text("changelog")
                                    .font(AppTheme.monoFontSm)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.08, green: 0.10, blue: 0.14))

                            ScrollView {
                                Text(info.releaseNotes)
                                    .font(AppTheme.monoFont)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 140)
                            .padding(12)
                            .background(AppTheme.logGradient)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                        )
                    }

                    // 下载进度
                    if model.isDownloadingUpdate, let progress = model.updateDownloadProgress {
                        VStack(alignment: .leading, spacing: 6) {
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
                    }

                    // 安装中
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
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(message.contains("最新") ? AppTheme.success.opacity(0.15) : AppTheme.warning.opacity(0.15))
                            .frame(width: 80, height: 80)
                        Image(systemName: message.contains("最新") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(message.contains("最新") ? AppTheme.success : AppTheme.warning)
                    }

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
