import AppKit
import SwiftUI

@main
struct WeChatExporterApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}

            // 检查更新菜单项
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    model.checkForUpdatesManually()
                }
                .keyboardShortcut("U", modifiers: .command)

                Button("更新设置…") {
                    model.showUpdateSettings = true
                }
                .keyboardShortcut("U", modifiers: [.command, .option])
            }
        }
    }
}
