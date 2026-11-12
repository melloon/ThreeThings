import AppKit
import Combine
import SwiftUI

// MARK: - Browser scripting

/// A browser whose current tab can be read and steered through AppleScript.
struct Browser {
    let bundleID: String
    /// How this browser's scripting dictionary names the tab in front.
    let tab: String
    let chromium: Bool

    static let all = [
        Browser(bundleID: "com.kagi.kagimacOS", tab: "current tab of front window", chromium: false),
        Browser(bundleID: "com.google.Chrome", tab: "active tab of front window", chromium: true),
        Browser(bundleID: "com.brave.Browser", tab: "active tab of front window", chromium: true),
    ]

    static func find(_ bundleID: String) -> Browser? {
        all.first { $0.bundleID == bundleID }
    }

    private var tell: String { "tell application id \"\(bundleID)\" to " }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    private func currentURL() -> String? {
        run(tell + "get URL of \(tab)")
    }

    func currentHost() -> String? {
        guard let raw = currentURL(), let host = URL(string: raw)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Goes back one page, or closes the tab when there is nothing to go back to.
    func leavePage() {
        if chromium {
            // Chromium's "go back" does nothing on a fresh tab, so compare the address after.
            let before = currentURL()
            _ = run(tell + "go back (\(tab))")
            Thread.sleep(forTimeInterval: 0.8)
            if currentURL() == before {
                _ = run(tell + "close \(tab)")
            }
        } else {
            let js = "history.length > 1 ? (history.back(), 'back') : 'close'"
            let result = run(tell + "do JavaScript \"\(js)\" in \(tab)")
            if result != "back" {
                _ = run(tell + "close \(tab)")
            }
        }
    }
}

// MARK: - Tracker

final class Tracker {
    static let shared = Tracker()
    private let store = Store.shared
    private let scriptQueue = DispatchQueue(label: "onething.orion")
    private var timer: Timer?
    private var ticks = 0
    private var fetching = false
    /// Distraction-list entries the user pushed through, and when each pass runs out.
    private var passes: [String: Date] = [:]
    private var nudged: Set<String> = []

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func finishSession() {
        guard let session = store.endActiveSession() else { return }
        passes.removeAll()
        nudged.removeAll()
        Overlay.shared.showCheckin(session)
    }

    private func tick() {
        store.now = Date()
        if let s = store.activeSession, store.remaining(s) <= 0 { finishSession() }

        ticks += 1
        if ticks % 30 == 0 { store.saveIfDirty() }
        guard ticks % 2 == 0, !Overlay.shared.isVisible else { return }

        // No keyboard or mouse input for two minutes counts as away.
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle < 120 else { return }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier else { return }

        if let browser = Browser.find(bundleID) {
            guard !fetching else { return }
            fetching = true
            scriptQueue.async {
                let host = browser.currentHost()
                DispatchQueue.main.async {
                    self.fetching = false
                    self.handle(app: app, bundleID: bundleID, host: host, browser: browser)
                }
            }
        } else {
            handle(app: app, bundleID: bundleID, host: nil, browser: nil)
        }
    }

    private func handle(app: NSRunningApplication, bundleID: String, host: String?, browser: Browser?) {
        guard !Overlay.shared.isVisible else { return }
        let name = app.localizedName ?? bundleID
        let settings = store.data.settings

        var key: String?
        var display = name
        if let host, let entry = settings.blockedEntry(forHost: host) {
            key = entry
            display = entry
        } else if settings.blockedApps.contains(bundleID) {
            key = bundleID
        }

        store.record(app: name, bundleID: bundleID, host: host, distracting: key != nil)

        guard let key, let session = store.activeSession else { return }
        if let until = passes[key], until > Date() {
            if until.timeIntervalSinceNow < 60, !nudged.contains(key) {
                nudged.insert(key)
                HUD.shared.show("1 minute left on \(display), then back to “\(session.title)”")
            }
            return
        }
        nudged.remove(key)

        let isSite = host != nil && key != bundleID
        Overlay.shared.show(FrictionView(
            task: session.title,
            target: display,
            seconds: settings.frictionSeconds,
            passMinutes: settings.passMinutes,
            onBack: {
                Overlay.shared.close()
                if isSite, let browser {
                    self.scriptQueue.async {
                        browser.leavePage()
                        DispatchQueue.main.async { app.activate() }
                    }
                } else {
                    app.hide()
                }
            },
            onContinue: { reason in
                self.store.addOverride(target: display, reason: reason, task: session.title)
                self.passes[key] = Date().addingTimeInterval(Double(settings.passMinutes) * 60)
                Overlay.shared.close()
                app.activate()
            }))
    }
}

// MARK: - Full-screen overlay

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Overlay {
    static let shared = Overlay()
    private var panel: NSPanel?
    var isVisible: Bool { panel != nil }

    func show<V: View>(_ card: V) {
        close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            card
        })
        p.setFrame(screen.frame, display: true)
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func showCheckin(_ session: Session) {
        show(CheckinView(title: session.title) { outcome in
            Store.shared.setOutcome(session.id, outcome)
            self.close()
        })
    }
}

// MARK: - Small heads-up message

final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?

    func show(_ text: String) {
        panel?.close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let view = NSHostingView(rootView: Text(text)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule()))
        let size = view.fittingSize
        let frame = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: frame.midX - size.width / 2,
                                            y: frame.maxY - size.height - 16,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.panel === p {
                p.close()
                self?.panel = nil
            }
        }
    }
}

// MARK: - Overlay cards

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(28)
            .frame(width: 460, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 30)
    }
}

struct FrictionView: View {
    let task: String
    let target: String
    let seconds: Int
    let passMinutes: Int
    let onBack: () -> Void
    let onContinue: (String) -> Void

    @State private var elapsed = 0
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: Int { max(0, seconds - elapsed) }
    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Card {
            Text("You're meant to be working on")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(task).font(.title.bold())
            Text("\(target) is on your distraction list.")
            TextField("Why do you need it right now?", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($reasonFocused)
            HStack {
                Button(remaining > 0 ? "Continue in \(remaining)s" : "Continue for \(passMinutes) min") {
                    onContinue(trimmed)
                }
                .disabled(remaining > 0 || trimmed.count < 3)
                Spacer()
                Button("Back to work", action: onBack)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .onReceive(timer) { _ in elapsed += 1 }
        .onAppear { reasonFocused = true }
    }
}

struct CheckinView: View {
    let title: String
    let onAnswer: (String) -> Void

    var body: some View {
        Card {
            Text("Session over").font(.subheadline).foregroundStyle(.secondary)
            Text(title).font(.title.bold())
            Text("Did you do it?")
            HStack {
                Button("Not really") { onAnswer("no") }
                Button("Made progress") { onAnswer("partial") }
                Spacer()
                Button("Done") { onAnswer("done") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }
}
