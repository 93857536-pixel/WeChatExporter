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
