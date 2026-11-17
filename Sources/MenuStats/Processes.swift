import AppKit

struct ProcessUsage: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let path: String     // executable path; used to find the app a helper belongs to
    let cpu: Double      // percent of one core, like Activity Monitor
    let memory: UInt64   // resident bytes
    var id: Int32 { pid }
}

/// Disk and energy use since the previous sample. Only readable for your own processes.
struct ProcessIO: Equatable {
    var diskRead = 0.0    // bytes per second
    var diskWrite = 0.0
    var energy = 0.0      // watts
}

enum ProcessSampler {
    /// Uses `ps`, which can read processes owned by other users (WindowServer,
    /// kernel helpers) that proc_pid_rusage cannot see without root.
    static func sample() async -> [ProcessUsage] {
        guard let output = await Shell.run("/bin/ps", ["-Aeo", "pid=,pcpu=,rss=,comm="]) else { return [] }
        return output.split(separator: "\n").compactMap { line -> ProcessUsage? in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2])
            else { return nil }
            let path = String(parts[3])
            return ProcessUsage(pid: pid, name: (path as NSString).lastPathComponent, path: path,
                                cpu: cpu, memory: rss * 1024)
        }
    }

    static func app(for pid: Int32) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}

/// Per-process disk and energy counters from proc_pid_rusage, turned into rates between calls.
final class ProcessIOSampler {
    private struct Counters {
        let read: UInt64
        let written: UInt64
        let energy: UInt64   // nanojoules
    }

    private var last: (counters: [pid_t: Counters], time: TimeInterval)?

    func sample() -> [pid_t: ProcessIO] {
        let now = ProcessInfo.processInfo.systemUptime
        var counters: [pid_t: Counters] = [:]
        for pid in Self.allPIDs() {
            var info = rusage_info_v6()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            // Fails for other users' processes without root; those are skipped.
            guard result == 0 else { continue }
            counters[pid] = Counters(read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten,
                                     energy: info.ri_energy_nj)
        }
        defer { last = (counters, now) }
        guard let previous = last, now > previous.time else { return [:] }
        let dt = now - previous.time

        var rates: [pid_t: ProcessIO] = [:]
        for (pid, c) in counters {
            guard let p = previous.counters[pid] else { continue }
            rates[pid] = ProcessIO(diskRead: c.read >= p.read ? Double(c.read - p.read) / dt : 0,
                                   diskWrite: c.written >= p.written ? Double(c.written - p.written) / dt : 0,
                                   energy: c.energy >= p.energy ? Double(c.energy - p.energy) / dt / 1e9 : 0)
        }
        return rates
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, found))))
    }
}

/// One row in the process lists: a single process, or an app with all its helpers.
struct ProcessEntry: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    var pids: [pid_t] = []
    var cpu = 0.0
    var memory: UInt64 = 0
    var diskRead = 0.0
    var diskWrite = 0.0
    var energy = 0.0
    var netIn = 0.0
    var netOut = 0.0

    var disk: Double { diskRead + diskWrite }
    var network: Double { netIn + netOut }

    /// Builds the rows, optionally folding helpers into the app bundle they live in
    /// (e.g. every "Claude Helper" process into Claude).
    static func make(processes: [ProcessUsage], io: [pid_t: ProcessIO],
                     bandwidth: [AppBandwidth], grouped: Bool) -> [ProcessEntry] {
        let network = Dictionary(bandwidth.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [String: ProcessEntry] = [:]
        var order: [String] = []
        for process in processes {
            let bundle = grouped ? outermostApp(in: process.path) : nil
            let key = bundle ?? "pid-\(process.pid)"
            if entries[key] == nil {
                order.append(key)
                let name = bundle.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
                    ?? process.name
                entries[key] = ProcessEntry(id: key, name: name, bundlePath: bundle)
            }
            entries[key]?.pids.append(process.pid)
            entries[key]?.cpu += process.cpu
            entries[key]?.memory += process.memory
            if let usage = io[process.pid] {
                entries[key]?.diskRead += usage.diskRead
                entries[key]?.diskWrite += usage.diskWrite
                entries[key]?.energy += usage.energy
            }
            if let traffic = network[process.pid] {
                entries[key]?.netIn += traffic.bytesIn
                entries[key]?.netOut += traffic.bytesOut
            }
        }
        return order.compactMap { entries[$0] }
    }

    /// "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/..." → "/Applications/Claude.app".
    static func outermostApp(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Force quits every process in the row that this user is allowed to signal.
    func forceQuit() {
        for pid in pids where pid != getpid() && kill(pid, 0) == 0 {
            if !(NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false) {
                kill(pid, SIGKILL)
            }
        }
    }

    var canForceQuit: Bool {
        pids.contains { $0 != getpid() && kill($0, 0) == 0 }
    }
}
