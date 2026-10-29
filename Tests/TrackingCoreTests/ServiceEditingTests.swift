import XCTest
@testable import TrackingCore

final class ServiceEditingTests: XCTestCase {
    private let app = Source(id: Service(rawValue: "notion-app"), name: "Notion", kind: .app, identifier: "notion.id")
    private let web = Source(id: Service(rawValue: "notion-web"), name: "notion.so", kind: .website, identifier: "notion.so")
    private let slack = Source(id: Service(rawValue: "slack"), name: "Slack", kind: .app, identifier: "com.tinyspeck.slackmacgap")
    private var sources: [Source] { [app, web, slack] }
    private var visits: [Visit] {
        sources.enumerated().map { i, source in
            let start = Date(timeIntervalSince1970: Double(i * 1000))
            return Visit(service: source.id, start: start, end: start.addingTimeInterval(Double((i + 1) * 60)))
        }
    }

    private func restored(_ catalog: CategoryCatalog) throws -> CategoryCatalog {
        try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(catalog))
    }

    func testRenameKeepsIdentitySearchAndUsage() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let id = catalog.serviceID(for: app)
        try catalog.renameService(id, to: "  Research notes  ", sources: sources)
        let group = try XCTUnwrap(catalog.serviceGroups(from: sources).first { $0.id == id })
        XCTAssertEqual(group.name, "Research notes")
        XCTAssertEqual(group.sourceIDs, [app.id, web.id])
        XCTAssertTrue(group.matches("Research"))
        XCTAssertTrue(group.matches("notion.id"))
        XCTAssertEqual(catalog.categoryID(for: id), "work")
        XCTAssertEqual(try restored(catalog), catalog)
        XCTAssertEqual(app.name, "Notion")
        let rows = ServiceDirectory.rows(groups: catalog.serviceGroups(from: sources), totals: Ledger(visits: visits).lifetimeTotals, catalog: catalog)
        XCTAssertEqual(rows.first { $0.id == id }?.usage, UsageTotals(seconds: 180, visits: 2))
    }

    func testMergeAppliesCategoryAndFutureDiscoveryWithoutChangingRecordedIDs() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let from = catalog.serviceID(for: app), to = catalog.serviceID(for: slack)
        try catalog.mergeService(from, into: to, name: "Collaboration", categoryID: "communication", sources: sources)
        let discovered = Source(name: "Workspace", kind: .website, identifier: "workspace.notion.com")
        catalog.applyServiceDefaults(to: sources + [discovered])
        let groups = catalog.serviceGroups(from: sources + [discovered])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, to)
        XCTAssertEqual(groups[0].name, "Collaboration")
        XCTAssertEqual(groups[0].sourceIDs, Set((sources + [discovered]).map(\.id)))
        XCTAssertEqual(catalog.members(sources: sources + [discovered])["communication"], groups[0].sourceIDs)
        let rows = ServiceDirectory.rows(groups: groups, totals: Ledger(visits: visits).lifetimeTotals, catalog: catalog)
        XCTAssertEqual(rows[0].usage, UsageTotals(seconds: 360, visits: 3))
        XCTAssertEqual(rows[0].kind, .mixed)
        XCTAssertEqual(try restored(catalog), catalog)
    }

    func testSplitSurvivesRestartDefaultsAndDiscoveryAndKeepsItsCategory() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let originalID = catalog.serviceID(for: app)
        try catalog.assign("learning", to: originalID)
        let separated = try catalog.splitServiceMember(web.id, from: originalID, name: "Notion web", sources: sources)
        catalog = try restored(catalog)
        let discovered = Source(name: "New workspace", kind: .website, identifier: "team.notion.com")
        let all = sources + [discovered]
        catalog.applyServiceDefaults(to: all)
        XCTAssertEqual(catalog.serviceID(for: web), separated)
        XCTAssertEqual(catalog.serviceID(for: discovered), originalID)
        XCTAssertEqual(catalog.categoryID(for: separated), "learning")
        let rows = ServiceDirectory.rows(groups: catalog.serviceGroups(from: all), totals: Ledger(visits: visits).lifetimeTotals, catalog: catalog)
        XCTAssertEqual(rows.first { $0.id == separated }?.usage, UsageTotals(seconds: 120, visits: 1))
        XCTAssertEqual(rows.reduce(UsageTotals()) { $0 + $1.usage }, UsageTotals(seconds: 360, visits: 3))
        XCTAssertEqual(catalog.members(sources: all)["learning"], [app.id, web.id, discovered.id])
    }

    func testSplitOverrideSurvivesMergeOfOriginalAutomaticGroup() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let original = catalog.serviceID(for: app)
        let separate = try catalog.splitServiceMember(web.id, from: original, name: "Web notes", sources: sources)
        try catalog.mergeService(original, into: catalog.serviceID(for: slack), name: "Workspace", categoryID: "work", sources: sources)
        XCTAssertEqual(catalog.serviceID(for: web), separate)
        XCTAssertNotEqual(catalog.serviceID(for: app), separate)
        XCTAssertEqual(catalog.serviceGroups(from: sources).count, 2)
    }

    func testMergeKeepsDestinationIconSourceAndSplitUsesRemainingMember() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let destination = catalog.serviceID(for: app)
        try catalog.mergeService(catalog.serviceID(for: slack), into: destination, name: "Notes", categoryID: "work", sources: sources)
        catalog = try restored(catalog)
        XCTAssertEqual(catalog.serviceGroups(from: sources).first?.representative.id, app.id)
        let split = try catalog.splitServiceMember(app.id, from: destination, name: "Notion app", sources: sources)
        let groups = catalog.serviceGroups(from: sources)
        XCTAssertEqual(groups.first { $0.id == split }?.representative.id, app.id)
        XCTAssertNotEqual(groups.first { $0.id == destination }?.representative.id, app.id)
    }

    func testRepeatedMergeSplitAndRemergeNeverDuplicateOrLoseSources() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let original = catalog.serviceID(for: app)
        let separate = try catalog.splitServiceMember(web.id, from: original, name: "Web", sources: sources)
        let destination = catalog.serviceID(for: slack)
        try catalog.mergeService(separate, into: destination, name: "Workspace", categoryID: "personal", sources: sources)
        try catalog.mergeService(destination, into: original, name: "All together", categoryID: "work", sources: sources)
        var current = original
        for _ in 0..<6 {
            let id = try catalog.splitServiceMember(web.id, from: current, name: "Web", sources: sources)
            try catalog.mergeService(current, into: id, name: "All together", categoryID: "work", sources: sources)
            current = catalog.serviceID(for: app)
            // Merge into a different surviving identity on each iteration.
            let slackID = try catalog.splitServiceMember(slack.id, from: current, name: "Slack", sources: sources)
            try catalog.mergeService(slackID, into: current, name: "All together", categoryID: "work", sources: sources)
            let all = catalog.serviceGroups(from: sources)
            XCTAssertEqual(all.count, 1)
            XCTAssertEqual(all[0].sourceIDs, Set(sources.map(\.id)))
            catalog = try restored(catalog)
        }
        XCTAssertEqual(Set(sources.map { catalog.serviceID(for: $0) }).count, 1)
    }

    func testOverviewSelectionAndCSVFollowManualMembership() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        try catalog.mergeService(catalog.serviceID(for: app), into: catalog.serviceID(for: slack),
                                 name: "Together", categoryID: "communication", sources: sources)
        let splitID = try catalog.splitServiceMember(web.id, from: catalog.serviceID(for: web), name: "Notes web", sources: sources)
        try catalog.assign("learning", to: splitID)
        try catalog.select(["learning"])
        XCTAssertEqual(catalog.includedSourceIDs(sources: sources), [web.id])
        let activity = DayActivity(ledger: Ledger(visits: visits), interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86400), includedServices: catalog.includedSourceIDs(sources: sources))
        XCTAssertEqual(activity.statistics(for: [web.id]).seconds, 120)
        let csv = VisitCSV.export(visits, sources: sources, categories: catalog)
        XCTAssertTrue(csv.contains("\"Notion\",")) // Raw source names are retained in a raw-record export.
        XCTAssertEqual(csv.components(separatedBy: "\"Communication\"").count - 1, 2)
        XCTAssertEqual(csv.components(separatedBy: "\"Learning\"").count - 1, 1)
    }

    func testInvalidEditsLeaveCatalogUnchanged() throws {
        var catalog = CategoryCatalog(legacySources: sources)
        let before = catalog, group = catalog.serviceID(for: app), destination = catalog.serviceID(for: slack)
        for name in ["", "  ", "a\nb", String(repeating: "x", count: 254)] {
            XCTAssertThrowsError(try catalog.renameService(group, to: name, sources: sources))
            XCTAssertThrowsError(try catalog.mergeService(group, into: destination, name: name, categoryID: "work", sources: sources))
            XCTAssertThrowsError(try catalog.splitServiceMember(web.id, from: group, name: name, sources: sources))
            XCTAssertEqual(catalog, before)
        }
        XCTAssertThrowsError(try catalog.mergeService(group, into: group, name: "Same", categoryID: "work", sources: sources))
        XCTAssertThrowsError(try catalog.mergeService(group, into: destination, name: "Valid", categoryID: "missing", sources: sources))
        XCTAssertThrowsError(try catalog.mergeService("missing", into: destination, name: "Valid", categoryID: "work", sources: sources))
        XCTAssertThrowsError(try catalog.renameService("missing", to: "Valid", sources: sources))
        XCTAssertThrowsError(try catalog.splitServiceMember(slack.id, from: destination, name: "Slack", sources: sources))
        XCTAssertThrowsError(try catalog.splitServiceMember(slack.id, from: group, name: "Slack", sources: sources))
        XCTAssertEqual(catalog, before)
    }

    func testOldFilesSeparateCodexFromChatGPTAndPreserveCategoryOnce() throws {
        let chat = Source(name: "ChatGPT", kind: .app, identifier: "com.openai.chat")
        let codex = Source(name: "ChatGPT", kind: .app, identifier: "com.openai.codex")
        var old = CategoryCatalog(legacySources: [chat])
        try old.assign("personal", to: "known:chatgpt")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["servicePreferences"] = nil
        var catalog = try JSONDecoder().decode(CategoryCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        catalog.applyServiceDefaults(to: [chat, codex])
        XCTAssertEqual(catalog.serviceGroups(from: [chat, codex]).map(\.name), ["ChatGPT", "Codex"])
        XCTAssertEqual(catalog.categoryID(for: "known:codex"), "personal")
        XCTAssertEqual(ServiceGrouping.sourceName(for: codex), "Codex")
        try catalog.mergeService("known:codex", into: "known:chatgpt", name: "AI tools", categoryID: "work", sources: [chat, codex])
        let before = catalog
        catalog = try restored(catalog)
        catalog.applyServiceDefaults(to: [chat, codex])
        XCTAssertEqual(catalog, before)
        XCTAssertEqual(catalog.serviceGroups(from: [chat, codex]).count, 1)
    }

    func testStoreCommitsGroupingAndCategoryTogetherWithoutRewritingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrackingStore(directory: directory)
        let originalVisits = visits
        try store.saveSources(sources); try store.saveVisits(originalVisits)
        let sourceBytes = try Data(contentsOf: store.sourcesURL), visitBytes = try Data(contentsOf: store.visitsURL)
        var catalog = CategoryCatalog(legacySources: sources)
        let split = try catalog.splitServiceMember(web.id, from: catalog.serviceID(for: app), name: "Web notes", sources: sources)
        try catalog.assign("learning", to: split)
        try store.saveCategories(catalog)
        XCTAssertEqual(try store.loadCategories(legacySources: sources), catalog)
        XCTAssertEqual(try Data(contentsOf: store.sourcesURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: store.visitsURL), visitBytes)
        XCTAssertEqual(try store.loadVisits(), originalVisits)
    }

    func testCorruptMergeCyclesAreRejectedWithoutOverwritingSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrackingStore(directory: directory)
        try store.saveCategories(CategoryCatalog())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.categoriesURL)) as? [String: Any])
        json["servicePreferences"] = ["names": [:], "redirects": ["a": "b", "b": "a"], "sourceAssignments": [:]]
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: store.categoriesURL)
        XCTAssertThrowsError(try store.loadCategories(legacySources: sources))
        XCTAssertEqual(try Data(contentsOf: store.categoriesURL), bytes)
        json["servicePreferences"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(CategoryCatalog.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
