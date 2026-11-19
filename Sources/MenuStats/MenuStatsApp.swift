import SwiftUI

@main
struct MenuStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
    }

    // The menu bar item and panel are managed by StatusItemController; SwiftUI needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = StatusItemController(monitor: SystemMonitor())
            Updater.shared.start()
        }
    }
}
