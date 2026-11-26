import Foundation
import TrackingCore
import XCTest
@testable import FocusTraceMCP

final class UsageReportTests: XCTestCase {
    private var directory: URL!
    private let formatter = ISO8601DateFormatter()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDailyReportDistinguishesMidnightVisitIdleAndMissingData() throws {
        let database = try RecordingDatabase(directory: directory)
        let visit = Visit(service: .youtube, start: date("2026-07-02T14:59:00Z"), end: date("2026-07-02T15:02:00Z"))
        let idle = DateInterval(start: date("2026-07-03T15:00:00Z"), duration: 10)
        try database.save(visits: [(0, visit)], coverage: [(0, idle)])

        let query = UsageQuery(startDate: "2026-07-02", endDate: "2026-07-06", timeZone: "Asia/Seoul", groupBy: .day)
        let report = try UsageReport.read(query, databaseURL: database.url, now: date("2026-07-07T00:00:00Z"))
        let days = try XCTUnwrap(report.days)
        XCTAssertEqual(days.map(\.recorded), [true, true, true, false])
        XCTAssertEqual(days.map { $0.usage?.seconds }, [60, 120, 0, nil])
        XCTAssertEqual(days.map { $0.usage?.visits }, [1, 0, 0, nil])
        XCTAssertEqual(report.total?.seconds, 180)
        XCTAssertEqual(report.recordedDays, 3)
        XCTAssertEqual(report.averageSecondsPerRecordedDay, 60)
        XCTAssertEqual(report.lastObservedAt, idle.end)
    }

    func testReportUsesCustomServiceMergesAndOnlyNamesServicesOnRequest() throws {
        let database = try RecordingDatabase(directory: directory)
        let app = Source(name: "Example app", kind: .app, identifier: "org.example.app")
        let web = Source(name: "example.org", kind: .website, identifier: "example.org")
        let sources = [app, web]
        var catalog = CategoryCatalog()
        try catalog.mergeService(catalog.serviceID(for: app), into: catalog.serviceID(for: web),
                                 name: "Merged service", categoryID: "work", sources: sources)
        try database.saveCatalog(sources: sources, categories: catalog)
        let start = date("2026-07-02T00:00:00Z")
        let visits = sources.enumerated().map { index, source in
            (index, Visit(service: source.id, start: start.addingTimeInterval(Double(index) * 60),
                          end: start.addingTimeInterval(Double(index + 1) * 60)))
        }
        try database.save(visits: visits, coverage: [])

        let defaultQuery = UsageQuery(startDate: "2026-07-02", endDate: "2026-07-03", timeZone: "UTC", groupBy: nil)
        let serviceQuery = UsageQuery(startDate: "2026-07-02", endDate: "2026-07-03", timeZone: "UTC", groupBy: .service)
        let now = date("2026-07-04T00:00:00Z")
        let summary = try UsageReport.read(defaultQuery, databaseURL: database.url, now: now)
        XCTAssertNil(summary.services)
        XCTAssertEqual(summary.categories?.map(\.name), ["Work"])
        XCTAssertEqual(summary.categories?.first?.usage.seconds, 120)
        let detail = try UsageReport.read(serviceQuery, databaseURL: database.url, now: now)
        XCTAssertEqual(detail.services?.map(\.name), ["Merged service"])
        XCTAssertEqual(detail.services?.first?.usage.visits, 2)
    }

    func testReadDoesNotCreateOrChangeRecordingFile() throws {
        let path = directory.appendingPathComponent("recording.sqlite3")
        let query = UsageQuery(startDate: "2026-07-02", endDate: "2026-07-03", timeZone: "UTC", groupBy: nil)
        XCTAssertThrowsError(try UsageReport.read(query, databaseURL: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let database = try RecordingDatabase(directory: directory)
        let bytes = try Data(contentsOf: database.url)
        let report = try UsageReport.read(query, databaseURL: path)
        XCTAssertEqual(report.recordedDays, 0)
        XCTAssertNil(report.total)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testOverviewUsesCompletedDaysAndCanFocusServiceAndHour() throws {
        let database = try RecordingDatabase(directory: directory)
        let app = Source(name: "Editor", kind: .app, identifier: "org.example.editor")
        var catalog = CategoryCatalog()
        let serviceID = catalog.serviceID(for: app)
        try catalog.assign("work", to: serviceID)
        try database.saveCatalog(sources: [app], categories: catalog)
        let previous = date("2026-07-02T12:00:00Z")
        let current = date("2026-07-03T12:00:00Z")
        try database.save(visits: [
            (0, Visit(service: app.id, start: previous, end: previous.addingTimeInterval(120))),
            (1, Visit(service: app.id, start: current, end: current.addingTimeInterval(240)))
        ], coverage: [])
        let now = current.addingTimeInterval(7_200)
        let month = OverviewQuery(date: "2026-07-03", period: .month, timeZone: "UTC", categoryIds: ["work"],
                                  serviceId: nil, groupBy: .service, binIndex: nil)
        let average = try OverviewReport.read(month, databaseURL: database.url, now: now)
        XCTAssertEqual(average.completedRecordedDays, 1)
        XCTAssertEqual(average.headline?.seconds, 120)
        XCTAssertEqual(average.bins[2].seconds, 240)
        XCTAssertEqual(average.rows.first?.id, serviceID)

        let day = OverviewQuery(date: "2026-07-03", period: .day, timeZone: "UTC", categoryIds: ["work"],
                                serviceId: serviceID, groupBy: .service, binIndex: 12)
        let hour = try OverviewReport.read(day, databaseURL: database.url, now: now)
        XCTAssertEqual(hour.headline?.seconds, 240)
        XCTAssertEqual(hour.bins[12].seconds, 240)
        XCTAssertEqual(hour.bins[12].categories.count, 0)
        XCTAssertEqual(hour.rows.first?.usage?.visits, 1)
        XCTAssertEqual(hour.breakdownInterval.start, current)
        XCTAssertEqual(hour.breakdownInterval.endExclusive, current.addingTimeInterval(3_600))
    }

    func testVisitPagesKeepOriginalTimesAndClipUsageAtRangeBoundaries() throws {
        let database = try RecordingDatabase(directory: directory)
        let legacySource = Service(rawValue: "orphan-legacy")
        let first = Visit(service: legacySource, start: date("2026-07-02T23:59:00Z"), end: date("2026-07-03T00:01:00Z"))
        let second = Visit(service: legacySource, start: date("2026-07-03T00:02:00Z"), end: date("2026-07-03T00:02:15Z"))
        try database.save(visits: [(0, first), (1, second)], coverage: [])
        let now = date("2026-07-04T00:00:00Z")
        func query(after: UUID?) -> VisitsQuery {
            VisitsQuery(startDate: "2026-07-03", endDate: "2026-07-04", timeZone: "UTC",
                        startAt: nil, endAt: "2026-07-03T00:03:00.000Z",
                        categoryIds: ["uncategorized"], serviceId: nil, sourceId: legacySource.rawValue,
                        afterVisitId: after, limit: 1)
        }
        let page = try VisitsReport.read(query(after: nil), databaseURL: database.url, now: now)
        XCTAssertEqual(page.visits.first?.id, second.id)
        XCTAssertEqual(page.quickChecks, 1)
        XCTAssertEqual(page.total?.visits, 1)
        XCTAssertEqual(page.total?.seconds, 75)
        XCTAssertEqual(page.longestVisitSeconds, 60)
        XCTAssertEqual(page.nextAfterVisitId, second.id)

        let next = try VisitsReport.read(query(after: page.nextAfterVisitId), databaseURL: database.url, now: now)
        XCTAssertEqual(next.visits.first?.id, first.id)
        XCTAssertEqual(next.visits.first?.categoryId, "uncategorized")
        XCTAssertEqual(next.visits.first?.start, first.start)
        XCTAssertEqual(next.visits.first?.countedInRange, false)
        XCTAssertEqual(next.visits.first?.secondsInRange, 60)
        XCTAssertNil(next.nextAfterVisitId)
        XCTAssertThrowsError(try VisitsReport.read(query(after: UUID()), databaseURL: database.url, now: now))
    }

    func testToolPayloadIncludesUnusedServicesAndSavedRecordingMetadata() throws {
        let database = try RecordingDatabase(directory: directory)
        let web = Source(name: "Example", kind: .website, identifier: "example.org", aliases: ["alias.example.org"])
        try database.saveCatalog(sources: [web], categories: CategoryCatalog())
        try database.saveOptions(TrackingOptions(websitesEnabled: true, enabledBrowsers: [.safari]))
        let start = date("2026-07-03T00:00:00Z")
        try database.save(visits: [], coverage: [(0, DateInterval(start: start, duration: 20))])
        func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let tool = try XCTUnwrap(FocusTraceTools.all.first { $0.name == name })
            let context = RecordingContext(databaseURL: database.url, backups: nil)
            let result = try tool.run(JSONSerialization.data(withJSONObject: arguments), context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        }
        let directory = try call("list_services", ["search": "alias.example.org", "include_members": true])
        let services = try XCTUnwrap(directory["services"] as? [String: Any])
        let rows = try XCTUnwrap(services["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(services["total"] as? Int, 1)
        XCTAssertEqual(row["type"] as? String, "Web")
        XCTAssertEqual((row["lifetime_usage"] as? [String: Any])?["visits"] as? Int, 0)
        let member = (row["members"] as? [[String: Any]])?.first?["source"] as? [String: Any]
        XCTAssertEqual(member?["identifier"] as? String, "example.org")
        XCTAssertEqual(member?["aliases"] as? [String], ["alias.example.org"])

        let info = try call("recording_info", [:])
        XCTAssertEqual(info["stored_visits"] as? Int, 0)
        XCTAssertEqual(info["stored_coverage_intervals"] as? Int, 1)
        XCTAssertNotNil(info["data_starts_at"])
        let settings = info["settings"] as? [String: Any]
        XCTAssertEqual(settings?["website_tracking_enabled"] as? Bool, true)
        XCTAssertEqual(settings?["enabled_browsers"] as? [String], ["Safari"])
        let coverage = try call("list_recording_coverage", ["start_date": "2026-07-03", "end_date": "2026-07-04",
                                                           "time_zone": "UTC", "start_at": "2026-07-03T00:00:05Z"])
        let intervals = (coverage["coverage"] as? [String: Any])?["rows"] as? [[String: Any]]
        XCTAssertEqual(intervals?.first?["seconds_in_range"] as? Double, 15)
    }

    private func date(_ value: String) -> Date {
        formatter.date(from: value)!
    }
}
