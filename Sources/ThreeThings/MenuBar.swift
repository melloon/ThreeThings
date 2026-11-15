import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item, the panel that drops down from it, and the main window.
///
/// SwiftUI's own menu bar window does not follow its content: when the content changes height the
/// window keeps its old size or grows from the wrong edge. This panel is sized and placed by the
/// app, so its top edge always stays under the menu bar.
final class MenuBarController: NSObject {
    static let shared = MenuBarController()
    private let store = Store.shared
    private let panel = MenuPanel()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var cancellable: AnyCancellable?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                                       weight: .regular)
        statusItem = item
        panel.setContent(MenuView().environmentObject(store))
        cancellable = store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshTitle()
        }
        refreshTitle()
    }

    /// The text shown in the menu bar, or nil when only the icon should show.
    static func title(session: Session?, remaining: TimeInterval, breakRemaining: TimeInterval?) -> String? {
        if let session {
            return "\(session.isPaused ? "⏸" : "◉") \(String(session.title.prefix(24))) · \(clock(remaining))"
        }
        if let breakRemaining { return "Break · \(clock(breakRemaining))" }
        return nil
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        let session = store.activeSession
        let title = MenuBarController.title(session: session,
                                            remaining: session.map(store.remaining) ?? 0,
                                            breakRemaining: store.breakEnds?.timeIntervalSince(store.now)) ?? ""
        if button.title != title { button.title = title }
        let image = title.isEmpty ? menuBarIcon : nil
        if button.image !== image { button.image = image }
    }

    @objc private func toggle() {
        if panel.isOpen {
            panel.close()
            return
        }
        // The click that just dismissed the panel should not reopen it.
        guard Date().timeIntervalSince(panel.lastClosed) > 0.25,
              let button = statusItem?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.open(below: anchor, screen: window.screen ?? NSScreen.main)
    }

    func openMainWindow() {
        panel.close()
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ThreeThings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TodayView().environmentObject(store))
            window.setContentSize(NSSize(width: 620, height: 680))
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The drop-down panel. It takes its size from its SwiftUI content and keeps its top-left corner
/// where it was opened, so a change in height always extends or retracts the bottom edge.
final class MenuPanel: NSObject {
    private final class Window: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private static let gapBelowMenuBar: CGFloat = 5
    private let window: Window
    private let effect = NSVisualEffectView()
    private var host: NSView?
    private var contentSize = CGSize(width: 320, height: 200)
    private var topLeft = CGPoint.zero
    private var clickMonitor: Any?
    private var refitTimer: Timer?
    private(set) var lastClosed = Date.distantPast

    var isOpen: Bool { window.isVisible }
    var frame: NSRect { window.frame }
    /// Lets tests run the real panel on screen without showing it.
    var alpha: CGFloat {
        get { window.alphaValue }
        set { window.alphaValue = newValue }
    }

    override init() {
        window = Window(contentRect: NSRect(origin: .zero, size: contentSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in self?.close() }

        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = MenuPanel.roundedMask(radius: 10)
        window.contentView = effect

        NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    func setContent<V: View>(_ view: V) {
        host?.removeFromSuperview()
        let hosting = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        host = hosting
    }

    /// Opens the panel under `anchor` (the menu bar item, in screen coordinates). When a screen is
    /// given, the panel is kept inside its visible area.
    func open(below anchor: NSRect, screen: NSScreen?) {
        if let fit = host?.fittingSize, fit.width > 0, fit.height > 0 { contentSize = fit }
        var x = anchor.minX
        var top = anchor.minY
        if let visible = screen?.visibleFrame {
            x = max(visible.minX + 8, min(x, visible.maxX - contentSize.width - 8))
            // The item's own frame can end above the bottom of a taller (notched) menu bar.
            top = min(top, visible.maxY)
        }
        topLeft = CGPoint(x: x, y: top - MenuPanel.gapBelowMenuBar)
        applyFrame()
        window.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        // SwiftUI gives no dependable signal when the content's natural size changes, so while
        // the panel is open its content is measured ten times a second and the frame follows.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let fit = self.host?.fittingSize else { return }
            self.contentChanged(to: fit)
        }
        RunLoop.main.add(timer, forMode: .common)
        refitTimer = timer
    }

    func close() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        lastClosed = Date()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        refitTimer?.invalidate()
        refitTimer = nil
    }

    @objc private func resignedKey() { dismiss() }

    /// Closes the panel because the user clicked elsewhere, unless they are taking a screenshot,
    /// so the open menu can be captured.
    private func dismiss() {
        if !MenuPanel.screenshotInProgress { close() }
    }

    /// True while the system screenshot tool's selection overlay is on screen.
    private static var screenshotInProgress: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "screencaptureui" }
    }

    private func contentChanged(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if window.isVisible { applyFrame() }
    }

    private func applyFrame() {
        let frame = NSRect(x: topLeft.x, y: topLeft.y - contentSize.height,
                           width: contentSize.width, height: contentSize.height)
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    /// A stretchable rounded rectangle, so the panel and its shadow get rounded corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
