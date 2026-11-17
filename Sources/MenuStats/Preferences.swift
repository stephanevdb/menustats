import Foundation

/// UserDefaults keys and typed readers for settings used outside SwiftUI views.
enum Prefs {
    static let updateIntervalKey = "general.updateInterval"
    static let temperatureUnitKey = "general.temperatureUnit"
    static let networkUnitKey = "general.networkUnit"
    static let unusedAppDaysKey = "cleanup.unusedDays"
    static let overviewOrderKey = "overview.order"
    static let overviewHiddenKey = "overview.hidden"

    static let updateIntervals: [TimeInterval] = [1, 2, 5]
    static let unusedAppDayOptions = [30, 90, 180, 365]

    /// Seconds between samples: 1, 2 (default) or 5.
    static var updateInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: updateIntervalKey)
        return updateIntervals.contains(value) ? value : 2
    }

    static var useFahrenheit: Bool {
        UserDefaults.standard.string(forKey: temperatureUnitKey) == "F"
    }

    static var networkInBytes: Bool {
        UserDefaults.standard.string(forKey: networkUnitKey) == "bytes"
    }

    static var unusedAppDays: Int {
        let value = UserDefaults.standard.integer(forKey: unusedAppDaysKey)
        return unusedAppDayOptions.contains(value) ? value : 90
    }

    static func describe(days: Int) -> String {
        switch days {
        case 30: "1 month"
        case 365: "1 year"
        default: "\(days / 30) months"
        }
    }
}

/// Cards on the Overview tab, which Settings lets you hide and reorder.
enum OverviewCard: String, CaseIterable, Identifiable {
    case cpu, gpu, neuralEngine, memory, devices, network, disk, sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        case .memory: "Memory"
        case .devices: "Bluetooth devices"
        case .network: "Network"
        case .disk: "Disk"
        case .sensors: "Sensors"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up.fill"
        case .neuralEngine: "brain"
        case .memory: "memorychip"
        case .devices: "dot.radiowaves.left.and.right"
        case .network: "network"
        case .disk: "internaldrive"
        case .sensors: "thermometer.medium"
        }
    }

    /// Saved order, with any cards added in later versions appended at the end.
    static func order(from raw: String) -> [OverviewCard] {
        let saved = raw.split(separator: ",").compactMap { OverviewCard(rawValue: String($0)) }
        return saved + allCases.filter { !saved.contains($0) }
    }

    static func hidden(from raw: String) -> Set<OverviewCard> {
        Set(raw.split(separator: ",").compactMap { OverviewCard(rawValue: String($0)) })
    }

    static func raw(_ cards: some Sequence<OverviewCard>) -> String {
        cards.map(\.rawValue).joined(separator: ",")
    }
}
