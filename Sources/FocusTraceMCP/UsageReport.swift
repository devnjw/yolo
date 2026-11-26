import Foundation
import TrackingCore

struct UsageQuery: Decodable {
    enum Grouping: String, Decodable {
        case category, service, day
    }

    let startDate: String
    let endDate: String
    let timeZone: String?
    let groupBy: Grouping?
}

struct ReportCalendar {
    let calendar: Calendar
    let formatter: DateFormatter

    init(timeZone: String?, calendar: Calendar = Calendar(identifier: .gregorian)) throws {
        var calendar = calendar
        if let timeZone {
            guard let zone = TimeZone(identifier: timeZone) else {
                throw QueryError("Use a valid IANA time zone, such as Asia/Seoul.")
            }
            calendar.timeZone = zone
        }
        self.calendar = calendar

        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
    }

    func date(_ value: String) throws -> Date {
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw QueryError("Use valid YYYY-MM-DD dates.")
        }
        return date
    }

    func range(startDate: String, endDate: String, startAt: String? = nil, endAt: String? = nil) throws -> DateInterval {
        let start = try date(startDate)
        let end = try date(endDate)
        guard start < end else { throw QueryError("end_date must be later than start_date and is exclusive.") }
        guard let days = calendar.dateComponents([.day], from: start, to: end).day, days <= 366 else {
            throw QueryError("Query up to 366 calendar days at a time.")
        }
        let narrowedStart = try startAt.map(Self.timestamp) ?? start
        let narrowedEnd = try endAt.map(Self.timestamp) ?? end
        guard start <= narrowedStart, narrowedStart < narrowedEnd, narrowedEnd <= end else {
            throw QueryError("start_at and end_at must narrow the date range to a nonempty interval.")
        }
        return DateInterval(start: narrowedStart, end: narrowedEnd)
    }

    private static func timestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = .withInternetDateTime
        guard let date = formatter.date(from: value) else {
            throw QueryError("Use RFC 3339 timestamps with a time zone offset for start_at and end_at.")
        }
        return date
    }
}

struct QueryError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

struct UsageReport: Encodable {
    struct Totals: Encodable {
        let seconds: TimeInterval
        let visits: Int

        init(_ statistics: Statistics) {
            seconds = statistics.seconds
            visits = statistics.visits
        }

        init(_ usage: UsageTotals) {
            seconds = usage.seconds
            visits = usage.visits
        }
    }

    struct Group: Encodable {
        let name: String
        let category: String?
        let usage: Totals
    }

    struct Day: Encodable {
        let date: String
        let recorded: Bool
        let usage: Totals?
    }

    let startDate: String
    let endDateExclusive: String
    let timeZone: String
    let lastObservedAt: Date?
    let recordedDays: Int
    let total: Totals?
    let averageSecondsPerRecordedDay: Double?
    let categories: [Group]?
    let services: [Group]?
    let days: [Day]?

    static func read(_ query: UsageQuery, databaseURL: URL, now: Date = Date()) throws -> UsageReport {
        let dates = try ReportCalendar(timeZone: query.timeZone)
        let range = try dates.range(startDate: query.startDate, endDate: query.endDate)
        let (calendar, formatter) = (dates.calendar, dates.formatter)
        let snapshot = try RecordingDatabase.readSnapshot(at: databaseURL)
        let ledger = Ledger(visits: snapshot.visits)
        let catalog = snapshot.categories
        let grouping = query.groupBy ?? .category
        let end = max(range.start, min(range.end, now))
        let interval = DateInterval(start: range.start, end: end)
        var recordedDays = 0
        var days: [Day] = []
        var cursor = interval.start
        while cursor < interval.end {
            let next = min(interval.end, calendar.dateInterval(of: .day, for: cursor)!.end)
            let day = DateInterval(start: cursor, end: next)
            let recorded = snapshot.coverage.hasRecording(in: day, ledger: ledger)
            if recorded { recordedDays += 1 }
            if grouping == .day {
                let usage = recorded ? Totals(ledger.stats(in: day)) : nil
                days.append(Day(date: formatter.string(from: cursor), recorded: recorded, usage: usage))
            }
            cursor = next
        }

        let activity = DayActivity(ledger: ledger, interval: interval)
        let total = recordedDays > 0 ? Totals(activity.statistics) : nil
        return UsageReport(
            startDate: query.startDate, endDateExclusive: query.endDate, timeZone: calendar.timeZone.identifier,
            lastObservedAt: snapshot.lastObservedAt, recordedDays: recordedDays, total: total,
            averageSecondsPerRecordedDay: total.map { $0.seconds / Double(recordedDays) },
            categories: grouping == .category ? categoryUsage(activity, snapshot: snapshot) : nil,
            services: grouping == .service ? serviceUsage(activity, catalog: catalog, sources: snapshot.sources) : nil,
            days: grouping == .day ? days : nil
        )
    }

    private static func categoryUsage(_ activity: DayActivity, snapshot: RecordingSnapshot) -> [Group] {
        let catalog = snapshot.categories
        let members = catalog.members(sources: snapshot.sources, recordedIDs: Set(activity.sources.keys))
        return ranked(catalog.options.map { category in
            Group(name: category.name, category: nil,
                  usage: Totals(activity.statistics(for: members[category.id] ?? [])))
        })
    }

    private static func serviceUsage(_ activity: DayActivity, catalog: CategoryCatalog, sources: [Source]) -> [Group] {
        let totals = activity.sources.mapValues {
            UsageTotals(seconds: $0.statistics.seconds, visits: $0.statistics.visits)
        }
        let rows = ServiceDirectory.rows(groups: catalog.serviceGroups(from: sources), totals: totals, catalog: catalog)
        var groups = rows.map { Group(name: $0.group.name, category: $0.category.name, usage: Totals($0.usage)) }
        let unidentified = Set(activity.sources.keys).subtracting(sources.map(\.id))
        if !unidentified.isEmpty {
            groups.append(Group(name: "Unidentified services", category: catalog.fallbackCategory.name,
                                usage: Totals(activity.statistics(for: unidentified))))
        }
        return ranked(groups)
    }

    private static func ranked(_ groups: [Group]) -> [Group] {
        groups.filter { $0.usage.seconds > 0 || $0.usage.visits > 0 }.sorted {
            if $0.usage.seconds != $1.usage.seconds { return $0.usage.seconds > $1.usage.seconds }
            if $0.usage.visits != $1.usage.visits { return $0.usage.visits > $1.usage.visits }
            return $0.name < $1.name
        }
    }
}

extension RecordingSnapshot {
    var lastObservedAt: Date? {
        [coverage.intervals.lazy.map(\.end).max(), visits.lazy.map(\.end).max()].compactMap { $0 }.max()
    }
}
