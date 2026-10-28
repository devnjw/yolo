import XCTest
@testable import TrackingCore

final class SourceCatalogTests: XCTestCase {
    func testUnlistedAppIsDiscoveredAndReusesItsSavedIdentity() throws {
        let app = SourceCatalog.app(identifier: "com.example.Editor", name: "Editor", sources: [])
        XCTAssertEqual(app.kind, .app)
        XCTAssertFalse(app.isDistracting)
        let saved = try JSONDecoder().decode([Source].self, from: JSONEncoder().encode([app]))
        XCTAssertEqual(SourceCatalog.app(identifier: app.identifier, name: "New name", sources: saved).id, app.id)
    }

    func testRemovedAppIsStillRecordedUsingItsHistoricalIdentity() {
        let old = Source(name: "Editor", kind: .app, identifier: "com.example.Editor", archived: true)
        XCTAssertEqual(SourceCatalog.app(identifier: old.identifier, name: old.name, sources: [old]).id, old.id)
    }

    func testUnlistedWebsiteStoresOnlyNormalizedHostAndReusesIdentity() throws {
        let source = try XCTUnwrap(SourceCatalog.website(url: "https://www.Example.com./private?token=secret#fragment", sources: []))
        XCTAssertEqual(source.identifier, "example.com")
        XCTAssertEqual(source.name, "example.com")
        XCTAssertFalse(source.isDistracting)
        XCTAssertEqual(SourceCatalog.website(url: "http://example.com/another", sources: [source])?.id, source.id)
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("private"))
    }

    func testLocalHostsAndAddressesAreRecordedButBrowserInternalPagesAreNotSites() {
        for (url, host) in [("http://localhost:3000/work", "localhost"), ("http://127.0.0.1:8080/", "127.0.0.1"),
                            ("https://intranet/", "intranet"), ("http://[::1]:3000/", "::1")] {
            XCTAssertEqual(SourceCatalog.website(url: url, sources: [])?.identifier, host)
        }
        for url in ["chrome://newtab", "about:blank", "file:///tmp/test.html", "", "not a URL"] {
            XCTAssertNil(SourceCatalog.website(url: url, sources: []))
        }
    }

    func testExistingAliasesSpecificDomainsAndArchivedIDsArePreserved() {
        XCTAssertEqual(SourceCatalog.website(url: "https://youtu.be/video", sources: Source.defaults)?.id, .youtube)
        let parent = Source(name: "Example", kind: .website, identifier: "example.com", isDistracting: true)
        let child = Source(name: "Work", kind: .website, identifier: "work.example.com", archived: true)
        XCTAssertEqual(SourceCatalog.website(url: "https://work.example.com/doc", sources: [parent, child])?.id, child.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://work.example.com/doc", sources: [parent, child])?.isDistracting, false)
        XCTAssertEqual(SourceCatalog.website(url: "https://example.com.evil.test/", sources: [parent])?.identifier, "example.com.evil.test")
    }

    func testParentDomainDoesNotAbsorbGoogleServicesAndVisitsStaySeparate() throws {
        let google = Source(name: "Google", kind: .website, identifier: "google.com")
        var sources = [google]
        for host in ["meet.google.com", "mail.google.com", "drive.google.com", "docs.google.com"] {
            let source = try XCTUnwrap(SourceCatalog.website(url: "https://\(host)/private?token=secret", sources: sources))
            XCTAssertEqual(source.identifier, host)
            XCTAssertNotEqual(source.id, google.id)
            sources.append(source)
            let saved = try JSONDecoder().decode([Source].self, from: JSONEncoder().encode(sources))
            XCTAssertEqual(SourceCatalog.website(url: "https://\(host)/next", sources: saved)?.id, source.id)
        }
        let meet = sources[1]
        var categories = CategoryCatalog()
        categories.applyServiceDefaults(to: sources)
        XCTAssertEqual(categories.category(for: ServiceGrouping.identity(for: meet)).id, "communication")
        XCTAssertNotEqual(ServiceGrouping.identity(for: meet), ServiceGrouping.identity(for: google))

        var ledger = Ledger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.observe(google.id, at: start)
        ledger.observe(meet.id, at: start.addingTimeInterval(2))
        ledger.stop(at: start.addingTimeInterval(4))
        XCTAssertEqual(ledger.visits.map(\.service), [google.id, meet.id])
        XCTAssertEqual(ledger.visits.map(\.duration), [2, 2])
    }

    func testHostDiscoveryIsIndependentOfParentRegistrationOrder() throws {
        let parent = Source(name: "Example", kind: .website, identifier: "example.com", archived: true)
        let child = try XCTUnwrap(SourceCatalog.website(url: "https://work.example.com", sources: [parent]))
        XCTAssertEqual(child.identifier, "work.example.com")
        XCTAssertNotEqual(child.id, parent.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://example.com", sources: [child, parent])?.id, parent.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://WWW.Work.Example.com./path", sources: [parent, child])?.id, child.id)
    }

    func testExactHostWinsOverAliasesAndAliasDoesNotAbsorbSubdomains() throws {
        let parent = Source(name: "Example", kind: .website, identifier: "example.com", aliases: ["work.example.com", "short.test"])
        let child = Source(name: "Work", kind: .website, identifier: "work.example.com", archived: true)
        XCTAssertEqual(SourceCatalog.website(url: "https://work.example.com", sources: [parent, child])?.id, child.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://short.test/path", sources: [parent])?.id, parent.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://app.short.test/path", sources: [parent])?.identifier, "app.short.test")
    }

    func testKnownServiceGroupingStillCombinesDistinctHosts() throws {
        let youtube = try XCTUnwrap(Source.defaults.first { $0.id == .youtube })
        let mobile = try XCTUnwrap(SourceCatalog.website(url: "https://m.youtube.com/watch?v=private", sources: [youtube]))
        XCTAssertEqual(mobile.identifier, "m.youtube.com")
        XCTAssertNotEqual(mobile.id, youtube.id)
        let groups = ServiceGrouping.groups(from: [youtube, mobile])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sourceIDs, Set([youtube.id, mobile.id]))
    }

    func testLegacyWatchlistMigratesWithoutChangingIDsAndRemovedItemsRemainUnselected() throws {
        let json = Data("""
        [{"id":"kakao","name":"KakaoTalk","kind":"app","identifier":"com.kakao.KakaoTalkMac","aliases":[],"archived":false},
         {"id":"youtube","name":"YouTube","kind":"website","identifier":"youtube.com","aliases":["youtu.be"],"archived":true}]
        """.utf8)
        let sources = try JSONDecoder().decode([Source].self, from: json)
        XCTAssertEqual(sources.map(\.id), [.kakao, .youtube])
        XCTAssertTrue(sources[0].isDistracting)
        XCTAssertFalse(sources[1].isDistracting)
        XCTAssertEqual(try JSONDecoder().decode([Source].self, from: JSONEncoder().encode(sources)), sources)
    }

    func testExplicitUnmarkPersistsAndDoesNotDisableWebsiteRecording() throws {
        var youtube = Source.defaults.last!
        youtube.isDistracting = false
        let restored = try JSONDecoder().decode(Source.self, from: JSONEncoder().encode(youtube))
        XCTAssertFalse(restored.isDistracting)
        XCTAssertEqual(SourceCatalog.website(url: "https://youtube.com/watch?v=1", sources: [restored])?.id, .youtube)
    }
}
