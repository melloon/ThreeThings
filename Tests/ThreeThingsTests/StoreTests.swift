import XCTest
@testable import ThreeThings

final class StoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threethings-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeStore() -> Store { Store(fileURL: fileURL) }

    // MARK: Blocklist

    func testBlockedEntryMatchesSubdomainsButNotLookalikes() {
        let settings = Settings()
        XCTAssertEqual(settings.blockedEntry(forHost: "youtube.com"), "youtube.com")
        XCTAssertEqual(settings.blockedEntry(forHost: "m.YouTube.com"), "youtube.com")
        XCTAssertNil(settings.blockedEntry(forHost: "notyoutube.com"))
        XCTAssertNil(settings.blockedEntry(forHost: "youtube.com.example.org"))
    }

    func testAddBlockedHostNormalisesInput() {
        let store = makeStore()
        store.addBlockedHost("  https://www.Example.com/some/page ")
        XCTAssertTrue(store.data.settings.blockedHosts.contains("example.com"))

        let count = store.data.settings.blockedHosts.count
        store.addBlockedHost("example.com")
        XCTAssertEqual(store.data.settings.blockedHosts.count, count, "duplicates are ignored")
    }

    func testToggleBlockedForSiteAndApp() {
        let store = makeStore()
        XCTAssertTrue(store.isBlocked(host: "old.reddit.com", bundleID: "browser"))
        store.toggleBlocked(host: "old.reddit.com", bundleID: "browser")
        XCTAssertFalse(store.isBlocked(host: "reddit.com", bundleID: "browser"))

        XCTAssertFalse(store.isBlocked(host: nil, bundleID: "com.example.chat"))
        store.toggleBlocked(host: nil, bundleID: "com.example.chat")
        XCTAssertTrue(store.isBlocked(host: nil, bundleID: "com.example.chat"))
        store.toggleBlocked(host: nil, bundleID: "com.example.chat")
        XCTAssertFalse(store.isBlocked(host: nil, bundleID: "com.example.chat"))
    }

    // MARK: Tasks and sessions

    func testAtMostThreeTasksPerDay() {
        let store = makeStore()
        for title in ["one", "two", "three", "four"] { store.addTask(title) }
        store.addTask("   ")
        XCTAssertEqual(store.todayTasks.map(\.title), ["one", "two", "three"])
    }

    func testSessionLifecycle() throws {
        let store = makeStore()
        store.addTask("Write report")
        let task = try XCTUnwrap(store.todayTasks.first)

        store.startSession(task)
        let session = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(session.title, "Write report")
        XCTAssertEqual(session.plannedMinutes, store.data.settings.sessionMinutes)

        store.startSession(task)
        XCTAssertEqual(store.data.sessions.count, 1, "only one session runs at a time")

        let ended = try XCTUnwrap(store.endActiveSession())
        XCTAssertNil(store.activeSession)
        XCTAssertNil(store.endActiveSession())

        store.setOutcome(ended.id, "partial")
        XCTAssertFalse(try XCTUnwrap(store.todayTasks.first).done)
        store.setOutcome(ended.id, "done")
        XCTAssertTrue(try XCTUnwrap(store.todayTasks.first).done)
    }

    func testUnfinishedTasksCarryOverToToday() {
        let store = makeStore()
        let yesterday = dayKey(Date().addingTimeInterval(-86400))
        let lastWeek = dayKey(Date().addingTimeInterval(-7 * 86400))
        store.data.tasks = [
            TaskItem(title: "old", day: lastWeek),
            TaskItem(title: "finished", day: yesterday, done: true),
            TaskItem(title: "unfinished", day: yesterday),
        ]
        store.carryOverTasks()

        XCTAssertEqual(store.todayTasks.map(\.title), ["unfinished"])
        XCTAssertEqual(store.data.tasks.first { $0.title == "finished" }?.day, yesterday)
        XCTAssertEqual(store.data.tasks.first { $0.title == "old" }?.day, lastWeek,
                       "only the most recent day carries over")
    }

    func testCarryOverLeavesAStartedDayAlone() {
        let store = makeStore()
        store.addTask("today's own task")
        store.data.tasks.append(TaskItem(title: "unfinished", day: dayKey(Date().addingTimeInterval(-86400))))
        store.carryOverTasks()
        XCTAssertEqual(store.todayTasks.map(\.title), ["today's own task"])
    }

    // MARK: Weekly totals

    func testWeekSummariesTotalEachDay() {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!
        let sessionID = UUID()

        func segment(_ start: Date, minutes: Double, session: UUID? = nil, distracting: Bool = false) -> Segment {
            Segment(start: start, end: start.addingTimeInterval(minutes * 60), app: "App", bundleID: "app",
                    host: nil, sessionID: session, distracting: distracting)
        }
        store.data.segments = [
            segment(twoDaysAgo, minutes: 25, session: sessionID),
            segment(twoDaysAgo.addingTimeInterval(3600), minutes: 10, distracting: true),
            segment(today, minutes: 5, session: sessionID, distracting: true),
            segment(eightDaysAgo, minutes: 30, distracting: true),
        ]
        store.data.sessions = [
            Session(taskID: UUID(), title: "a", start: twoDaysAgo, end: twoDaysAgo.addingTimeInterval(1500),
                    plannedMinutes: 25, outcome: "done"),
            Session(taskID: UUID(), title: "b", start: twoDaysAgo.addingTimeInterval(7200),
                    end: twoDaysAgo.addingTimeInterval(8700), plannedMinutes: 25, outcome: "partial"),
        ]

        let days = store.weekSummaries(endingOn: Date())
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.id, dayKey(Date()), "the last day is today")
        XCTAssertEqual(days[4].focus, 25 * 60)
        XCTAssertEqual(days[4].distracted, 10 * 60)
        XCTAssertEqual(days[4].sessions, 2)
        XCTAssertEqual(days[4].sessionsDone, 1)
        XCTAssertEqual(days[6].focus, 5 * 60)
        XCTAssertEqual(days[6].distracted, 5 * 60)
        XCTAssertEqual(days.reduce(0) { $0 + $1.distracted }, 15 * 60, "older time is excluded")
    }

    // MARK: Tracking

    func testRecordMergesSameActivityAndSplitsOnChange() {
        let store = makeStore()
        store.record(app: "Orion", bundleID: "browser", host: "example.com", distracting: false)
        store.record(app: "Orion", bundleID: "browser", host: "example.com", distracting: false)
        XCTAssertEqual(store.data.segments.count, 1)

        store.record(app: "Orion", bundleID: "browser", host: "youtube.com", distracting: true)
        store.record(app: "Notes", bundleID: "notes", host: nil, distracting: false)
        XCTAssertEqual(store.data.segments.map(\.label), ["example.com", "youtube.com", "Notes"])
    }

    func testRecordStartsNewSegmentWhenSessionStarts() throws {
        let store = makeStore()
        store.addTask("Task")
        store.record(app: "Notes", bundleID: "notes", host: nil, distracting: false)
        store.startSession(try XCTUnwrap(store.todayTasks.first))
        store.record(app: "Notes", bundleID: "notes", host: nil, distracting: false)

        XCTAssertEqual(store.data.segments.count, 2)
        XCTAssertNil(store.data.segments[0].sessionID)
        XCTAssertEqual(store.data.segments[1].sessionID, store.activeSession?.id)
    }

    // MARK: Persistence

    func testDataSurvivesReload() {
        let store = makeStore()
        store.addTask("Persist me")
        store.addBlockedHost("example.org")
        store.addOverride(target: "youtube.com", reason: "tutorial", task: "Persist me")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.todayTasks.map(\.title), ["Persist me"])
        XCTAssertTrue(reloaded.data.settings.blockedHosts.contains("example.org"))
        XCTAssertEqual(reloaded.data.overrides.first?.reason, "tutorial")
    }

    func testFileSavedBeforeASettingExistedStillLoads() throws {
        // A file from before check-ins were added: no checkinMinutes or checkinSound.
        let old = """
        {"tasks":[{"id":"\(UUID().uuidString)","title":"Kept","day":"\(dayKey(Date()))","done":false}],
         "sessions":[],"segments":[],"overrides":[],
         "settings":{"blockedHosts":["example.com"],"blockedApps":[],"sessionMinutes":45,
                     "frictionSeconds":20,"passMinutes":5}}
        """
        try Data(old.utf8).write(to: fileURL)

        let store = makeStore()
        XCTAssertEqual(store.todayTasks.map(\.title), ["Kept"])
        XCTAssertEqual(store.data.settings.sessionMinutes, 45)
        XCTAssertEqual(store.data.settings.blockedHosts, ["example.com"])
        XCTAssertEqual(store.data.settings.checkinMinutes, Settings().checkinMinutes)
    }

    func testCheckinsDue() {
        XCTAssertEqual(Tracker.checkinsDue(elapsed: 9 * 60 + 59, everyMinutes: 10), 0)
        XCTAssertEqual(Tracker.checkinsDue(elapsed: 10 * 60, everyMinutes: 10), 1)
        XCTAssertEqual(Tracker.checkinsDue(elapsed: 24 * 60, everyMinutes: 10), 2)
        XCTAssertEqual(Tracker.checkinsDue(elapsed: 24 * 60, everyMinutes: 0), 0, "0 turns check-ins off")
    }

    func testSessionLeftOpenIsClosedOnLoad() throws {
        let store = makeStore()
        store.addTask("Task")
        store.startSession(try XCTUnwrap(store.todayTasks.first))

        let reloaded = makeStore()
        XCTAssertNil(reloaded.activeSession)
        XCTAssertNotNil(reloaded.data.sessions.first?.end)
    }

    func testDataFileIsPrivateToTheUser() throws {
        let store = makeStore()
        store.addTask("Task")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: Browser front window

    func testBrowserWindowInFrontIsRecognised() {
        let browserWindow = CGRect(x: 0, y: 39, width: 1800, height: 1045)
        let sliver = CGRect(x: 783, y: 574, width: 20, height: 1)
        XCTAssertTrue(Browser.isFrontWindow(scriptedBounds: [0, 39, 1800, 1084],
                                            onScreen: [sliver, browserWindow]))
    }

    func testSettingsWindowInFrontOfBrowserWindowIsNotTheBrowserWindow() {
        let settings = CGRect(x: 500, y: 200, width: 780, height: 560)
        let browserWindow = CGRect(x: 0, y: 39, width: 1800, height: 1045)
        XCTAssertFalse(Browser.isFrontWindow(scriptedBounds: [0, 39, 1800, 1084],
                                             onScreen: [settings, browserWindow]))
    }

    func testNoWindowsOrBadBoundsIsNotTheBrowserWindow() {
        XCTAssertFalse(Browser.isFrontWindow(scriptedBounds: [0, 39, 1800, 1084], onScreen: []))
        XCTAssertFalse(Browser.isFrontWindow(scriptedBounds: [], onScreen: [CGRect(x: 0, y: 0, width: 800, height: 600)]))
    }

    // MARK: Formatting

    func testClockAndDuration() {
        XCTAssertEqual(clock(1500), "25:00")
        XCTAssertEqual(clock(-5), "0:00")
        XCTAssertEqual(duration(45), "45s")
        XCTAssertEqual(duration(600), "10m")
        XCTAssertEqual(duration(3900), "1h 5m")
    }
}
