import XCTest
@testable import TrackingCore

final class ServiceDirectoryTests: XCTestCase {
    private let app2 = Source(id: Service(rawValue: "app2"), name: "Tool 2", kind: .app, identifier: "test.tool2")
    private let app10 = Source(id: Service(rawValue: "app10"), name: "Tool 10", kind: .app, identifier: "test.tool10")
    private let web = Source(id: Service(rawValue: "web"), name: "Notes", kind: .website,
                             identifier: "notes.test", aliases: ["alias.test"])
    private let notionApp = Source(id: Service(rawValue: "notion-app"), name: "Notion", kind: .app, identifier: "notion.id")
    private let notionWeb = Source(id: Service(rawValue: "notion-web"), name: "notion.so", kind: .website, identifier: "notion.so")
    private var sources: [Source] { [app10, notionWeb, app2, web, notionApp] }
    private var groups: [ServiceGroup] { ServiceGrouping.groups(from: sources) }
    private var totals: [Service: UsageTotals] {
        [app2.id: UsageTotals(seconds: 900, visits: 20), app10.id: UsageTotals(seconds: 60, visits: 100),
         notionApp.id: UsageTotals(seconds: 120, visits: 3), notionWeb.id: UsageTotals(seconds: 480, visits: 7)]
    }

    func testNaturalNameOrderAndItsReverse() {
        let ascending = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog())
        XCTAssertEqual(ascending.map(\.group.name), ["Notes", "Notion", "Tool 2", "Tool 10"])
        let descending = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog(), descending: true)
        XCTAssertEqual(descending.map(\.id), ascending.map(\.id).reversed())
    }

    func testTotalsCombineAllMembersAndRetainUnusedServices() throws {
        let rows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog())
        let notion = try XCTUnwrap(rows.first { $0.group.name == "Notion" })
        XCTAssertEqual(notion.kind, .mixed)
        XCTAssertEqual(notion.usage, UsageTotals(seconds: 600, visits: 10))
        XCTAssertEqual(rows.first { $0.group.name == "Notes" }?.usage, UsageTotals())
        XCTAssertEqual(rows.reduce(UsageTotals()) { $0 + $1.usage }, UsageTotals(seconds: 1560, visits: 130))
    }

    func testNumericSortUsesRawValuesAndStableNameTies() {
        var input = totals
        input[web.id] = UsageTotals(seconds: 60, visits: 100)
        let visits = ServiceDirectory.rows(groups: groups.reversed(), totals: input, catalog: CategoryCatalog(),
                                           sort: .visits, descending: true)
        XCTAssertEqual(visits.map(\.group.name), ["Notes", "Tool 10", "Tool 2", "Notion"])
        let time = ServiceDirectory.rows(groups: groups, totals: input, catalog: CategoryCatalog(), sort: .time)
        XCTAssertEqual(time.map(\.group.name), ["Notes", "Tool 10", "Notion", "Tool 2"])
        XCTAssertTrue(ServiceDirectory.Sort.time.prefersDescending)
        XCTAssertTrue(ServiceDirectory.Sort.visits.prefersDescending)
        XCTAssertFalse(ServiceDirectory.Sort.name.prefersDescending)
    }

    func testEqualNamesUseStableIdentityRatherThanInputOrder() {
        let a = Source(id: Service(rawValue: "a"), name: "Same", kind: .website, identifier: "a.test")
        let b = Source(id: Service(rawValue: "b"), name: "Same", kind: .app, identifier: "test.b")
        let input = ServiceGrouping.groups(from: [b, a])
        for descending in [false, true] {
            let first = ServiceDirectory.rows(groups: input, totals: [:], catalog: CategoryCatalog(), descending: descending)
            let second = ServiceDirectory.rows(groups: input.reversed(), totals: [:], catalog: CategoryCatalog(), descending: descending)
            XCTAssertEqual(first.map(\.id), second.map(\.id))
        }
    }

    func testTypeBucketsPartitionWithoutDuplicatingMixedServices() {
        let catalog = CategoryCatalog()
        let app = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog, kind: .app)
        let web = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog, kind: .web)
        let mixed = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog, kind: .mixed)
        XCTAssertEqual(app.map(\.group.name), ["Tool 2", "Tool 10"])
        XCTAssertEqual(web.map(\.group.name), ["Notes"])
        XCTAssertEqual(mixed.map(\.group.name), ["Notion"])
        XCTAssertEqual((app + web + mixed).count, groups.count)
        XCTAssertEqual(Set((app + web + mixed).map(\.id)).count, groups.count)
    }

    func testSearchTypeAndCategoryIntersectWithoutUsingOverviewSelection() throws {
        var catalog = CategoryCatalog()
        let category = try catalog.create(name: "Research")
        try catalog.assign(category, to: ServiceGrouping.identity(for: web))
        try catalog.assign(category, to: ServiceGrouping.identity(for: notionApp))
        // Deliberately exclude Research in Overview. The directory is independent.
        try catalog.select([ActivityCategory.uncategorized.id])
        let matches = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog,
                                            search: " ALIAS.TEST ", kind: .web, categoryID: category)
        XCTAssertEqual(matches.map(\.group.name), ["Notes"])
        XCTAssertTrue(ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog,
                                             search: "alias.test", kind: .app, categoryID: category).isEmpty)
        let memberMatch = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog,
                                                search: "notion.so", kind: .mixed, categoryID: category)
        XCTAssertEqual(memberMatch.first?.usage, UsageTotals(seconds: 600, visits: 10))
    }

    func testCategorySortingFollowsEditsAndDeletion() throws {
        var catalog = CategoryCatalog()
        let alpha = try catalog.create(name: "Alpha")
        let zulu = try catalog.create(name: "Zulu")
        try catalog.assign(alpha, to: ServiceGrouping.identity(for: app2))
        try catalog.assign(zulu, to: ServiceGrouping.identity(for: app10))
        var rows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog, sort: .category)
        XCTAssertEqual(rows.map(\.category.name), ["Alpha", "Other", "Other", "Zulu"])
        try catalog.rename(alpha, to: "Zzz")
        rows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog, sort: .category, descending: true)
        XCTAssertEqual(rows.map(\.category.name), ["Zzz", "Zulu", "Other", "Other"])
        try catalog.remove(zulu)
        rows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: catalog)
        XCTAssertEqual(rows.first { $0.group.name == "Tool 10" }?.category.id, ActivityCategory.uncategorized.id)
    }

    func testTypeSortingPreservesRowsWithoutDuplicates() {
        let typeRows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog(),
                                             sort: .type, descending: true)
        XCTAssertEqual(typeRows.map(\.kind), [.web, .mixed, .app, .app])
        XCTAssertEqual(typeRows.count, groups.count)
        XCTAssertEqual(Set(typeRows.map(\.id)), Set(groups.map(\.id)))
    }

    func testEmptyFilterResults() {
        let rows = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog(), search: "not-found")
        XCTAssertTrue(rows.isEmpty)
    }

    func testEveryColumnCyclesThroughBothDirectionsThenClears() {
        for column in ServiceDirectory.Sort.allCases {
            let first = ServiceDirectory.SortSelection().selecting(column)
            XCTAssertEqual(first.column, column)
            XCTAssertEqual(first.descending, column.prefersDescending)
            let second = first.selecting(column)
            XCTAssertEqual(second.column, column)
            XCTAssertEqual(second.descending, !column.prefersDescending)
            XCTAssertEqual(second.selecting(column), ServiceDirectory.SortSelection())
        }
    }

    func testChangingSortColumnStartsItsOwnCycle() {
        let reversedName = ServiceDirectory.SortSelection(column: .name, descending: true)
        let visits = reversedName.selecting(.visits)
        XCTAssertEqual(visits, ServiceDirectory.SortSelection(column: .visits, descending: true))
        XCTAssertEqual(visits.selecting(.category), ServiceDirectory.SortSelection(column: .category))
    }

    func testClearedSortRestoresStableNameOrderRegardlessOfOldDirection() {
        let expected = ServiceDirectory.rows(groups: groups, totals: totals, catalog: CategoryCatalog())
        for descending in [false, true] {
            let reset = ServiceDirectory.rows(groups: groups.reversed(), totals: totals, catalog: CategoryCatalog(),
                                               sort: nil, descending: descending)
            XCTAssertEqual(reset.map(\.id), expected.map(\.id))
        }
    }
}
