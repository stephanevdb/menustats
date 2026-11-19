import AppKit
import CoreServices

struct CleanupTarget: Identifiable, Equatable {
    enum Action: Equatable {
        /// Empties the Trash: directly with Full Disk Access, otherwise through Finder.
        case emptyTrash
        /// Permanently deletes the folder's contents; apps rebuild these on demand.
        case deleteContents
        /// Deletes the Caches folder inside every sandboxed app's container.
        case deleteContainerCaches
        /// Moves the folder's contents to the Trash, so it can be undone.
        case moveContentsToTrash
        /// Runs the tool's own cleanup command (executable path + arguments), e.g. `go clean -modcache`.
        case runCommand([String])
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let url: URL
    let action: Action

    var buttonTitle: String {
        switch action {
        case .emptyTrash: "Empty"
        case .deleteContents, .deleteContainerCaches, .runCommand: "Clear"
        case .moveContentsToTrash: "Move to Trash"
        }
    }

    var confirmTitle: String {
        switch action {
        case .moveContentsToTrash: "Confirm"
        default: "Delete forever"
        }
    }
}

enum Cleanup {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The Trash and Safari's folder are only readable with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        ["Library/Safari", ".Trash"].contains {
            (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent($0).path)) != nil
        }
    }

    /// Full Disk Access is often only picked up by a fresh process, so offer a quick relaunch.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static var targets: [CleanupTarget] {
        var targets = [
            CleanupTarget(id: "trash", title: "Trash", detail: "Permanently deleted",
                          symbol: "trash", url: home.appendingPathComponent(".Trash"), action: .emptyTrash),
            CleanupTarget(id: "caches", title: "App caches", detail: "Rebuilt by apps as needed",
                          symbol: "archivebox", url: home.appendingPathComponent("Library/Caches"),
                          action: .deleteContents),
            CleanupTarget(id: "logs", title: "Logs", detail: "Old app and crash logs",
                          symbol: "doc.text", url: home.appendingPathComponent("Library/Logs"),
                          action: .deleteContents),
            CleanupTarget(id: "downloads", title: "Downloads", detail: "Moved to Trash, restorable",
                          symbol: "arrow.down.circle", url: home.appendingPathComponent("Downloads"),
                          action: .moveContentsToTrash),
        ]
        // Without Full Disk Access, reading other apps' containers triggers a permission prompt per app.
        if hasFullDiskAccess {
            targets.insert(CleanupTarget(id: "containers", title: "Sandboxed app caches",
                                         detail: "Caches inside App Store app containers",
                                         symbol: "shippingbox", url: home.appendingPathComponent("Library/Containers"),
                                         action: .deleteContainerCaches), at: 2)
        }
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if FileManager.default.fileExists(atPath: derivedData.path) {
            targets.insert(CleanupTarget(id: "xcode", title: "Xcode build files", detail: "DerivedData, rebuilt on next build",
                                         symbol: "hammer", url: derivedData, action: .deleteContents),
                           at: targets.count - 1)
        }
        return targets
    }

    /// Allocated size of what `target` would clean, or nil if it can't be read.
    static func size(of target: CleanupTarget) async -> UInt64? {
        await Task.detached(priority: .utility) {
            guard target.action == .deleteContainerCaches else { return allocatedSize(of: target.url) }
            guard let caches = containerCaches(in: target.url) else { return nil }
            return caches.reduce(0) { $0 + (allocatedSize(of: $1) ?? 0) }
        }.value
    }

    private static func allocatedSize(of url: URL) -> UInt64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true })
        else { return nil }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// `<container>/Data/Library/Caches` for every app container that has one.
    private static func containerCaches(in containers: URL) -> [URL]? {
        guard let apps = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)
        else { return nil }
        return apps
            .map { $0.appendingPathComponent("Data/Library/Caches") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func clean(_ target: CleanupTarget) async {
        switch target.action {
        case .emptyTrash where !hasFullDiskAccess:
            await MainActor.run {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            }
        case .emptyTrash, .deleteContents, .moveContentsToTrash:
            await Task.detached(priority: .utility) {
                removeContents(of: target.url, toTrash: target.action == .moveContentsToTrash)
            }.value
        case .deleteContainerCaches:
            await Task.detached(priority: .utility) {
                for caches in containerCaches(in: target.url) ?? [] {
                    removeContents(of: caches, toTrash: false)
                }
            }.value
        case .runCommand(let command):
            guard let tool = command.first else { return }
            _ = await Shell.run(tool, Array(command.dropFirst()))
        }
    }

    private static func removeContents(of folder: URL, toTrash: Bool) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items {
            // Items in use or protected by macOS are skipped.
            if toTrash {
                try? fm.trashItem(at: item, resultingItemURL: nil)
            } else {
                try? fm.removeItem(at: item)
            }
        }
    }
}

// MARK: - Developer caches

extension Cleanup {
    /// Package-manager and build-tool caches that exist on this Mac. Each rebuilds itself on the next
    /// install or build. Tools with their own cleanup command use it (Go's module cache is read-only,
    /// pnpm's store is hard-linked into projects).
    static var developerCaches: [CleanupTarget] {
        let caches = home.appendingPathComponent("Library/Caches")
        func tool(_ name: String) -> String? {
            ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        var list: [CleanupTarget] = []
        func add(_ id: String, _ title: String, _ url: URL, _ action: CleanupTarget.Action = .deleteContents) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            list.append(CleanupTarget(id: "dev-\(id)", title: title, detail: url.path.replacingOccurrences(of: home.path, with: "~"),
                                      symbol: "shippingbox", url: url, action: action))
        }
        if let brew = tool("brew") {
            // brew cleanup also auto-removes unused packages unless told not to.
            add("brew", "Homebrew", caches.appendingPathComponent("Homebrew"),
                .runCommand(["/usr/bin/env", "HOMEBREW_NO_AUTOREMOVE=1", brew, "cleanup", "--prune=all", "-s"]))
        }
        add("npm", "npm", home.appendingPathComponent(".npm/_cacache"))
        if let pnpm = tool("pnpm") {
            add("pnpm", "pnpm", home.appendingPathComponent("Library/pnpm/store"), .runCommand([pnpm, "store", "prune"]))
        }
        add("yarn", "Yarn", caches.appendingPathComponent("Yarn"))
        add("bun", "Bun", home.appendingPathComponent(".bun/install/cache"))
        add("pip", "pip", caches.appendingPathComponent("pip"))
        add("cargo", "Cargo", home.appendingPathComponent(".cargo/registry"))
        if let go = tool("go") {
            add("go", "Go modules", home.appendingPathComponent("go/pkg/mod"), .runCommand([go, "clean", "-modcache"]))
        }
        add("gradle", "Gradle", home.appendingPathComponent(".gradle/caches"))
        add("maven", "Maven", home.appendingPathComponent(".m2/repository"))
        add("cocoapods", "CocoaPods", caches.appendingPathComponent("CocoaPods"))
        add("swiftpm", "Swift Package Manager", caches.appendingPathComponent("org.swift.swiftpm"))
        return list
    }
}

// MARK: - Unused apps

struct UnusedApp: Identifiable, Equatable {
    let url: URL
    let name: String
    let lastUsed: Date?
    let size: UInt64?
    let isAppStore: Bool
    var id: String { url.path }
}

extension Cleanup {
    /// Apps in /Applications not used for `days` days, biggest first. Apple's own apps,
    /// running apps and MenuStats are left out.
    static func unusedApps(olderThan days: Int = 90) async -> [UnusedApp] {
        return await Task.detached(priority: .utility) {
            // An app counts as in use if any process runs from inside it (VPN extensions, sync helpers).
            let running = runningExecutablePaths()
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let apps = URL(fileURLWithPath: "/Applications")
            let urls = (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            return urls
                .filter { app in
                    app.pathExtension == "app" && !running.contains { $0.hasPrefix(app.path + "/") }
                }
                .compactMap { url -> UnusedApp? in
                    guard let id = Bundle(url: url)?.bundleIdentifier,
                          !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier
                    else { return nil }
                    let lastUsed = lastUsedDate(of: url, bundleID: id)
                    if let lastUsed, lastUsed > cutoff { return nil }
                    // Without any recorded use, only flag apps installed before the cutoff.
                    if lastUsed == nil, let added = metadata(url, kMDItemDateAdded) as? Date, added > cutoff { return nil }
                    return UnusedApp(
                        url: url,
                        name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                        lastUsed: lastUsed,
                        size: (metadata(url, "kMDItemPhysicalSize" as CFString) as? NSNumber)?.uint64Value,
                        isAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
                    )
                }
                .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }.value
    }

    private static func runningExecutablePaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, found))).compactMap { pid in
            var buffer = [CChar](repeating: 0, count: 4096)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        }
    }

    /// Spotlight's last-used date misses apps opened some ways, so also look at when the app
    /// last wrote its preferences or data, and take the most recent.
    private static func lastUsedDate(of url: URL, bundleID: String) -> Date? {
        let library = home.appendingPathComponent("Library")
        let traces = [
            "Preferences/\(bundleID).plist", "Containers/\(bundleID)", "Application Support/\(bundleID)",
            "Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "Saved Application State/\(bundleID).savedState",
        ].map { library.appendingPathComponent($0) }
        let dates = traces.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return ([metadata(url, kMDItemLastUsedDate) as? Date] + dates).compactMap { $0 }.max()
    }

    private static func metadata(_ url: URL, _ key: CFString) -> Any? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, key)
    }

    /// Moves the app to the Trash; returns false if macOS refused (e.g. it needs an admin password).
    static func trash(_ app: UnusedApp) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([app.url]) { _, error in continuation.resume(returning: error == nil) }
        }
    }
}

// MARK: - Space map

struct SpaceEntry: Identifiable, Equatable {
    let url: URL
    let size: UInt64
    let isFolder: Bool
    var id: String { url.path }
    var name: String { isFolder ? url.lastPathComponent : "Files in this folder" }
}

/// Folder sizes from `du`, two levels at a time so the first drill-down is instant.
/// Results are kept for the app's lifetime; rescanning a folder refreshes it.
@MainActor
final class SpaceMap: ObservableObject {
    @Published private(set) var sizes: [String: UInt64] = [:]
    @Published private(set) var scanning: String?
    @Published var current = FileManager.default.homeDirectoryForCurrentUser

    var root: URL { FileManager.default.homeDirectoryForCurrentUser }
    var hasScanned: Bool { sizes[current.path] != nil }

    /// Biggest children of the current folder, plus loose files as one entry.
    var entries: [SpaceEntry] {
        guard let total = sizes[current.path] else { return [] }
        let prefix = current.path.hasSuffix("/") ? current.path : current.path + "/"
        let folders = sizes
            .filter { $0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/") }
            .map { SpaceEntry(url: URL(fileURLWithPath: $0.key), size: $0.value, isFolder: true) }
        let files = total - min(total, folders.reduce(0) { $0 + $1.size })
        let all = folders + (files > 1_000_000 ? [SpaceEntry(url: current, size: files, isFolder: false)] : [])
        return all.sorted { $0.size > $1.size }
    }

    func open(_ url: URL) {
        current = url
        // The two-level scan above covers one drill-down; go deeper with a fresh scan.
        let prefix = url.path + "/"
        if !sizes.keys.contains(where: { $0.hasPrefix(prefix) }) { scan() }
    }

    func scan() {
        guard scanning == nil else { return }
        let target = current
        scanning = target.path
        Task {
            let output = await Shell.run("/usr/bin/du", ["-k", "-d", "2", "-x", target.path]) ?? ""
            var found: [String: UInt64] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let kb = UInt64(parts[0]) else { continue }
                found[String(parts[1])] = kb * 1024
            }
            // Replace stale results under this folder.
            let prefix = target.path + "/"
            sizes = sizes.filter { $0.key != target.path && !$0.key.hasPrefix(prefix) }.merging(found) { $1 }
            scanning = nil
        }
    }
}

// MARK: - System Data

struct SystemDataItem: Identifiable, Equatable {
    enum Kind: String {
        case appData = "App data"
        case sandboxed = "App container"
        case shared = "Shared app data"
        case hidden = "Hidden folder"
        case developer = "Developer"
        case system = "macOS"
    }

    let url: URL
    let name: String
    let kind: Kind
    let size: UInt64
    /// Data belonging to an app that's no longer installed, usually safe to delete.
    var isLeftover = false
    var id: String { url.path }
}

/// Measures the places macOS counts as "System Data": app data under Library, sandboxed app
/// containers, hidden folders in the home folder, developer files and the sleep image.
/// Results are kept for the app's lifetime because a full scan takes a minute or two.
@MainActor
final class SystemDataScanner: ObservableObject {
    @Published private(set) var items: [SystemDataItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    /// A macOS update that has been downloaded and staged; installing it frees its space.
    @Published private(set) var pendingUpdate = false
    @Published private(set) var localSnapshots = 0

    private let home = FileManager.default.homeDirectoryForCurrentUser

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let library = home.appendingPathComponent("Library")
            async let appSupport = children(of: library.appendingPathComponent("Application Support"), kind: .appData)
            async let containers = children(of: library.appendingPathComponent("Containers"), kind: .sandboxed)
            async let groups = children(of: library.appendingPathComponent("Group Containers"), kind: .shared)
            async let hidden = hiddenFolders()
            async let developer = sizes(of: [library.appendingPathComponent("Developer")], kind: .developer)
            async let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])

            var all = await appSupport + containers + groups + hidden + developer
            if let sleep = Self.fileSize("/private/var/vm/sleepimage") {
                all.append(SystemDataItem(url: URL(fileURLWithPath: "/private/var/vm/sleepimage"),
                                          name: "Sleep image", kind: .system, size: sleep))
            }
            items = all.filter { $0.size > 100_000_000 }.sorted { $0.size > $1.size }

            let snapshotList = await snapshots ?? ""
            pendingUpdate = snapshotList.contains("MSUPrepareUpdate")
            localSnapshots = snapshotList.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
            scannedAt = Date()
            scanning = false
        }
    }

    /// Sizes of every item directly inside `folder`, from one `du` pass.
    private func children(of folder: URL, kind: SystemDataItem.Kind) async -> [SystemDataItem] {
        guard let output = await Shell.run("/usr/bin/du", ["-k", "-d", "1", "-x", folder.path]) else { return [] }
        return parse(output, kind: kind).filter { $0.url.path != folder.path }
    }

    private func sizes(of urls: [URL], kind: SystemDataItem.Kind) async -> [SystemDataItem] {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty,
              let output = await Shell.run("/usr/bin/du", ["-sk", "-x"] + existing.map(\.path))
        else { return [] }
        return parse(output, kind: kind)
    }

    private func hiddenFolders() async -> [SystemDataItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let hidden = names
            .filter { $0.hasPrefix(".") && $0 != ".Trash" }
            .map { home.appendingPathComponent($0) }
        return await sizes(of: hidden, kind: .hidden)
    }

    private func parse(_ output: String, kind: SystemDataItem.Kind) -> [SystemDataItem] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = UInt64(parts[0]) else { return nil }
            let url = URL(fileURLWithPath: String(parts[1]))
            let (name, leftover) = Self.describe(url, kind: kind)
            return SystemDataItem(url: url, name: name, kind: kind, size: kb * 1024, isLeftover: leftover)
        }
    }

    private static let knownHidden = [
        ".lmstudio": "LM Studio models", ".ollama": "Ollama models", ".cache": "Tool caches (.cache)",
        ".local": "Local tools (.local)", ".nvm": "Node versions (nvm)", ".rustup": "Rust toolchains",
        ".cargo": "Cargo (Rust)", ".npm": "npm", ".gradle": "Gradle", ".m2": "Maven", ".bun": "Bun",
        ".cursor": "Cursor extensions", ".vscode": "VS Code extensions", ".docker": "Docker",
        ".orbstack": "OrbStack", ".android": "Android SDK", ".conda": "Conda", ".pyenv": "Python versions (pyenv)",
        ".nuget": "NuGet packages (.NET)", ".gemini": "Gemini CLI", ".claude": "Claude Code", ".codex": "Codex CLI",
    ]

    /// A readable name (e.g. a container's app name), and whether its app is gone.
    private static func describe(_ url: URL, kind: SystemDataItem.Kind) -> (String, Bool) {
        let folder = url.lastPathComponent
        switch kind {
        case .hidden:
            return (knownHidden[folder] ?? "~/\(folder)", false)
        case .developer:
            return ("Xcode and developer files", false)
        case .sandboxed, .appData, .shared:
            // Group containers are "<team>.<id>"; containers and many support folders are bundle IDs.
            let id = kind == .shared ? folder.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder : folder
            guard id.contains("."), !id.hasPrefix("com.apple.") else { return (id, false) }
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return (FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), false)
            }
            // Only sandboxed containers are reliably named after their app's bundle ID.
            return (id, kind == .sandboxed)
        case .system:
            return (folder, false)
        }
    }

    private static func fileSize(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
    }

    static func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
