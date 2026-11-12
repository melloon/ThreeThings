import XCTest
@testable import OneThing

final class StoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onething-test-\(UUID().uuidString).json")
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

    // MARK: Formatting

    func testClockAndDuration() {
        XCTAssertEqual(clock(1500), "25:00")
        XCTAssertEqual(clock(-5), "0:00")
        XCTAssertEqual(duration(45), "45s")
        XCTAssertEqual(duration(600), "10m")
        XCTAssertEqual(duration(3900), "1h 5m")
    }
}
