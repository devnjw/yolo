import XCTest
import SQLite3
@testable import TrackingCore

final class RecordingDatabaseTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func visit(_ offset: Double = 0) -> Visit {
        Visit(service: .youtube, start: Date(timeIntervalSinceReferenceDate: offset),
              end: Date(timeIntervalSinceReferenceDate: offset + 1))
    }

    func testImportsLegacyOncePreservingIDsOrderDatesAndOriginalBytes() throws {
        let legacy = TrackingStore(directory: directory)
        let visits = [visit(100), visit(20)] // Original order need not be chronological.
        var coverage = RecordingCoverage()
        coverage.observe(at: visits[0].start); coverage.observe(at: visits[0].end)
        try legacy.saveVisits(visits); try legacy.saveCoverage(coverage)
        let visitBytes = try Data(contentsOf: legacy.visitsURL)
        let coverageBytes = try Data(contentsOf: legacy.coverageURL)
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try database!.loadVisits(), visits)
        XCTAssertEqual(try database!.loadCoverage(), coverage)
        var updated = visits[1]; updated.end = updated.end.addingTimeInterval(2)
        try database!.save(visits: [(1, updated)], coverage: [])
        database = nil
        let reopened = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try reopened.loadVisits(), [visits[0], updated])
        XCTAssertEqual(try Data(contentsOf: legacy.visitsURL), visitBytes)
        XCTAssertEqual(try Data(contentsOf: legacy.coverageURL), coverageBytes)
        // Stale legacy data must never overwrite authoritative SQLite records.
        try Data("broken".utf8).write(to: legacy.visitsURL)
        XCTAssertEqual(try RecordingDatabase(directory: directory).loadVisits(), [visits[0], updated])
    }

    func testMalformedLegacyCoverageCannotPartiallyImportVisits() throws {
        let legacy = TrackingStore(directory: directory)
        let original = [visit()]
        try legacy.saveVisits(original)
        try Data("broken".utf8).write(to: legacy.coverageURL)
        XCTAssertThrowsError(try RecordingDatabase(directory: directory))
        XCTAssertEqual(try legacy.loadVisits(), original)
        var coverage = RecordingCoverage(); coverage.observe(at: Date())
        try legacy.saveCoverage(coverage)
        let recovered = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try recovered.loadVisits(), original)
        XCTAssertEqual(try recovered.loadCoverage(), coverage)
    }

    func testTailUpdatesAndNewVisitsSurviveRestartWithoutDuplicates() throws {
        var ledger = Ledger()
        var coverage = RecordingCoverage()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        ledger.observe(.youtube, at: start); coverage.observe(at: start)
        try database!.save(visits: ledger.recordsToSave(after: 0), coverage: [(0, coverage.intervals[0])])
        ledger.observe(.kakao, at: start.addingTimeInterval(2)); coverage.observe(at: start.addingTimeInterval(2))
        ledger.observe(.kakao, at: start.addingTimeInterval(3)); coverage.observe(at: start.addingTimeInterval(3))
        let delta = ledger.recordsToSave(after: 1)
        XCTAssertEqual(delta.count, 2)
        try database!.save(visits: delta, coverage: [(0, coverage.intervals[0])])
        try database!.save(visits: delta, coverage: [(0, coverage.intervals[0])])
        database = nil
        let reopened = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try reopened.loadVisits(), ledger.visits)
        XCTAssertEqual(try reopened.loadCoverage(), coverage)
    }

    func testVisitAndCoverageChangesRollBackTogetherOnFailure() throws {
        let database = try RecordingDatabase(directory: directory)
        let original = visit()
        try database.save(visits: [(0, original)], coverage: [])
        var changed = original; changed.end = changed.end.addingTimeInterval(2)
        let invalidInterval = DateInterval(start: Date(timeIntervalSinceReferenceDate: .infinity), duration: 0)
        XCTAssertThrowsError(try database.save(visits: [(0, changed)], coverage: [(0, invalidInterval)]))
        XCTAssertEqual(try database.loadVisits(), [original])
        XCTAssertEqual(try database.loadCoverage().intervals, [])
        // Duplicate UUID at a second ordinal also rolls back an earlier update.
        XCTAssertThrowsError(try database.save(visits: [(0, changed), (1, original)], coverage: []))
        XCTAssertEqual(try database.loadVisits(), [original])
    }

    func testCorruptDatabaseIsNotReplacedByLegacyOrDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("recording.sqlite3")
        let broken = Data("not a database".utf8)
        try broken.write(to: path)
        XCTAssertThrowsError(try RecordingDatabase(directory: directory))
        XCTAssertEqual(try Data(contentsOf: path), broken)
    }

    func testPermissionsAndUnsupportedFutureVersion() throws {
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        let path = database!.url
        try database!.save(visits: [(0, visit())], coverage: [])
        for (url, mode) in [(directory!, 0o700), (path, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
        database = nil
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        XCTAssertThrowsError(try RecordingDatabase(directory: directory))
    }

    func testWriterFinishesQueuedBatchThenLatestTail() throws {
        let database = try RecordingDatabase(directory: directory)
        let writer = RecordingWriter(database: database)
        let first = visit()
        var last = first; last.end = last.end.addingTimeInterval(3)
        let completion = expectation(description: "background completion")
        writer.submit(visits: [(0, first)], coverage: []) { result in
            XCTAssertFalse(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail("Unexpected write error: \(error)") }
            completion.fulfill()
        }
        try writer.finish(visits: [(0, last)], coverage: [])
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(try database.loadVisits(), [last])
    }

    func testWriterLatchesFailureAndDoesNotSkipFailedBatchAtQuit() throws {
        let database = try RecordingDatabase(directory: directory)
        let writer = RecordingWriter(database: database)
        let first = visit()
        let completion = expectation(description: "failed batch")
        writer.submit(visits: [(0, first), (1, first)], coverage: []) { result in
            if case .success = result { XCTFail("Expected a failed batch") }
            completion.fulfill()
        }
        XCTAssertThrowsError(try writer.finish(visits: [(0, visit(20))], coverage: []))
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(try database.loadVisits(), [])
    }

    func testSaveCursorsAcrossRolloverIdleAndClockChangesPreserveAllRecords() throws {
        let database = try RecordingDatabase(directory: directory)
        var ledger = Ledger()
        var coverage = RecordingCoverage()
        var visitCursor = 0, coverageCursor = 0
        func save() throws {
            let intervals = coverage.intervals
            let first = max(0, coverageCursor - 1)
            try database.save(visits: ledger.recordsToSave(after: visitCursor),
                              coverage: intervals.indices.dropFirst(first).map { ($0, intervals[$0]) })
            visitCursor = ledger.visitCount; coverageCursor = intervals.count
        }
        for i in 0..<900 {
            // Includes a backwards clock adjustment and a long unobserved gap.
            let offset = i < 300 ? i : i < 600 ? i - 500 : i + 1000
            let date = Date(timeIntervalSinceReferenceDate: Double(offset))
            coverage.observe(at: date)
            if i.isMultiple(of: 17) { ledger.stop(at: date) }
            else { ledger.observe(i.isMultiple(of: 2) ? .youtube : .kakao, at: date) }
            if i.isMultiple(of: 11) { try save() }
        }
        try save()
        XCTAssertGreaterThan(ledger.visitCount, 768)
        XCTAssertEqual(try database.loadVisits(), ledger.visits)
        XCTAssertEqual(try database.loadCoverage(), coverage)
    }

    func testOptionalLegacyFixtureUpgradeOnPrivateCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["FOCUSTRACE_LEGACY_FIXTURE"] else {
            throw XCTSkip("Set FOCUSTRACE_LEGACY_FIXTURE to verify an existing installation on a private copy")
        }
        let fixture = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var bytes: [String: Data] = [:]
        for name in ["visits.json", "coverage.json", "sources.json", "categories.json"] {
            let source = fixture.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            bytes[name] = data
            let destination = directory.appendingPathComponent(name)
            try data.write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let legacy = TrackingStore(directory: directory)
        let expectedVisits = try legacy.loadVisits(), expectedCoverage = try legacy.loadCoverage()
        let database = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try database.loadVisits(), expectedVisits)
        XCTAssertEqual(try database.loadCoverage(), expectedCoverage)
        XCTAssertNoThrow(try legacy.loadCategories(legacySources: legacy.loadSources()))
        for (name, data) in bytes {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), data)
        }
    }

}
