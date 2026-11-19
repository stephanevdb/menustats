import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the stats panel. MenuBarExtra repositions its window on its
/// own whenever the content resizes, which made the panel jump; here the panel is always
/// centred under the item, or pushed against the screen edge when there isn't room.
@MainActor
final class StatusItemController: NSObject {
    private let monitor: SystemMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatsPanelWindow()
    private var hostingView: NSHostingView<AnyView>!
    private var contentSize: CGSize = .zero
    private var outsideClickMonitor: Any?
    private var lastClose = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    /// Gap between the menu bar and the panel, and the minimum distance to a screen edge.
    private let gap: CGFloat = 5
    private let edgeMargin: CGFloat = 6

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init()

        hostingView = NSHostingView(rootView: AnyView(
            StatsPanel(monitor: monitor)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.contentSizeChanged(size)
                }
                // While the window catches up with a new size, keep the content pinned to the
                // top instead of centred, so it doesn't shift for a frame.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        ))
        // The panel follows the SwiftUI content's size, not the other way round.
        hostingView.sizingOptions = []
        panel.setContent(hostingView)
        panel.onEscape = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            StatusItemTooltip.button = button
        }

        // @Published emits the new values before they're stored, so use the emitted ones.
        monitor.bar.$snapshot.combineLatest(monitor.bar.$alerts)
            .sink { [weak self] snapshot, alerts in self?.updateImage(snapshot, alerts) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateImage(self.monitor.bar.snapshot, self.monitor.bar.alerts)
            }
            .store(in: &cancellables)
        // Switching to another app (or clicking a different window) closes the panel.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in self?.close() }
            .store(in: &cancellables)
    }

    private func updateImage(_ snapshot: Snapshot, _ alerts: Set<AlertKind>) {
        statusItem.button?.image = MenuBarImage.render(snapshot: snapshot, alerts: alerts)
    }

    // MARK: Showing and hiding

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.3 {
            // A click on the item while the panel is open can first close it via resign-key;
            // don't immediately reopen it.
            open()
        }
    }

    private func open() {
        if contentSize == .zero { contentSize = hostingView.fittingSize }
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClose = Date()
        statusItem.button?.highlight(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Positioning

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if panel.isVisible { position() }
    }

    /// Centred under the menu bar item, clamped so it never goes past a screen edge;
    /// the top edge stays fixed just below the menu bar while the height changes.
    private func position() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = contentSize

        var x = (itemFrame.midX - size.width / 2).rounded()
        x = min(x, visible.maxX - edgeMargin - size.width)
        x = max(x, visible.minX + edgeMargin)
        let top = min(itemFrame.minY, visible.maxY) - gap
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// A borderless, rounded, translucent panel like the system's menu bar extras use.
final class StatsPanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                   styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    // Borderless panels can't become key by default, which would break text fields.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    func setContent(_ view: NSView) {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // A stretchable rounded mask gives the panel its corners while keeping the blur.
        let radius: CGFloat = 12
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        background.maskImage = mask

        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        contentView = background
    }
}
