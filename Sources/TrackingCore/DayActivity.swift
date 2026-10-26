import Foundation

/// A calendar day's display model. Time is clipped to the day; entries and
/// quick checks belong to the day on which a visit started.
public struct DayActivity {
    public struct SourceActivity {
        public let service: Service
        public let visits: [Visit]
        public let statistics: Statistics
        public let longestSeconds: TimeInterval
        public let timeShare: Double
    }

    public let interval: DateInterval
    public let statistics: Statistics
    public let sources: [Service: SourceActivity]
    public let mostTime: Service?
    public let mostVisits: Service?

    public init(ledger: Ledger, interval: DateInterval, includedServices: Set<Service>? = nil) {
        self.interval = interval
        let visits = ledger.visits.filter {
            (includedServices?.contains($0.service) ?? true) &&
                (($0.start >= interval.start && $0.start < interval.end) || $0.seconds(in: interval) > 0)
        }
        statistics = Statistics(visits: visits, activeID: ledger.activeID, in: interval)
        let grouped = Dictionary(grouping: visits, by: \.service)
        let total = statistics.seconds
        sources = grouped.mapValues { entries in
            let service = entries[0].service
            let stats = Statistics(visits: entries, activeID: ledger.activeID, in: interval)
            return SourceActivity(
                service: service,
                visits: entries.sorted { $0.start > $1.start },
                statistics: stats,
                longestSeconds: entries.map { $0.seconds(in: interval) }.max() ?? 0,
                timeShare: total > 0 ? stats.seconds / total : 0
            )
        }
        let stableOrder = sources.values.sorted { $0.service.rawValue < $1.service.rawValue }
        mostTime = stableOrder.filter { $0.statistics.seconds > 0 }
            .max { $0.statistics.seconds < $1.statistics.seconds }?.service
        mostVisits = stableOrder.filter { $0.statistics.visits > 0 }
            .max { $0.statistics.visits < $1.statistics.visits }?.service
    }

    public func statistics(for service: Service) -> Statistics {
        sources[service]?.statistics ?? .zero
    }

    /// Calendar hour boundaries preserve 23/25-hour days; repeated hours share a bar.
    public func hourlyTotals(calendar: Calendar = .current) -> [TimeInterval] {
        var totals = Array(repeating: 0.0, count: 24)
        for visit in sources.values.flatMap(\.visits) {
            var cursor = max(visit.start, interval.start)
            let end = min(visit.end, interval.end)
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                let next = min(hour.end, end)
                totals[calendar.component(.hour, from: cursor)] += next.timeIntervalSince(cursor)
                cursor = next
            }
        }
        return totals
    }
}
