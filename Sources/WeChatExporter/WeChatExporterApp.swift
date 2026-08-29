import AppKit
import SwiftUI
import UserNotifications

@main
struct WeChatExporterApp: App {
    @StateObject private var model = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .sheet(isPresented: $model.showConsent) {
                    ConsentSheet(model: model)
                        .interactiveDismissDisabled(true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}

            // 设置菜单项
            CommandGroup(after: .appInfo) {
                Button("设置…") {
                    model.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("检查更新…") {
                    model.checkForUpdatesManually()
                }
                .keyboardShortcut("U", modifiers: .command)
            }
        }
    }
}

/// 应用代理：处理系统通知点击与启动时应用待安装更新
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册通知中心代理并设置通知类别 / 请求授权
        UNUserNotificationCenter.current().delegate = self
        NotificationService.setup()

        // 启动时若有待安装更新，自动应用（实现"下次启动自动更新"）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.applyPendingUpdateIfNeeded()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NotificationService.handleResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 应用在前台时也显示横幅通知
        completionHandler([.banner, .sound])
    }

    private func applyPendingUpdateIfNeeded() {
        guard UpdatePreferences.hasPendingInstall else { return }
        do {
            try UpdateService.shared.applyPendingInstall()
        } catch {
            UpdateService.clearPendingInstall()
        }
    }
}

/// 首次启动的「诊断日志上传」条款弹窗
private struct ConsentSheet: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 标题
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("诊断日志上传")
                    .font(.title3.weight(.bold))
            }

            // 正文
            VStack(alignment: .leading, spacing: 14) {
                Text("为了让导出工具越来越稳定，当导出过程中发生错误时，本应用可以自动将以下诊断信息发送到开发者服务器：")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Label("应用版本与操作系统版本", systemImage: "circle.fill")
                    Label("错误消息与错误发生时的操作步骤", systemImage: "circle.fill")
                    Label("程序运行日志的最后部分", systemImage: "circle.fill")
                }
                .font(.body)
                .foregroundStyle(.primary)

                Text("这些信息仅包含技术诊断数据，不包含你的聊天内容、联系人信息、账号信息或任何个人隐私数据。")
                    .font(.body)
                    .foregroundStyle(AppTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Label("同意：导出报错时自动上传诊断信息，用于开发者分析并修复问题", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                    Label("不同意：应用功能完全不受影响，任何情况下都不会上传任何数据", systemImage: "minus.circle")
                        .foregroundStyle(AppTheme.subtleText)
                }
                .font(.body)

                Text("你随时可以在「设置」中更改此选项。")
                    .font(.body)
                    .foregroundStyle(AppTheme.subtleText)
            }

            // 按钮
            HStack {
                Button("不同意") {
                    model.setDiagnosticsConsent(false)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button("同意并继续") {
                    model.setDiagnosticsConsent(true)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
