import SwiftUI

// MARK: - Cleanup

struct CleanupTab: View {
    enum SizeState: Equatable {
        case loading
        case known(UInt64)
        case unknown
    }

    @ObservedObject var monitor: SystemMonitor
    @State private var sizes: [String: SizeState] = [:]
    @State private var busy: Set<String> = []
    @State private var hasFullDiskAccess = Cleanup.hasFullDiskAccess
    @State private var targets = Cleanup.targets
    @State private var devCaches = Cleanup.developerCaches

    private var s: Snapshot { monitor.snapshot }

    var body: some View {
        AdaptiveColumns {
            if !hasFullDiskAccess {
                FullDiskAccessHint { recheck() }
            }
            Card(title: "Free up space", symbol: "sparkles", tint: .indigo,
                 value: "\(Fmt.bytes(s.diskFree)) free") {
                SegmentedBar(segments: [(s.diskFraction, s.diskFraction > 0.9 ? .red : .indigo)])
                VStack(spacing: 8) {
                    ForEach(targets) { target in
                        CleanupRow(target: target, size: sizes[target.id] ?? .loading,
                                   busy: busy.contains(target.id)) {
                            clean(target)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if !devCaches.isEmpty {
                Card(title: "Developer caches", symbol: "hammer.fill", tint: .orange, value: nil) {
                    VStack(spacing: 8) {
                        ForEach(devCaches) { target in
                            CleanupRow(target: target, size: sizes[target.id] ?? .loading,
                                       busy: busy.contains(target.id)) {
                                clean(target)
                            }
                        }
                    }
                    Text("These download again the next time a project needs them.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            // Space map sits on the shorter side so it has room to grow after a scan.
            SpaceMapCard(map: monitor.spaceMap)
        } right: {
            if Docker.cli != nil { DockerCleanupCard(monitor: monitor) }
            UnusedAppsCard(monitor: monitor)
            SystemDataCard(scanner: monitor.systemData)
        }
        .task { recheck() }
    }

    /// Re-reads the permission (it can change while the app runs) and re-measures everything.
    private func recheck() {
        hasFullDiskAccess = Cleanup.hasFullDiskAccess
        targets = Cleanup.targets
        devCaches = Cleanup.developerCaches
        sizes = [:]
        Task { await measureAll() }
    }

    private func measureAll() async {
        await withTaskGroup(of: (String, SizeState).self) { group in
            for target in targets + devCaches {
                group.addTask { (target.id, await Self.measure(target)) }
            }
            for await (id, size) in group { sizes[id] = size }
        }
    }

    private static func measure(_ target: CleanupTarget) async -> SizeState {
        guard let bytes = await Cleanup.size(of: target) else { return .unknown }
        return .known(bytes)
    }

    private func clean(_ target: CleanupTarget) {
        busy.insert(target.id)
        Task {
            await Cleanup.clean(target)
            sizes[target.id] = await Self.measure(target)
            busy.remove(target.id)
            monitor.refreshDisk()
        }
    }
}

struct FullDiskAccessHint: View {
    let recheck: () -> Void

    var body: some View {
        Card(title: "Full Disk Access is off", symbol: "lock.shield", tint: .orange, value: nil) {
            Text("Turn it on to see the Trash size, empty it without asking Finder, and clean caches inside App Store apps.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("In Settings, switch on MenuStats (or click + and choose it in Applications), then restart MenuStats.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { Cleanup.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Check again", action: recheck)
                    .buttonStyle(.bordered)
                Button("Restart") { Cleanup.relaunch() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
    }
}

struct CleanupRow: View {
    let target: CleanupTarget
    let size: CleanupTab.SizeState
    let busy: Bool
    let action: () -> Void

    private var isEmpty: Bool { size == .known(0) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: target.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title).font(.system(size: 11, weight: .medium))
                Text(target.detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            switch size {
            case .loading: ProgressView().controlSize(.mini)
            case .known(let bytes): Text(Fmt.bytes(bytes)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            case .unknown: Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ConfirmButton(title: target.buttonTitle, confirmTitle: target.confirmTitle,
                          busy: busy, disabled: isEmpty, action: action)
        }
    }
}

/// A button that needs a second click within 3 seconds, for actions that delete things.
// MARK: - Cleanup extras

struct DockerCleanupCard: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var usage: [DockerDiskUsage]?
    @State private var loading = true
    @State private var busy: Set<String> = []

    var body: some View {
        let reclaimable = usage?.reduce(0) { $0 + $1.reclaimableBytes } ?? 0
        Card(title: "Docker cleanup", symbol: "shippingbox.fill", tint: .blue,
             value: usage == nil ? nil : "\(Fmt.bytes(reclaimable)) freeable") {
            if loading && usage == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if let usage {
                VStack(spacing: 8) {
                    ForEach(usage) { item in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 11, weight: .medium))
                                Text(item.detail).font(.system(size: 10))
                                    .foregroundStyle(item.type == "Local Volumes" ? Color.orange : Color.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(Fmt.bytes(item.reclaimableBytes))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                            ConfirmButton(title: "Remove", confirmTitle: "Delete forever",
                                          busy: busy.contains(item.id), disabled: item.reclaimableBytes == 0) {
                                busy.insert(item.id)
                                Task {
                                    await Docker.prune(item)
                                    await load()
                                    busy.remove(item.id)
                                    monitor.refreshDisk()
                                }
                            }
                        }
                    }
                }
                Text("Docker Desktop hands freed space back to macOS gradually.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Docker isn't running, so its disk use can't be read.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        usage = await Docker.diskUsage()
        loading = false
    }
}

struct UnusedAppsCard: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage(Prefs.unusedAppDaysKey) private var days = 90
    @State private var apps: [UnusedApp]?
    @State private var busy: Set<String> = []
    @State private var failed: Set<String> = []

    var body: some View {
        let total = apps?.reduce(0) { $0 + ($1.size ?? 0) } ?? 0
        Card(title: "Unused apps", symbol: "app.badge.clock", tint: .purple,
             value: apps.map { $0.isEmpty ? nil : Fmt.bytes(total) } ?? nil) {
            if let apps {
                if apps.isEmpty {
                    Text("Every app was used in the last \(Prefs.describe(days: days)).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not opened in \(Prefs.describe(days: days)) or more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(apps.prefix(8)) { row($0) }
                    }
                    if apps.count > 8 {
                        Text("+ \(apps.count - 8) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .task(id: days) {
            apps = nil
            apps = await Cleanup.unusedApps(olderThan: days)
        }
    }

    private func row(_ app: UnusedApp) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(app.name).fontWeight(.medium).lineLimit(1)
                    if app.isAppStore {
                        Text("App Store").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(failed.contains(app.id) ? "Needs your password: drag it to the Trash in Finder"
                     : app.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "No recorded use")
                    .font(.system(size: 10))
                    .foregroundStyle(failed.contains(app.id) ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let size = app.size {
                Text(Fmt.bytes(size)).fontWeight(.medium).monospacedDigit()
            }
            if failed.contains(app.id) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else {
                ConfirmButton(title: "Trash", confirmTitle: "Confirm", busy: busy.contains(app.id)) {
                    busy.insert(app.id)
                    Task {
                        if await Cleanup.trash(app) {
                            apps?.removeAll { $0.id == app.id }
                            monitor.refreshDisk()
                        } else {
                            failed.insert(app.id)
                        }
                        busy.remove(app.id)
                    }
                }
            }
        }
        .font(.system(size: 11))
    }
}

struct SpaceMapCard: View {
    @ObservedObject var map: SpaceMap

    var body: some View {
        Card(title: "Space map", symbol: "chart.bar.doc.horizontal", tint: .teal, value: nil) {
            breadcrumb
            if map.scanning == map.current.path {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning \(map.current == map.root ? "your home folder, about a minute" : map.current.lastPathComponent)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if !map.hasScanned {
                Button("Scan home folder") { map.scan() }
                    .controlSize(.small)
            } else {
                let entries = Array(map.entries.prefix(10))
                let largest = entries.first?.size ?? 1
                VStack(spacing: 5) {
                    ForEach(entries) { entry in
                        SpaceRow(entry: entry, fraction: Double(entry.size) / Double(largest)) {
                            if entry.isFolder { map.open(entry.url) }
                        }
                    }
                }
            }
        }
    }

    private var breadcrumb: some View {
        let relative = map.current.path.replacingOccurrences(of: map.root.path, with: "")
        let parts = relative.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            if map.current != map.root {
                Button { map.open(map.current.deletingLastPathComponent()) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Up one folder")
            }
            Text((["~"] + parts).joined(separator: " › "))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let total = map.sizes[map.current.path] {
                Text(Fmt.bytes(total)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if map.hasScanned, map.scanning == nil {
                Button { map.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Scan again")
            }
        }
    }
}

struct SpaceRow: View {
    let entry: SpaceEntry
    let fraction: Double
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isFolder ? "folder.fill" : "doc.on.doc")
                .foregroundStyle(entry.isFolder ? Color.teal : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(entry.size)).fontWeight(.medium).monospacedDigit()
                }
                GeometryReader { geo in
                    Capsule().fill(Color.teal.gradient)
                        .frame(width: max(2, geo.size.width * fraction))
                }
                .frame(height: 3)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.3)
            .help("Show in Finder")
        }
        .font(.system(size: 11))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(entry.isFolder ? "Click to look inside" : "")
    }
}

struct SystemDataCard: View {
    @ObservedObject var scanner: SystemDataScanner
    @State private var showAll = false

    var body: some View {
        let total = scanner.items.reduce(0) { $0 + $1.size }
        Card(title: "System Data", symbol: "externaldrive.fill.badge.questionmark", tint: .gray,
             value: scanner.scannedAt == nil ? nil : Fmt.bytes(total)) {
            if scanner.pendingUpdate {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("A downloaded macOS update is waiting. Installing it frees its space.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Software Update") { SystemDataScanner.openSoftwareUpdate() }
                        .controlSize(.small)
                }
                .font(.system(size: 11))
            }
            if scanner.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring app data and hidden folders, about a minute…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if scanner.scannedAt == nil {
                Text("macOS lumps app data, hidden folders, virtual machines and caches into System Data. Find out what's in yours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Analyze System Data") { scanner.scan() }
                    .controlSize(.small)
            } else {
                let items = showAll ? scanner.items : Array(scanner.items.prefix(10))
                let largest = scanner.items.first?.size ?? 1
                VStack(spacing: 5) {
                    ForEach(items) { item in
                        SystemDataRow(item: item, fraction: Double(item.size) / Double(largest))
                    }
                }
                HStack {
                    if scanner.items.count > 10 {
                        Button(showAll ? "Show less" : "Show all \(scanner.items.count)") { showAll.toggle() }
                            .buttonStyle(.borderless)
                    }
                    if scanner.localSnapshots > 0 {
                        Text("\(scanner.localSnapshots) Time Machine snapshot\(scanner.localSnapshots == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { scanner.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Measure again")
                }
                .font(.system(size: 10))
                Text("Delete large items from inside their app where you can (models, bottles, VMs). Shown: items over 100 MB.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SystemDataRow: View {
    let item: SystemDataItem
    let fraction: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Text(item.isLeftover ? "Leftover" : item.kind.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(item.isLeftover ? Color.orange : Color.secondary)
                        .help(item.isLeftover ? "Its app is no longer installed, so this is usually safe to delete" : "")
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.primary.opacity(0.07)))
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(item.size)).fontWeight(.medium).monospacedDigit()
                }
                GeometryReader { geo in
                    Capsule().fill(Color.gray.gradient)
                        .frame(width: max(2, geo.size.width * fraction))
                }
                .frame(height: 3)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.3)
            .help("Show in Finder")
        }
        .font(.system(size: 11))
        .onHover { hovering = $0 }
    }
}
