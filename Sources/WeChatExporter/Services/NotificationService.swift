import Foundation
import UserNotifications

/// 系统通知服务 — 用于更新完成后的横幅提示（点击横幅即可重启安装）
enum NotificationService {
    private static let updateCategoryID = "WECHAT_EXPORTER_UPDATE"

    /// 启动时注册通知类别并请求授权
    static func setup() {
        // 注册"更新就绪"通知类别，点击通知触发重启安装
        let restartAction = UNNotificationAction(
            identifier: "restart_install",
            title: "重启并安装",
            options: [.foreground]
        )
        let laterAction = UNNotificationAction(
            identifier: "later",
            title: "稍后",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: updateCategoryID,
            actions: [restartAction, laterAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            // 不强制用户授权；拒绝时静默降级为应用内提示
        }
    }

    /// 是否已授权
    static var isAuthorized: Bool {
        var authorized = false
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            authorized = settings.authorizationStatus == .authorized
            semaphore.signal()
        }
        semaphore.wait()
        return authorized
    }

    /// 发送"更新已就绪"横幅通知
    static func postUpdateReady(version: String, tagName: String) {
        let content = UNMutableNotificationContent()
        content.title = "微信聊天记录导出 有新版本"
        content.body = "v\(version) 已下载完成，点击重启即可完成更新。"
        content.sound = .default
        content.categoryIdentifier = updateCategoryID
        content.userInfo = ["update_version": version, "update_tag": tagName]

        let request = UNNotificationRequest(
            identifier: "wechat-exporter-update-\(version)",
            content: content,
            trigger: nil // 立即显示
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 处理通知点击 / 动作（由 AppDelegate 转发）
    static func handleResponse(_ response: UNNotificationResponse) {
        let center = UNUserNotificationCenter.current()
        // 移除已展示的通知
        center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])

        switch response.actionIdentifier {
        case "restart_install", UNNotificationDefaultActionIdentifier:
            // 用户点击横幅 → 立即重启安装
            Task { @MainActor in
                try? UpdateService.shared.applyPendingInstall()
            }
        default:
            // "稍后"或直接关闭：保留待安装记录，下次启动自动应用
            break
        }
    }
}
