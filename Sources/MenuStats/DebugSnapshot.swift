#if DEBUG
import SwiftUI

/// `MenuStats --snapshot <dir>` (debug builds only) renders the menu bar label
/// and the panel to PNGs, for checking the layout without clicking the status item.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        if args.contains("--icon") {
            let renderer = ImageRenderer(content: AppIconArt())
            renderer.scale = 1
            if let cg = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("AppIcon-1024.png"))
            }
            exit(0)
        }
        if args.contains("--dump-system-data") {
            let scanner = SystemDataScanner()
            scanner.scan()
            while scanner.scanning || scanner.scannedAt == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
            for item in scanner.items.prefix(25) { print(Fmt.bytes(item.size), "|", item.name, "|", item.kind.rawValue) }
            print("pending update:", scanner.pendingUpdate, "snapshots:", scanner.localSnapshots)
            exit(0)
        }
        if args.contains("--dump-cleanup") {
            Task {
                for app in await Cleanup.unusedApps() {
                    print("app", app.name, app.lastUsed.map { "\($0)" } ?? "never", app.size.map(Fmt.bytes) ?? "?", app.isAppStore ? "MAS" : "")
                }
                for cache in Cleanup.developerCaches {
                    print("cache", cache.title, await Cleanup.size(of: cache).map(Fmt.bytes) ?? "?")
                }
                for usage in await Docker.diskUsage() ?? [] {
                    print("docker", usage.title, Fmt.bytes(usage.reclaimableBytes))
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        let monitor = SystemMonitor()
        monitor.panelVisible = true
        RunLoop.main.run(until: Date().addingTimeInterval(9))

        if args.contains("--worst-net") {
            var worst = monitor.snapshot
            worst.netIn = 999_000 / 8
            worst.netOut = 9_900_000_000 / 8
            let bars = VStack(alignment: .leading, spacing: 4) {
                ForEach(BarStyle.allCases) { style in
                    CompactStats(snapshot: worst, style: style,
                                 items: BarItems(network: true, gpu: true, temperature: true, power: true), showGauges: true)
                }
            }
            .padding(6)
            .background(Color(white: 0.85))
            write(bars, to: dir.appendingPathComponent("bar-worst.png"), scale: 4)
            exit(0)
        }

        for style in BarStyle.allCases {
            let bars = VStack(alignment: .leading, spacing: 4) {
                ForEach([false, true], id: \.self) { disk in
                    CompactStats(snapshot: monitor.snapshot, style: style,
                                 items: BarItems(network: true, disk: disk, gpu: disk, temperature: disk, power: disk),
                                 showGauges: true)
                }
            }
            .padding(6)
            .background(Color(white: 0.85))
            write(bars, to: dir.appendingPathComponent("bar-\(style.rawValue).png"), scale: 4)
        }

        // ImageRenderer can't draw ScrollView contents, so each tab is rendered on its own.
        let tabs: [(String, AnyView)] = [
            ("overview", AnyView(OverviewTab(monitor: monitor))),
            ("processes", AnyView(ProcessesTab(monitor: monitor))),
            ("cleanup", AnyView(CleanupTab(monitor: monitor))),
            ("settings", AnyView(SettingsTab())),
        ]
        for (name, view) in tabs {
            let panel = view
                .padding(12)
                .fixedSize()
                .background(Color(white: 0.16))
                .environment(\.colorScheme, .dark)
            write(panel, to: dir.appendingPathComponent("tab-\(name).png"), scale: 2)
        }
        exit(0)
    }

    private static func write(_ view: some View, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }
}
#endif
