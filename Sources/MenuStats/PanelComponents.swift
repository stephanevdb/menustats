import SwiftUI
import Charts

// MARK: - Building blocks

struct TabBar: View {
    @Binding var selection: Tab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.background.opacity(0.9))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String?
    var badge: (String, Color)? = nil
    var isExpanded: Binding<Bool>? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let badge {
                    Pill(text: badge.0, color: badge.1)
                }
                if let isExpanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded?.wrappedValue.toggle() }
            .help(isExpanded == nil ? "" : "Click to show the last hour")
            content
        }
        .padding(10)
        .background(CardBackground())
    }
}

/// A sparkline area that grows and gains a time caption when its card is expanded.
struct ChartBlock<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content.frame(height: isExpanded ? 80 : 34)
            if isExpanded {
                HStack {
                    Text("1 h ago")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06))
            )
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

struct CopyRow: View {
    let label: String
    let value: String?
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Text(copied ? "Copied" : value)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            } else {
                Text("—").fontWeight(.medium)
            }
        }
        .font(.system(size: 11))
    }
}

struct LegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 11))
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

struct SegmentedBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.1.gradient)
                        .frame(width: max(0, geo.size.width * min(1, segment.0)))
                }
                Spacer(minLength: 0)
            }
            .background(.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: segments.map(\.0))
    }
}

/// Per-core load as labelled horizontal bars, two per row.
struct CoreGrid: View {
    struct Core {
        let label: String
        let value: Double
        let tint: Color
    }

    let cores: [Core]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 4) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                HStack(spacing: 5) {
                    Text(core.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule().fill(core.tint.gradient)
                                .frame(width: max(3, geo.size.width * min(1, core.value)))
                        }
                    }
                    .frame(height: 5)
                    Text(Fmt.percent(core.value))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .animation(.easeOut(duration: 0.4), value: cores.map(\.value))
    }
}

/// One network interface: its name, live traffic, and copyable addresses.
struct InterfaceBlock: View {
    let interface: InterfaceInfo
    let rate: InterfaceRate?
    let linkSpeed: Double?   // bits per second

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(interface.displayName).fontWeight(.semibold)
                Text(interface.bsdName).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if let rate {
                    Text("↓ \(Fmt.rate(rate.down, compact: false))  ↑ \(Fmt.rate(rate.up, compact: false))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            if let linkSpeed {
                InfoRow(label: "Link speed", value: Fmt.rate(linkSpeed / 8, compact: false))
            }
            ForEach(interface.ipv4, id: \.self) { CopyRow(label: "IPv4", value: $0) }
            // Hosts often carry several temporary IPv6 addresses; two is enough here.
            ForEach(interface.ipv6.prefix(2), id: \.self) { CopyRow(label: "IPv6", value: $0) }
        }
        .padding(.vertical, 2)
    }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(i <= level ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 2.5, height: CGFloat(i) * 2.5)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    let maxValue: Double
    let tint: Color
    var filled = true

    var body: some View {
        // Right-align the series so it scrolls in from the right as history builds. After the
        // update speed changes, history can briefly hold more points than fit; keep the newest.
        let shown = Array(values.suffix(capacity))
        let offset = capacity - shown.count
        Chart {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, v in
                if filled {
                    AreaMark(x: .value("t", i + offset), y: .value("v", v))
                        .foregroundStyle(tint.opacity(0.25).gradient)
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("t", i + offset), y: .value("v", v))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...(capacity - 1))
        .chartYScale(domain: 0...maxValue)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct Chip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - Layout

struct ForceTwoColumnsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on the other tabs when Overview needed two columns, so the panel keeps one size.
    var forceTwoColumns: Bool {
        get { self[ForceTwoColumnsKey.self] }
        set { self[ForceTwoColumnsKey.self] = newValue }
    }
}

/// Last column decision per layout, so a tab that's rebuilt (e.g. when switching back to it)
/// starts in the right layout instead of flashing one column before measuring.
@MainActor
enum ColumnMemory {
    static var twoColumns: [String: Bool] = [:]
}

/// Stacks cards in one column, or two side by side when one column would be taller than
/// the screen. Scrolling is only the last resort, when even two columns don't fit.
struct AdaptiveColumns<Left: View, Right: View>: View {
    static var columnWidth: CGFloat { 316 }

    /// In two-column mode, put each card in whichever column is shorter instead of a fixed
    /// left/right split; used where the user picks the card order.
    var balanced = false

    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @Environment(\.forceTwoColumns) private var forceTwoColumns
    @State private var naturalHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    // Header, tabs, footer and the gap below the menu bar take about 140 pt.
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 140 }
    // Each call site has its own content type, which makes a stable key for remembering the layout.
    private var memoryKey: String { String(describing: Left.self) }

    private var twoColumns: Bool {
        if forceTwoColumns { return true }
        // Until the hidden copy has been measured, reuse the previous decision.
        guard naturalHeight > 0 else { return ColumnMemory.twoColumns[memoryKey] ?? false }
        return naturalHeight > maxHeight
    }

    var body: some View {
        Group {
            if shownHeight > maxHeight {
                ScrollView { columns }
                    .scrollIndicators(.never)
                    .frame(height: maxHeight)
            } else {
                columns
            }
        }
        .background(alignment: .top) {
            // Invisible single-column copy, measured to decide whether one column fits.
            VStack(spacing: 8) { left; right }
                .frame(width: Self.columnWidth)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .allowsHitTesting(false)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    naturalHeight = $0
                    ColumnMemory.twoColumns[memoryKey] = $0 > maxHeight
                }
        }
    }

    private var columns: some View {
        Group {
            if twoColumns && balanced {
                MasonryLayout(columnWidth: Self.columnWidth, spacing: 8) { left; right }
            } else if twoColumns {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 8) { left }.frame(width: Self.columnWidth)
                    VStack(spacing: 8) { right }.frame(width: Self.columnWidth)
                }
            } else {
                VStack(spacing: 8) { left; right }.frame(width: Self.columnWidth)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
    }
}

struct AppIcon: View {
    let app: NSRunningApplication?

    var body: some View {
        Group {
            if let icon = app?.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "gearshape.fill").resizable().foregroundStyle(.secondary).padding(2)
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    var busy = false
    var disabled = false
    let action: () -> Void
    @State private var confirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        if busy {
            ProgressView().controlSize(.mini).frame(width: 60)
        } else {
            Button(confirming ? confirmTitle : title) {
                if confirming {
                    resetTask?.cancel()
                    confirming = false
                    action()
                } else {
                    confirming = true
                    resetTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { confirming = false }
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(confirming ? .red : nil)
            .controlSize(.small)
            .disabled(disabled)
        }
    }
}

/// Two columns, filled in order, each card going to the currently shorter column.
struct MasonryLayout: Layout {
    let columnWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }

    private func arrange(_ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var heights: [CGFloat] = [0, 0]
        var origins: [CGPoint] = []
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = heights[0] <= heights[1] ? 0 : 1
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: heights[column]))
            heights[column] += height + spacing
        }
        let height = max(0, (heights.max() ?? 0) - spacing)
        return (origins, CGSize(width: columnWidth * 2 + spacing, height: height))
    }
}
