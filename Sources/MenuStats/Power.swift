import Foundation
import IOKit

struct PowerReading: Equatable {
    var cpu = 0.0   // watts
    var gpu = 0.0
    var ane = 0.0   // Neural Engine
    var dram = 0.0
    var total: Double { cpu + gpu + ane + dram }
    /// Average clock while the GPU was active, in MHz; nil when it was off the whole interval.
    var gpuClockMHz: Double?
    /// Share of the interval the GPU was powered on.
    var gpuActive = 0.0
    /// Neural Engine reads/writes to main memory, in bytes per second.
    var aneRead = 0.0
    var aneWrite = 0.0
    /// Total memory (DRAM) traffic and who it comes from, in bytes per second.
    var memoryRead = 0.0
    var memoryWrite = 0.0
    var memoryByCPU = 0.0
    var memoryByGPU = 0.0
    var memoryByDisplay = 0.0
}

struct GPUInfo: Equatable {
    var model: String
    var cores: Int?
    var memoryInUse: UInt64?
}

/// Reads Apple silicon energy counters through IOReport, the same source `powermetrics`
/// uses, but without needing root. IOReport is private API, so everything is looked up at
/// runtime and the sampler is nil on Macs where it isn't available (e.g. Intel).
final class PowerSampler {
    private typealias CopyGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                                    UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias SamplesFn = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias CountFn = @convention(c) (CFDictionary) -> Int32

    private let createSamples: SamplesFn
    private let delta: DeltaFn
    private let channelGroup: StringFn
    private let channelName: StringFn
    private let unitLabel: StringFn
    private let integerValue: IntegerFn
    private let stateCount: CountFn
    private let stateResidency: IntegerFn

    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private let gpuFrequencies: [Double]   // MHz per GPU performance state, index 0 = OFF
    private var last: (sample: CFDictionary, time: TimeInterval)?

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyGroup = load("IOReportCopyChannelsInGroup", as: CopyGroupFn.self),
              let merge = load("IOReportMergeChannels", as: MergeFn.self),
              let subscribe = load("IOReportCreateSubscription", as: SubscribeFn.self),
              let createSamples = load("IOReportCreateSamples", as: SamplesFn.self),
              let delta = load("IOReportCreateSamplesDelta", as: DeltaFn.self),
              let channelGroup = load("IOReportChannelGetGroup", as: StringFn.self),
              let channelName = load("IOReportChannelGetChannelName", as: StringFn.self),
              let unitLabel = load("IOReportChannelGetUnitLabel", as: StringFn.self),
              let integerValue = load("IOReportSimpleGetIntegerValue", as: IntegerFn.self),
              let stateCount = load("IOReportStateGetCount", as: CountFn.self),
              let stateResidency = load("IOReportStateGetResidency", as: IntegerFn.self),
              let energy = copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        if let gpuStates = copyGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?
            .takeRetainedValue() {
            merge(energy, gpuStates, nil)
        }
        // Memory controller traffic per agent (CPU, GPU, ANE, ...), in bytes.
        if let memory = copyGroup("AMC Stats" as CFString, "Perf Counters" as CFString, 0, 0, 0)?
            .takeRetainedValue() {
            merge(energy, memory, nil)
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, energy, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }

        self.createSamples = createSamples
        self.delta = delta
        self.channelGroup = channelGroup
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.stateCount = stateCount
        self.stateResidency = stateResidency
        self.subscription = subscription
        self.channels = channels
        self.gpuFrequencies = Self.readGPUFrequencies()
    }

    /// Power since the previous call; the first call only primes the counters.
    func sample() -> PowerReading? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { last = (current, now) }
        guard let previous = last, now > previous.time,
              let diff = delta(previous.sample, current, nil)?.takeRetainedValue() as NSDictionary?,
              let items = diff["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        let seconds = now - previous.time

        var reading = PowerReading()
        var gpuJoules: Double?
        for item in items {
            let channel = item as CFDictionary
            let group = channelGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = channelName(channel)?.takeUnretainedValue() as String? ?? ""

            if group == "Energy Model" {
                let joules = Double(integerValue(channel, 0)) * Self.joules(per: unitLabel(channel)?.takeUnretainedValue() as String?)
                switch name {
                case "CPU Energy": reading.cpu = joules / seconds
                case "GPU Energy": gpuJoules = joules
                case "GPU" where gpuJoules == nil: reading.gpu = joules / seconds
                case "DRAM": reading.dram = joules / seconds
                case let n where n.hasPrefix("ANE"): reading.ane += joules / seconds
                default: break
                }
            } else if group == "AMC Stats" {
                // DCS = traffic that actually reaches DRAM; channels are "<agent> DCS RD/WR".
                let rate = Double(integerValue(channel, 0)) / seconds
                let agent = name.components(separatedBy: " DCS ").first ?? ""
                let isTraffic = name.hasSuffix(" DCS RD") || name.hasSuffix(" DCS WR")
                switch name {
                case "ANE DCS RD": reading.aneRead = rate
                case "ANE DCS WR": reading.aneWrite = rate
                case "DCS RD": reading.memoryRead = rate
                case "DCS WR": reading.memoryWrite = rate
                default: break
                }
                if isTraffic {
                    if agent == "ECPU" || agent == "PCPU" { reading.memoryByCPU += rate }
                    if agent.hasPrefix("GFX") { reading.memoryByGPU += rate }
                    if agent.hasPrefix("DISP") { reading.memoryByDisplay += rate }
                }
            } else if name == "GPUPH" {
                let count = Int(stateCount(channel))
                let residency = (0..<count).map { Double(stateResidency(channel, Int32($0))) }
                let total = residency.reduce(0, +)
                let active = residency.dropFirst().reduce(0, +)
                if total > 0 { reading.gpuActive = active / total }
                if active > 0, gpuFrequencies.count == count {
                    reading.gpuClockMHz = zip(residency, gpuFrequencies).dropFirst()
                        .reduce(0) { $0 + $1.0 * $1.1 } / active
                }
            }
        }
        // "GPU Energy" (counted in nJ) is the finer-grained counter when present.
        if let gpuJoules { reading.gpu = gpuJoules / seconds }
        return reading
    }

    private static func joules(per unit: String?) -> Double {
        switch unit {
        case "mJ": 1e-3
        case "uJ", "µJ": 1e-6
        case "nJ": 1e-9
        default: 1e-3
        }
    }

    /// The power manager's "voltage-states9" table lists (Hz, mV) pairs for each GPU state.
    private static func readGPUFrequencies() -> [Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "voltage-states9" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        else { return [] }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        return stride(from: 0, to: values.count - 1, by: 2).map { Double(values[$0]) / 1_000_000 }
    }
}

extension GPUSampler {
    /// Model and core count from the GPU driver, plus memory it currently has in use.
    static func info() -> GPUInfo? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let stats = property("PerformanceStatistics") as? [String: Any]
        return GPUInfo(
            model: property("model") as? String ?? "GPU",
            cores: (property("gpu-core-count") as? NSNumber)?.intValue,
            memoryInUse: (stats?["In use system memory"] as? NSNumber)?.uint64Value
        )
    }
}

// MARK: - Neural Engine

struct NeuralEngineInfo: Equatable {
    var cores: Int?
    var architecture: String?
}

struct NeuralEngineClient: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }
}

enum NeuralEngine {
    /// Core count and architecture from the ANE driver; read once, it never changes.
    static let info: NeuralEngineInfo? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let props = IORegistryEntryCreateCFProperty(service, "DeviceProperties" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return NeuralEngineInfo(
            cores: (props["ANEDevicePropertyNumANECores"] as? NSNumber)?.intValue,
            architecture: props["ANEDevicePropertyTypeANEArchitectureTypeStr"] as? String
        )
    }()

    /// Processes holding a connection to the Neural Engine driver, i.e. with models loaded.
    /// Having a model loaded doesn't mean it's computing right now.
    static func clients() -> [NeuralEngineClient] {
        // The per-app connections hang off the load balancer and aren't registered services,
        // so they're found by walking its children rather than by matching.
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H1xANELoadBalancer"))
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [NeuralEngineClient] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            // Format: "pid 3272, Shottr"
            guard let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString,
                                                                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  let comma = creator.firstIndex(of: ","),
                  let pid = pid_t(creator[..<comma].replacingOccurrences(of: "pid ", with: ""))
            else { continue }
            let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            // aned is the system's own Neural Engine daemon, always connected.
            if name != "aned", !result.contains(where: { $0.pid == pid }) {
                result.append(NeuralEngineClient(pid: pid, name: ProcessName.full(of: pid) ?? name))
            }
        }
        return result
    }
}
