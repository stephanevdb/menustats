import SwiftUI

enum BarKey {
    static let cpu = "bar.cpu"
    static let memory = "bar.memory"
    static let network = "bar.network"
    static let disk = "bar.disk"
    static let gpu = "bar.gpu"
    static let temperature = "bar.temperature"
    static let power = "bar.power"
    static let gauges = "bar.gauges"
    static let style = "bar.style"
}

enum BarStyle: String, CaseIterable, Identifiable {
    case classic, pills, rings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic"
        case .pills: "Pills"
        case .rings: "Rings"
        }
    }
}

/// Which stats the menu bar shows.
struct BarItems {
    var cpu = true
    var memory = true
    var network = false
    var disk = false
    var gpu = false
    var temperature = false
    var power = false

    var isEmpty: Bool { !(cpu || memory || network || disk || gpu || temperature || power) }
}

/// The status item. SwiftUI flattens custom layouts in MenuBarExtra labels,
/// so the compact view is rendered to a template image instead.
struct MenuBarLabel: View {
    @ObservedObject var state: MenuBarState
    @AppStorage(BarKey.cpu) private var showCPU = true
    @AppStorage(BarKey.memory) private var showMemory = true
    @AppStorage(BarKey.network) private var showNetwork = false
    @AppStorage(BarKey.disk) private var showDisk = false
    @AppStorage(BarKey.gpu) private var showGPU = false
    @AppStorage(BarKey.temperature) private var showTemperature = false
    @AppStorage(BarKey.power) private var showPower = false
    @AppStorage(BarKey.gauges) private var showGauges = true
    @AppStorage(BarKey.style) private var style = BarStyle.classic
    // Re-render when the units change.
    @AppStorage(Prefs.temperatureUnitKey) private var temperatureUnit = "C"
    @AppStorage(Prefs.networkUnitKey) private var networkUnit = "bits"

    private var items: BarItems {
        BarItems(cpu: showCPU, memory: showMemory, network: showNetwork, disk: showDisk,
                 gpu: showGPU, temperature: showTemperature, power: showPower)
    }

    var body: some View {
        if !items.isEmpty {
            Image(nsImage: render())
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }

    @MainActor
    private func render() -> NSImage {
        let content = CompactStats(
            snapshot: state.snapshot,
            style: style,
            items: items,
            showGauges: showGauges
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        guard !state.alerts.isEmpty else {
            image.isTemplate = true
            return image
        }
        // An active alert paints the whole label red instead of following the menu bar color.
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.systemRed.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// MenuBarExtra has no tooltip API, so this sets it on the underlying status bar button.
@MainActor
enum StatusItemTooltip {
    private static weak var button: NSStatusBarButton?

    static func apply(_ text: String) {
        if button == nil {
            button = NSApp?.windows
                .filter { $0.className.contains("NSStatusBarWindow") }
                .lazy
                .compactMap { $0.contentView.flatMap(find) }
                .first
        }
        button?.toolTip = text
    }

    private static func find(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}

struct CompactStats: View {
    let snapshot: Snapshot
    let style: BarStyle
    let items: BarItems
    let showGauges: Bool

    private struct Metric: Identifiable {
        let letter: String
        let label: String
        let fraction: Double   // drives gauges, pill fill and rings
        let text: String       // shown value in Classic
        let short: String      // number inside a pill
        /// Percentages can be rings; temperature and power are shown as text in Rings style.
        var isPercent = true
        var id: String { label }
    }

    private static func percent(_ letter: String, _ label: String, _ fraction: Double) -> Metric {
        Metric(letter: letter, label: label, fraction: fraction, text: Fmt.percent(fraction),
               short: "\(Int((fraction * 100).rounded()))")
    }

    private var metrics: [Metric] {
        var m: [Metric] = []
        if items.cpu { m.append(Self.percent("C", "CPU", snapshot.cpuTotal)) }
        if items.memory { m.append(Self.percent("M", "MEM", snapshot.memFraction)) }
        if items.gpu { m.append(Self.percent("G", "GPU", snapshot.gpu ?? 0)) }
        if items.disk { m.append(Self.percent("D", "SSD", snapshot.diskFraction)) }
        if items.temperature, let celsius = snapshot.temperatures.cpu {
            let text = Fmt.temperature(celsius).replacingOccurrences(of: "C", with: "").replacingOccurrences(of: "F", with: "")
            m.append(Metric(letter: "T", label: "TEMP", fraction: min(1, max(0, celsius / 100)),
                            text: text, short: text.replacingOccurrences(of: "°", with: ""), isPercent: false))
        }
        if items.power, let watts = snapshot.power?.total {
            // Scaled against ~25 W, about the most a MacBook Air chip draws.
            m.append(Metric(letter: "W", label: "PWR", fraction: min(1, watts / 25),
                            text: String(format: watts < 10 ? "%.1fW" : "%.0fW", watts),
                            short: String(format: watts < 10 ? "%.1f" : "%.0f", watts), isPercent: false))
        }
        return m
    }

    var body: some View {
        HStack(spacing: style == .classic ? 7 : 5) {
            switch style {
            case .classic:
                ForEach(metrics) {
                    GaugeItem(label: $0.label, value: $0.text, fraction: $0.fraction, showGauge: showGauges)
                }
            case .pills:
                // Two pills stacked per column.
                let columns = stride(from: 0, to: metrics.count, by: 2).map {
                    Array(metrics[$0..<min($0 + 2, metrics.count)])
                }
                ForEach(columns.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 1.5) {
                        ForEach(columns[i]) { PillGauge(letter: $0.letter, text: $0.short, fraction: $0.fraction) }
                    }
                }
            case .rings:
                // Up to three percentage rings; temperature and power sit next to them as text.
                let rings = Array(metrics.filter(\.isPercent).prefix(3))
                if !rings.isEmpty {
                    RingsItem(fractions: rings.map(\.fraction))
                }
                let values = metrics.filter { !$0.isPercent }
                if !values.isEmpty {
                    VStack(alignment: .trailing, spacing: -1.5) {
                        ForEach(values) { Text($0.text).font(.system(size: 8, weight: .semibold).monospacedDigit()) }
                    }
                    .fixedSize()
                }
            }
            if items.network {
                NetworkItem(down: snapshot.netIn, up: snapshot.netOut, small: style != .classic)
            }
        }
        .foregroundStyle(.black)
        .frame(height: 22)
    }
}

private struct GaugeItem: View {
    let label: String
    let value: String
    let fraction: Double
    let showGauge: Bool

    var body: some View {
        HStack(spacing: 3) {
            if showGauge {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.25))
                    RoundedRectangle(cornerRadius: 1.5).fill(.black)
                        .frame(height: max(1.5, 15 * min(1, fraction)))
                }
                .frame(width: 4, height: 15)
            }
            VStack(alignment: .leading, spacing: -2) {
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.65)
                Text(value)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .frame(width: 26, alignment: .leading)
        }
    }
}

/// A battery-style capsule: the fill shows the level and the number is cut out of it.
private struct PillGauge: View {
    let letter: String
    let text: String
    let fraction: Double

    var body: some View {
        HStack(spacing: 1.5) {
            Text(letter)
                .font(.system(size: 6.5, weight: .heavy))
                .frame(width: 5)
            ZStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.35))
                        Rectangle().fill(.black)
                            .frame(width: geo.size.width * min(1, max(0, fraction)))
                    }
                    .clipShape(Capsule())
                }
                Text(text)
                    .font(.system(size: 8, weight: .heavy).monospacedDigit())
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 21, height: 9)
        }
    }
}

/// Concentric activity-style rings, outermost first. A single ring shows its value inside.
private struct RingsItem: View {
    let fractions: [Double]

    var body: some View {
        let lineWidth: CGFloat = fractions.count >= 3 ? 1.7 : 2.4
        let step = lineWidth + (fractions.count >= 3 ? 0.9 : 1.2)
        ZStack {
            ForEach(Array(fractions.enumerated()), id: \.offset) { i, f in
                let inset = lineWidth / 2 + CGFloat(i) * step
                Circle()
                    .stroke(.black.opacity(0.25), lineWidth: lineWidth)
                    .padding(inset)
                Circle()
                    .trim(from: 0, to: min(1, max(0.001, f)))
                    .stroke(.black, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
            }
            if fractions.count == 1 {
                Text("\(Int((fractions[0] * 100).rounded()))")
                    .font(.system(size: 7, weight: .heavy).monospacedDigit())
            }
        }
        .frame(width: 19, height: 19)
    }
}

private struct NetworkItem: View {
    let down: Double
    let up: Double
    var small = false

    var body: some View {
        VStack(alignment: .trailing, spacing: small ? -1.5 : -1) {
            row(Fmt.rate(up, compact: true), symbol: "arrow.up")
            row(Fmt.rate(down, compact: true), symbol: "arrow.down")
        }
        // Sizes to its text, so short values like "0b" take less room.
        .fixedSize()
    }

    private func row(_ text: String, symbol: String) -> some View {
        HStack(spacing: 1) {
            Text(text)
                .font(.system(size: small ? 8 : 9, weight: .semibold).monospacedDigit())
                .fixedSize()
            Image(systemName: symbol).font(.system(size: small ? 5 : 6, weight: .heavy))
        }
    }
}
