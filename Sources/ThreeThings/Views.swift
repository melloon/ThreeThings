import AppKit
import Charts
import ServiceManagement
import SwiftUI

/// Fixed chart colours, one per kind of time, so they never depend on the system accent colour.
/// Each has a light and a dark step, checked for contrast and colour-blind separation.
enum ChartColor {
    static let activity = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let distraction = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let focus = dynamic(light: 0x1BAF7A, dark: 0x199E70)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A small colour swatch with its meaning, for chart legends.
struct LegendItem: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Tracker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save()
    }
}

/// The app icon's ring and three dots, drawn as a template image so the menu bar tints it for
/// light and dark appearances.
let menuBarIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        NSColor.black.set()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
        ring.lineWidth = 1.5
        ring.stroke()
        for offset in [-3.6, 0, 3.6] {
            NSBezierPath(ovalIn: NSRect(x: rect.midX + offset - 1.35, y: rect.midY - 1.35,
                                        width: 2.7, height: 2.7)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}()

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
                Image(nsImage: menuBarIcon)
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
            WeekView().tabItem { Text("Week") }
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

                HStack(spacing: 14) {
                    Text("Where the time went").font(.headline)
                    Spacer()
                    LegendItem(color: ChartColor.activity, label: "Work and neutral")
                    LegendItem(color: ChartColor.distraction, label: "Distracting")
                }
                if usage.isEmpty {
                    Text("Nothing tracked yet.").foregroundStyle(.secondary)
                }
                ForEach(usage.prefix(15)) { row in
                    let blocked = store.isBlocked(host: row.host, bundleID: row.bundleID)
                    HStack {
                        Text(row.label).lineLimit(1).frame(width: 190, alignment: .leading)
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(blocked ? ChartColor.distraction : ChartColor.activity)
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

// MARK: - Week

struct WeekView: View {
    @EnvironmentObject var store: Store
    @State private var weekOffset = 0

    private static let focusLabel = "In focus sessions"
    private static let distractionLabel = "On distractions"

    private var anchor: Date {
        Calendar.current.date(byAdding: .day, value: weekOffset * 7, to: store.now) ?? store.now
    }

    var body: some View {
        let days = store.weekSummaries(endingOn: anchor)
        let focus = days.reduce(0) { $0 + $1.focus }
        let distracted = days.reduce(0) { $0 + $1.distracted }
        let sessions = days.reduce(0) { $0 + $1.sessions }
        let done = days.reduce(0) { $0 + $1.sessionsDone }

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .help("Previous 7 days")
                    Text(title(days)).font(.title2.bold())
                    Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .help("Next 7 days")
                        .disabled(weekOffset >= 0)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Stat(title: "In focus sessions", value: duration(focus))
                    Stat(title: "On distractions", value: duration(distracted))
                    Stat(title: "Sessions marked done", value: "\(done) of \(sessions)")
                }

                Text("Focus and distraction by day").font(.headline)
                if focus + distracted == 0 {
                    Text("Nothing tracked in these 7 days.").foregroundStyle(.secondary)
                } else {
                    chart(days)
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Day")
                        Text("Focus").gridColumnAlignment(.trailing)
                        Text("Distractions").gridColumnAlignment(.trailing)
                        Text("Sessions done").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(days) { day in
                        GridRow {
                            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                            Text(day.focus > 0 ? duration(day.focus) : "–")
                            Text(day.distracted > 0 ? duration(day.distracted) : "–")
                            Text(day.sessions > 0 ? "\(day.sessionsDone) of \(day.sessions)" : "–")
                        }
                        .monospacedDigit()
                    }
                }
            }
            .padding(8)
        }
    }

    /// Two bars per day on one shared time axis: focus session time and distraction time.
    private func chart(_ days: [DaySummary]) -> some View {
        // Round the time axis to whole steps that suit the tallest bar.
        let tallest = (days.map { max($0.focus, $0.distracted) }.max() ?? 0) / 60
        let step: Double = tallest <= 60 ? 15 : tallest <= 180 ? 30 : tallest <= 480 ? 60 : 120
        let top = max(step, (tallest / step).rounded(.up) * step)
        let ticks = Array(stride(from: 0, through: top, by: step))

        return Chart {
            ForEach(days) { day in
                let weekday = day.date.formatted(.dateTime.weekday(.abbreviated))
                BarMark(x: .value("Day", weekday), y: .value("Minutes", day.focus / 60), width: .fixed(18))
                    .foregroundStyle(by: .value("Kind", Self.focusLabel))
                    .position(by: .value("Kind", Self.focusLabel), axis: .horizontal, span: .fixed(40))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                BarMark(x: .value("Day", weekday), y: .value("Minutes", day.distracted / 60), width: .fixed(18))
                    .foregroundStyle(by: .value("Kind", Self.distractionLabel))
                    .position(by: .value("Kind", Self.distractionLabel), axis: .horizontal, span: .fixed(40))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
        }
        .chartForegroundStyleScale([
            Self.focusLabel: ChartColor.focus,
            Self.distractionLabel: ChartColor.distraction,
        ])
        .chartLegend(position: .top, alignment: .leading, spacing: 14)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Double.self) { Text(Self.axisLabel(minutes)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .frame(height: 220)
    }

    private static func axisLabel(_ minutes: Double) -> String {
        let m = Int(minutes)
        if m == 0 { return "0" }
        if m % 60 == 0 { return "\(m / 60)h" }
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    private func title(_ days: [DaySummary]) -> String {
        if weekOffset == 0 { return "Last 7 days" }
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(first.formatted(style)) to \(last.formatted(style))"
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var newHost = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.headline)
                Toggle("Open ThreeThings at login", isOn: Binding(
                    get: { openAtLogin },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                if let loginError {
                    Text("Couldn't change the login setting: \(loginError)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text("Sessions").font(.headline)
                Stepper("Session length: \(store.data.settings.sessionMinutes) min",
                        value: $store.data.settings.sessionMinutes, in: 5...120, step: 5)
                Stepper("Wait before you can continue: \(store.data.settings.frictionSeconds) s",
                        value: $store.data.settings.frictionSeconds, in: 5...120, step: 5)
                Stepper("Pass after pushing through: \(store.data.settings.passMinutes) min",
                        value: $store.data.settings.passMinutes, in: 1...30)

                Text("Check-ins").font(.headline)
                Stepper(store.data.settings.checkinMinutes > 0
                        ? "Ask “still on task?” every \(store.data.settings.checkinMinutes) min of a session"
                        : "Check-ins are off",
                        value: $store.data.settings.checkinMinutes, in: 0...60, step: 5)
                Toggle("Play a sound with check-ins", isOn: $store.data.settings.checkinSound)
                    .disabled(store.data.settings.checkinMinutes == 0)
                Text("Check-ins arrive as notifications. macOS asks for permission when your next session starts, and hides them while a Focus mode such as Do Not Disturb is on.")
                    .font(.caption).foregroundStyle(.secondary)

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
            .onChange(of: store.data.settings.checkinMinutes) { store.save() }
            .onChange(of: store.data.settings.checkinSound) { store.save() }
        }
    }

    private func addHost() {
        store.addBlockedHost(newHost)
        newHost = ""
    }
}
