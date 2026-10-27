import Foundation

public struct Statistics: Equatable {
    public let seconds: TimeInterval
    public let visits: Int
    public let shortVisits: Int

    public static let zero = Statistics(seconds: 0, visits: 0, shortVisits: 0)

    public static func + (lhs: Statistics, rhs: Statistics) -> Statistics {
        Statistics(seconds: lhs.seconds + rhs.seconds, visits: lhs.visits + rhs.visits,
                   shortVisits: lhs.shortVisits + rhs.shortVisits)
    }

    private init(seconds: TimeInterval, visits: Int, shortVisits: Int) {
        self.seconds = seconds
        self.visits = visits
        self.shortVisits = shortVisits
    }

    init<S: Sequence>(visits: S, activeID: UUID?, in interval: DateInterval) where S.Element == Visit {
        var seconds: TimeInterval = 0
        var entries = 0
        var quickChecks = 0
        for visit in visits {
            seconds += visit.seconds(in: interval)
            if visit.start >= interval.start && visit.start < interval.end {
                entries += 1
                if visit.id != activeID && visit.duration <= 30 { quickChecks += 1 }
            }
        }
        self.init(seconds: seconds, visits: entries, shortVisits: quickChecks)
    }
}
