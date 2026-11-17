import SwiftUI

@main
struct MenuStatsApp: App {
    @StateObject private var monitor = SystemMonitor()

    init() {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            StatsPanel(monitor: monitor)
        } label: {
            MenuBarLabel(state: monitor.bar)
        }
        .menuBarExtraStyle(.window)
    }
}
