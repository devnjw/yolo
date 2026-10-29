import XCTest
import SQLite3
@testable import TrackingCore

final class RecordingBackupsTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("Data", isDirectory: true) }
    private var repository: RecordingBackups { RecordingBackups(directory: root.appendingPathComponent("Backups", isDirectory: true)) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func populated() throws -> RecordingDatabase {
        let database = try RecordingDatabase(directory: directory)
        let source = Source(name: "Site", kind: .website, identifier: "example.com", aliases: ["example.org"])
        var categories = CategoryCatalog(legacySources: [source])
        let id = try categories.create(name: "Custom", tint: .purple, customHex: 0xABCDEF, assigning: categories.serviceID(for: source))
        try categories.select([id])
        try database.saveCatalog(sources: [source], categories: categories)
        try database.saveOptions(TrackingOptions(websitesEnabled: true, enabledBrowsers: [.safari], idleMinutes: 10))
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var coverage = RecordingCoverage(); coverage.observe(at: start); coverage.observe(at: start.addingTimeInterval(2))
        try database.save(visits: [(0, Visit(service: source.id, start: start, end: start.addingTimeInterval(2)))], coverage: [(0, coverage.intervals[0])])
        return database
    }

    func testSingleFileBackupRestoresCompleteSnapshotAndPreservesCurrentDataInRecovery() throws {
        let database = try populated()
        let original = try database.loadSnapshot()
        let manual = root.appendingPathComponent("manual.sqlite3")
        try database.backup(to: manual)
        XCTAssertEqual(try RecordingDatabase.validateBackup(at: manual), original)
        try database.saveCatalog(sources: [], categories: CategoryCatalog())
        try database.saveOptions(TrackingOptions())
        let changed = try database.loadSnapshot()
        let recovery = try repository.recoveryURL()
        XCTAssertEqual(try database.restore(from: manual, recoveryURL: recovery), original)
        XCTAssertEqual(try database.loadSnapshot(), original)
        XCTAssertEqual(try RecordingDatabase.validateBackup(at: recovery), changed)
        let attributes = try FileManager.default.attributesOfItem(atPath: manual.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidBackupAndUnavailableRecoveryLocationLeaveLiveDataUntouched() throws {
        let database = try populated(), original = try database.loadSnapshot()
        let invalid = root.appendingPathComponent("bad.sqlite3")
        try Data("broken".utf8).write(to: invalid)
        XCTAssertThrowsError(try database.restore(from: invalid, recoveryURL: root.appendingPathComponent("recovery.sqlite3")))
        XCTAssertEqual(try database.loadSnapshot(), original)
        let valid = root.appendingPathComponent("valid.sqlite3")
        try database.backup(to: valid)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        XCTAssertThrowsError(try database.restore(from: valid, recoveryURL: blocked.appendingPathComponent("recovery.sqlite3")))
        XCTAssertEqual(try database.loadSnapshot(), original)
    }

    func testBackupCannotOverwriteLiveFileOrAliasAndFailurePreservesExistingBackup() throws {
        var database: RecordingDatabase? = try populated()
        let original = try database!.loadSnapshot()
        XCTAssertThrowsError(try database!.backup(to: database!.url, overwrite: true))
        let alias = root.appendingPathComponent("alias.sqlite3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: database!.url)
        XCTAssertThrowsError(try database!.backup(to: alias, overwrite: true))
        XCTAssertThrowsError(try database!.restore(from: alias, recoveryURL: root.appendingPathComponent("recovery.sqlite3")))
        let destination = root.appendingPathComponent("existing.sqlite3")
        let bytes = Data("keep me".utf8); try bytes.write(to: destination)
        XCTAssertThrowsError(try database!.backup(to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try database!.loadSnapshot(), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".focustrace-backup-") })
        // macOS SQLite invalidates its open handle when a hard link is added.
        // Verify identity protection, then reopen after removing the test link.
        let hardLink = root.appendingPathComponent("hardlink.sqlite3")
        try FileManager.default.linkItem(at: database!.url, to: hardLink)
        XCTAssertThrowsError(try database!.backup(to: hardLink, overwrite: true))
        try FileManager.default.removeItem(at: hardLink)
        database = nil
        XCTAssertEqual(try RecordingDatabase(directory: directory).loadSnapshot(), original)
    }

    func testAutomaticDailyRetentionDoesNotDeleteManualOrRecoveryBackups() throws {
        let database = try populated(), backups = repository
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_700_006_400)
        let manual = root.appendingPathComponent("manual.sqlite3")
        try database.backup(to: manual)
        let recovery = try backups.recoveryURL(now: base); try database.backup(to: recovery)
        var last: RecordingBackups.Entry!
        for day in 0..<10 {
            last = try backups.automaticBackupIfNeeded(database: database, now: base.addingTimeInterval(Double(day * 86400)), calendar: calendar)
        }
        XCTAssertEqual(try backups.automaticEntries().count, 7)
        let again = try backups.automaticBackupIfNeeded(database: database, now: last.date.addingTimeInterval(1), calendar: calendar)
        XCTAssertEqual(again.url, last.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        // A corrupt "today" backup must not suppress creation of a valid one.
        try Data("broken".utf8).write(to: last.url)
        let repaired = try backups.automaticBackupIfNeeded(database: database, now: last.date.addingTimeInterval(2), calendar: calendar)
        XCTAssertNotEqual(repaired.url, last.url)
        XCTAssertEqual(try RecordingDatabase.validateBackup(at: repaired.url), try database.loadSnapshot())
    }

    func testWriterBacksUpLatestTailAndCatalogWithoutCapturingLaterWrites() throws {
        let database = try populated(), writer = RecordingWriter(database: database)
        let initial = try database.loadSnapshot()
        var tail = initial.visits[0]; tail.end = tail.end.addingTimeInterval(1)
        let captured = tail
        let destination = root.appendingPathComponent("writer.sqlite3")
        let completed = expectation(description: "backup completed")
        writer.backup(visits: [(0, captured)], coverage: [], destination: destination, repository: repository) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        tail.end = tail.end.addingTimeInterval(1)
        try writer.finish(visits: [(0, tail)], coverage: [])
        wait(for: [completed], timeout: 5)
        let snapshot = try RecordingDatabase.validateBackup(at: destination)
        XCTAssertEqual(snapshot.visits, [captured])
        XCTAssertEqual(snapshot.sources, initial.sources)
        XCTAssertEqual(snapshot.categories, initial.categories)
        XCTAssertEqual(snapshot.options, initial.options)
        XCTAssertEqual(try database.loadVisits(), [tail])
    }

    func testCorruptClosedDatabaseCanBeRecoveredAndOriginalBytesArePreserved() throws {
        var database: RecordingDatabase? = try populated()
        let expected = try database!.loadSnapshot()
        let backup = root.appendingPathComponent("good.sqlite3"); try database!.backup(to: backup)
        let live = database!.url; database = nil
        let corrupted = Data("corrupted database".utf8); try corrupted.write(to: live)
        let recovery = try repository.recoveryURL()
        let repaired = try RecordingDatabase.recoverClosedDatabase(at: live, from: backup, recoveryURL: recovery)
        XCTAssertEqual(try repaired.loadSnapshot(), expected)
        XCTAssertEqual(try Data(contentsOf: recovery), corrupted)
    }

    func testOfflineRecoveryNeverDiscardsPendingJournal() throws {
        var database: RecordingDatabase? = try populated()
        let backup = root.appendingPathComponent("good.sqlite3"); try database!.backup(to: backup)
        let live = database!.url; database = nil
        let original = try Data(contentsOf: live)
        let journal = URL(fileURLWithPath: live.path + "-journal")
        let bytes = Data("unfinished journal".utf8); try bytes.write(to: journal)
        XCTAssertThrowsError(try RecordingDatabase.recoverClosedDatabase(at: live, from: backup, recoveryURL: repository.recoveryURL()))
        XCTAssertEqual(try Data(contentsOf: live), original)
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testUnknownSQLiteDatabaseIsRejectedWithoutModification() throws {
        let other = root.appendingPathComponent("other.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(other.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE other(value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        let original = try Data(contentsOf: other)
        XCTAssertThrowsError(try RecordingDatabase.validateBackup(at: other))
        XCTAssertEqual(try Data(contentsOf: other), original)
    }

    func testLockedDestinationCannotPartiallyReplaceLiveDatabase() throws {
        let database = try populated()
        let backup = root.appendingPathComponent("selected.sqlite3")
        try database.backup(to: backup)
        try database.saveCatalog(sources: [], categories: CategoryCatalog())
        let current = try database.loadSnapshot()
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.url.path, &reader), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM visits", nil, nil, nil), SQLITE_OK)
        let recovery = try repository.recoveryURL()
        XCTAssertThrowsError(try database.restore(from: backup, recoveryURL: recovery))
        XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try database.loadSnapshot(), current)
        XCTAssertEqual(try RecordingDatabase.validateBackup(at: recovery), current)
    }

}
