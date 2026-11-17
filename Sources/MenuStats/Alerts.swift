import Foundation
import UserNotifications

enum AlertKind: String, CaseIterable {
    case cpu, memory, disk

    var message: String {
        switch self {
        case .cpu: "CPU has been above 90% for over a minute."
        case .memory: "Memory pressure is critical. Close some apps to free memory."
        case .disk: "Less than 10 GB of disk space is left."
        }
    }
}

enum AlertKey {
    static let enabled = "alerts.enabled"
}

/// Tracks alert conditions and posts one notification each time a condition starts.
@MainActor
final class AlertCenter {
    private(set) var active: Set<AlertKind> = []
    private var cpuHighSince: Date?
    private var requestedPermission = false

    // Notification APIs need a bundle; the bare debug binary has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func evaluate(_ s: Snapshot) -> Set<AlertKind> {
        guard UserDefaults.standard.object(forKey: AlertKey.enabled) as? Bool ?? true else {
            active = []
            cpuHighSince = nil
            return active
        }

        var now: Set<AlertKind> = []

        // Hysteresis: start at 90% sustained, clear once it drops under 80%.
        if s.cpuTotal >= 0.9 {
            if cpuHighSince == nil { cpuHighSince = Date() }
        } else if s.cpuTotal < 0.8 {
            cpuHighSince = nil
        }
        if let since = cpuHighSince, Date().timeIntervalSince(since) >= 60 { now.insert(.cpu) }
        if s.memPressure == .critical { now.insert(.memory) }
        if s.diskTotal > 0 && s.diskFree < 10_000_000_000 { now.insert(.disk) }

        for kind in now.subtracting(active) { notify(kind) }
        active = now
        return active
    }

    private func notify(_ kind: AlertKind) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        if !requestedPermission {
            requestedPermission = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = "MenuStats"
        content.body = kind.message
        center.add(UNNotificationRequest(identifier: "alert.\(kind.rawValue)", content: content, trigger: nil))
    }
}
