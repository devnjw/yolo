import XCTest
import SQLite3
@testable import TrackingCore

final class CatalogDatabaseTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }

    private func sql(_ text: String) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("recording.sqlite3").path, &connection), SQLITE_OK)
        guard sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK else {
            throw RecordingDatabaseError(String(cString: sqlite3_errmsg(connection)))
        }
    }
    private func downgradeToV1() throws {
        try sql("""
            DROP TABLE source_aliases; DROP TABLE sources; DROP TABLE category_assignments;
            DROP TABLE categories; DROP TABLE catalog_settings; DROP TABLE tracking_options;
            PRAGMA user_version=1; PRAGMA application_id=0;
            """)
    }

    func testV1MigrationUsesCurrentSQLiteVisitsAndJSONCatalogExactlyOnce() throws {
        let legacy = TrackingStore(directory: directory)
        let old = Visit(service: .youtube, start: Date(timeIntervalSinceReferenceDate: 10), end: Date(timeIntervalSinceReferenceDate: 12))
        let newer = Visit(service: .kakao, start: Date(timeIntervalSinceReferenceDate: 20), end: Date(timeIntervalSinceReferenceDate: 22))
        try legacy.saveVisits([old])
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        try database!.save(visits: [(1, newer)], coverage: [])
        database = nil
        try downgradeToV1()
        let sources = [Source(name: "Custom", kind: .website, identifier: "example.com", aliases: ["example.org"], archived: true)]
        var categories = CategoryCatalog(legacySources: sources)
        let id = try categories.create(name: "My category", tint: .indigo, customHex: 0x123456)
        try categories.assign(id, to: categories.serviceID(for: sources[0]))
        try categories.renameService(categories.serviceID(for: sources[0]), to: "Renamed", sources: sources)
        try categories.select([id])
        try legacy.saveSources(sources); try legacy.saveCategories(categories)
        try Data("obsolete malformed visits".utf8).write(to: legacy.visitsURL)
        let sourceBytes = try Data(contentsOf: legacy.sourcesURL), categoryBytes = try Data(contentsOf: legacy.categoriesURL)
        let options = TrackingOptions(websitesEnabled: true, enabledBrowsers: [.safari], idleMinutes: 10)
        database = try RecordingDatabase(directory: directory, legacyOptions: options)
        XCTAssertEqual(try database!.loadVisits(), [old, newer])
        XCTAssertEqual(try database!.loadSources(), sources)
        XCTAssertEqual(try database!.loadCategories(), categories)
        XCTAssertEqual(try database!.loadOptions(), options)
        XCTAssertEqual(try Data(contentsOf: legacy.sourcesURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: legacy.categoriesURL), categoryBytes)
        database = nil
        try Data("broken".utf8).write(to: legacy.sourcesURL)
        try Data("broken".utf8).write(to: legacy.categoriesURL)
        let reopened = try RecordingDatabase(directory: directory)
        XCTAssertEqual(try reopened.loadSources(), sources)
        XCTAssertEqual(try reopened.loadCategories(), categories)
        XCTAssertEqual(try reopened.loadOptions(), options)
    }

    func testMalformedCatalogCannotPartiallyUpgradeV1() throws {
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        let visit = Visit(service: .youtube, start: Date(), end: Date())
        try database!.save(visits: [(0, visit)], coverage: [])
        database = nil
        try downgradeToV1()
        let legacy = TrackingStore(directory: directory)
        try Data("broken".utf8).write(to: legacy.categoriesURL)
        let original = try Data(contentsOf: directory.appendingPathComponent("recording.sqlite3"))
        XCTAssertThrowsError(try RecordingDatabase(directory: directory))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recording.sqlite3")), original)
        try legacy.saveCategories(CategoryCatalog())
        XCTAssertEqual(try RecordingDatabase(directory: directory).loadVisits(), [visit])
    }

    func testCatalogTransactionsRollBackAndPreserveGroupingSettings() throws {
        let database = try RecordingDatabase(directory: directory)
        let sources = [Source(name: "Notion", kind: .app, identifier: "notion.id"),
                       Source(name: "Notion web", kind: .website, identifier: "notion.so"),
                       Source(name: "Other", kind: .website, identifier: "example.com")]
        var categories = CategoryCatalog(legacySources: sources)
        let split = try categories.splitServiceMember(sources[1].id, from: "known:notion", name: "Separate", sources: sources)
        try categories.mergeService(split, into: categories.serviceID(for: sources[2]), name: "Merged", categoryID: "learning", sources: sources)
        try categories.select(["learning"])
        try database.saveCatalog(sources: sources, categories: categories)
        XCTAssertEqual(try database.loadCategories(), categories)
        XCTAssertEqual(try database.loadSources(), sources)
        XCTAssertThrowsError(try database.saveCatalog(sources: [sources[0], sources[0]], categories: CategoryCatalog()))
        XCTAssertEqual(try database.loadCategories(), categories)
        XCTAssertEqual(try database.loadSources(), sources)
        let options = TrackingOptions(websitesEnabled: true, enabledBrowsers: [], idleMinutes: 0)
        try database.saveOptions(options)
        XCTAssertThrowsError(try database.saveOptions(TrackingOptions(idleMinutes: -1)))
        XCTAssertEqual(try database.loadOptions(), options)
    }

    func testCorruptV2CatalogDoesNotFallBackToLegacyJSON() throws {
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        database = nil
        try sql("DELETE FROM catalog_settings")
        XCTAssertThrowsError(try RecordingDatabase(directory: directory))
        _ = database
    }

    func testLeasePreventsAnotherAppFromRestoringOrWritingSameDirectory() throws {
        var lease: RecordingLease? = try RecordingLease(directory: directory)
        XCTAssertThrowsError(try RecordingLease(directory: directory))
        lease = nil
        XCTAssertNoThrow(try RecordingLease(directory: directory))
        _ = lease
    }

    func testUpgradeArchivePreservesV1DatabaseAndJSONBeforeMigration() throws {
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        database = nil
        try downgradeToV1()
        let legacy = TrackingStore(directory: directory)
        try legacy.saveSources(Source.defaults)
        try legacy.saveCategories(CategoryCatalog(legacySources: Source.defaults))
        let original = try Data(contentsOf: directory.appendingPathComponent("recording.sqlite3"))
        let archiveRoot = directory.appendingPathComponent("Archives")
        database = try RecordingDatabase(directory: directory, migrationBackupDirectory: archiveRoot)
        let archives = try FileManager.default.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1)
        let archive = try XCTUnwrap(archives.first)
        // SQLite backup preserves logical contents, but may update header counters.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(archive.appendingPathComponent("recording.sqlite3").path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT user_version FROM pragma_user_version", -1, &query, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(query, 0), 1)
        sqlite3_finalize(query)
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT count(*) FROM sqlite_master WHERE name='categories'", -1, &query, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(query, 0), 0)
        sqlite3_finalize(query)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("recording.sqlite3")).count, original.count)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("sources.json")), try Data(contentsOf: legacy.sourcesURL))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("categories.json")), try Data(contentsOf: legacy.categoriesURL))
        XCTAssertEqual(try database!.loadSources(), Source.defaults)
    }


    func testOptionalV1InstallationBackupAndRestoreOnPrivateCopy() throws {
        guard let fixture = ProcessInfo.processInfo.environment["FOCUSTRACE_V1_FIXTURE"] else {
            throw XCTSkip("Set FOCUSTRACE_V1_FIXTURE to test a private v1 database copy")
        }
        let input = URL(fileURLWithPath: fixture)
        try FileManager.default.copyItem(at: input, to: directory)
        let expectedVisits = try JSONDecoder().decode([Visit].self, from: Data(contentsOf: input.appendingPathComponent("expected-visits.json")))
        struct CoverageEntry: Decodable { let start: Double; let end: Double }
        let intervals = try JSONDecoder().decode([CoverageEntry].self, from: Data(contentsOf: input.appendingPathComponent("expected-coverage.json")))
        let expectedCoverage = RecordingCoverage(intervals: intervals.map {
            DateInterval(start: Date(timeIntervalSinceReferenceDate: $0.start), end: Date(timeIntervalSinceReferenceDate: $0.end))
        })
        let legacy = TrackingStore(directory: directory)
        let sources = try legacy.loadSources(), categories = try legacy.loadCategories(legacySources: sources)
        let database = try RecordingDatabase(directory: directory, migrationBackupDirectory: directory.appendingPathComponent("Migrations"))
        let original = try database.loadSnapshot()
        XCTAssertEqual(original.visits, expectedVisits)
        XCTAssertEqual(original.coverage, expectedCoverage)
        XCTAssertEqual(original.sources, sources)
        XCTAssertEqual(original.categories, categories)
        let backup = directory.appendingPathComponent("roundtrip.sqlite3")
        try database.backup(to: backup)
        try database.saveCatalog(sources: [], categories: CategoryCatalog())
        XCTAssertEqual(try database.restore(from: backup, recoveryURL: directory.appendingPathComponent("recovery.sqlite3")), original)
        XCTAssertEqual(try RecordingDatabase.validateBackup(at: backup), original)
    }


    func testMissingRecordingTableIsNotSilentlyRecreatedAndIdentityCannotBeOverwritten() throws {
        var database: RecordingDatabase? = try RecordingDatabase(directory: directory)
        let first = Visit(service: .youtube, start: Date(), end: Date())
        try database!.save(visits: [(0, first)], coverage: [])
        XCTAssertThrowsError(try database!.save(visits: [(0, Visit(service: .kakao, start: Date(), end: Date()))], coverage: []))
        XCTAssertEqual(try database!.loadVisits(), [first])
        database = nil
        try sql("DROP TABLE visits")
        // Constructor validation alone needs the application model; startup's
        // complete snapshot read must detect the missing recording table.
        XCTAssertThrowsError(try RecordingDatabase(directory: directory).loadSnapshot())
    }

}
