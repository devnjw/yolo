import XCTest
@testable import TrackingCore

final class UsageTotalsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func assertIndexMatchesVisits(_ ledger: Ledger, file: StaticString = #filePath, line: UInt = #line) {
        let grouped = Dictionary(grouping: ledger.visits, by: \.service)
        XCTAssertEqual(Set(ledger.lifetimeTotals.keys), Set(grouped.keys), file: file, line: line)
        for (id, visits) in grouped {
            XCTAssertEqual(ledger.lifetimeTotals[id]?.visits, visits.count, file: file, line: line)
            XCTAssertEqual(ledger.lifetimeTotals[id]?.seconds ?? -1, visits.reduce(0) { $0 + $1.duration },
                           accuracy: 0.000001, file: file, line: line)
        }
    }

    func testInitialIndexIncludesWholeHistoryAndZeroDurationVisits() {
        let visits = [
            Visit(service: .kakao, start: start.addingTimeInterval(-100_000), end: start),
            Visit(service: .youtube, start: start, end: start.addingTimeInterval(2)),
            Visit(service: .kakao, start: start, end: start),
            Visit(service: .linkedin, start: start, end: start.addingTimeInterval(-1))
        ]
        let ledger = Ledger(visits: visits)
        assertIndexMatchesVisits(ledger)
        XCTAssertEqual(ledger.lifetimeTotals[.kakao], UsageTotals(seconds: 100_000, visits: 2))
        XCTAssertEqual(ledger.lifetimeTotals[.linkedin], UsageTotals(seconds: 0, visits: 1))
        XCTAssertEqual(ledger.visits, visits)
        XCTAssertNil(ledger.activeID)
    }

    func testIncrementalIndexMatchesAfterEveryObservationAndStop() {
        var ledger = Ledger()
        assertIndexMatchesVisits(ledger)
        let observations: [(Service?, Double)] = [
            (.kakao, 0), (.kakao, 0.75), (.kakao, 1.5), (.youtube, 2),
            (.youtube, 3), (nil, 4), (.kakao, 5), (.kakao, 3600),
            (.kakao, 3601), (.linkedin, 3599), (.linkedin, 3600), (nil, 3601),
            (nil, 3601), (.youtube, 3601), (.youtube, 3601)
        ]
        for (service, offset) in observations {
            ledger.observe(service, at: start.addingTimeInterval(offset))
            assertIndexMatchesVisits(ledger)
        }
        ledger.stop(at: start.addingTimeInterval(3602))
        assertIndexMatchesVisits(ledger)
        XCTAssertEqual(ledger.lifetimeTotals.values.reduce(0) { $0 + $1.visits }, ledger.visits.count)
        // The suspension and backwards clock jump do not fill unobserved time.
        XCTAssertLessThan(ledger.lifetimeTotals.values.reduce(0) { $0 + $1.seconds }, 20)
    }

    func testRestoringRebuildsIndexAndStartsNewVisit() throws {
        var ledger = Ledger()
        ledger.observe(.kakao, at: start)
        ledger.observe(.kakao, at: start.addingTimeInterval(1.25))
        let data = try JSONEncoder().encode(ledger.visits)
        var restored = Ledger(visits: try JSONDecoder().decode([Visit].self, from: data))
        XCTAssertEqual(restored.lifetimeTotals, ledger.lifetimeTotals)
        restored.observe(.kakao, at: start.addingTimeInterval(100))
        XCTAssertEqual(restored.lifetimeTotals[.kakao], UsageTotals(seconds: 1.25, visits: 2))
        assertIndexMatchesVisits(restored)
    }

    func testLongRunningObservationUpdatesDurationWithoutCreatingVisits() {
        var ledger = Ledger()
        for second in 0...10_000 {
            ledger.observe(.kakao, at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(ledger.lifetimeTotals[.kakao], UsageTotals(seconds: 10_000, visits: 1))
        assertIndexMatchesVisits(ledger)
    }
}
