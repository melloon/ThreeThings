import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - Browser scripting

/// A browser whose current tab can be read and steered through AppleScript.
struct Browser {
    let bundleID: String
    /// How this browser's scripting dictionary names a window's selected tab.
    let tabName: String
    let chromium: Bool

    private var tab: String { "\(tabName) of front window" }

    static let all = [
        Browser(bundleID: "com.kagi.kagimacOS", tabName: "current tab", chromium: false),
        Browser(bundleID: "com.google.Chrome", tabName: "active tab", chromium: true),
        Browser(bundleID: "com.brave.Browser", tabName: "active tab", chromium: true),
        Browser(bundleID: "com.apple.Safari", tabName: "current tab", chromium: false),
        // Browsers that ship the standard Chromium scripting dictionary.
        Browser(bundleID: "com.microsoft.edgemac", tabName: "active tab", chromium: true),
        Browser(bundleID: "com.vivaldi.Vivaldi", tabName: "active tab", chromium: true),
        Browser(bundleID: "com.operasoftware.Opera", tabName: "active tab", chromium: true),
        Browser(bundleID: "org.chromium.Chromium", tabName: "active tab", chromium: true),
        Browser(bundleID: "company.thebrowser.Browser", tabName: "active tab", chromium: true),
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

    /// The site in the browser window the user is looking at, or nil when something else is in
    /// front. A browser's scripted "front window" only counts browser windows, so with Settings
    /// or another auxiliary window in front it still names the browser window behind it. To
    /// catch that, the scripted window's frame is compared with the app's real frontmost window.
    func currentHost(pid: pid_t) -> String? {
        let script = """
        tell application id "\(bundleID)"
            set w to front window
            if not (visible of w) then return ""
            set b to bounds of w
            return (URL of \(tabName) of w) & linefeed & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
        end tell
        """
        guard let lines = run(script)?.split(separator: "\n"), lines.count == 2 else { return nil }
        let bounds = lines[1].split(separator: ",").compactMap { Int($0) }
        guard Browser.isFrontWindow(scriptedBounds: bounds, onScreen: Browser.windowFrames(pid: pid)),
              let host = URL(string: String(lines[0]))?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Frames of the app's ordinary on-screen windows, front to back.
    static func windowFrames(pid: pid_t) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
            return frame
        }
    }

    /// Whether the scripted window (left, top, right, bottom) is the app's frontmost real window.
    /// Slivers such as tooltips and helper windows are skipped.
    static func isFrontWindow(scriptedBounds b: [Int], onScreen frames: [CGRect]) -> Bool {
        guard b.count == 4,
              let front = frames.first(where: { $0.width >= 100 && $0.height >= 100 }) else { return false }
        let scripted = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
        return abs(front.minX - scripted.minX) <= 2 && abs(front.minY - scripted.minY) <= 2
            && abs(front.width - scripted.width) <= 2 && abs(front.height - scripted.height) <= 2
    }

    /// Goes back one page, or closes the tab when there is nothing to go back to.
    func leavePage() {
        let before = currentURL()
        var closing = false
        if chromium {
            // Chromium's "go back" does nothing on a fresh tab, so compare the address after.
            _ = run(tell + "go back (\(tab))")
            Thread.sleep(forTimeInterval: 0.8)
            closing = currentURL() == before
        } else {
            // Safari only runs this with "Allow JavaScript from Apple Events" turned on.
            let js = "history.length > 1 ? (history.back(), 'back') : 'close'"
            closing = run(tell + "do JavaScript \"\(js)\" in \(tab)") != "back"
        }
        guard closing else { return }
        _ = run(tell + "close \(tab)")
        // Last resort for a browser that refuses both, so the friction screen cannot loop.
        Thread.sleep(forTimeInterval: 0.3)
        if let before, currentURL() == before {
            _ = run(tell + "set URL of \(tab) to \"about:blank\"")
        }
    }
}

// MARK: - Tracker

final class Tracker {
    static let shared = Tracker()
    private let store = Store.shared
    private let scriptQueue = DispatchQueue(label: "threethings.orion")
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

    /// How many check-ins should have fired this far into a session.
    static func checkinsDue(elapsed: TimeInterval, everyMinutes: Int) -> Int {
        everyMinutes > 0 ? Int(elapsed / Double(everyMinutes * 60)) : 0
    }

    private var checkinSession: UUID?
    private var checkinsSent = 0

    private func checkIn(_ session: Session) {
        let settings = store.data.settings
        guard settings.checkinMinutes > 0 else { return }
        if checkinSession != session.id {
            checkinSession = session.id
            checkinsSent = 0
            Checkins.shared.prepare()
        }
        let due = Tracker.checkinsDue(elapsed: store.now.timeIntervalSince(session.start),
                                      everyMinutes: settings.checkinMinutes)
        guard due > checkinsSent else { return }
        checkinsSent = due
        // Not while the friction screen is up, and not in the last two minutes.
        let remaining = store.remaining(session)
        guard remaining > 120, !Overlay.shared.isVisible else { return }
        Checkins.shared.post(task: session.title, remaining: remaining, sound: settings.checkinSound)
    }

    func finishSession() {
        guard let session = store.endActiveSession() else { return }
        Checkins.shared.clear()
        passes.removeAll()
        nudged.removeAll()
        Overlay.shared.showCheckin(session)
    }

    private func tick() {
        store.now = Date()
        if let s = store.activeSession, store.remaining(s) <= 0 { finishSession() }
        if let s = store.activeSession { checkIn(s) }

        ticks += 1
        if ticks % 30 == 0 {
            store.saveIfDirty()
            store.carryOverTasks()
        }
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
                let host = browser.currentHost(pid: app.processIdentifier)
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

// MARK: - Check-in notifications

/// Posts the "still on task?" check-in as a system notification: a banner that slides in and
/// leaves on its own. Falls back to the in-app heads-up message when notifications are not allowed.
final class Checkins: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Checkins()
    private static let identifier = "checkin"
    private var center: UNUserNotificationCenter { .current() }

    /// Asks for permission the first time; later calls do nothing visible.
    func prepare() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(task: String, remaining: TimeInterval, sound: Bool) {
        let title = "Still on “\(task)”?"
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { HUD.shared.show(title) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "\(Int((remaining / 60).rounded())) min left in this session."
            content.sound = sound ? .default : nil
            // Reusing one identifier replaces the previous check-in, so they never pile up.
            self.center.add(UNNotificationRequest(identifier: Checkins.identifier, content: content, trigger: nil))
        }
    }

    func clear() {
        center.removeDeliveredNotifications(withIdentifiers: [Checkins.identifier])
    }

    /// Show the banner even when ThreeThings itself is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
        // A non-activating panel takes keyboard focus without activating ThreeThings. Activating
        // the app would pull its other windows, such as an open Settings window, to the front.
        let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.hidesOnDeactivate = false
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
