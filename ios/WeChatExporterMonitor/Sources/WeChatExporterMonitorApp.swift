import SwiftUI

@main
struct WeChatExporterMonitorApp: App {
    @StateObject private var store = MonitorStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
