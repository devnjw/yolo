import XCTest
@testable import TrackingCore

final class LedgerIndexTests: XCTestCase {
    func testIndexedQueriesMatchFullScanWithUnorderedOverlappingAndBoundaryVisits() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var visits: [Visit] = []
        for i in 0..<1100 {
            let offset = Double((i * 997) % 5000)
            let duration = Double(i % 100)
            let service: Service = i.isMultiple(of: 2) ? .youtube : .kakao
            visits.append(Visit(service: service, start: base.addingTimeInterval(offset),
                                end: base.addingTimeInterval(offset + duration)))
        }
        visits.append(Visit(service: .kakao, start: base.addingTimeInterval(-1000), end: base.addingTimeInterval(8000)))
        visits.append(Visit(service: .youtube, start: base.addingTimeInterval(200), end: base.addingTimeInterval(100)))
        let ledger = Ledger(visits: visits)
        for i in stride(from: -200, to: 5500, by: 113) {
            let interval = DateInterval(start: base.addingTimeInterval(Double(i)), duration: 200)
            let expected = Statistics(visits: visits, activeID: nil, in: interval)
            XCTAssertEqual(ledger.stats(in: interval), expected)
            XCTAssertEqual(DayActivity(ledger: ledger, interval: interval).statistics, expected)
        }
        XCTAssertEqual(ledger.visits, visits)
    }

    func testSnapshotsRemainImmutableAcrossBlockRolloverAndActiveUpdates() {
        var ledger = Ledger()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var snapshots: [(Ledger, [Visit])] = []
        for i in 0..<600 {
            ledger.observe(i.isMultiple(of: 2) ? .youtube : .kakao, at: base.addingTimeInterval(Double(i)))
            if i.isMultiple(of: 73) { snapshots.append((ledger, ledger.visits)) }
        }
        XCTAssertEqual(ledger.visitCount, 600)
        for (snapshot, visits) in snapshots { XCTAssertEqual(snapshot.visits, visits) }
        XCTAssertEqual(ledger.recordsToSave(after: 598).map(\.ordinal), [597, 598, 599])
        XCTAssertEqual(ledger.recordsToSave(after: 600).map(\.ordinal), [599])
        XCTAssertEqual(ledger.recordsToSave(after: 0).map(\.visit), ledger.visits)
    }

    func testImportedTailIsNotExtendedAndClockChangesRemainQueryable() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let original = Visit(service: .youtube, start: base, end: base.addingTimeInterval(1))
        var ledger = Ledger(visits: [original])
        ledger.observe(.kakao, at: base.addingTimeInterval(10))
        ledger.observe(.kakao, at: base.addingTimeInterval(11))
        ledger.observe(.youtube, at: base.addingTimeInterval(-10))
        XCTAssertEqual(ledger.visits.first, original)
        XCTAssertEqual(ledger.visitCount, 3)
        let range = DateInterval(start: base.addingTimeInterval(-20), duration: 40)
        XCTAssertEqual(ledger.stats(in: range), Statistics(visits: ledger.visits, activeID: ledger.activeID, in: range))
    }
}
