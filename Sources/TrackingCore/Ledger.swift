import Foundation

/// Every observation accounts only for a short, observed interval. A delayed
/// sample (sleep, suspension, stalled permission prompt) never fills the gap.
public struct Ledger {
    public private(set) var visits: [Visit]
    public private(set) var activeID: UUID?
    public private(set) var lifetimeTotals: [Service: UsageTotals]
    private var lastSample: Date?
    public init(visits: [Visit] = []) {
        self.visits = visits
        lifetimeTotals = [:]
        for visit in visits {
            lifetimeTotals[visit.service, default: UsageTotals()].seconds += visit.duration
            lifetimeTotals[visit.service, default: UsageTotals()].visits += 1
        }
    }

    public mutating func observe(_ service: Service?, at now: Date) {
        let gap = lastSample.map { now.timeIntervalSince($0) }
        if let gap, gap < 0 || gap > 4 { activeID = nil }
        if let id = activeID, let index = visits.indices.last, visits[index].id == id {
            let previousDuration = visits[index].duration
            visits[index].end = now
            lifetimeTotals[visits[index].service, default: UsageTotals()].seconds += visits[index].duration - previousDuration
            if visits[index].service != service { activeID = nil }
        }
        if activeID == nil, let service {
            let visit = Visit(service: service, start: now, end: now)
            visits.append(visit); activeID = visit.id
            lifetimeTotals[service, default: UsageTotals()].visits += 1
        }
        lastSample = now
    }

    public mutating func stop(at now: Date) { observe(nil, at: now) }

    public func stats(for service: Service? = nil, in interval: DateInterval) -> Statistics {
        Statistics(visits: visits.lazy.filter { service == nil || $0.service == service },
                   activeID: activeID, in: interval)
    }
}
