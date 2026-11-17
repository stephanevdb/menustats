import Foundation

enum Fmt {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// Network rate in bits ("340Kb" / "340 Kbps") or, if chosen in Settings, bytes ("42KB" / "42 KB/s").
    static func rate(_ bytesPerSecond: Double, compact: Bool) -> String {
        let bytes = Prefs.networkInBytes
        let units = switch (bytes, compact) {
        case (false, true): ["b", "Kb", "Mb", "Gb"]
        case (false, false): ["bps", "Kbps", "Mbps", "Gbps"]
        case (true, true): ["B", "KB", "MB", "GB"]
        case (true, false): ["B/s", "KB/s", "MB/s", "GB/s"]
        }
        var value = max(0, bytesPerSecond) * (bytes ? 1 : 8)
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let separator = compact ? "" : " "
        if index > 0 && value < 10 {
            return String(format: "%.1f%@%@", value, separator, units[index])
        }
        return "\(Int(value.rounded()))\(separator)\(units[index])"
    }

    /// Disk throughput: "12 MB/s".
    static func throughput(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index > 0 && value < 10 { return String(format: "%.1f %@", value, units[index]) }
        return "\(Int(value.rounded())) \(units[index])"
    }

    static func watts(_ value: Double) -> String {
        value < 1 ? String(format: "%.2f W", value) : String(format: "%.1f W", value)
    }

    static func temperature(_ celsius: Double) -> String {
        Prefs.useFahrenheit ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F" : "\(Int(celsius.rounded()))°C"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
