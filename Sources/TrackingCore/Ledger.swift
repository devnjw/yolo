import Foundation

/// Immutable history is shared between UI snapshots. Only the bounded recent
/// block is copied when a sample extends a visit; never the entire history.
public struct Ledger {
    private static let blockSize = 256
    private var blocks: [VisitBlock]
    private var recent: [Visit] = []
    public private(set) var visitCount: Int
    public private(set) var activeID: UUID?
    public private(set) var lifetimeTotals: [Service: UsageTotals]
    private var lastSample: Date?
    public let identity = UUID()
    public private(set) var revision: UInt64 = 0

    /// Materialize history only for explicit full-history operations (CSV/export).
    public var visits: [Visit] { blocks.flatMap(\.visits) + recent }
    public var recordedIDs: Set<Service> { Set(lifetimeTotals.keys) }

    public init(visits: [Visit] = []) {
        blocks = stride(from: 0, to: visits.count, by: Self.blockSize).map {
            VisitBlock(Array(visits[$0..<min($0 + Self.blockSize, visits.count)]))
        }
        visitCount = visits.count
        lifetimeTotals = [:]
        for visit in visits {
            lifetimeTotals[visit.service, default: UsageTotals()].seconds += visit.duration
            lifetimeTotals[visit.service, default: UsageTotals()].visits += 1
        }
    }

    public mutating func observe(_ service: Service?, at now: Date) {
        let previousID = activeID
        let previousEnd = recent.last?.end
        let previousCount = visitCount
        defer {
            if activeID != previousID || recent.last?.end != previousEnd || visitCount != previousCount {
                revision &+= 1
            }
        }
        let gap = lastSample.map { now.timeIntervalSince($0) }
        if let gap, gap < 0 || gap > 4 { activeID = nil }
        if let id = activeID, let index = recent.indices.last, recent[index].id == id {
            let previousDuration = recent[index].duration
            recent[index].end = now
            lifetimeTotals[recent[index].service, default: UsageTotals()].seconds += recent[index].duration - previousDuration
            if recent[index].service != service { activeID = nil }
        }
        if activeID == nil, let service {
            if recent.count >= Self.blockSize {
                blocks.append(VisitBlock(recent))
                recent = []
            }
            let visit = Visit(service: service, start: now, end: now)
            recent.append(visit); activeID = visit.id; visitCount += 1
            lifetimeTotals[service, default: UsageTotals()].visits += 1
        }
        lastSample = now
    }

    public mutating func stop(at now: Date) { observe(nil, at: now) }

    /// Includes boundary candidates; consumers retain their exact clipping rules.
    public func visits(in interval: DateInterval) -> [Visit] {
        blocks.flatMap { $0.candidates(in: interval) } + recent.filter {
            $0.start < interval.end && max($0.start, $0.end) >= interval.start
        }
    }

    /// Only the previously saved tail can change; all earlier visits are immutable.
    public func recordsToSave(after count: Int) -> [(ordinal: Int, visit: Visit)] {
        let first = max(0, count - 1)
        var result: [(Int, Visit)] = []
        var offset = 0
        for block in blocks {
            if offset + block.visits.count > first {
                for i in max(0, first - offset)..<block.visits.count {
                    result.append((offset + i, block.visits[i]))
                }
            }
            offset += block.visits.count
        }
        for i in max(0, min(recent.count, first - offset))..<recent.count {
            result.append((offset + i, recent[i]))
        }
        return result
    }

    public func stats(for service: Service? = nil, in interval: DateInterval) -> Statistics {
        Statistics(visits: visits(in: interval).lazy.filter { service == nil || $0.service == service },
                   activeID: activeID, in: interval)
    }
}

/// Per-block interval index also handles out-of-order imports, clock changes,
/// overlapping visits, and visits spanning multiple days.
private final class VisitBlock {
    let visits: [Visit]
    private let order: [Int]
    private let prefixEnds: [Date]

    init(_ visits: [Visit]) {
        self.visits = visits
        order = visits.indices.sorted { visits[$0].start < visits[$1].start }
        var end = Date.distantPast
        prefixEnds = order.map { index in
            let visit = visits[index]
            end = max(end, max(visit.start, visit.end))
            return end
        }
    }

    func candidates(in interval: DateInterval) -> [Visit] {
        guard let first = order.first, visits[first].start < interval.end,
              let lastEnd = prefixEnds.last, lastEnd >= interval.start else { return [] }
        var low = 0, high = order.count
        while low < high {
            let mid = (low + high) / 2
            if prefixEnds[mid] < interval.start { low = mid + 1 } else { high = mid }
        }
        var result: [Visit] = []
        while low < order.count && visits[order[low]].start < interval.end {
            let visit = visits[order[low]]
            if max(visit.start, visit.end) >= interval.start { result.append(visit) }
            low += 1
        }
        return result
    }
}
