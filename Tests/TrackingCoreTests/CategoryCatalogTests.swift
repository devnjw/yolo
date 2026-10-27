import XCTest
@testable import TrackingCore

final class CategoryCatalogTests: XCTestCase {
    private let app = Source(name: "Notion", kind: .app, identifier: "notion.id")
    private let site = Source(name: "app.notion.com", kind: .website, identifier: "app.notion.com")

    func testFreshCatalogHasEditableDefaultsAndUncategorizedFallback() throws {
        var catalog = CategoryCatalog()
        XCTAssertEqual(catalog.categories.map(\.name), ["Work", "Learning", "Communication", "Social", "Entertainment", "Personal"])
        XCTAssertNil(catalog.selectedIDs)
        XCTAssertEqual(catalog.category(for: "unknown").id, "uncategorized")
        try catalog.rename("work", to: "Projects")
        XCTAssertEqual(catalog.category(id: "work").name, "Projects")
        for category in catalog.categories { try catalog.remove(category.id) }
        XCTAssertTrue(catalog.categories.isEmpty)
        XCTAssertEqual(catalog.options, [.uncategorized])
        XCTAssertThrowsError(try catalog.remove("uncategorized"))
    }

    func testInitialSuggestionsUseServicePurposeWithoutChangingSources() {
        var selected = site
        selected.isDistracting = true
        let originals = [app, selected, Source(name: "Other", kind: .app, identifier: "other")]
        let catalog = CategoryCatalog(legacySources: originals)
        let groupID = ServiceGrouping.identity(for: app)
        XCTAssertEqual(catalog.category(for: groupID).name, "Work")
        XCTAssertEqual(catalog.assignments.count, 1)
        XCTAssertEqual(catalog.category(for: ServiceGrouping.identity(for: originals[2])).id, "uncategorized")
        XCTAssertFalse(originals[0].isDistracting)
        XCTAssertTrue(originals[1].isDistracting)
        XCTAssertNil(catalog.selectedIDs)
    }

    func testAssignmentAppliesToFutureMembersAndHistoricalVisits() throws {
        var catalog = CategoryCatalog()
        try catalog.assign("learning", to: ServiceGrouping.identity(for: app))
        let before = catalog.members(sources: [app])
        XCTAssertEqual(before["learning"], [app.id])
        let discovered = try XCTUnwrap(SourceCatalog.website(url: "https://app.notion.com/page", sources: [app]))
        let after = catalog.members(sources: [app, discovered])
        XCTAssertEqual(after["learning"], [app.id, discovered.id])
        try catalog.select(["learning"])
        XCTAssertEqual(catalog.includedSourceIDs(sources: [app, discovered]), [app.id, discovered.id])
        try catalog.assign("work", to: ServiceGrouping.identity(for: app))
        XCTAssertTrue(catalog.includedSourceIDs(sources: [app, discovered]).isEmpty)
    }

    func testCreateAndAssignRenameAndRoundTripPreserveStableID() throws {
        var catalog = CategoryCatalog()
        let group = ServiceGrouping.identity(for: app)
        let id = try catalog.create(name: "  Reading  ", assigning: group)
        try catalog.select([id])
        try catalog.rename(id, to: "Research")
        XCTAssertEqual(catalog.category(for: group).name, "Research")
        XCTAssertEqual(catalog.selectionName, "Research")
        XCTAssertEqual(try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
        XCTAssertEqual(catalog.selectedIDs, [id])
    }

    func testInvalidNamesAndAssignmentLeaveCatalogUnchanged() throws {
        var catalog = CategoryCatalog()
        let before = catalog
        for name in ["", "  ", "WORK", "Other", "All categories", String(repeating: "a", count: 41), "a\nb"] {
            XCTAssertThrowsError(try catalog.create(name: name))
            XCTAssertEqual(catalog, before)
        }
        XCTAssertThrowsError(try catalog.rename("work", to: "Social"))
        XCTAssertThrowsError(try catalog.assign("missing", to: "group"))
        XCTAssertThrowsError(try catalog.select([]))
        XCTAssertThrowsError(try catalog.select(["missing"]))
        XCTAssertEqual(catalog, before)
    }

    func testDeleteMovesAllAssignmentsAndRepairsSelectionAtomically() throws {
        var catalog = CategoryCatalog()
        try catalog.assign("social", to: "one")
        try catalog.assign("social", to: "two")
        try catalog.select(["social", "work"])
        try catalog.remove("social", movingTo: "personal")
        XCTAssertEqual(catalog.assignments, ["one": "personal", "two": "personal"])
        XCTAssertEqual(catalog.selectedIDs, ["work"])
        try catalog.select(["personal"])
        try catalog.remove("personal")
        XCTAssertEqual(catalog.assignments, ["one": "uncategorized", "two": "uncategorized"])
        XCTAssertNil(catalog.selectedIDs)
        XCTAssertEqual(catalog.category(for: "one").id, "uncategorized")
        let before = catalog
        XCTAssertThrowsError(try catalog.remove("work", movingTo: "work"))
        XCTAssertThrowsError(try catalog.remove("work", movingTo: "missing"))
        XCTAssertEqual(catalog, before)
    }

    func testAllIncludesNewCategoriesAndUncategorizedWithoutDuplicatingSources() throws {
        var catalog = CategoryCatalog()
        let group = ServiceGrouping.identity(for: app)
        let custom = try catalog.create(name: "Reading", assigning: group)
        let other = Source(name: "Example", kind: .website, identifier: "example.com")
        let orphan = Service(rawValue: "historical-unknown")
        let sources = [app, site, other]
        let members = catalog.members(sources: sources, recordedIDs: [orphan])
        XCTAssertEqual(members[custom], [app.id, site.id])
        XCTAssertEqual(members["uncategorized"], [other.id, orphan])
        XCTAssertEqual(members.values.reduce(0) { $0 + $1.count }, 4)
        XCTAssertEqual(catalog.includedSourceIDs(sources: sources, recordedIDs: [orphan]), [app.id, site.id, other.id, orphan])
        try catalog.select([custom, "uncategorized"])
        XCTAssertEqual(catalog.includedSourceIDs(sources: sources, recordedIDs: [orphan]).count, 4)
    }

    func testCategoryTotalsAndAveragesUseCommonDenominatorIncludingZeroActivityDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let other = Source(name: "Other", kind: .app, identifier: "other")
        let sources = [app, site, other]
        let visits = [
            Visit(service: app.id, start: day, end: day.addingTimeInterval(120)),
            Visit(service: site.id, start: day.addingTimeInterval(120), end: day.addingTimeInterval(180)),
            Visit(service: other.id, start: day.addingTimeInterval(86400), end: day.addingTimeInterval(86490))
        ]
        var coverage = RecordingCoverage()
        coverage.observe(at: day.addingTimeInterval(172800))
        var catalog = CategoryCatalog()
        try catalog.assign("work", to: ServiceGrouping.identity(for: app))
        let all = PeriodActivity(ledger: Ledger(visits: visits), coverage: coverage, period: .week, date: day,
                                 now: day.addingTimeInterval(3 * 86400), includedServices: catalog.includedSourceIDs(sources: sources), calendar: calendar)
        XCTAssertEqual(all.recordedDays, 3)
        XCTAssertEqual(all.seconds, 90)
        let members = catalog.members(sources: sources)
        XCTAssertEqual(all.activity.statistics(for: members["work"]!).seconds / all.divisor, 60)
        XCTAssertEqual(all.activity.statistics(for: members["uncategorized"]!).seconds / all.divisor, 30)
        XCTAssertEqual(members.values.reduce(Statistics.zero) { $0 + all.activity.statistics(for: $1) }, all.activity.statistics)
        try catalog.select(["work"])
        let filtered = PeriodActivity(ledger: Ledger(visits: visits), coverage: coverage, period: .week, date: day,
                                      now: day.addingTimeInterval(3 * 86400), includedServices: catalog.includedSourceIDs(sources: sources), calendar: calendar)
        XCTAssertEqual(filtered.recordedDays, all.recordedDays)
        XCTAssertEqual(filtered.seconds, 60)
        XCTAssertEqual(filtered.visits, 2.0 / 3.0)
    }
    func testSuggestionsPreserveOverridesUncategorizedAndDeletedCategoriesAfterReload() throws {
        let youtube = Source(name: "YouTube", kind: .website, identifier: "youtube.com")
        let sources = [app, youtube]
        var catalog = CategoryCatalog(legacySources: sources)
        let notionID = ServiceGrouping.identity(for: app)
        let youtubeID = ServiceGrouping.identity(for: youtube)
        try catalog.assign("learning", to: youtubeID)
        try catalog.assign("uncategorized", to: notionID)
        catalog = try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(catalog))
        catalog.applyServiceDefaults(to: sources + [site])
        XCTAssertEqual(catalog.categoryID(for: notionID), "uncategorized")
        XCTAssertEqual(catalog.categoryID(for: youtubeID), "learning")
        try catalog.remove("learning")
        try catalog.remove("work")
        catalog.applyServiceDefaults(to: sources + [Source(name: "GitHub", kind: .website, identifier: "github.com")])
        XCTAssertEqual(catalog.categoryID(for: youtubeID), "uncategorized")
        XCTAssertFalse(catalog.categories.contains { $0.id == "work" || $0.id == "learning" })
        XCTAssertEqual(catalog.assignments.count, 2)
    }

    func testLegacyDistractionsAreReclassifiedOnceAndUnknownRecordsRemainIncluded() throws {
        let unknown = Source(id: Service(rawValue: "unknown"), name: "Unknown", kind: .app, identifier: "custom.app")
        let kakao = Source.defaults[0]
        let youtube = Source.defaults[3]
        let old = #"{"categories":[{"id":"work","name":"Projects","tint":"blue"},{"id":"communication","name":"Communication","tint":"orange"},{"id":"entertainment","name":"Entertainment","tint":"pink"},{"id":"legacy-distractions","name":"Distractions","tint":"purple"}],"assignments":{"source:kakao":"legacy-distractions","known:youtube":"legacy-distractions","source:unknown":"legacy-distractions","known:notion":"work"},"selectedIDs":["legacy-distractions"]}"#
        var catalog = try JSONDecoder().decode(CategoryCatalog.self, from: Data(old.utf8))
        let sources = [kakao, youtube, unknown, app]
        catalog.applyServiceDefaults(to: sources)
        XCTAssertEqual(catalog.category(for: ServiceGrouping.identity(for: kakao)).id, "communication")
        XCTAssertEqual(catalog.category(for: "known:youtube").id, "entertainment")
        XCTAssertEqual(catalog.category(for: "known:notion").name, "Projects")
        XCTAssertEqual(catalog.category(for: "source:unknown").id, "uncategorized")
        XCTAssertFalse(catalog.categories.contains { $0.id == "legacy-distractions" })
        XCTAssertNil(catalog.selectedIDs)
        XCTAssertEqual(catalog.includedSourceIDs(sources: sources), Set(sources.map(\.id)))
        let once = catalog
        catalog.applyServiceDefaults(to: sources)
        XCTAssertEqual(catalog, once)
    }

    func testSuggestionsMatchExactAppIDsAndDomainBoundariesOnly() {
        func suggestion(_ identifier: String, _ kind: Source.Kind = .website, name: String = "Example") -> String? {
            ServiceCategoryDefaults.categoryID(for: Source(name: name, kind: kind, identifier: identifier, aliases: ["youtube.com"]))
        }
        XCTAssertEqual(suggestion("COM.KAKAO.KAKAOTALKMAC", .app), "communication")
        XCTAssertEqual(suggestion("team.slack.com"), "communication")
        XCTAssertEqual(suggestion("m.youtube.com"), "entertainment")
        XCTAssertEqual(suggestion("researchgate.net"), "learning")
        XCTAssertEqual(suggestion("link.coupang.com"), "personal")
        XCTAssertEqual(suggestion("x.com"), "social")
        XCTAssertNil(suggestion("youtube.com.example.org"))
        XCTAssertNil(suggestion("notyoutube.com"))
        XCTAssertNil(suggestion("unknown.app", .app, name: "Slack"))
        XCTAssertNil(suggestion("com.google.Chrome", .app))
        XCTAssertNil(suggestion("google.com"))
        XCTAssertNil(suggestion("example.com"))
    }

    func testPresetAndCustomColorsPersistAcrossEditsAndReload() throws {
        var catalog = CategoryCatalog()
        let id = try catalog.create(name: "Reading", tint: .yellow, assigning: "reader")
        XCTAssertEqual(catalog.category(id: id).tint, .yellow)
        XCTAssertNil(catalog.category(id: id).customHex)
        try catalog.select([id])
        try catalog.update(id, name: "Books", tint: .yellow, customHex: 0x123ABC)
        catalog = try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(catalog.category(id: id).customHex, 0x123ABC)
        XCTAssertEqual(catalog.category(for: "reader").name, "Books")
        XCTAssertEqual(catalog.selectedIDs, [id])
        try catalog.update(id, name: "Books", tint: .indigo, customHex: nil)
        XCTAssertNil(catalog.category(id: id).customHex)
        XCTAssertEqual(catalog.category(id: id).tint, .indigo)
        let black = try catalog.create(name: "Black", tint: .gray, customHex: 0)
        XCTAssertEqual(catalog.category(id: black).customHex, 0)
    }

    func testInvalidColorOrNameDoesNotPartiallyEditCategory() throws {
        var catalog = CategoryCatalog()
        let before = catalog
        XCTAssertThrowsError(try catalog.update("work", name: "Projects", tint: .red, customHex: 0x1000000))
        XCTAssertThrowsError(try catalog.update("work", name: "Social", tint: .red, customHex: 0x123456))
        XCTAssertThrowsError(try catalog.create(name: "Invalid", tint: .blue, customHex: UInt32.max))
        XCTAssertThrowsError(try catalog.update("missing", name: "Other", tint: .red, customHex: nil))
        XCTAssertEqual(catalog, before)
        let invalid = #"{"categories":[{"id":"work","name":"Work","tint":"blue","customHex":16777216}],"assignments":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(CategoryCatalog.self, from: Data(invalid.utf8)))
    }

    func testOldCategoryDataWithoutCustomColorPreservesItsPreset() throws {
        let old = #"{"categories":[{"id":"work","name":"Work","tint":"green"}],"assignments":{"known:notion":"work"}}"#
        let catalog = try JSONDecoder().decode(CategoryCatalog.self, from: Data(old.utf8))
        XCTAssertEqual(catalog.category(id: "work").tint, .green)
        XCTAssertNil(catalog.category(id: "work").customHex)
        XCTAssertEqual(ActivityCategory.Tint.allCases.count, 10)
    }

    func testFallbackNameAndColorAreEditableWithoutChangingMembershipOrSelection() throws {
        var catalog = CategoryCatalog()
        let unknown = Source(name: "Unknown", kind: .app, identifier: "example.unknown")
        let orphan = Service(rawValue: "old-unknown")
        try catalog.assign("uncategorized", to: ServiceGrouping.identity(for: app))
        try catalog.select(["uncategorized"])
        let before = catalog.includedSourceIDs(sources: [app, unknown], recordedIDs: [orphan])
        try catalog.update("uncategorized", name: "Misc", tint: .indigo, customHex: 0x3344AA)
        catalog = try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(catalog.selectionName, "Misc")
        XCTAssertEqual(catalog.category(for: "new-service").name, "Misc")
        XCTAssertEqual(catalog.category(for: ServiceGrouping.identity(for: app)).customHex, 0x3344AA)
        XCTAssertEqual(catalog.includedSourceIDs(sources: [app, unknown], recordedIDs: [orphan]), before)
        XCTAssertThrowsError(try catalog.remove("uncategorized"))
        let saved = catalog
        XCTAssertThrowsError(try catalog.update("uncategorized", name: "Work", tint: .red, customHex: nil))
        XCTAssertEqual(catalog, saved)
        try catalog.rename("uncategorized", to: "Unsorted")
        XCTAssertEqual(catalog.fallbackCategory.customHex, 0x3344AA)
    }

    func testOldCatalogGetsOtherWithoutOverwritingExistingNamedCategory() throws {
        let old = #"{"categories":[{"id":"custom","name":"Other","tint":"red"}],"assignments":{},"selectedIDs":["uncategorized"]}"#
        let catalog = try JSONDecoder().decode(CategoryCatalog.self, from: Data(old.utf8))
        XCTAssertEqual(catalog.category(id: "custom").name, "Other")
        XCTAssertEqual(catalog.fallbackCategory.name, "Other 2")
        XCTAssertEqual(catalog.selectedIDs, ["uncategorized"])
        XCTAssertEqual(CategoryCatalog().fallbackCategory.name, "Other")
    }

}
