import AppKit
import SwiftUI
import XCTest
@testable import ThreeThings

/// The menu panel must keep its top edge under the menu bar however its content changes height.
/// The panel is opened on screen but fully transparent, so nothing appears while the tests run.
final class MenuPanelTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        _ = NSApplication.shared
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threethings-panel-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    func testTopEdgeStaysPutWhileContentGrowsAndShrinks() throws {
        let store = Store(fileURL: fileURL)
        store.addTask("One")
        let panel = MenuPanel()
        panel.setContent(MenuView().environmentObject(store))
        let anchor = NSRect(x: 200, y: 600, width: 30, height: 24)
        panel.alpha = 0

        panel.open(below: anchor, screen: nil)
        settle()
        let idle = panel.frame
        XCTAssertTrue(panel.isOpen)
        XCTAssertEqual(idle.minX, anchor.minX)
        XCTAssertEqual(idle.maxY, anchor.minY - 5, "opens just under the menu bar item")
        XCTAssertEqual(idle.width, 320)

        // Two more tasks and a running session make the content taller.
        store.addTask("Two")
        store.addTask("Three")
        store.startSession(try XCTUnwrap(store.todayTasks.first))
        settle()
        let running = panel.frame
        XCTAssertGreaterThan(running.height, idle.height + 40, "the panel grew with its content")
        XCTAssertEqual(running.maxY, idle.maxY, "growing extends the bottom edge, not the top")
        XCTAssertEqual(running.minX, idle.minX)

        // Ending the session and removing tasks makes it shorter again.
        store.endActiveSession()
        for task in store.todayTasks.dropFirst() { store.removeTask(task.id) }
        settle()
        let shrunk = panel.frame
        XCTAssertLessThan(shrunk.height, running.height - 40, "the panel shrank with its content")
        XCTAssertEqual(shrunk.maxY, idle.maxY, "shrinking retracts the bottom edge, not the top")

        panel.close()
        XCTAssertFalse(panel.isOpen)
    }

    func testOpensAtTheRightSizeAfterContentChangedWhileClosed() throws {
        let store = Store(fileURL: fileURL)
        store.addTask("One")
        let panel = MenuPanel()
        panel.setContent(MenuView().environmentObject(store))
        let anchor = NSRect(x: 200, y: 600, width: 30, height: 24)
        panel.alpha = 0

        panel.open(below: anchor, screen: nil)
        settle()
        let before = panel.frame
        panel.close()

        store.addTask("Two")
        store.addTask("Three")
        store.startSession(try XCTUnwrap(store.todayTasks.first))
        settle()

        panel.open(below: anchor, screen: nil)
        let reopened = panel.frame
        XCTAssertGreaterThan(reopened.height, before.height + 40, "sized for the new content straight away")
        XCTAssertEqual(reopened.maxY, anchor.minY - 5)
        settle()
        XCTAssertEqual(panel.frame, reopened, "no second jump after opening")
        panel.close()
    }

    func testMenuBarTitle() {
        var session = Session(taskID: UUID(), title: "Review pull requests", start: Date(), plannedMinutes: 25)
        XCTAssertEqual(MenuBarController.title(session: session, remaining: 1412, breakRemaining: nil),
                       "◉ Review pull requests · 23:32")
        session.pausedAt = Date()
        XCTAssertEqual(MenuBarController.title(session: session, remaining: 1244, breakRemaining: nil),
                       "⏸ Review pull requests · 20:44")
        XCTAssertEqual(MenuBarController.title(session: nil, remaining: 0, breakRemaining: 296), "Break · 4:56")
        XCTAssertNil(MenuBarController.title(session: nil, remaining: 0, breakRemaining: nil))
    }
}
