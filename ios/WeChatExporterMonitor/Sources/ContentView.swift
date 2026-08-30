import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("概览", systemImage: "gauge") }
            LogsView()
                .tabItem { Label("报错日志", systemImage: "doc.text.magnifyingglass") }
            FixesView()
                .tabItem { Label("修复进度", systemImage: "wrench.and.screwdriver") }
            HermesView()
                .tabItem { Label("Hermes", systemImage: "brain") }
        }
        .task { await store.loadAll() }
    }
}
