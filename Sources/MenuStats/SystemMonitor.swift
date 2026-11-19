import AppKit
import Darwin

enum MemoryPressure {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

struct InterfaceRate: Equatable {
    var down: Double
    var up: Double
    /// Negotiated link speed in bits per second, when the interface reports one (Ethernet does).
    var linkSpeed: Double?
}

struct Snapshot {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuTotal: Double { min(1, cpuUser + cpuSystem) }
    var cores: [Double] = []
    /// Apple silicon lists efficiency cores first; 0 on Macs with one core type.
    var efficiencyCores = 0
    var load: [Double] = [0, 0, 0]

    var gpu: Double?
    var gpuInfo: GPUInfo?
    var power: PowerReading?

    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var memPressure = MemoryPressure.normal
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    var memFraction: Double { memTotal > 0 ? min(1, Double(memUsed) / Double(memTotal)) : 0 }

    var netIn = 0.0
    var netOut = 0.0
    /// Per-interface (BSD name) download/upload in bytes per second.
    var interfaceRates: [String: InterfaceRate] = [:]

    var diskTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var diskRead = 0.0
    var diskWrite = 0.0
    var diskUsed: UInt64 { diskTotal > diskFree ? diskTotal - diskFree : 0 }
    var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }

    var temperatures = Temperatures()
    var fans: [Fan] = []

    var uptime: TimeInterval = 0
    var thermal: ProcessInfo.ThermalState = .nominal
}

/// A 2-minute series at the sample rate plus a 1-hour series of 30 s averages.
/// Sample counts follow the update speed chosen in Settings.
struct MetricHistory {
    static var recentLength: Int { Int((120 / Prefs.updateInterval).rounded()) }
    static let hourLength = 120
    private static var samplesPerBucket: Int { max(1, Int((30 / Prefs.updateInterval).rounded())) }

    private(set) var recent: [Double] = []
    private var buckets: [Double] = []
    private var bucketSum = 0.0
    private var bucketCount = 0

    var hour: [Double] { bucketCount > 0 ? buckets + [bucketSum / Double(bucketCount)] : buckets }

    mutating func add(_ value: Double) {
        recent.append(value)
        if recent.count > Self.recentLength { recent.removeFirst(recent.count - Self.recentLength) }
        bucketSum += value
        bucketCount += 1
        if bucketCount >= Self.samplesPerBucket {
            buckets.append(bucketSum / Double(bucketCount))
            if buckets.count > Self.hourLength - 1 { buckets.removeFirst(buckets.count - (Self.hourLength - 1)) }
            bucketSum = 0
            bucketCount = 0
        }
    }
}

struct Histories {
    var cpu = MetricHistory()
    var memory = MetricHistory()
    var gpu = MetricHistory()
    var ane = MetricHistory()
    var netIn = MetricHistory()
    var netOut = MetricHistory()
    var diskRead = MetricHistory()
    var diskWrite = MetricHistory()
}

/// What the status item needs; updated every tick even while the panel is closed.
@MainActor
final class MenuBarState: ObservableObject {
    @Published fileprivate(set) var snapshot = Snapshot()
    @Published fileprivate(set) var alerts: Set<AlertKind> = []
}

@MainActor
final class SystemMonitor: ObservableObject {
    private(set) var interval = Prefs.updateInterval

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history = Histories()
    @Published private(set) var alerts: Set<AlertKind> = []
    // Only sampled while the panel is open.
    @Published private(set) var processes: [ProcessUsage] = []
    @Published private(set) var network = NetworkDetails()
    @Published private(set) var frozenApps: [pid_t] = []
    @Published private(set) var bandwidth: [AppBandwidth] = []
    @Published private(set) var bluetooth: [BluetoothDevice] = []
    @Published private(set) var neuralEngineClients: [NeuralEngineClient] = []
    @Published private(set) var processIO: [pid_t: ProcessIO] = [:]
    @Published private(set) var listeningPorts: [ListeningPort] = []
    /// nil = Docker isn't installed or its engine isn't running.
    @Published private(set) var containers: [DockerContainer]?
    @Published private(set) var speedTest: SpeedResult?
    @Published private(set) var speedTestRunning = false

    let bar = MenuBarState()
    /// Kept here so a scan survives closing the panel.
    let spaceMap = SpaceMap()
    let systemData = SystemDataScanner()

    /// The panel's published values only change while it is open, so a closed
    /// panel costs no SwiftUI updates.
    var panelVisible = false {
        didSet {
            guard panelVisible, !oldValue else { return }
            snapshot = current
            history = store
            lastPing = .distantPast
            refreshPanelDetails()
        }
    }
    private var current = Snapshot()
    private var store = Histories()

    private let host: host_t
    private let pageSize: UInt64
    private let temperatureSensors = TemperatureSensors()
    private let smc = SMC()
    private let powerSampler = PowerSampler()
    private let alertCenter = AlertCenter()
    private var lastCPU: host_cpu_load_info?
    private var lastCoreTicks: [[UInt32]] = []
    private var lastNet: (counters: [String: (rx: UInt64, tx: UInt64, baud: UInt64)], time: TimeInterval)?
    private var lastDiskIO: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var lastDiskCheck = Date.distantPast
    private var lastPing = Date.distantPast
    private var lastPublicIP = Date.distantPast
    private var lastBluetooth = Date.distantPast
    private var bandwidthRunning = false
    private var dockerRunning = false
    private let processIOSampler = ProcessIOSampler()
    private var lastPorts = Date.distantPast
    private var lastDocker = Date.distantPast
    private var tickCount = 0
    private var timer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var panelWindow: NSWindow?

    init() {
        host = mach_host_self()
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size)

        tick()
        startTimer()
        // Follow the update speed setting without a restart.
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Prefs.updateInterval != self.interval else { return }
                self.interval = Prefs.updateInterval
                self.startTimer()
            }
        })

        // The MenuBarExtra panel is the only window that becomes key besides the status item.
        for (name, visible) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, !window.className.contains("StatusBar") else { return }
                MainActor.assumeIsolated {
                    if visible { self?.panelWindow = window }
                    self?.panelVisible = visible
                }
            })
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps sampling while the menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        tickCount += 1
        var s = current
        updateCPU(&s)
        updateCores(&s)
        updateMemory(&s)
        updateNetwork(&s)
        updateDiskIO(&s)
        if Date().timeIntervalSince(lastDiskCheck) > 30 {
            updateDisk(&s)
            lastDiskCheck = Date()
        }
        s.gpu = GPUSampler.utilization()
        s.gpuInfo = GPUSampler.info()
        // Only the panel shows power and memory traffic, so sample rarely while it's closed.
        let powerInBar = UserDefaults.standard.bool(forKey: BarKey.power)
        if panelVisible || powerInBar || tickCount % 5 == 0, let power = powerSampler?.sample() { s.power = power }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        s.load = load
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.thermal = ProcessInfo.processInfo.thermalState
        // Sensors change slowly and are the costliest read, so every 10 s.
        if tickCount % 5 == 1 {
            s.temperatures = temperatureSensors.read()
            s.fans = smc?.fans() ?? []
        }
        current = s
        bar.snapshot = s

        store.cpu.add(s.cpuTotal)
        store.memory.add(s.memFraction)
        store.gpu.add(s.gpu ?? 0)
        store.ane.add(s.power?.ane ?? 0)
        store.netIn.add(s.netIn)
        store.netOut.add(s.netOut)
        store.diskRead.add(s.diskRead)
        store.diskWrite.add(s.diskWrite)

        let newAlerts = alertCenter.evaluate(s)
        if newAlerts != alerts {
            alerts = newAlerts
            bar.alerts = newAlerts
        }
        StatusItemTooltip.apply(tooltip(for: s))

        // Key notifications alone can leave this stuck on, so confirm the window is on screen.
        if panelVisible, let window = panelWindow, !window.isVisible { panelVisible = false }
        if panelVisible {
            snapshot = s
            history = store
            refreshPanelDetails()
        }
    }

    private func tooltip(for s: Snapshot) -> String {
        var parts = ["CPU \(Fmt.percent(s.cpuTotal))", "Memory \(Fmt.percent(s.memFraction))"]
        if let gpu = s.gpu { parts.append("GPU \(Fmt.percent(gpu))") }
        parts.append("↓ \(Fmt.rate(s.netIn, compact: false))  ↑ \(Fmt.rate(s.netOut, compact: false))")
        if let t = s.temperatures.cpu { parts.append("CPU \(Fmt.temperature(t))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Panel-only details

    private func refreshPanelDetails() {
        Task {
            let sampled = await ProcessSampler.sample()
            if panelVisible { processes = sampled }
        }
        var details = network
        NetworkInfo.wifi(into: &details)
        details.interfaces = NetworkInfo.interfaces()
        // A new network or VPN usually means a new public IP, so look it up again right away.
        if details.interfaces != network.interfaces { lastPublicIP = .distantPast }
        if details != network { network = details }

        if Date().timeIntervalSince(lastPing) > 10 {
            lastPing = Date()
            Task { network.pingMs = await NetworkInfo.ping() }
        }
        // Every 5 minutes, or every 30 s while it's unknown (e.g. offline), never every tick.
        let publicIPAge = Date().timeIntervalSince(lastPublicIP)
        if publicIPAge > 300 || (network.publicIP == nil && publicIPAge > 30) {
            lastPublicIP = Date()
            Task {
                if let ip = await NetworkInfo.publicIP() { network.publicIP = ip }
            }
            // Fails quietly on networks without IPv6.
            Task { network.publicIPv6 = await NetworkInfo.publicIP(v6: true) }
        }

        processIO = processIOSampler.sample()
        if Date().timeIntervalSince(lastPorts) > 5 {
            lastPorts = Date()
            Task {
                let ports = await PortLookup.listening()
                if ports != listeningPorts { listeningPorts = ports }
            }
        }

        let clients = NeuralEngine.clients()
        if clients != neuralEngineClients { neuralEngineClients = clients }

        let frozen = FrozenApps.pids()
        if frozen != frozenApps { frozenApps = frozen }

        // nettop needs about a second per sample, so never start a second one.
        if !bandwidthRunning {
            bandwidthRunning = true
            Task {
                let sampled = await BandwidthSampler.sample()
                bandwidthRunning = false
                if panelVisible { bandwidth = sampled }
            }
        }
        // `docker stats` takes about a second, so refresh every 4 s at most.
        if Docker.cli != nil, !dockerRunning, Date().timeIntervalSince(lastDocker) > 4 {
            dockerRunning = true
            Task {
                let list = await Docker.containers()
                dockerRunning = false
                lastDocker = Date()
                if panelVisible, list != containers { containers = list }
            }
        }
        // system_profiler is slow and battery levels change slowly.
        if Date().timeIntervalSince(lastBluetooth) > 60 {
            lastBluetooth = Date()
            Task { bluetooth = await BluetoothBatteries.read() }
        }
    }

    /// Starts or stops a container, then refreshes the list right away.
    func toggleContainer(_ container: DockerContainer) async {
        if container.isRunning {
            await Docker.stop(container.id)
        } else {
            await Docker.start(container.id)
        }
        containers = await Docker.containers()
        lastDocker = Date()
    }

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        Task {
            let result = await SpeedTest.run()
            speedTestRunning = false
            if let result { speedTest = result }
        }
    }

    /// Re-reads free disk space right away, e.g. after a cleanup.
    func refreshDisk() {
        updateDisk(&current)
        lastDiskCheck = Date()
        snapshot = current
        bar.snapshot = current
    }

    // MARK: CPU

    private func updateCPU(_ s: inout Snapshot) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        defer { lastCPU = info }
        guard let prev = lastCPU else { return }

        // Tick counters are UInt32 and can wrap, hence the wrapping subtraction.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return }
        s.cpuUser = (user + nice) / total
        s.cpuSystem = system / total
    }

    private func updateCores(_ s: inout Snapshot) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(cpuCount)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else { return }

        s.cores = zip(ticks, lastCoreTicks).map { now, prev in
            let d = (0..<states).map { Double(now[$0] &- prev[$0]) }
            let total = d.reduce(0, +)
            return total > 0 ? 1 - d[Int(CPU_STATE_IDLE)] / total : 0
        }
        if s.efficiencyCores == 0 {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("hw.perflevel1.logicalcpu", &value, &size, nil, 0) == 0 {
                s.efficiencyCores = Int(value)
            }
        }
    }

    // MARK: Memory

    private func updateMemory(_ s: inout Snapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        // Same breakdown Activity Monitor uses for "Memory Used".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        s.memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        s.memWired = UInt64(stats.wire_count) * pageSize
        s.memCompressed = UInt64(stats.compressor_page_count) * pageSize
        s.memCached = (UInt64(stats.external_page_count) + purgeable) * pageSize

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }

        // 1 = normal, 2 = warning, 4 = critical (same signal as Activity Monitor's graph).
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            s.memPressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }
    }

    // MARK: Network

    private func updateNetwork(_ s: inout Snapshot) {
        guard let counters = Self.readNetworkBytes() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastNet = (counters, now) }
        guard let prev = lastNet, now > prev.time else { return }
        let dt = now - prev.time

        var rates: [String: InterfaceRate] = [:]
        for (name, c) in counters {
            guard let p = prev.counters[name] else { continue }
            rates[name] = InterfaceRate(down: c.rx >= p.rx ? Double(c.rx - p.rx) / dt : 0,
                                        up: c.tx >= p.tx ? Double(c.tx - p.tx) / dt : 0,
                                        linkSpeed: c.baud > 0 ? Double(c.baud) : nil)
        }
        s.interfaceRates = rates
        // The headline numbers count physical (en*) interfaces only, so VPN traffic isn't counted twice.
        let physical = rates.filter { $0.key.hasPrefix("en") }.values
        s.netIn = physical.reduce(0) { $0 + $1.down }
        s.netOut = physical.reduce(0) { $0 + $1.up }
    }

    /// 64-bit byte counters for every non-loopback interface via NET_RT_IFLIST2.
    private static func readNetworkBytes() -> [String: (rx: UInt64, tx: UInt64, baud: UInt64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &len, nil, 0) == 0 else { return nil }

        var counters: [String: (rx: UInt64, tx: UInt64, baud: UInt64)] = [:]
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if header.ifm_msglen == 0 { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if msg.ifm_flags & IFF_LOOPBACK == 0,
                       if_indextoname(UInt32(msg.ifm_index), &name) != nil {
                        counters[String(cString: name)] = (msg.ifm_data.ifi_ibytes, msg.ifm_data.ifi_obytes,
                                                           msg.ifm_data.ifi_baudrate)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return counters
    }

    // MARK: Disk

    private func updateDisk(_ s: inout Snapshot) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        s.diskTotal = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        s.diskFree = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    private func updateDiskIO(_ s: inout Snapshot) {
        let (read, write) = DiskIOSampler.totals()
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastDiskIO = (read, write, now) }
        guard let prev = lastDiskIO, now > prev.time else { return }
        let dt = now - prev.time
        s.diskRead = read >= prev.read ? Double(read - prev.read) / dt : 0
        s.diskWrite = write >= prev.write ? Double(write - prev.write) / dt : 0
    }
}
