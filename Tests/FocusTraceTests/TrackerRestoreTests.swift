import Combine
import XCTest
import TrackingCore
@testable import FocusTrace

@MainActor final class TrackerRestoreTests: XCTestCase {
    private func fixture() throws -> (URL, URL, RecordingSnapshot) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = root.appendingPathComponent("Data", isDirectory: true)
        let database = try RecordingDatabase(directory: data)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        try database.save(visits: [(0, Visit(service: .youtube, start: start, end: start.addingTimeInterval(2)))], coverage: [])
        try database.saveOptions(TrackingOptions(websitesEnabled: true, enabledBrowsers: [.safari], idleMinutes: 10))
        let expected = try database.loadSnapshot()
        let backup = root.appendingPathComponent("restore.sqlite3")
        try database.backup(to: backup)
        try database.save(visits: [(1, Visit(service: .kakao, start: start.addingTimeInterval(10), end: start.addingTimeInterval(12)))], coverage: [])
        try database.saveCatalog(sources: [], categories: CategoryCatalog())
        return (root, backup, expected)
    }

    func testRestoreIgnoresOldSaveCompletionsAndReloadsAllPublishedState() async throws {
        let (root, backup, expected) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tracker = Tracker(directory: root.appendingPathComponent("Data"), backupDirectory: root.appendingPathComponent("Backups"), defaults: defaults, observesSystem: false)
        XCTAssertNil(tracker.storageError)
        tracker.save(); tracker.save() // one queued write plus a coalesced request
        let completed = expectation(description: "restore completion")
        let subscription = tracker.$restoring.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        tracker.restoreBackup(from: backup)
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(tracker.backupError)
        XCTAssertEqual(tracker.ledger.visits, expected.visits)
        XCTAssertEqual(tracker.sources, expected.sources)
        XCTAssertEqual(tracker.categories, expected.categories)
        XCTAssertTrue(tracker.websitesEnabled)
        XCTAssertEqual(tracker.enabledBrowsers, [.safari])
        XCTAssertEqual(tracker.idleMinutes, 10)
        tracker.finish()
        XCTAssertEqual(try RecordingDatabase(directory: root.appendingPathComponent("Data")).loadSnapshot(), expected)
    }

    func testQuitWhileRestoreIsPendingCannotWriteOldHistoryBackOrRestartTracking() async throws {
        let (root, backup, expected) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = Tracker(directory: root.appendingPathComponent("Data"), backupDirectory: root.appendingPathComponent("Backups"),
                              defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), observesSystem: false)
        let completed = expectation(description: "restore finishes after quit")
        let subscription = tracker.$restoring.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        tracker.restoreBackup(from: backup)
        tracker.finish() // synchronously drains the restore, never the old ledger
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(tracker.running)
        XCTAssertEqual(try RecordingDatabase(directory: root.appendingPathComponent("Data")).loadSnapshot(), expected)
    }

    func testRestoreWorksWhenCorruptDatabasePreventedStartup() async throws {
        let (root, backup, expected) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Data")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("recording.sqlite3"))
        let tracker = Tracker(directory: directory, backupDirectory: root.appendingPathComponent("Backups"),
                              defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), observesSystem: false)
        XCTAssertNotNil(tracker.storageError)
        XCTAssertTrue(tracker.canRestoreBackup)
        let completed = expectation(description: "startup recovery completed")
        let subscription = tracker.$restoring.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        tracker.restoreBackup(from: backup)
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(tracker.storageError)
        XCTAssertNil(tracker.backupError)
        XCTAssertEqual(tracker.ledger.visits, expected.visits)
        tracker.finish()
    }
}
