
import SwiftUI
import Charts
import ServiceManagement

enum Tab: String, CaseIterable {
    case overview = "Overview"
    case processes = "Processes"
    case cleanup = "Cleanup"
    case settings = "Settings"
}

struct StatsPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var updater = Updater.shared
    @State private var tab = Tab.overview
    /// Overview's size, which the other tabs adopt so the panel doesn't jump when switching.
    @State private var overviewSize: CGSize = .zero

    private var s: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: 10) {
            header
            TabBar(selection: $tab)
            Group {
                switch tab {
                case .overview:
                    OverviewTab(monitor: monitor)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { overviewSize = $0 }
                case .processes: ProcessesTab(monitor: monitor)
                case .cleanup: CleanupTab(monitor: monitor)
                case .settings: SettingsTab()
                }
            }
            .environment(\.forceTwoColumns,
                         tab != .overview && overviewSize.width > AdaptiveColumns<EmptyView, EmptyView>.columnWidth + 1)
            .frame(minHeight: tab == .overview ? nil : overviewSize.height, alignment: .top)
            footer
        }
        .padding(12)
        .fixedSize()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "This Mac")
                    .font(.system(size: 14, weight: .semibold))
                Text("Up \(Fmt.duration(s.uptime))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let version = updater.availableVersion {
                Button { updater.update() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(version)")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help(Updater.brew == nil ? "Opens the download page" : "Installs with Homebrew, then reopens MenuStats")
            } else if updater.state == .updating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Updating…").font(.system(size: 10, weight: .semibold))
                }
            }
            if !monitor.alerts.isEmpty {
                Pill(text: "\(monitor.alerts.count) alert\(monitor.alerts.count == 1 ? "" : "s")", color: .red)
            }
            Pill(text: Fmt.thermal(s.thermal), color: thermalColor)
        }
        .padding(.horizontal, 2)
    }

    private var thermalColor: Color {
        switch s.thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                    configuration: .init()
                )
            } label: {
                Label("Activity Monitor", systemImage: "waveform.path.ecg")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - Overview

enum CardID: Hashable {
    case cpu, gpu, ane, memory, network, disk
}

struct OverviewTab: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var expanded: Set<CardID> = []
    @StateObject private var location = LocationPermission()
    @AppStorage(Prefs.overviewOrderKey) private var orderRaw = ""
    @AppStorage(Prefs.overviewHiddenKey) private var hiddenRaw = ""

    private var s: Snapshot { monitor.snapshot }
    private var h: Histories { monitor.history }

    var body: some View {
        let hidden = OverviewCard.hidden(from: hiddenRaw)
        AdaptiveColumns(balanced: true) {
            ForEach(OverviewCard.order(from: orderRaw).filter { !hidden.contains($0) }) { card($0) }
        } right: {
            EmptyView()
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    /// A card, or nothing when this Mac has no data for it (e.g. no Bluetooth devices).
    @ViewBuilder
    private func card(_ card: OverviewCard) -> some View {
        switch card {
        case .cpu: cpuCard
        case .gpu: if let gpu = s.gpu { gpuCard(gpu) }
        case .neuralEngine: if let power = s.power { neuralEngineCard(power) }
        case .memory: memoryCard
        case .devices: if !monitor.bluetooth.isEmpty { DevicesCard(devices: monitor.bluetooth) }
        case .network: networkCard
        case .disk: diskCard
        case .sensors: if hasSensors { sensorsCard }
        }
    }

    private func binding(_ id: CardID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }

    private func series(_ history: MetricHistory, _ id: CardID) -> (values: [Double], capacity: Int) {
        expanded.contains(id)
            ? (history.hour, MetricHistory.hourLength)
            : (history.recent, MetricHistory.recentLength)
    }

    // MARK: CPU

    private var cpuCard: some View {
        let data = series(h.cpu, .cpu)
        return Card(title: "CPU", symbol: "cpu", tint: .blue, value: Fmt.percent(s.cpuTotal),
                    isExpanded: binding(.cpu)) {
            ChartBlock(isExpanded: expanded.contains(.cpu)) {
                Sparkline(values: data.values, capacity: data.capacity, maxValue: 1, tint: .blue)
            }
            HStack(spacing: 12) {
                InfoRow(label: "User", value: Fmt.percent(s.cpuUser))
                InfoRow(label: "System", value: Fmt.percent(s.cpuSystem))
            }
            if !s.cores.isEmpty {
                let e = min(s.efficiencyCores, s.cores.count)
                // Efficiency cores come first in the list; show performance cores first.
                let cores: [CoreGrid.Core] = e > 0
                    ? s.cores[e...].enumerated().map { .init(label: "P\($0.offset + 1)", value: $0.element, tint: .blue) }
                        + s.cores[..<e].enumerated().map { .init(label: "E\($0.offset + 1)", value: $0.element, tint: .cyan) }
                    : s.cores.enumerated().map { .init(label: "\($0.offset + 1)", value: $0.element, tint: .blue) }
                CoreGrid(cores: cores)
            }
            InfoRow(label: "Load average",
                    value: s.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            if let power = s.power {
                InfoRow(label: "Power", value: Fmt.watts(power.cpu))
            }
        }
    }

    // MARK: GPU

    private func gpuCard(_ gpu: Double) -> some View {
        let data = series(h.gpu, .gpu)
        return Card(title: "GPU", symbol: "square.stack.3d.up.fill", tint: .mint, value: Fmt.percent(gpu),
                    isExpanded: binding(.gpu)) {
            if let info = s.gpuInfo {
                Text(info.cores.map { "\(info.model) · \($0)-core GPU" } ?? info.model)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ChartBlock(isExpanded: expanded.contains(.gpu)) {
                Sparkline(values: data.values, capacity: data.capacity, maxValue: 1, tint: .mint)
            }
            if let power = s.power {
                HStack(spacing: 12) {
                    InfoRow(label: "Clock", value: power.gpuClockMHz.map { "\(Int($0.rounded())) MHz" } ?? "Idle")
                    InfoRow(label: "Power", value: Fmt.watts(power.gpu))
                }
            }
            if let memory = s.gpuInfo?.memoryInUse {
                InfoRow(label: "Memory in use", value: Fmt.bytes(memory))
            }
        }
    }

    // MARK: Neural Engine

    private func neuralEngineCard(_ power: PowerReading) -> some View {
        let data = series(h.ane, .ane)
        let active = power.ane > 0.005
        return Card(title: "Neural Engine", symbol: "brain", tint: .pink,
                    value: active ? Fmt.watts(power.ane) : "Idle",
                    isExpanded: binding(.ane)) {
            if let info = NeuralEngine.info, let cores = info.cores {
                Text("\(cores)-core Neural Engine" + (info.architecture.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ChartBlock(isExpanded: expanded.contains(.ane)) {
                // Scale to at least 1 W so idle noise stays flat.
                Sparkline(values: data.values, capacity: data.capacity,
                          maxValue: max(data.values.max() ?? 0, 1), tint: .pink)
            }
            InfoRow(label: "Power", value: Fmt.watts(power.ane))
            InfoRow(label: "Memory traffic",
                    value: "↓ \(Fmt.throughput(power.aneRead))  ↑ \(Fmt.throughput(power.aneWrite))")
            if !monitor.neuralEngineClients.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps with models loaded")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(monitor.neuralEngineClients) { client in
                        let app = NSRunningApplication(processIdentifier: client.pid)
                        HStack(spacing: 7) {
                            AppIcon(app: app)
                            Text(app?.localizedName ?? client.name).lineLimit(1)
                            Spacer()
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(.top, 2)
            }
            Text("macOS doesn't report a usage %. Power and memory traffic show how hard it's working.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        Card(title: "Memory", symbol: "memorychip", tint: .purple, value: Fmt.percent(s.memFraction),
             badge: (s.memPressure.title, pressureColor), isExpanded: binding(.memory)) {
            if expanded.contains(.memory) {
                ChartBlock(isExpanded: true) {
                    Sparkline(values: h.memory.hour, capacity: MetricHistory.hourLength, maxValue: 1, tint: .purple)
                }
            }
            SegmentedBar(segments: [
                (fraction(s.memApp, of: s.memTotal), .purple),
                (fraction(s.memWired, of: s.memTotal), .orange),
                (fraction(s.memCompressed, of: s.memTotal), .pink),
            ])
            HStack(spacing: 12) {
                LegendRow(color: .purple, label: "App", value: Fmt.bytes(s.memApp))
                LegendRow(color: .orange, label: "Wired", value: Fmt.bytes(s.memWired))
            }
            HStack(spacing: 12) {
                LegendRow(color: .pink, label: "Compressed", value: Fmt.bytes(s.memCompressed))
                InfoRow(label: "Swap", value: Fmt.bytes(s.swapUsed))
            }
            InfoRow(label: "Used", value: "\(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal))")
            if let power = s.power, power.memoryRead + power.memoryWrite > 0 {
                Divider().opacity(0.5)
                InfoRow(label: "Bandwidth",
                        value: "↓ \(Fmt.throughput(power.memoryRead))  ↑ \(Fmt.throughput(power.memoryWrite))")
                let ane = power.aneRead + power.aneWrite
                let known = power.memoryByCPU + power.memoryByGPU + ane + power.memoryByDisplay
                let other = max(0, power.memoryRead + power.memoryWrite - known)
                // Per-source counters can add up to a bit more than the total; scale to whichever is larger.
                let total = max(power.memoryRead + power.memoryWrite, known + other)
                SegmentedBar(segments: [
                    (power.memoryByCPU / total, .blue),
                    (power.memoryByGPU / total, .mint),
                    (ane / total, .pink),
                    (power.memoryByDisplay / total, .orange),
                    (other / total, .gray),
                ])
                HStack(spacing: 12) {
                    LegendRow(color: .blue, label: "CPU", value: Fmt.throughput(power.memoryByCPU))
                    LegendRow(color: .mint, label: "GPU", value: Fmt.throughput(power.memoryByGPU))
                }
                HStack(spacing: 12) {
                    LegendRow(color: .pink, label: "NE", value: Fmt.throughput(ane))
                    LegendRow(color: .orange, label: "Display", value: Fmt.throughput(power.memoryByDisplay))
                }
            }
        }
    }

    private var pressureColor: Color {
        switch s.memPressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    // MARK: Network

    private var networkCard: some View {
        let down = series(h.netIn, .network)
        let up = series(h.netOut, .network)
        let peak = max(down.values.max() ?? 0, up.values.max() ?? 0, 1024)
        let n = monitor.network
        return Card(title: "Network", symbol: "network", tint: .teal, value: nil, isExpanded: binding(.network)) {
            ChartBlock(isExpanded: expanded.contains(.network)) {
                ZStack {
                    Sparkline(values: down.values, capacity: down.capacity, maxValue: peak, tint: .teal)
                    Sparkline(values: up.values, capacity: up.capacity, maxValue: peak, tint: .orange, filled: false)
                }
            }
            HStack(spacing: 12) {
                LegendRow(color: .teal, label: "↓ Down", value: Fmt.rate(s.netIn, compact: false))
                LegendRow(color: .orange, label: "↑ Up", value: Fmt.rate(s.netOut, compact: false))
            }
            Divider().opacity(0.5)
            wifiRow(n)
            if n.wifiConnected { wifiDetails(n) }
            ForEach(n.interfaces) { interface in
                // Wi‑Fi reports its live link rate through CoreWLAN; wired links through the interface.
                let wifiRate = interface.bsdName == n.wifiInterface ? n.txRate.map { $0 * 1_000_000 } : nil
                InterfaceBlock(interface: interface, rate: s.interfaceRates[interface.bsdName],
                               linkSpeed: wifiRate ?? s.interfaceRates[interface.bsdName]?.linkSpeed)
            }
            CopyRow(label: "Public IPv4", value: n.publicIP)
            if let v6 = n.publicIPv6 { CopyRow(label: "Public IPv6", value: v6) }
            InfoRow(label: "Ping 1.1.1.1", value: n.pingMs.map { String(format: "%.0f ms", $0) } ?? "—")
            SpeedTestRow(monitor: monitor)
        }
    }

    @ViewBuilder
    private func wifiDetails(_ n: NetworkDetails) -> some View {
        let w = n.wifiDetails
        let channel = [w.channel.map { "Ch \($0)" }, w.band, w.widthMHz.map { "\($0) MHz" }].compactMap { $0 }
        if !channel.isEmpty {
            InfoRow(label: "Channel", value: channel.joined(separator: " · "))
        }
        if let standard = w.standard {
            InfoRow(label: "Standard", value: standard)
        }
        if let rssi = n.rssi, let noise = w.noise {
            // Signal-to-noise ratio is what decides how fast Wi‑Fi can actually go.
            let snr = rssi - noise
            let quality = snr >= 40 ? "Excellent" : snr >= 25 ? "Good" : snr >= 15 ? "Fair" : "Poor"
            InfoRow(label: "Signal quality", value: "\(quality) · SNR \(snr) dB · noise \(noise) dBm")
        }
        if let security = w.security {
            InfoRow(label: "Security", value: security)
        }
    }

    @ViewBuilder
    private func wifiRow(_ n: NetworkDetails) -> some View {
        HStack {
            Text("Wi‑Fi").foregroundStyle(.secondary)
            Spacer()
            if !n.wifiConnected {
                Text("Not connected").fontWeight(.medium)
            } else {
                if let name = n.wifiName {
                    Text(name).fontWeight(.medium).lineLimit(1)
                } else if location.status == .denied || location.status == .restricted {
                    Text("Name hidden")
                        .foregroundStyle(.secondary)
                        .help("Allow MenuStats in System Settings › Privacy & Security › Location Services to see the Wi‑Fi name")
                } else {
                    Text("Connected").fontWeight(.medium)
                }
                if let rssi = n.rssi {
                    SignalBars(rssi: rssi)
                    Text("\(rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
    }

    // MARK: Disk

    private var diskCard: some View {
        let read = series(h.diskRead, .disk)
        let write = series(h.diskWrite, .disk)
        let peak = max(read.values.max() ?? 0, write.values.max() ?? 0, 1_000_000)
        return Card(title: "Disk", symbol: "internaldrive", tint: .indigo, value: Fmt.percent(s.diskFraction),
                    isExpanded: binding(.disk)) {
            if expanded.contains(.disk) {
                ChartBlock(isExpanded: true) {
                    ZStack {
                        Sparkline(values: read.values, capacity: read.capacity, maxValue: peak, tint: .indigo)
                        Sparkline(values: write.values, capacity: write.capacity, maxValue: peak, tint: .pink, filled: false)
                    }
                }
            }
            SegmentedBar(segments: [(s.diskFraction, .indigo)])
            InfoRow(label: "Used", value: "\(Fmt.bytes(s.diskUsed)) of \(Fmt.bytes(s.diskTotal))")
            InfoRow(label: "Available", value: Fmt.bytes(s.diskFree))
            HStack(spacing: 12) {
                LegendRow(color: .indigo, label: "Read", value: Fmt.throughput(s.diskRead))
                LegendRow(color: .pink, label: "Write", value: Fmt.throughput(s.diskWrite))
            }
        }
    }

    // MARK: Sensors

    private var hasSensors: Bool {
        let t = s.temperatures
        return t.cpu != nil || t.ssd != nil || t.battery != nil || !s.fans.isEmpty
    }

    private var sensorsCard: some View {
        let t = s.temperatures
        return Card(title: "Sensors", symbol: "thermometer.medium", tint: .red,
                    value: t.cpu.map(Fmt.temperature)) {
            if let cpu = t.cpu {
                InfoRow(label: "CPU average", value: Fmt.temperature(cpu))
            }
            if let hottest = t.cpuMax {
                InfoRow(label: "CPU hottest", value: Fmt.temperature(hottest))
            }
            if let ssd = t.ssd {
                InfoRow(label: "SSD", value: Fmt.temperature(ssd))
            }
            if let battery = t.battery {
                InfoRow(label: "Battery", value: Fmt.temperature(battery))
            }
            if let power = s.power {
                InfoRow(label: "Chip power", value: Fmt.watts(power.total))
                    .help("CPU + GPU + Neural Engine + memory")
            }
            ForEach(Array(s.fans.enumerated()), id: \.offset) { i, fan in
                InfoRow(label: s.fans.count > 1 ? "Fan \(i + 1)" : "Fan", value: "\(Int(fan.rpm)) rpm")
                SegmentedBar(segments: [(fan.fraction, .red)])
            }
        }
    }

    private func fraction(_ part: UInt64, of total: UInt64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @AppStorage(BarKey.cpu) private var showCPU = true
    @AppStorage(BarKey.memory) private var showMemory = true
    @AppStorage(BarKey.network) private var showNetwork = false
    @AppStorage(BarKey.disk) private var showDisk = false
    @AppStorage(BarKey.gpu) private var showGPU = false
    @AppStorage(BarKey.temperature) private var showTemperature = false
    @AppStorage(BarKey.power) private var showPower = false
    @AppStorage(BarKey.gauges) private var showGauges = true
    @AppStorage(BarKey.style) private var style = BarStyle.classic
    @AppStorage(AlertKey.enabled) private var alertsEnabled = true
    @AppStorage(Prefs.updateIntervalKey) private var updateInterval = 2.0
    @AppStorage(Prefs.temperatureUnitKey) private var temperatureUnit = "C"
    @AppStorage(Prefs.networkUnitKey) private var networkUnit = "bits"
    @AppStorage(Prefs.unusedAppDaysKey) private var unusedDays = 90
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        AdaptiveColumns {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Menu bar")
                HStack(spacing: 6) {
                    Chip(title: "CPU", isOn: $showCPU)
                    Chip(title: "Memory", isOn: $showMemory)
                    Chip(title: "GPU", isOn: $showGPU)
                    Chip(title: "Disk", isOn: $showDisk)
                }
                HStack(spacing: 6) {
                    Chip(title: "Network", isOn: $showNetwork)
                    Chip(title: "Temp", isOn: $showTemperature)
                    Chip(title: "Power", isOn: $showPower)
                }
                Picker("Style", selection: $style) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                if style == .classic {
                    SwitchRow(title: "Show gauges", isOn: $showGauges)
                }
            }
            .padding(10)
            .background(CardBackground())

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Alerts")
                SwitchRow(title: "Alert on high usage", isOn: $alertsEnabled)
                Text("Turns the menu bar red and sends a notification when CPU stays above 90% for a minute, memory pressure is critical, or less than 10 GB of disk is free.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(CardBackground())

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("General")
                SettingPicker(title: "Update every", selection: $updateInterval,
                              options: Prefs.updateIntervals.map { ($0, "\(Int($0)) s") })
                SettingPicker(title: "Temperature", selection: $temperatureUnit,
                              options: [("C", "°C"), ("F", "°F")])
                SettingPicker(title: "Network speeds", selection: $networkUnit,
                              options: [("bits", "Bits"), ("bytes", "Bytes")])
                SettingPicker(title: "Unused apps after", selection: $unusedDays,
                              options: Prefs.unusedAppDayOptions.map { ($0, $0 == 365 ? "1 yr" : "\($0 / 30) mo") })
                SwitchRow(title: "Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(CardBackground())
        } right: {
            OverviewCardsSettings()
                .padding(10)
                .background(CardBackground())

            KeepRunningSettings()
                .padding(10)
                .background(CardBackground())

            UpdateSettings()
                .padding(10)
                .background(CardBackground())
        }
    }
}

/// A labelled row with a small segmented control.
struct SettingPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11))
            Spacer(minLength: 8)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Show/hide and reorder the Overview tab's cards.
struct OverviewCardsSettings: View {
    @AppStorage(Prefs.overviewOrderKey) private var orderRaw = ""
    @AppStorage(Prefs.overviewHiddenKey) private var hiddenRaw = ""

    var body: some View {
        let order = OverviewCard.order(from: orderRaw)
        let hidden = OverviewCard.hidden(from: hiddenRaw)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Overview cards")
                Spacer()
                if !orderRaw.isEmpty || !hiddenRaw.isEmpty {
                    Button("Reset") {
                        orderRaw = ""
                        hiddenRaw = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            ForEach(Array(order.enumerated()), id: \.element) { index, card in
                HStack(spacing: 7) {
                    Toggle(isOn: Binding(
                        get: { !hidden.contains(card) },
                        set: { visible in
                            hiddenRaw = OverviewCard.raw(OverviewCard.allCases.filter {
                                $0 == card ? !visible : hidden.contains($0)
                            })
                        }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Image(systemName: card.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(card.title)
                        .foregroundStyle(hidden.contains(card) ? .secondary : .primary)
                    Spacer()
                    Button { move(card, by: -1, in: order) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(card, by: 1, in: order) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == order.count - 1)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            Text("Cards fill whichever column is shorter. Cards without data on this Mac stay hidden.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func move(_ card: OverviewCard, by offset: Int, in order: [OverviewCard]) {
        guard let index = order.firstIndex(of: card), order.indices.contains(index + offset) else { return }
        var reordered = order
        reordered.swapAt(index, index + offset)
        orderRaw = OverviewCard.raw(reordered)
    }
}

struct KeepRunningSettings: View {
    @AppStorage(KeepRunning.key) private var raw = KeepRunning.defaultValue

    private var ids: [String] { KeepRunning.ids(from: raw) }

    /// Running Dock apps that aren't on the list yet.
    private var candidates: [NSRunningApplication] {
        let listed = Set(ids)
        return NSWorkspace.shared.runningApplications
            .filter {
                guard let id = $0.bundleIdentifier else { return false }
                return $0.activationPolicy == .regular && !listed.contains(id)
                    && $0.processIdentifier != getpid() && id != "com.apple.finder"
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Keep running on force quit")
                Spacer()
                Menu {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        Button {
                            if let id = app.bundleIdentifier { raw = KeepRunning.raw(from: ids + [id]) }
                        } label: {
                            if let icon = app.icon { Image(nsImage: icon) }
                            Text(app.localizedName ?? app.bundleIdentifier ?? "App")
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(candidates.isEmpty)
            }
            if ids.isEmpty {
                Text("No apps. Force quit closes everything except Finder.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 7) {
                    Group {
                        if let icon = KeepRunning.icon(for: id) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(KeepRunning.name(for: id)).lineLimit(1)
                    Spacer()
                    Button {
                        raw = KeepRunning.raw(from: ids.filter { $0 != id })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from list")
                }
                .font(.system(size: 11))
            }
        }
    }
}

// MARK: - Overview extras

struct DevicesCard: View {
    let devices: [BluetoothDevice]

    var body: some View {
        Card(title: "Devices", symbol: "dot.radiowaves.left.and.right", tint: .blue, value: nil) {
            ForEach(devices) { device in
                HStack(spacing: 7) {
                    Image(systemName: device.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(device.name).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(device.levels, id: \.label) { level in
                        HStack(spacing: 2) {
                            if !level.label.isEmpty {
                                Text(level.label).foregroundStyle(.secondary)
                            }
                            Text("\(level.percent)%")
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .foregroundStyle(level.percent < 20 ? Color.red : Color.primary)
                        }
                    }
                }
                .font(.system(size: 11))
            }
        }
    }
}

struct SpeedTestRow: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text("Speed test").foregroundStyle(.secondary)
            Spacer()
            if monitor.speedTestRunning {
                ProgressView().controlSize(.mini)
                Text("Testing, about 20 s…").foregroundStyle(.secondary)
            } else if let result = monitor.speedTest {
                Text("↓ \(Fmt.rate(result.download / 8, compact: false))  ↑ \(Fmt.rate(result.upload / 8, compact: false))")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .help(result.responsiveness.map {
                        "Responsiveness \($0) RPM · tested at \(result.date.formatted(date: .omitted, time: .shortened))"
                    } ?? "")
                Button { monitor.runSpeedTest() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Run again")
            } else {
                Button("Run test") { monitor.runSpeedTest() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 11))
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(UpdateKey.checkAutomatically) private var checkAutomatically = true
    @AppStorage(UpdateKey.installAutomatically) private var installAutomatically = false

    private var installedWithHomebrew: Bool { Updater.brew != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Updates")
            SwitchRow(title: "Check for updates automatically", isOn: $checkAutomatically)
            SwitchRow(title: "Install updates automatically", isOn: $installAutomatically)
                .disabled(!checkAutomatically || !installedWithHomebrew)
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(updater.currentVersion)").font(.system(size: 11, weight: .medium))
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(isFailure ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                switch updater.state {
                case .checking, .updating:
                    ProgressView().controlSize(.small)
                case .available(let version):
                    Button("Update to \(version)") { updater.update() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                default:
                    Button("Check now") { Task { await updater.check() } }
                        .controlSize(.small)
                }
            }
            Text(installedWithHomebrew
                 ? "Updates install with Homebrew and MenuStats reopens by itself."
                 : "Not installed with Homebrew, so updating opens the download page.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isFailure: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var status: String {
        switch updater.state {
        case .idle: updater.lastChecked == nil ? "Not checked yet" : "Up to date"
        case .checking: "Checking…"
        case .upToDate: "Up to date" + (updater.lastChecked.map { ", checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .available(let version): "Version \(version) is available"
        case .updating: "Installing with Homebrew…"
        case .failed(let reason): reason
        }
    }
}
