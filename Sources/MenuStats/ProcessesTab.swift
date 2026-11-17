import SwiftUI

// MARK: - Processes

struct ProcessesTab: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage("processes.grouped") private var grouped = true

    var body: some View {
        let entries = ProcessEntry.make(processes: monitor.processes, io: monitor.processIO,
                                        bandwidth: monitor.bandwidth, grouped: grouped)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        AdaptiveColumns {
            ForceQuitAllButton()
            Picker("Show", selection: $grouped) {
                Text("By app").tag(true)
                Text("By process").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("By app adds each app's helper processes into one row")
            if !monitor.frozenApps.isEmpty { FrozenAppsCard(pids: monitor.frozenApps) }
            if monitor.processes.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                EntryListCard(title: "Top CPU", symbol: "cpu", tint: .blue,
                              entries: top(entries, 7) { $0.cpu }) {
                    // ps reports percent of one core; show share of the whole CPU like the menu bar does.
                    String(format: "%.1f%%", $0.cpu / cores)
                }
                EntryListCard(title: "Top memory", symbol: "memorychip", tint: .purple,
                              entries: top(entries, 7) { Double($0.memory) }) {
                    Fmt.bytes($0.memory)
                }
                EntryListCard(title: "Top energy", symbol: "bolt.fill", tint: .yellow,
                              entries: top(entries, 4) { $0.energy },
                              footnote: "Your apps only; macOS hides system processes' energy without admin rights.") {
                    Fmt.watts($0.energy)
                }
            }
        } right: {
            ProcessSearchCard(processes: monitor.processes)
            ListeningPortsCard(ports: monitor.listeningPorts)
            EntryListCard(title: "Top network", symbol: "network", tint: .teal,
                          entries: top(entries, 5) { $0.network },
                          empty: "No network activity right now") {
                "↓\(Fmt.rate($0.netIn, compact: true))  ↑\(Fmt.rate($0.netOut, compact: true))"
            }
            EntryListCard(title: "Top disk", symbol: "internaldrive", tint: .indigo,
                          entries: top(entries, 5) { $0.disk },
                          empty: "No disk activity from your apps right now") {
                "R \(Fmt.throughput($0.diskRead))  W \(Fmt.throughput($0.diskWrite))"
            }
            if Docker.cli != nil { DockerCard(monitor: monitor) }
        }
    }

    /// The `count` entries with the highest non-zero `metric`.
    private func top(_ entries: [ProcessEntry], _ count: Int, by metric: (ProcessEntry) -> Double) -> [ProcessEntry] {
        Array(entries.filter { metric($0) > 0 }.sorted { metric($0) > metric($1) }.prefix(count))
    }
}

struct EntryListCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let entries: [ProcessEntry]
    var footnote: String?
    var empty: String?
    let value: (ProcessEntry) -> String

    var body: some View {
        Card(title: title, symbol: symbol, tint: tint, value: nil) {
            if entries.isEmpty, let empty {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 4) {
                ForEach(entries) { EntryRow(entry: $0, value: value($0)) }
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EntryRow: View {
    let entry: ProcessEntry
    let value: String
    @State private var hovering = false

    var body: some View {
        let app = entry.pids.count == 1 ? NSRunningApplication(processIdentifier: entry.pids[0]) : nil
        HStack(spacing: 7) {
            Group {
                if let bundle = entry.bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable()
                } else if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.fill").resizable().foregroundStyle(.secondary).padding(2)
                }
            }
            .frame(width: 16, height: 16)
            Text(entry.bundlePath == nil ? (app?.localizedName ?? entry.name) : entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.pids.count > 1 {
                Text(verbatim: "\(entry.pids.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                    .help("\(entry.pids.count) processes")
            }
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1)
            // Processes owned by other users (root, system services) can't be killed.
            if entry.canForceQuit {
                Button(action: entry.forceQuit) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(hovering ? .red : .secondary)
                .opacity(hovering ? 1 : 0.35)
                .help(entry.pids.count > 1 ? "Force quit \(entry.name) and its helpers" : "Force quit \(entry.name)")
            } else {
                Image(systemName: "xmark.circle.fill").hidden()
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }
}

struct ProcessSearchCard: View {
    let processes: [ProcessUsage]
    @State private var query = ""

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = needle.isEmpty ? [] : processes
            .filter { $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle) || "\($0.pid)" == needle }
            .sorted { $0.cpu > $1.cpu }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        Card(title: "Find a process", symbol: "magnifyingglass", tint: .gray, value: nil) {
            TextField("Name or PID", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if !needle.isEmpty {
                if matches.isEmpty {
                    Text("No running process matches “\(query)”.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    ForEach(matches.prefix(6)) { process in
                        EntryRow(entry: ProcessEntry(id: "\(process.pid)", name: process.name, bundlePath: nil,
                                                     pids: [process.pid], cpu: process.cpu, memory: process.memory),
                                 value: "\(String(format: "%.1f%%", process.cpu / cores)) · \(Fmt.bytes(process.memory))")
                    }
                }
                if matches.count > 6 {
                    Text("+ \(matches.count - 6) more, type more to narrow it down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct ListeningPortsCard: View {
    let ports: [ListeningPort]

    var body: some View {
        Card(title: "Listening ports", symbol: "point.3.connected.trianglepath.dotted", tint: .orange,
             value: ports.isEmpty ? nil : "\(ports.count)") {
            if ports.isEmpty {
                Text("None of your apps are accepting connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(ports.prefix(8)) { port in
                    // Helpers (e.g. "Discord Helper (Renderer)") are shown as the app they belong to.
                    let path = ProcessName.path(of: port.pid)
                    let bundle = path.flatMap(ProcessEntry.outermostApp(in:))
                    let app = NSRunningApplication(processIdentifier: port.pid)
                    HStack(spacing: 7) {
                        Text(verbatim: ":\(port.port)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .frame(width: 48, alignment: .leading)
                        if let bundle {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle))
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            AppIcon(app: app)
                        }
                        Text(bundle.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
                             ?? app?.localizedName ?? path.map { ($0 as NSString).lastPathComponent } ?? port.command)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(port.isExposed ? "Network" : "This Mac")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(port.isExposed ? Color.orange : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.primary.opacity(0.07)))
                            .help(port.isExposed ? "Other devices on your network can connect" : "Only reachable from this Mac")
                        if kill(port.pid, 0) == 0 {
                            Button {
                                kill(port.pid, SIGKILL)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Force quit \(port.command)")
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            if ports.count > 8 {
                Text("+ \(ports.count - 8) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Kills every app with a Dock icon. Needs a second click within 3 s because unsaved work is lost.
struct ForceQuitAllButton: View {
    @State private var confirming = false
    @State private var resetTask: Task<Void, Never>?

    private var targets: [NSRunningApplication] {
        let keep = KeepRunning.current
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != getpid()
                && $0.bundleIdentifier != "com.apple.finder" // macOS relaunches it immediately anyway
                && !keep.contains($0.bundleIdentifier ?? "")
        }
    }

    var body: some View {
        Button {
            if confirming {
                resetTask?.cancel()
                confirming = false
                forceQuitAll()
            } else {
                confirming = true
                resetTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { confirming = false }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: confirming ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                Text(confirming ? "Click again to force quit \(targets.count) apps" : "Force quit all apps")
                    .contentTransition(.opacity)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.gradient)
                    .opacity(confirming ? 1 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: confirming)
        .help("Force quits every app in the Dock except Finder and your keep-running list in Settings. Unsaved work is lost.")
    }

    private func forceQuitAll() {
        for app in targets {
            // SIGKILL can't be caught or ignored, so no app can block or delay it.
            if !app.forceTerminate() {
                kill(app.processIdentifier, SIGKILL)
            }
        }
    }
}

// MARK: - Processes extras

struct FrozenAppsCard: View {
    let pids: [pid_t]

    var body: some View {
        Card(title: "Not responding", symbol: "exclamationmark.triangle.fill", tint: .red, value: nil) {
            ForEach(pids, id: \.self) { pid in
                let app = NSRunningApplication(processIdentifier: pid)
                HStack(spacing: 7) {
                    AppIcon(app: app)
                    Text(app?.localizedName ?? "PID \(pid)").lineLimit(1)
                    Spacer()
                    Button("Force quit") {
                        if !(app?.forceTerminate() ?? false) { kill(pid, SIGKILL) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.mini)
                }
                .font(.system(size: 11))
            }
        }
    }
}

// MARK: - Docker

struct DockerCard: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var busy: Set<String> = []

    var body: some View {
        let containers = monitor.containers
        let running = containers?.filter(\.isRunning).count ?? 0
        Card(title: "Docker", symbol: "shippingbox.fill", tint: .blue,
             value: containers.map { _ in "\(running) running" }) {
            if let containers {
                if containers.isEmpty {
                    Text("No containers")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    // Running first, then by name.
                    ForEach(containers.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }) { c in
                        row(c)
                    }
                }
            } else {
                HStack {
                    Text("Docker isn't running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Docker") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func row(_ c: DockerContainer) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(c.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.name).fontWeight(.medium).lineLimit(1)
                Text(c.isRunning ? c.image : c.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if c.isRunning {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(c.cpu.map { String(format: "%.1f%%", $0) } ?? "—").fontWeight(.medium).monospacedDigit()
                    Text(c.memory ?? "").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if busy.contains(c.id) {
                ProgressView().controlSize(.mini).frame(width: 18)
            } else {
                Button {
                    busy.insert(c.id)
                    Task {
                        await monitor.toggleContainer(c)
                        busy.remove(c.id)
                    }
                } label: {
                    Image(systemName: c.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(c.isRunning ? "Stop \(c.name)" : "Start \(c.name)")
            }
        }
        .font(.system(size: 11))
    }
}
