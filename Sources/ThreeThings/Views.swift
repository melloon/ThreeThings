import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Tracker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save()
    }
}

@main
struct ThreeThingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            if let s = store.activeSession {
                Text("◉ \(String(s.title.prefix(24))) · \(clock(store.remaining(s)))")
            } else {
                Image(systemName: "scope")
            }
        }
        .menuBarExtraStyle(.window)

        Window("ThreeThings", id: "today") {
            TodayView().environmentObject(store)
        }
        .defaultSize(width: 620, height: 680)
    }
}

// MARK: - Menu bar popover

struct MenuView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var newTask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = store.activeSession {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Focusing on").font(.caption).foregroundStyle(.secondary)
                    Text(s.title).font(.headline)
                    HStack {
                        Text(clock(store.remaining(s)))
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        Spacer()
                        Button("Finish") { Tracker.shared.finishSession() }
                    }
                }
            } else {
                Text(store.todayTasks.isEmpty ? "What are today's ThreeThings?" : "Pick one and start")
                    .font(.headline)
            }

            Divider()

            ForEach(store.todayTasks) { task in
                HStack(spacing: 8) {
                    Button { store.toggleDone(task.id) } label: {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .help(task.done ? "Mark as not done" : "Mark as done")
                    Text(task.title)
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer()
                    if store.activeSession == nil && !task.done {
                        Button { store.startSession(task) } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Start a \(store.data.settings.sessionMinutes) minute session")
                    }
                    Button { store.removeTask(task.id) } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove task")
                    .disabled(store.activeSession?.taskID == task.id)
                }
            }

            if store.todayTasks.count < Store.maxTasksPerDay {
                TextField("Add a task", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.addTask(newTask)
                        newTask = ""
                    }
            }

            Divider()

            HStack {
                Button("Today and settings") {
                    openWindow(id: "today")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(TopEdgeAnchor())
    }
}

/// Keeps the menu bar popover's top edge fixed when its content changes height. AppKit resizes
/// a window from its bottom-left corner, so without this the popover grows up over the menu bar
/// or shrinks away from it instead of extending downwards.
struct TopEdgeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class AnchorView: NSView {
        private var top: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            top = nil
            guard let window else { return }

            // Each time the popover opens, the system has just placed it under the menu bar.
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.top = window.frame.maxY
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                object: window, queue: .main) { [weak self] _ in
                guard let top = self?.top, window.isVisible,
                      abs(window.frame.maxY - top) > 0.5 else { return }
                window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

// MARK: - Today window

struct TodayView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            DayView().tabItem { Text("Day") }
            SettingsView().tabItem { Text("Settings") }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
    }
}

struct UsageRow: Identifiable {
    var id: String { label }
    let label: String
    let bundleID: String
    let host: String?
    var seconds: TimeInterval
}

struct DayView: View {
    @EnvironmentObject var store: Store
    @State private var dayOffset = 0

    private var day: Date { Calendar.current.date(byAdding: .day, value: dayOffset, to: store.now) ?? store.now }
    private var key: String { dayKey(day) }
    private var segments: [Segment] { store.data.segments.filter { dayKey($0.start) == key } }
    private var sessions: [Session] { store.data.sessions.filter { dayKey($0.start) == key } }
    private var overrides: [Override] { store.data.overrides.filter { dayKey($0.date) == key } }

    private var rows: [UsageRow] {
        var byLabel: [String: UsageRow] = [:]
        for s in segments {
            byLabel[s.label, default: UsageRow(label: s.label, bundleID: s.bundleID, host: s.host, seconds: 0)]
                .seconds += s.seconds
        }
        return byLabel.values.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let segs = segments
        let total = segs.reduce(0) { $0 + $1.seconds }
        let inSession = segs.filter { $0.sessionID != nil }.reduce(0) { $0 + $1.seconds }
        let distracted = segs.filter { $0.distracting }.reduce(0) { $0 + $1.seconds }
        let usage = rows
        let top = usage.first?.seconds ?? 1

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .help("Previous day")
                    Text(dayOffset == 0 ? "Today" : day.formatted(date: .complete, time: .omitted))
                        .font(.title2.bold())
                    Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .help("Next day")
                        .disabled(dayOffset >= 0)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Stat(title: "At the laptop", value: duration(total))
                    Stat(title: "In focus sessions", value: duration(inSession))
                    Stat(title: "On distractions", value: duration(distracted))
                }

                Text("Sessions").font(.headline)
                if sessions.isEmpty {
                    Text("No sessions yet.").foregroundStyle(.secondary)
                }
                ForEach(sessions) { s in
                    HStack {
                        Text(s.start.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(s.title).lineLimit(1)
                        Spacer()
                        Text(duration((s.end ?? store.now).timeIntervalSince(s.start)))
                            .foregroundStyle(.secondary)
                        Text(outcomeLabel(s)).frame(width: 110, alignment: .trailing)
                    }
                }

                Text("Where the time went").font(.headline)
                if usage.isEmpty {
                    Text("Nothing tracked yet.").foregroundStyle(.secondary)
                }
                ForEach(usage.prefix(15)) { row in
                    let blocked = store.isBlocked(host: row.host, bundleID: row.bundleID)
                    HStack {
                        Text(row.label).lineLimit(1).frame(width: 190, alignment: .leading)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(blocked ? Color.orange : Color.accentColor)
                            .frame(width: max(2, 170 * row.seconds / top), height: 8)
                            .frame(width: 170, alignment: .leading)
                        Text(duration(row.seconds))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Spacer()
                        Button(blocked ? "Distracting" : "Mark distracting") {
                            store.toggleBlocked(host: row.host, bundleID: row.bundleID)
                        }
                        .controlSize(.small)
                        .tint(blocked ? .orange : nil)
                    }
                }

                if !overrides.isEmpty {
                    Text("Times you pushed through").font(.headline)
                    ForEach(overrides) { o in
                        HStack(alignment: .firstTextBaseline) {
                            Text(o.date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(o.target).frame(width: 150, alignment: .leading)
                            Text("“\(o.reason)”").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func outcomeLabel(_ s: Session) -> String {
        if s.end == nil { return "In progress" }
        switch s.outcome {
        case "done": return "Done"
        case "partial": return "Made progress"
        case "no": return "Not really"
        default: return "No answer"
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var newHost = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sessions").font(.headline)
                Stepper("Session length: \(store.data.settings.sessionMinutes) min",
                        value: $store.data.settings.sessionMinutes, in: 5...120, step: 5)
                Stepper("Wait before you can continue: \(store.data.settings.frictionSeconds) s",
                        value: $store.data.settings.frictionSeconds, in: 5...120, step: 5)
                Stepper("Pass after pushing through: \(store.data.settings.passMinutes) min",
                        value: $store.data.settings.passMinutes, in: 1...30)

                Text("Distracting sites").font(.headline)
                ForEach(store.data.settings.blockedHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("Remove") {
                            store.data.settings.blockedHosts.removeAll { $0 == host }
                            store.save()
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField("example.com", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addHost)
                    Button("Add", action: addHost)
                }

                Text("Distracting apps").font(.headline)
                if store.data.settings.blockedApps.isEmpty {
                    Text("None yet. Mark an app as distracting from the Day tab once it has been tracked.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.data.settings.blockedApps, id: \.self) { bundleID in
                    HStack {
                        Text(store.appName(for: bundleID))
                        Spacer()
                        Button("Remove") {
                            store.data.settings.blockedApps.removeAll { $0 == bundleID }
                            store.save()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .onChange(of: store.data.settings.sessionMinutes) { store.save() }
            .onChange(of: store.data.settings.frictionSeconds) { store.save() }
            .onChange(of: store.data.settings.passMinutes) { store.save() }
        }
    }

    private func addHost() {
        store.addBlockedHost(newHost)
        newHost = ""
    }
}
