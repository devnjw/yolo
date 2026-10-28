import Foundation

public enum ActivityPeriod: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"
    public var id: String { rawValue }
    public var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: component, for: date)!
    }
}

/// Evidence that the recorder was running, including idle time without visits.
/// Gaps caused by sleep, shutdown, or stalled sampling are never filled in.
public struct RecordingCoverage: Codable, Equatable {
    public private(set) var intervals: [DateInterval] = []
    public init() {}

    public mutating func observe(at date: Date) {
        if let last = intervals.last, date >= last.end, date.timeIntervalSince(last.end) <= 4 {
            intervals[intervals.count - 1] = DateInterval(start: last.start, end: date)
        } else {
            intervals.append(DateInterval(start: date, duration: 0))
        }
    }
}

/// A single period, with a shared denominator for time, visits and source rows.
/// A recorded day means evidence of recording, not guaranteed full-day coverage.
public struct PeriodActivity {
    public struct Bin: Identifiable {
        public let id: Int
        public let interval: DateInterval
        public let seconds: Double?
        public let denominator: Int
        public let isFuture: Bool
        /// Uses the same clipping and denominator as the total above.
        public let sourceSeconds: [Service: Double]

        /// Narrow an existing snapshot without changing recording evidence or its average denominator.
        public func filtered(to services: Set<Service>) -> Bin {
            let filteredSeconds = sourceSeconds.filter { services.contains($0.key) }
            return Bin(id: id, interval: interval,
                       seconds: seconds.map { _ in filteredSeconds.values.reduce(0, +) },
                       denominator: denominator, isFuture: isFuture, sourceSeconds: filteredSeconds)
        }

        public struct CategorySegment: Identifiable {
            public let category: ActivityCategory
            public let startSeconds: Double
            public let endSeconds: Double
            public var id: String { category.id }
            public var seconds: Double { endSeconds - startSeconds }
        }

        public func categorySegments(_ categories: [ActivityCategory], members: [String: Set<Service>]) -> [CategorySegment] {
            guard seconds != nil, !isFuture else { return [] }
            var offset = 0.0
            return categories.compactMap { category in
                let duration = (members[category.id] ?? []).reduce(0.0) { $0 + (sourceSeconds[$1] ?? 0) }
                guard duration > 0 else { return nil }
                let start = offset
                offset += duration
                return CategorySegment(category: category, startSeconds: start, endSeconds: offset)
            }
        }
    }

    public let period: ActivityPeriod
    public let interval: DateInterval
    public let activity: DayActivity
    public let recordedDays: Int
    public let bins: [Bin]
    public let hasData: Bool
    public var divisor: Double { Double(period == .day ? 1 : max(1, recordedDays)) }
    public var seconds: Double? { hasData ? activity.statistics.seconds / divisor : nil }
    public var visits: Double? { hasData ? Double(activity.statistics.visits) / divisor : nil }

    public init(ledger: Ledger, coverage: RecordingCoverage = RecordingCoverage(),
                period: ActivityPeriod, date: Date, now: Date = Date(),
                includedServices: Set<Service>, calendar: Calendar = .current) {
        self.period = period
        let range = period.interval(containing: date, calendar: calendar)
        interval = range
        let today = calendar.startOfDay(for: now)
        let observedVisits = ledger.visits.filter { $0.start < range.end && $0.end >= range.start }
        let observedCoverage = coverage.intervals.filter { $0.start < range.end && $0.end >= range.start }
        func known(_ day: DateInterval) -> Bool {
            observedVisits.contains { ($0.start >= day.start && $0.start < day.end) || $0.seconds(in: day) > 0 } ||
            observedCoverage.contains { ($0.start >= day.start && $0.start < day.end) || ($0.start < day.end && $0.end > day.start) }
        }
        func knownDays(in interval: DateInterval) -> Int {
            var cursor = interval.start, count = 0
            while cursor < interval.end && cursor < today {
                let day = calendar.dateInterval(of: .day, for: cursor)!
                if known(day) { count += 1 }
                cursor = day.end
            }
            return count
        }
        let days = knownDays(in: range)
        recordedDays = days
        hasData = period == .day ? range.start <= now && known(range) : days > 0
        let effectiveEnd = period == .day ? min(range.end, now) : min(range.end, today)
        let effective = DateInterval(start: range.start, end: max(range.start, effectiveEnd))
        activity = DayActivity(ledger: ledger, interval: effective, includedServices: includedServices)
        var result: [Bin] = []
        var cursor = range.start
        let component: Calendar.Component = period == .day ? .hour : period == .year ? .month : .day
        while cursor < range.end {
            let segment = calendar.dateInterval(of: component, for: cursor)!
            let end = min(segment.end, range.end)
            let binRange = DateInterval(start: cursor, end: end)
            let future = cursor > now
            let denominator = period == .year ? knownDays(in: binRange) : 1
            let available = !future && (period == .year ? denominator > 0 : known(period == .day ? range : binRange))
            let clippedEnd = period == .year ? min(end, today) : min(end, now)
            let clipped = DateInterval(start: cursor, end: max(cursor, clippedEnd))
            let binActivity = DayActivity(ledger: ledger, interval: clipped, includedServices: includedServices)
            let divisor = Double(max(1, denominator))
            result.append(Bin(id: result.count, interval: binRange,
                              seconds: available ? binActivity.statistics.seconds / divisor : nil,
                              denominator: denominator, isFuture: future,
                              sourceSeconds: available ? binActivity.sources.mapValues { $0.statistics.seconds / divisor } : [:]))
            cursor = end
        }
        bins = result
    }

    /// Selection changes the list/detail scope; the period's headline stays fixed.
    public func selectionInterval(for bin: Bin, now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let limit = period == .year ? calendar.startOfDay(for: now) : now
        return DateInterval(start: bin.interval.start, end: max(bin.interval.start, min(bin.interval.end, limit)))
    }
}
