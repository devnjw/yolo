import Foundation

/// Recorded lifetime usage, including the currently observed visit. This is an
/// in-memory index; the original visits remain the persisted source of truth.
public struct UsageTotals: Equatable, Sendable {
    public internal(set) var seconds: TimeInterval
    public internal(set) var visits: Int

    public init(seconds: TimeInterval = 0, visits: Int = 0) {
        self.seconds = seconds
        self.visits = visits
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(seconds: lhs.seconds + rhs.seconds, visits: lhs.visits + rhs.visits)
    }
}
