import XCTest
@testable import TrackingCore

final class ServiceGroupingTests: XCTestCase {
    private let app = Source(name: "Notion", kind: .app, identifier: "notion.id")
    private let website = Source(name: "app.notion.com", kind: .website, identifier: "app.notion.com")

    func testKnownServiceGroupsAppAndDifferentDomainsWithoutChangingSourceIdentity() throws {
        let oldDomain = Source(name: "notion.so", kind: .website, identifier: "notion.so")
        let originals = [website, oldDomain, app]
        let groups = ServiceGrouping.groups(from: originals)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.name, "Notion")
        XCTAssertEqual(group.sourceIDs, Set(originals.map(\.id)))
        XCTAssertEqual(group.representative, app)
        XCTAssertEqual(group, ServiceGrouping.groups(from: originals.reversed()).first)
        XCTAssertTrue(group.matches("notion.so"))
        XCTAssertTrue(group.matches(" NOTION.ID "))
    }

    func testLookalikeNamesDomainsAndUserAliasesDoNotMergeUnrelatedServices() {
        let lookalikes = [
            Source(name: "Notion", kind: .app, identifier: "com.example.Notion"),
            Source(name: "Notion", kind: .website, identifier: "notion.com.evil.test"),
            Source(name: "Notion", kind: .website, identifier: "notnotion.com"),
            Source(name: "Notion", kind: .website, identifier: "example.com", aliases: ["notion.so"])
        ]
        XCTAssertEqual(ServiceGrouping.groups(from: [app] + lookalikes).count, 5)
        let unknown = Source(name: "ChatGPT", kind: .app, identifier: "com.example.chatgpt")
        XCTAssertTrue(ServiceGrouping.identity(for: unknown).hasPrefix("source:"))
    }

    func testExistingSelectionIsPreservedAcrossGroupWhileOtherMetadataStaysIntact() throws {
        var selected = website
        selected.isDistracting = true
        selected.archived = true
        selected.aliases = ["notion.so"]
        let originals = [app, selected, Source.defaults.last!]
        let normalized = ServiceGrouping.normalizedSelection(originals)
        XCTAssertTrue(normalized.allSatisfy(\.isDistracting))
        for (before, after) in zip(originals, normalized) {
            var expected = before
            expected.isDistracting = true
            XCTAssertEqual(expected, after)
        }
        XCTAssertEqual(ServiceGrouping.normalizedSelection(normalized), normalized)
        let restored = try JSONDecoder().decode([Source].self, from: JSONEncoder().encode(normalized))
        XCTAssertEqual(restored, normalized)
    }

    func testGroupUnmarkPersistsAndNewMemberInheritsSelectionWithoutDisablingTracking() throws {
        var selectedApp = app
        selectedApp.isDistracting = true
        let inherited = ServiceGrouping.normalizedSelection([selectedApp, website])
        XCTAssertTrue(inherited[1].isDistracting)
        let off = ServiceGrouping.settingDistracting(false, for: ServiceGrouping.identity(for: app), in: inherited)
        let restored = try JSONDecoder().decode([Source].self, from: JSONEncoder().encode(off))
        let discovered = try XCTUnwrap(SourceCatalog.website(url: "https://notion.so/page", sources: restored))
        let next = ServiceGrouping.normalizedSelection(restored + [discovered])
        XCTAssertTrue(next.allSatisfy { !$0.isDistracting })
        XCTAssertEqual(SourceCatalog.app(identifier: app.identifier, name: app.name, sources: next).id, app.id)
        XCTAssertEqual(SourceCatalog.website(url: "https://app.notion.com/page", sources: next)?.id, website.id)
    }

    func testGroupToggleDoesNotChangeOtherServiceAndSearchIncludesAliases() throws {
        let youtube = Source.defaults.last!
        let group = try XCTUnwrap(ServiceGrouping.groups(from: [youtube]).first)
        XCTAssertTrue(group.matches("youtu.be"))
        let next = ServiceGrouping.settingDistracting(true, for: ServiceGrouping.identity(for: app), in: [app, website, youtube])
        XCTAssertTrue(next[0].isDistracting)
        XCTAssertTrue(next[1].isDistracting)
        XCTAssertEqual(next[2], youtube)
    }

    func testGroupedStatisticsClipTimeAndPreserveVisitCountsAcrossSourceSwitches() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = DateInterval(start: start, duration: 100)
        let other = Source.defaults.last!
        let visits = [
            Visit(service: app.id, start: start.addingTimeInterval(-20), end: start.addingTimeInterval(10)),
            Visit(service: website.id, start: start.addingTimeInterval(10), end: start.addingTimeInterval(30)),
            Visit(service: app.id, start: start.addingTimeInterval(30), end: start.addingTimeInterval(120)),
            Visit(service: other.id, start: start.addingTimeInterval(140), end: start.addingTimeInterval(160))
        ]
        let ledger = Ledger(visits: visits)
        let activity = DayActivity(ledger: ledger, interval: interval)
        let members: Set<Service> = [app.id, website.id]
        XCTAssertEqual(activity.statistics(for: members).seconds, 100)
        XCTAssertEqual(activity.statistics(for: members).visits, 2)
        XCTAssertEqual(activity.statistics(for: members).shortVisits, 1)
        XCTAssertEqual(activity.visits(for: members), Array(visits.prefix(3).reversed()))
        XCTAssertEqual(ledger.visits, visits)
        XCTAssertEqual(activity.statistics(for: Set<Service>()), .zero)
    }

    func testGroupedActiveVisitDoesNotBecomeAQuickCheck() {
        let start = Date(timeIntervalSince1970: 1_000)
        var ledger = Ledger()
        ledger.observe(app.id, at: start)
        ledger.observe(website.id, at: start.addingTimeInterval(2))
        ledger.observe(website.id, at: start.addingTimeInterval(4))
        let activity = DayActivity(ledger: ledger, interval: DateInterval(start: start, duration: 60))
        let stats = activity.statistics(for: Set([app.id, website.id]))
        XCTAssertEqual(stats.seconds, 4)
        XCTAssertEqual(stats.visits, 2)
        XCTAssertEqual(stats.shortVisits, 1)
    }
}
