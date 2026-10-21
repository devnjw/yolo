import XCTest
@testable import TrackingCore

final class TrackingCoreTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func testSameServiceNavigationDoesNotCreateVisits() {
        var ledger = Ledger()
        ledger.observe(.youtube, at: base)
        for second in 1...10 { ledger.observe(.youtube, at: base.addingTimeInterval(Double(second))) }
        ledger.stop(at: base.addingTimeInterval(11))
        XCTAssertEqual(ledger.visits.count, 1)
        XCTAssertEqual(ledger.visits[0].duration, 11)
    }
    func testReturningCreatesAnotherVisit() {
        var ledger = Ledger()
        ledger.observe(.kakao, at: base)
        ledger.observe(nil, at: base.addingTimeInterval(1))
        ledger.observe(.kakao, at: base.addingTimeInterval(2))
        XCTAssertEqual(ledger.visits.count, 2)
    }
    func testSleepGapIsNeverCounted() {
        var ledger = Ledger()
        ledger.observe(.instagram, at: base)
        ledger.observe(.instagram, at: base.addingTimeInterval(1))
        ledger.observe(.instagram, at: base.addingTimeInterval(3600))
        XCTAssertEqual(ledger.visits.count, 2)
        XCTAssertEqual(ledger.visits[0].duration, 1)
    }
    func testMidnightClipsTimeAndCountsEntryOnStartDay() {
        let visit = Visit(service: .kakao, start: base.addingTimeInterval(-10), end: base.addingTimeInterval(10))
        let stats = Ledger(visits: [visit]).stats(in: DateInterval(start: base, duration: 86400))
        XCTAssertEqual(stats.seconds, 10)
        XCTAssertEqual(stats.visits, 0)
    }
    func testOnlyCompletedVisitsAreShortVisits() {
        var ledger = Ledger()
        ledger.observe(.linkedin, at: base)
        let day = DateInterval(start: base, duration: 86400)
        XCTAssertEqual(ledger.stats(in: day).shortVisits, 0)
        ledger.stop(at: base.addingTimeInterval(1))
        XCTAssertEqual(ledger.stats(in: day).shortVisits, 1)
    }
    func testDomainMatchingRejectsLookalikes() {
        XCTAssertEqual(Service.website("https://m.youtube.com/watch?v=private"), .youtube)
        XCTAssertEqual(Service.website("https://www.linkedin.com/feed"), .linkedin)
        XCTAssertNil(Service.website("https://youtube.com.evil.example"))
        XCTAssertNil(Service.website("https://notyoutube.com"))
        XCTAssertNil(Service.website("file:///youtube.com"))
    }
    func testReloadDoesNotContinueOldVisit() throws {
        var ledger = Ledger()
        ledger.observe(.youtube, at: base)
        let saved = try JSONEncoder().encode(ledger.visits)
        var restored = Ledger(visits: try JSONDecoder().decode([Visit].self, from: saved))
        restored.observe(.youtube, at: base.addingTimeInterval(100))
        XCTAssertEqual(restored.visits.count, 2)
        XCTAssertEqual(restored.visits[0].duration, 0)
    }

    func testLegacyVisitFormatKeepsStableServiceIDs() throws {
        let oldJSON = """
        [{"id":"7FB12DB6-37EC-4394-A60A-8806492E8C8F","service":"kakao","start":100,"end":110}]
        """.data(using: .utf8)!
        let visits = try JSONDecoder().decode([Visit].self, from: oldJSON)
        XCTAssertEqual(visits[0].service, .kakao)
        XCTAssertEqual(visits[0].duration, 10)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(visits)) as! [[String: Any]]
        XCTAssertEqual(reencoded[0]["service"] as? String, "kakao")
    }

    func testCustomSourcesSurviveRoundTripAndMatchPrecisely() throws {
        let source = Source(name: "Reddit", kind: .website, identifier: "reddit.com")
        let restored = try JSONDecoder().decode([Source].self, from: JSONEncoder().encode([source]))
        XCTAssertEqual(restored, [source])
        XCTAssertEqual(Source.matchWebsite("https://old.reddit.com/r/test", sources: restored), source.id)
        XCTAssertNil(Source.matchWebsite("https://notreddit.com", sources: restored))
        let visit = Visit(service: source.id, start: base, end: base.addingTimeInterval(12))
        XCTAssertEqual(try JSONDecoder().decode(Visit.self, from: JSONEncoder().encode(visit)), visit)
    }

    func testSpecificSubdomainWinsAndArchivedSourcesDoNotMatch() {
        let parent = Source(name: "Example", kind: .website, identifier: "example.com")
        var child = Source(name: "Video", kind: .website, identifier: "video.example.com")
        XCTAssertEqual(Source.matchWebsite("https://video.example.com/watch", sources: [parent, child]), child.id)
        child.archived = true
        XCTAssertEqual(Source.matchWebsite("https://video.example.com/watch", sources: [parent, child]), parent.id)
        var app = Source(name: "Test", kind: .app, identifier: "test.app")
        XCTAssertEqual(Source.matchApp("test.app", sources: [app]), app.id)
        app.archived = true
        XCTAssertNil(Source.matchApp("test.app", sources: [app]))
    }

    func testDomainInputNormalization() {
        XCTAssertEqual(Source.normalizedDomain(" https://www.Reddit.com/r/test "), "reddit.com")
        XCTAssertEqual(Source.normalizedDomain("video.example.com"), "video.example.com")
        XCTAssertNil(Source.normalizedDomain("not a domain"))
        XCTAssertNil(Source.normalizedDomain("file:///etc/passwd"))
        XCTAssertNil(Source.normalizedDomain("https://user:password@example.com"))
        XCTAssertNil(Source.normalizedDomain("example..com"))
        XCTAssertNil(Source.normalizedDomain("localhost"))
    }
}
