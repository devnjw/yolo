import Foundation
import TrackingCore

private func pageLimit(_ limit: Int?, maximum: Int) throws -> Int {
    let value = limit ?? 25
    guard (1...maximum).contains(value) else { throw QueryError("limit must be between 1 and \(maximum).") }
    return value
}

private struct Page<Row: Encodable>: Encodable {
    let rows: [Row]
    let total: Int
    let nextOffset: Int?

    init(_ rows: [Row], offset: Int?, limit: Int) throws {
        let start = offset ?? 0
        guard start >= 0 else { throw QueryError("offset must be nonnegative.") }
        total = rows.count
        let lower = min(start, total)
        let end = lower + min(limit, total - lower)
        self.rows = Array(rows[lower..<end])
        nextOffset = end < total ? end : nil
    }
}

struct ServicesQuery: Decodable {
    enum Kind: String, Decodable {
        case app, web, mixed

        var directoryKind: ServiceDirectory.Kind {
            switch self {
            case .app: return .app
            case .web: return .web
            case .mixed: return .mixed
            }
        }
    }

    enum Sort: String, Decodable {
        case name, type, category, visits, time

        var directorySort: ServiceDirectory.Sort {
            switch self {
            case .name: return .name
            case .type: return .type
            case .category: return .category
            case .visits: return .visits
            case .time: return .time
            }
        }
    }

    let serviceId: String?
    let search: String?
    let kind: Kind?
    let categoryId: String?
    let sort: Sort?
    let descending: Bool?
    let includeMembers: Bool?
    let offset: Int?
    let limit: Int?
}

struct ServicesReport: Encodable {
    struct Member: Encodable {
        let source: Source
        let lifetimeUsage: UsageReport.Totals
    }

    struct Row: Encodable {
        let id: String
        let name: String
        let type: String
        let categoryId: String
        let category: String
        let lifetimeUsage: UsageReport.Totals
        let memberCount: Int
        let members: [Member]?
    }

    fileprivate let services: Page<Row>
    let lastObservedAt: Date?

    static func read(_ query: ServicesQuery, databaseURL: URL) throws -> ServicesReport {
        let limit = try pageLimit(query.limit, maximum: 100)
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let catalog = snapshot.categories
        if let id = query.categoryId { try catalog.validateCategoryIDs([id]) }
        let groups = catalog.serviceGroups(from: snapshot.sources)
        let selected = try findService(query.serviceId, in: groups)
        let totals = Ledger(visits: snapshot.visits).lifetimeTotals
        let sort = query.sort?.directorySort ?? .name
        let directory = ServiceDirectory.rows(groups: selected.map { [$0] } ?? groups, totals: totals, catalog: catalog,
                                              search: query.search ?? "", kind: query.kind?.directoryKind,
                                              categoryID: query.categoryId, sort: sort,
                                              descending: query.descending ?? sort.prefersDescending)
        let rows = directory.map { row in
            Row(id: row.id, name: row.group.name, type: row.kind.rawValue, categoryId: row.category.id, category: row.category.name,
                lifetimeUsage: UsageReport.Totals(row.usage), memberCount: row.group.sources.count,
                members: query.includeMembers == true ? row.group.sources.map {
                    Member(source: $0, lifetimeUsage: UsageReport.Totals(totals[$0.id] ?? UsageTotals()))
                } : nil)
        }
        return ServicesReport(services: try Page(rows, offset: query.offset, limit: limit),
                              lastObservedAt: snapshot.lastObservedAt)
    }
}

struct VisitsQuery: Decodable {
    let startDate: String
    let endDate: String
    let timeZone: String?
    let startAt: String?
    let endAt: String?
    let categoryIds: [String]?
    let serviceId: String?
    let sourceId: String?
    let afterVisitId: UUID?
    let limit: Int?
}

struct VisitsReport: Encodable {
    struct Row: Encodable {
        let id: UUID
        let serviceId: String?
        let service: String?
        let sourceId: Service
        let source: String?
        let categoryId: String
        let category: String
        let start: Date
        let end: Date
        let seconds: TimeInterval
        let secondsInRange: TimeInterval
        let countedInRange: Bool
        let isQuickCheck: Bool
    }

    let interval: OverviewReport.Range
    let timeZone: String
    let hasRecording: Bool
    let total: UsageReport.Totals?
    let longestVisitSeconds: TimeInterval?
    let quickChecks: Int?
    let shareOfScopedTime: Double?
    let matchingVisitCount: Int
    let visits: [Row]
    let nextAfterVisitId: UUID?
    let lastObservedAt: Date?

    static func read(_ query: VisitsQuery, databaseURL: URL, now: Date = Date()) throws -> VisitsReport {
        let limit = try pageLimit(query.limit, maximum: 100)
        let dates = try ReportCalendar(timeZone: query.timeZone)
        let range = try dates.range(startDate: query.startDate, endDate: query.endDate,
                                   startAt: query.startAt, endAt: query.endAt)
        let interval = DateInterval(start: range.start, end: max(range.start, min(range.end, now)))
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let ledger = Ledger(visits: snapshot.visits)
        let catalog = snapshot.categories
        let groups = catalog.serviceGroups(from: snapshot.sources)
        let group = try findService(query.serviceId, in: groups)
        let categories = Set(query.categoryIds ?? [])
        try catalog.validateCategoryIDs(categories)
        let members = catalog.members(sources: snapshot.sources, recordedIDs: ledger.recordedIDs)
        let scope = categories.isEmpty ? nil : categories.reduce(into: Set<Service>()) {
            $0.formUnion(members[$1] ?? [])
        }
        let activity = DayActivity(ledger: ledger, interval: interval, includedServices: scope)
        var selected = Set(activity.sources.keys)
        if let group { selected.formIntersection(group.sourceIDs) }
        if let id = query.sourceId { selected.formIntersection([Service(rawValue: id)]) }
        let visits = activity.visits(for: selected)
        let start: Int
        if let after = query.afterVisitId {
            guard let index = visits.firstIndex(where: { $0.id == after }) else {
                throw QueryError("The visit cursor no longer matches this query. Start again without after_visit_id.")
            }
            start = index + 1
        } else {
            start = 0
        }
        let end = min(start + limit, visits.count)
        let sources = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        let groupsBySource = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.sources.map { ($0.id, group) }
        })
        let rows = visits[start..<end].map { visit in
            let group = groupsBySource[visit.service]
            let category = group.map { catalog.category(for: $0.id) } ?? catalog.fallbackCategory
            return Row(id: visit.id, serviceId: group?.id, service: group?.name, sourceId: visit.service,
                       source: sources[visit.service]?.name, categoryId: category.id, category: category.name,
                       start: visit.start, end: visit.end, seconds: visit.duration, secondsInRange: visit.seconds(in: interval),
                       countedInRange: visit.start >= interval.start && visit.start < interval.end,
                       isQuickCheck: visit.duration <= 30)
        }
        let hasRecording = interval.duration > 0 && snapshot.coverage.hasRecording(in: interval, ledger: ledger)
        let statistics = activity.statistics(for: selected)
        let scopedSeconds = activity.statistics.seconds
        return VisitsReport(interval: OverviewReport.Range(interval), timeZone: dates.calendar.timeZone.identifier,
                            hasRecording: hasRecording, total: hasRecording ? UsageReport.Totals(statistics) : nil,
                            longestVisitSeconds: hasRecording ? visits.lazy.map { $0.seconds(in: interval) }.max() ?? 0 : nil,
                            quickChecks: hasRecording ? statistics.shortVisits : nil,
                            shareOfScopedTime: scopedSeconds > 0 ? statistics.seconds / scopedSeconds : nil,
                            matchingVisitCount: visits.count, visits: rows,
                            nextAfterVisitId: end < visits.count ? rows.last?.id : nil,
                            lastObservedAt: snapshot.lastObservedAt)
    }
}

struct CoverageQuery: Decodable {
    let startDate: String
    let endDate: String
    let timeZone: String?
    let startAt: String?
    let endAt: String?
    let offset: Int?
    let limit: Int?
}

struct CoverageReport: Encodable {
    struct Row: Encodable {
        let start: Date
        let end: Date
        let secondsInRange: TimeInterval
    }

    let interval: OverviewReport.Range
    let timeZone: String
    fileprivate let coverage: Page<Row>
    let lastObservedAt: Date?

    static func read(_ query: CoverageQuery, databaseURL: URL) throws -> CoverageReport {
        let limit = try pageLimit(query.limit, maximum: 200)
        let dates = try ReportCalendar(timeZone: query.timeZone)
        let range = try dates.range(startDate: query.startDate, endDate: query.endDate,
                                   startAt: query.startAt, endAt: query.endAt)
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let rows = snapshot.coverage.intervals.compactMap { interval -> Row? in
            guard interval.start < range.end, interval.end > range.start || interval.start >= range.start else {
                return nil
            }
            let seconds = min(interval.end, range.end).timeIntervalSince(max(interval.start, range.start))
            return Row(start: interval.start, end: interval.end, secondsInRange: seconds)
        }
        return CoverageReport(interval: OverviewReport.Range(range), timeZone: dates.calendar.timeZone.identifier,
                              coverage: try Page(rows, offset: query.offset, limit: limit),
                              lastObservedAt: snapshot.lastObservedAt)
    }
}

struct RecordingInfo: Encodable {
    struct Settings: Encodable {
        let websiteTrackingEnabled: Bool
        let enabledBrowsers: [String]
    }

    let categories: [ActivityCategory]
    let selectedCategoryIds: [String]?
    let settings: Settings
    let dataStartsAt: Date?
    let lastObservedAt: Date?
    let storedVisits: Int
    let storedCoverageIntervals: Int
    let automaticBackupDates: [Date]?

    static func read(databaseURL: URL, backups: RecordingBackups?) throws -> RecordingInfo {
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let starts = [snapshot.coverage.intervals.lazy.map(\.start).min(), snapshot.visits.lazy.map(\.start).min()]
        let settings = Settings(websiteTrackingEnabled: snapshot.options.websitesEnabled,
                                enabledBrowsers: snapshot.options.enabledBrowsers.map(\.name).sorted())
        return RecordingInfo(categories: snapshot.categories.options, selectedCategoryIds: snapshot.categories.selectedIDs?.sorted(),
                             settings: settings, dataStartsAt: starts.compactMap { $0 }.min(),
                             lastObservedAt: snapshot.lastObservedAt, storedVisits: snapshot.visits.count,
                             storedCoverageIntervals: snapshot.coverage.intervals.count,
                             automaticBackupDates: backups.flatMap { try? $0.automaticEntries().map(\.date) })
    }
}
