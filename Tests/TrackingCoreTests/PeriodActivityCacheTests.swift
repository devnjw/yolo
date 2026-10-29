import XCTest
@testable import TrackingCore

final class PeriodActivityCacheTests: XCTestCase {
    func testCacheInvalidatesForVisitCoverageFilterDateAndCalendarChanges() {
        let cache = PeriodActivityCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_700_006_400)
        var ledger = Ledger()
        var coverage = RecordingCoverage()
        func report(_ services: Set<Service> = [.youtube], date: Date? = nil) -> PeriodActivity {
            cache.report(ledger: ledger, coverage: coverage, period: .day, date: date ?? base,
                         now: base.addingTimeInterval(100), includedServices: services, calendar: calendar)
        }
        XCTAssertNil(report().seconds)
        coverage.observe(at: base)
        XCTAssertEqual(report().seconds, 0)
        ledger.observe(.youtube, at: base)
        ledger.observe(.youtube, at: base.addingTimeInterval(2))
        XCTAssertEqual(report().seconds, 2)
        XCTAssertEqual(report().seconds, 2)
        XCTAssertEqual(report([.kakao]).seconds, 0)
        XCTAssertNil(report(date: base.addingTimeInterval(-86400)).seconds)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        XCTAssertEqual(report().seconds, 2)
        // A different ledger can have the same revision and count.
        ledger = Ledger(visits: [Visit(service: .youtube, start: base, end: base.addingTimeInterval(20))])
        XCTAssertEqual(report().seconds, 20)
    }

    func testCachedReportRetainsActiveVisitAndInvalidatesAtMidnight() {
        let cache = PeriodActivityCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_006_400))
        var ledger = Ledger()
        ledger.observe(.youtube, at: day.addingTimeInterval(86390))
        ledger.observe(.youtube, at: day.addingTimeInterval(86392))
        let before = cache.report(ledger: ledger, coverage: RecordingCoverage(), period: .day, date: day,
                                  now: day.addingTimeInterval(86399), includedServices: [.youtube], calendar: calendar)
        XCTAssertEqual(before.activity.statistics.shortVisits, 0)
        let after = cache.report(ledger: ledger, coverage: RecordingCoverage(), period: .week, date: day,
                                 now: day.addingTimeInterval(86400), includedServices: [.youtube], calendar: calendar)
        XCTAssertEqual(after.seconds, 2)
        ledger.stop(at: day.addingTimeInterval(86393))
        let stopped = cache.report(ledger: ledger, coverage: RecordingCoverage(), period: .day, date: day,
                                   now: day.addingTimeInterval(86400), includedServices: [.youtube], calendar: calendar)
        XCTAssertEqual(stopped.activity.statistics.shortVisits, 1)
        XCTAssertEqual(before.activity.statistics.seconds, 2)
    }
}
