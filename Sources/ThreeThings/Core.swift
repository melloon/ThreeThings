import Foundation
import Combine

// MARK: - Models

struct TaskItem: Codable, Identifiable {
    var id = UUID()
    var title: String
    var day: String
    var done = false
}

struct Session: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var title: String
    var start: Date
    var end: Date?
    var plannedMinutes: Int
    /// "done", "partial" or "no"; nil until the check-in is answered.
    var outcome: String?
}

/// A stretch of time with one app (and, in Orion, one site) in front.
struct Segment: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var app: String
    var bundleID: String
    var host: String?
    var sessionID: UUID?
    var distracting: Bool

    var seconds: TimeInterval { end.timeIntervalSince(start) }
    var label: String { host ?? app }
}

/// A time the user pushed through the friction screen.
struct Override: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var target: String
    var reason: String
    var task: String
}

struct Settings: Codable {
    var blockedHosts = [
        "youtube.com", "reddit.com", "x.com", "twitter.com", "instagram.com",
        "facebook.com", "tiktok.com", "news.ycombinator.com", "netflix.com",
    ]
    var blockedApps: [String] = []
    var sessionMinutes = 25
    var frictionSeconds = 20
    var passMinutes = 5
    /// Minutes between "still on task?" check-ins during a session; 0 turns them off.
    var checkinMinutes = 10
    var checkinSound = false

    /// The blocklist entry that covers this host, if any ("m.youtube.com" matches "youtube.com").
    func blockedEntry(forHost host: String) -> String? {
        let h = host.lowercased()
        return blockedHosts.first { h == $0 || h.hasSuffix("." + $0) }
    }
}

extension Settings {
    /// Reads whatever settings a saved file has and keeps the defaults for the rest, so a file
    /// written before a setting existed still loads.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedHosts = try c.decodeIfPresent([String].self, forKey: .blockedHosts) ?? blockedHosts
        blockedApps = try c.decodeIfPresent([String].self, forKey: .blockedApps) ?? blockedApps
        sessionMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? sessionMinutes
        frictionSeconds = try c.decodeIfPresent(Int.self, forKey: .frictionSeconds) ?? frictionSeconds
        passMinutes = try c.decodeIfPresent(Int.self, forKey: .passMinutes) ?? passMinutes
        checkinMinutes = try c.decodeIfPresent(Int.self, forKey: .checkinMinutes) ?? checkinMinutes
        checkinSound = try c.decodeIfPresent(Bool.self, forKey: .checkinSound) ?? checkinSound
    }
}

struct AppData: Codable {
    var tasks: [TaskItem] = []
    var sessions: [Session] = []
    var segments: [Segment] = []
    var overrides: [Override] = []
    var settings = Settings()
}

// MARK: - Helpers

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func dayKey(_ date: Date) -> String {
    dayFormatter.string(from: date)
}

/// One day's totals, for the weekly view.
struct DaySummary: Identifiable {
    let date: Date
    var focus: TimeInterval = 0
    var distracted: TimeInterval = 0
    var sessions = 0
    var sessionsDone = 0

    var id: String { dayKey(date) }
}

func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    if m >= 1 { return "\(m)m" }
    return "\(Int(seconds))s"
}

// MARK: - Store

final class Store: ObservableObject {
    static let shared = Store()
    static let maxTasksPerDay = 3

    @Published var data = AppData()
    @Published var now = Date()
    private var dirty = false

    static let defaultFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeThings", isDirectory: true)
        // The log shows which apps and sites were used, so only this account may read it.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("data.json")
    }()

    private let fileURL: URL

    /// The app uses `Store.shared`; tests pass their own file so they never touch real data.
    init(fileURL: URL = Store.defaultFileURL) {
        self.fileURL = fileURL
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppData.self, from: raw) {
            data = decoded
        }
        // A session left open by a quit or crash is closed at its planned end.
        for i in data.sessions.indices where data.sessions[i].end == nil {
            let s = data.sessions[i]
            data.sessions[i].end = min(Date(), s.start.addingTimeInterval(Double(s.plannedMinutes) * 60))
        }
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        data.segments.removeAll { $0.end < cutoff }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        carryOverTasks()
    }

    func save() {
        dirty = false
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    func saveIfDirty() { if dirty { save() } }

    // Tasks

    var todayTasks: [TaskItem] { data.tasks.filter { $0.day == dayKey(now) } }

    func addTask(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, todayTasks.count < Self.maxTasksPerDay else { return }
        data.tasks.append(TaskItem(title: t, day: dayKey(now)))
        save()
    }

    /// Moves unfinished tasks from the most recent earlier day to today. Runs only while today
    /// has no tasks of its own, so it never adds to a list the user has already started.
    func carryOverTasks() {
        let today = dayKey(now)
        guard !data.tasks.contains(where: { $0.day == today }),
              let lastDay = data.tasks.map(\.day).filter({ $0 < today }).max() else { return }
        var moved = 0
        for i in data.tasks.indices
        where data.tasks[i].day == lastDay && !data.tasks[i].done && moved < Self.maxTasksPerDay {
            data.tasks[i].day = today
            moved += 1
        }
        if moved > 0 { save() }
    }

    func toggleDone(_ id: UUID) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        data.tasks[i].done.toggle()
        save()
    }

    func removeTask(_ id: UUID) {
        data.tasks.removeAll { $0.id == id }
        save()
    }

    // Sessions

    var activeSession: Session? { data.sessions.first { $0.end == nil } }

    func remaining(_ s: Session) -> TimeInterval {
        s.start.addingTimeInterval(Double(s.plannedMinutes) * 60).timeIntervalSince(now)
    }

    func startSession(_ task: TaskItem) {
        guard activeSession == nil else { return }
        data.sessions.append(Session(taskID: task.id, title: task.title, start: Date(),
                                     plannedMinutes: data.settings.sessionMinutes))
        save()
    }

    @discardableResult
    func endActiveSession() -> Session? {
        guard let i = data.sessions.firstIndex(where: { $0.end == nil }) else { return nil }
        data.sessions[i].end = Date()
        save()
        return data.sessions[i]
    }

    func setOutcome(_ sessionID: UUID, _ outcome: String) {
        guard let i = data.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        data.sessions[i].outcome = outcome
        if outcome == "done", let t = data.tasks.firstIndex(where: { $0.id == data.sessions[i].taskID }) {
            data.tasks[t].done = true
        }
        save()
    }

    // Tracking

    func record(app: String, bundleID: String, host: String?, distracting: Bool) {
        let sid = activeSession?.id
        let t = Date()
        if let last = data.segments.last, last.bundleID == bundleID, last.host == host,
           last.sessionID == sid, t.timeIntervalSince(last.end) < 10 {
            data.segments[data.segments.count - 1].end = t
        } else {
            data.segments.append(Segment(start: t.addingTimeInterval(-2), end: t, app: app,
                                         bundleID: bundleID, host: host, sessionID: sid,
                                         distracting: distracting))
        }
        dirty = true
    }

    /// Totals for each of the seven days ending on `date`, oldest first.
    func weekSummaries(endingOn date: Date, calendar: Calendar = .current) -> [DaySummary] {
        let end = calendar.startOfDay(for: date)
        var days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
            .map { DaySummary(date: $0) }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.id, $0) })

        for segment in data.segments {
            guard let i = index[dayKey(segment.start)] else { continue }
            if segment.sessionID != nil { days[i].focus += segment.seconds }
            if segment.distracting { days[i].distracted += segment.seconds }
        }
        for session in data.sessions {
            guard let i = index[dayKey(session.start)] else { continue }
            days[i].sessions += 1
            if session.outcome == "done" { days[i].sessionsDone += 1 }
        }
        return days
    }

    func addOverride(target: String, reason: String, task: String) {
        data.overrides.append(Override(date: Date(), target: target, reason: reason, task: task))
        save()
    }

    // Blocklist

    func isBlocked(host: String?, bundleID: String) -> Bool {
        if let host { return data.settings.blockedEntry(forHost: host) != nil }
        return data.settings.blockedApps.contains(bundleID)
    }

    func toggleBlocked(host: String?, bundleID: String) {
        if let host {
            if let entry = data.settings.blockedEntry(forHost: host) {
                data.settings.blockedHosts.removeAll { $0 == entry }
            } else {
                addBlockedHost(host)
            }
        } else if data.settings.blockedApps.contains(bundleID) {
            data.settings.blockedApps.removeAll { $0 == bundleID }
        } else {
            data.settings.blockedApps.append(bundleID)
        }
        save()
    }

    func addBlockedHost(_ raw: String) {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: h), let host = url.host { h = host }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        guard !h.isEmpty, !data.settings.blockedHosts.contains(h) else { return }
        data.settings.blockedHosts.append(h)
        save()
    }

    func appName(for bundleID: String) -> String {
        data.segments.last { $0.bundleID == bundleID }?.app ?? bundleID
    }
}
