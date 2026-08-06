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
