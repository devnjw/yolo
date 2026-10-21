import XCTest
@testable import TrackingCore

final class TrackingStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TrackingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = TrackingStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMissingFilesUseDefaultsWithoutCreatingFiles() throws {
        XCTAssertEqual(try store.loadVisits(), [])
        XCTAssertEqual(try store.loadSources(), Source.defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRoundTripKeepsVisitAndArchivedSourceIdentity() throws {
        let source = Source(name: "Example", kind: .website, identifier: "example.com",
                            aliases: ["example.org"], archived: true)
        let visit = Visit(service: source.id, start: Date(timeIntervalSince1970: 100),
                          end: Date(timeIntervalSince1970: 120))
        try store.saveSources([source])
        try store.saveVisits([visit])
        XCTAssertEqual(try store.loadSources(), [source])
        XCTAssertEqual(try store.loadVisits(), [visit])
        XCTAssertNil(Ledger(visits: try store.loadVisits()).activeID)
    }

    func testEmptyCatalogIsNotReplacedByDefaults() throws {
        try store.saveSources([])
        XCTAssertEqual(try store.loadSources(), [])
    }

    func testMalformedRecordsThrowAndRemainUntouched() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformed = Data("[{broken".utf8)
        try malformed.write(to: store.visitsURL)
        try malformed.write(to: store.sourcesURL)
        XCTAssertThrowsError(try store.loadVisits())
        XCTAssertThrowsError(try store.loadSources())
        XCTAssertEqual(try Data(contentsOf: store.visitsURL), malformed)
        XCTAssertEqual(try Data(contentsOf: store.sourcesURL), malformed)
    }

    func testLegacyDatesAndStringIDsAreReadWithoutMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        [{"id":"7FB12DB6-37EC-4394-A60A-8806492E8C8F","service":"kakao","start":100,"end":110}]
        """
        try Data(json.utf8).write(to: store.visitsURL)
        let visit = try XCTUnwrap(store.loadVisits().first)
        XCTAssertEqual(visit.service, .kakao)
        XCTAssertEqual(visit.start, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(visit.duration, 10)
    }

    func testWritesKeepPrivatePermissionsAfterReplacement() throws {
        try store.saveVisits([])
        try store.saveSources(Source.defaults)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.visitsURL.path)
        try store.saveVisits([])
        for (url, expected) in [(directory!, 0o700), (store.visitsURL, 0o600), (store.sourcesURL, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
    }

    func testUnwritableLocationReportsFailureWithoutReplacingExistingFile() throws {
        let original = Data("not a directory".utf8)
        try original.write(to: directory)
        XCTAssertThrowsError(try store.saveVisits([]))
        XCTAssertEqual(try Data(contentsOf: directory), original)
    }
}
