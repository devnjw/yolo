import Foundation

/// One bounded report snapshot, reused across SwiftUI invalidations that do not
/// change the measurements. Call on the UI actor; never retains the whole ledger.
public final class PeriodActivityCache {
    private struct Key: Equatable {
        let identity: UUID
        let revision: UInt64
        let coverageCount: Int
        let coverageTail: DateInterval?
        let period: ActivityPeriod
        let interval: DateInterval
        let second: Double
        let services: Set<Service>
        let calendar: Calendar
    }
    private var key: Key?
    private var report: PeriodActivity?
    public init() {}

    public func report(ledger: Ledger, coverage: RecordingCoverage, period: ActivityPeriod,
                       date: Date, now: Date = Date(), includedServices: Set<Service>,
                       calendar: Calendar = .current) -> PeriodActivity {
        let next = Key(identity: ledger.identity, revision: ledger.revision,
                       coverageCount: coverage.intervals.count, coverageTail: coverage.intervals.last,
                       period: period, interval: period.interval(containing: date, calendar: calendar),
                       second: floor(now.timeIntervalSinceReferenceDate), services: includedServices, calendar: calendar)
        if key == next, let report { return report }
        let result = PeriodActivity(ledger: ledger, coverage: coverage, period: period, date: date,
                                    now: now, includedServices: includedServices, calendar: calendar)
        key = next; report = result
        return result
    }
}
