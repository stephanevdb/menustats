import Foundation
import IOKit

enum IORegistry {
    /// Reads `key` from every service of class `className`.
    static func properties(of className: String, key: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                result.append(value)
            }
            IOObjectRelease(service)
        }
        return result
    }
}

enum GPUSampler {
    static func utilization() -> Double? {
        let values = IORegistry.properties(of: "IOAccelerator", key: "PerformanceStatistics")
            .compactMap { ($0["Device Utilization %"] as? NSNumber)?.doubleValue }
        return values.max().map { $0 / 100 }
    }
}

enum DiskIOSampler {
    /// Cumulative bytes read/written across all block storage drivers.
    static func totals() -> (read: UInt64, write: UInt64) {
        IORegistry.properties(of: "IOBlockStorageDriver", key: "Statistics").reduce((0, 0)) { sum, stats in
            (sum.0 + ((stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0),
             sum.1 + ((stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0))
        }
    }
}

// MARK: - Temperatures

struct Temperatures: Equatable {
    var cpu: Double?
    var cpuMax: Double?
    var ssd: Double?
    var battery: Double?
}

/// Apple silicon exposes its thermal sensors through IOHIDEventSystem, which is
/// not public API, so the functions are looked up at runtime and every read is optional.
final class TemperatureSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFString>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let client: AnyObject?
    private let copyServices: CopyServicesFn?
    private let copyEvent: CopyEventFn?
    private let copyProperty: CopyPropertyFn?
    private let getFloat: GetFloatFn?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
        getFloat = load("IOHIDEventGetFloatValue", as: GetFloatFn.self)

        if let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
           let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
           let client = create(kCFAllocatorDefault)?.takeRetainedValue() {
            // Usage page 0xff00 / usage 5 = temperature sensors.
            _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            self.client = client
        } else {
            client = nil
        }
    }

    private enum Kind { case die, ssd, battery }
    /// Copying an event is the expensive part, so the sensors we use are looked up once.
    private lazy var sensors: [(service: AnyObject, kind: Kind)] = {
        guard let client, let copyServices, let copyProperty,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }
        return services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as String?
            else { return nil }
            if name.contains("tdie") { return (service, .die) }
            if name.hasPrefix("NAND") { return (service, .ssd) }
            if name.contains("battery") { return (service, .battery) }
            return nil
        }
    }()

    func read() -> Temperatures {
        guard let copyEvent, let getFloat else { return Temperatures() }

        var die: [Double] = []
        var ssd: [Double] = []
        var battery: [Double] = []
        for (service, kind) in sensors {
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Self.temperatureField)
            guard value > 0, value < 150 else { continue }
            switch kind {
            case .die: die.append(value)
            case .ssd: ssd.append(value)
            case .battery: battery.append(value)
            }
        }
        return Temperatures(
            cpu: die.isEmpty ? nil : die.reduce(0, +) / Double(die.count),
            cpuMax: die.max(),
            ssd: ssd.max(),
            battery: battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count)
        )
    }
}

// MARK: - Fans (SMC)

struct Fan: Equatable {
    var rpm: Double
    var min: Double
    var max: Double
    var fraction: Double { max > min ? Swift.min(1, Swift.max(0, (rpm - min) / (max - min))) : 0 }
}

/// Minimal AppleSMC reader for fan keys. Macs without fans report FNum = 0.
final class SMC {
    // Mirrors SMCKeyData_t from the kernel; padding is explicit so the layout matches C.
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    func fans() -> [Fan] {
        guard let count = read("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let rpm = read("F\(i)Ac") else { return nil }
            return Fan(rpm: rpm, min: read("F\(i)Mn") ?? 0, max: read("F\(i)Mx") ?? 0)
        }
    }

    private func read(_ key: String) -> Double? {
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.data8 = 9 // kSMCGetKeyInfo
        guard let info = call(&input), info.result == 0 else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // kSMCReadKey
        guard let output = call(&input), output.result == 0 else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0) }
        switch Self.string(info.keyInfo.dataType) {
        case "flt ":
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "fpe2":
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.size
        let kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &outputSize)
        return kr == KERN_SUCCESS ? output : nil
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
