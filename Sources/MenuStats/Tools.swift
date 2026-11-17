import AppKit

enum Shell {
    /// Runs a command off the main thread and returns its stdout
    /// (nil if it can't start, or exits with an error when `requireSuccess` is set).
    static func run(_ path: String, _ arguments: [String], requireSuccess: Bool = false) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if requireSuccess && process.terminationStatus != 0 { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

enum ProcessName {
    /// Kernel tools truncate process names (nettop to 15, the IORegistry to 16 characters);
    /// the executable path has the full one.
    static func full(of pid: pid_t) -> String? {
        path(of: pid).map { ($0 as NSString).lastPathComponent }
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Not responding apps

/// Uses the same WindowServer check that makes the Dock show "Application Not Responding".
/// It's private API, so it is looked up at runtime and simply reports nothing if missing.
enum FrozenApps {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let functions: (Int32, UnresponsiveFn, PSNFn)? = {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        guard let connection = dlsym(skyLight, "CGSMainConnectionID"),
              let unresponsive = dlsym(skyLight, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(services, "GetProcessForPID")
        else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFn.self)(),
                unsafeBitCast(unresponsive, to: UnresponsiveFn.self),
                unsafeBitCast(psn, to: PSNFn.self))
    }()

    static func pids() -> [pid_t] {
        guard let (connection, isUnresponsive, getPSN) = functions else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                var psn = ProcessSerialNumber()
                guard getPSN(app.processIdentifier, &psn) == noErr else { return nil }
                return isUnresponsive(connection, &psn) ? app.processIdentifier : nil
            }
    }
}

// MARK: - Bluetooth batteries

struct BluetoothDevice: Identifiable, Equatable {
    struct Level: Equatable {
        let label: String
        let percent: Int
    }

    let name: String
    let kind: String
    let levels: [Level]
    var id: String { name }

    var symbol: String {
        switch kind.lowercased() {
        case let k where k.contains("mouse"): "computermouse.fill"
        case let k where k.contains("keyboard"): "keyboard.fill"
        case let k where k.contains("trackpad"): "rectangle.and.hand.point.up.left.fill"
        case let k where k.contains("head"): "headphones"
        case let k where k.contains("gamepad"): "gamecontroller.fill"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

enum BluetoothBatteries {
    static func read() async -> [BluetoothDevice] {
        var devices = await fromSystemProfiler()
        // Apple keyboards/mice/trackpads also publish BatteryPercent in the IORegistry.
        let known = Set(devices.map(\.name))
        devices += fromRegistry().filter { !known.contains($0.name) }
        return devices.sorted { $0.name < $1.name }
    }

    private static func fromSystemProfiler() async -> [BluetoothDevice] {
        guard let output = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]]
        else { return [] }

        let labels = [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"),
                      ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "Case")]
        return connected.flatMap { entry in
            entry.compactMap { name, value -> BluetoothDevice? in
                guard let info = value as? [String: Any] else { return nil }
                let levels = labels.compactMap { key, label -> BluetoothDevice.Level? in
                    guard let text = info[key] as? String,
                          let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
                    else { return nil }
                    return .init(label: label, percent: percent)
                }
                guard !levels.isEmpty else { return nil }
                return BluetoothDevice(name: name, kind: info["device_minorType"] as? String ?? "", levels: levels)
            }
        }
    }

    private static func fromRegistry() -> [BluetoothDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [BluetoothDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let name = property("Product") as? String,
                  let percent = (property("BatteryPercent") as? NSNumber)?.intValue
            else { continue }
            devices.append(BluetoothDevice(name: name, kind: name, levels: [.init(label: "", percent: percent)]))
        }
        return devices
    }
}

// MARK: - Bandwidth per app

struct AppBandwidth: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let bytesIn: Double   // per second
    let bytesOut: Double
    var id: Int32 { pid }
    var total: Double { bytesIn + bytesOut }
}

enum BandwidthSampler {
    /// Two nettop samples one second apart in delta mode; the second block holds per-second bytes.
    static func sample() async -> [AppBandwidth] {
        guard let output = await Shell.run("/usr/bin/nettop",
                                           ["-P", "-d", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"])
        else { return [] }
        let blocks = output.components(separatedBy: ",bytes_in,bytes_out,\n")
        guard let last = blocks.last, blocks.count >= 3 else { return [] }

        return last.split(separator: "\n").compactMap { line -> AppBandwidth? in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = Double(fields[1]),
                  let bytesOut = Double(fields[2]),
                  bytesIn + bytesOut > 0
            else { return nil }
            return AppBandwidth(pid: pid, name: String(fields[0][..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }
}

// MARK: - Port lookup

struct PortUser: Identifiable, Equatable {
    let pid: Int32
    let command: String
    let user: String
    let proto: String
    let address: String
    let state: String?
    var id: String { "\(pid)-\(proto)-\(address)" }
}

/// A port a process is listening on, merged across its IPv4/IPv6 sockets.
struct ListeningPort: Identifiable, Equatable {
    let pid: Int32
    let command: String
    let port: Int
    /// True when it accepts connections from other devices, not just this Mac.
    let isExposed: Bool
    var id: String { "\(pid)-\(port)" }
}

enum PortLookup {
    /// Every TCP port in LISTEN state. Without sudo, lsof only sees your own processes.
    static func listening() async -> [ListeningPort] {
        guard let output = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLPnT"]) else { return [] }
        var merged: [String: ListeningPort] = [:]
        for user in parse(output) {
            // "*:3000", "127.0.0.1:5432", "[::1]:5432"
            guard let colon = user.address.lastIndex(of: ":"),
                  let port = Int(user.address[user.address.index(after: colon)...])
            else { continue }
            let host = String(user.address[..<colon])
            let local = host == "127.0.0.1" || host == "[::1]" || host == "localhost"
            let key = "\(user.pid)-\(port)"
            let exposed = !local || (merged[key]?.isExposed ?? false)
            merged[key] = ListeningPort(pid: user.pid, command: user.command, port: port, isExposed: exposed)
        }
        return merged.values.sorted { $0.port < $1.port }
    }

    private static func parse(_ output: String) -> [PortUser] {
        var results: [PortUser] = []
        var pid: Int32 = 0, command = "", user = ""
        var proto = "", address = "", state: String?
        var inFile = false

        func flush() {
            if inFile, !address.isEmpty {
                let entry = PortUser(pid: pid, command: command, user: user, proto: proto, address: address, state: state)
                if !results.contains(entry) { results.append(entry) }
            }
            proto = ""; address = ""; state = nil; inFile = false
        }

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value) ?? 0
            case "c": command = value
            case "L": user = value
            case "f": flush(); inFile = true
            case "P": proto = value
            case "n": address = value
            case "T" where value.hasPrefix("ST="): state = String(value.dropFirst(3))
            default: break
            }
        }
        flush()
        return results
    }
}

// MARK: - Speed test

struct SpeedResult: Equatable {
    let download: Double      // bits per second
    let upload: Double
    let responsiveness: Int?  // round-trips per minute
    let date: Date
}

enum SpeedTest {
    /// macOS's built-in networkQuality tool; takes about 15–20 seconds.
    static func run() async -> SpeedResult? {
        guard let output = await Shell.run("/usr/bin/networkQuality", ["-c"]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let download = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let upload = (json["ul_throughput"] as? NSNumber)?.doubleValue
        else { return nil }
        return SpeedResult(download: download, upload: upload,
                           responsiveness: (json["responsiveness"] as? NSNumber)?.intValue,
                           date: Date())
    }
}
