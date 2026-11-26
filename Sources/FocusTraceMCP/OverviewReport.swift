import Foundation
import TrackingCore

struct OverviewQuery: Decodable {
    enum Period: String, Decodable {
        case day, week, month, year

        var activityPeriod: ActivityPeriod {
            switch self {
            case .day: return .day
            case .week: return .week
            case .month: return .month
            case .year: return .year
            }
        }
    }

    enum Grouping: String, Decodable {
        case category, service
    }

    let date: String
    let period: Period
    let timeZone: String?
    let categoryIds: [String]?
    let serviceId: String?
    let groupBy: Grouping?
    let binIndex: Int?
}

struct OverviewReport: Encodable {
    struct Range: Encodable {
        let start: Date
        let endExclusive: Date

        init(_ interval: DateInterval) {
            start = interval.start
            endExclusive = interval.end
        }
    }

    struct Usage: Encodable {
        let seconds: Double
        let visits: Double

        init(_ statistics: Statistics, divisor: Double) {
            seconds = statistics.seconds / divisor
            visits = Double(statistics.visits) / divisor
        }
    }

    struct CategoryTime: Encodable {
        let categoryId: String
        let seconds: Double
    }

    struct Bin: Encodable {
        let index: Int
        let interval: Range
        let isFuture: Bool
        let seconds: Double?
        let divisor: Int
        let categories: [CategoryTime]
    }

    struct Row: Encodable {
        let id: String
        let name: String
        let categoryId: String
        let usage: Usage?
    }

    let period: String
    let timeZone: String
    let interval: Range
    let headlineInterval: Range
    let completedRecordedDays: Int
    let headlineIsDailyAverage: Bool
    let headline: Usage?
    let categoryIds: [String]
    let selectedServiceId: String?
    let bins: [Bin]
    let selectedBinIndex: Int?
    let breakdownInterval: Range
    let breakdownIsDailyAverage: Bool
    let breakdownHasData: Bool
    let groupBy: String
    let rows: [Row]
    let lastObservedAt: Date?

    static func read(_ query: OverviewQuery, databaseURL: URL, now: Date = Date()) throws -> OverviewReport {
        let dates = try ReportCalendar(timeZone: query.timeZone, calendar: .current)
        let date = try dates.date(query.date)
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let ledger = Ledger(visits: snapshot.visits)
        let catalog = snapshot.categories
        let categoryFilter = query.categoryIds.map(Set.init) ?? catalog.selectedIDs ?? []
        try catalog.validateCategoryIDs(categoryFilter)
        let categories = catalog.options.filter { categoryFilter.isEmpty || categoryFilter.contains($0.id) }
        let members = catalog.members(sources: snapshot.sources, recordedIDs: ledger.recordedIDs)
        let included = categories.reduce(into: Set<Service>()) { $0.formUnion(members[$1.id] ?? []) }
        let groups = catalog.serviceGroups(from: snapshot.sources)
        let selectedService = try findService(query.serviceId, in: groups)
        let selectedSources = selectedService.map { $0.sourceIDs.intersection(included) }
        let calendar = dates.calendar
        let period = query.period.activityPeriod
        let report = PeriodActivity(ledger: ledger, coverage: snapshot.coverage, period: period, date: date,
                                    now: now, includedServices: included, calendar: calendar)

        let selectedBin: PeriodActivity.Bin?
        if let index = query.binIndex {
            guard report.bins.indices.contains(index) else { throw QueryError("bin_index is outside the Overview period.") }
            selectedBin = report.bins[index]
        } else {
            selectedBin = nil
        }
        let breakdownInterval = selectedBin.map { report.selectionInterval(for: $0, now: now, calendar: calendar) }
            ?? report.activity.interval
        let breakdown = selectedBin.map { _ in
            DayActivity(ledger: ledger, interval: breakdownInterval, includedServices: included)
        } ?? report.activity
        let breakdownHasData = selectedBin.map { $0.seconds != nil } ?? report.hasData
        let breakdownDivisor = selectedBin.map { Double($0.denominator) } ?? report.divisor
        let grouping = query.groupBy ?? .category
        let headline = selectedSources.map { report.activity.statistics(for: $0) } ?? report.activity.statistics
        let bins = report.bins.map { bin in
            let filtered = selectedSources.map { bin.filtered(to: $0) } ?? bin
            let segments = selectedSources == nil ? bin.categorySegments(categories, members: members) : []
            return Bin(index: bin.id, interval: Range(bin.interval), isFuture: bin.isFuture,
                       seconds: filtered.seconds, divisor: bin.denominator,
                       categories: segments.map { CategoryTime(categoryId: $0.category.id, seconds: $0.seconds) })
        }
        return OverviewReport(
            period: query.period.rawValue, timeZone: calendar.timeZone.identifier,
            interval: Range(report.interval), headlineInterval: Range(report.activity.interval),
            completedRecordedDays: report.recordedDays, headlineIsDailyAverage: period != .day,
            headline: report.hasData ? Usage(headline, divisor: report.divisor) : nil,
            categoryIds: categories.map(\.id), selectedServiceId: selectedService?.id, bins: bins,
            selectedBinIndex: selectedBin?.id, breakdownInterval: Range(breakdownInterval),
            breakdownIsDailyAverage: selectedBin == nil ? period != .day : period == .year,
            breakdownHasData: breakdownHasData, groupBy: grouping.rawValue,
            rows: rows(for: grouping, breakdown: breakdown, divisor: max(1, breakdownDivisor),
                       hasData: breakdownHasData, categories: categories, members: members, groups: groups, catalog: catalog),
            lastObservedAt: snapshot.lastObservedAt
        )
    }

    private static func rows(for grouping: OverviewQuery.Grouping, breakdown: DayActivity, divisor: Double,
                             hasData: Bool, categories: [ActivityCategory], members: [String: Set<Service>],
                             groups: [ServiceGroup], catalog: CategoryCatalog) -> [Row] {
        let rows: [Row]
        switch grouping {
        case .category:
            rows = categories.map { category in
                let stats = breakdown.statistics(for: members[category.id] ?? [])
                return Row(id: category.id, name: category.name, categoryId: category.id,
                           usage: hasData ? Usage(stats, divisor: divisor) : nil)
            }
        case .service:
            rows = groups.compactMap { group in
                let stats = breakdown.statistics(for: group.sourceIDs)
                guard stats.seconds > 0 || stats.visits > 0 else { return nil }
                return Row(id: group.id, name: group.name, categoryId: catalog.category(for: group.id).id,
                           usage: Usage(stats, divisor: divisor))
            }
        }
        return rows.sorted {
            let lhs = $0.usage?.seconds ?? 0, rhs = $1.usage?.seconds ?? 0
            if lhs != rhs { return lhs > rhs }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

func findService(_ id: String?, in groups: [ServiceGroup]) throws -> ServiceGroup? {
    guard let id else { return nil }
    guard let group = groups.first(where: { $0.id == id }) else {
        throw QueryError("Unknown service_id. Use list_services to find a valid ID.")
    }
    return group
}

extension CategoryCatalog {
    func validateCategoryIDs(_ ids: Set<String>) throws {
        guard ids.isSubset(of: Set(options.map(\.id))) else {
            throw QueryError("Unknown category ID. Use recording_info to find valid IDs.")
        }
    }
}
