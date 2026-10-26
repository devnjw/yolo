import XCTest
@testable import TrackingCore

final class DayActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var day: DateInterval { DateInterval(start: start, duration: 86400) }

    func testFilteredReportUsesSameScopeForTotalsRankingsSharesAndTimeline() {
        let ledger = Ledger(visits: [
            Visit(service: .kakao, start: start, end: start.addingTimeInterval(20)),
            Visit(service: .youtube, start: start.addingTimeInterval(30), end: start.addingTimeInterval(90)),
            Visit(service: .linkedin, start: start.addingTimeInterval(100), end: start.addingTimeInterval(400))
        ])
        let report = DayActivity(ledger: ledger, interval: day, includedServices: [.kakao, .youtube])
        XCTAssertEqual(report.statistics.seconds, 80)
        XCTAssertEqual(report.statistics.visits, 2)
        XCTAssertEqual(report.statistics.shortVisits, 1)
        XCTAssertEqual(report.mostTime, .youtube)
        XCTAssertNil(report.sources[.linkedin])
        XCTAssertEqual(report.sources[.youtube]?.timeShare, 0.75)
        XCTAssertEqual(report.hourlyTotals().reduce(0, +), 80)
        XCTAssertEqual(DayActivity(ledger: ledger, interval: day).statistics.seconds, 380)
    }

    func testEmptySelectionMeansNoActivityAndActiveFilteredVisitIsNotQuickCheck() {
        var ledger = Ledger()
        ledger.observe(.youtube, at: start)
        ledger.observe(.youtube, at: start.addingTimeInterval(1))
        let empty = DayActivity(ledger: ledger, interval: day, includedServices: [])
        XCTAssertEqual(empty.statistics, .zero)
        XCTAssertTrue(empty.sources.isEmpty)
        XCTAssertNil(empty.mostTime)
        XCTAssertNil(empty.mostVisits)
        XCTAssertEqual(empty.hourlyTotals().reduce(0, +), 0)
        let selected = DayActivity(ledger: ledger, interval: day, includedServices: [.youtube])
        XCTAssertEqual(selected.statistics.visits, 1)
        XCTAssertEqual(selected.statistics.shortVisits, 0)
        XCTAssertEqual(selected.statistics.seconds, 1)
        XCTAssertEqual(ledger.visits.count, 1)
    }

    func testSeparatesMostTimeFromMostVisitsAndComputesShare() {
        let ledger = Ledger(visits: [
            Visit(service: .instagram, start: start, end: start.addingTimeInterval(120)),
            Visit(service: .kakao, start: start.addingTimeInterval(130), end: start.addingTimeInterval(140)),
            Visit(service: .kakao, start: start.addingTimeInterval(150), end: start.addingTimeInterval(180))
        ])
        let report = DayActivity(ledger: ledger, interval: day)
        XCTAssertEqual(report.mostTime, .instagram)
        XCTAssertEqual(report.mostVisits, .kakao)
        XCTAssertEqual(report.sources[.instagram]?.timeShare, 0.75)
        XCTAssertEqual(report.sources[.kakao]?.statistics.shortVisits, 2)
        XCTAssertEqual(report.sources[.kakao]?.longestSeconds, 30)
        XCTAssertEqual(report.sources[.kakao]?.visits.first?.start, start.addingTimeInterval(150))
    }

    func testMidnightCarryoverClipsLongestAndDoesNotCountAnotherEntry() {
        let ledger = Ledger(visits: [
            Visit(service: .youtube, start: start.addingTimeInterval(-60), end: start.addingTimeInterval(20)),
            Visit(service: .kakao, start: start.addingTimeInterval(-20), end: start),
            Visit(service: .linkedin, start: day.end, end: day.end.addingTimeInterval(10))
        ])
        let report = DayActivity(ledger: ledger, interval: day)
        XCTAssertEqual(report.sources.count, 1)
        XCTAssertEqual(report.sources[.youtube]?.longestSeconds, 20)
        XCTAssertEqual(report.sources[.youtube]?.statistics.visits, 0)
        XCTAssertEqual(report.sources[.youtube]?.statistics.shortVisits, 0)
        XCTAssertNil(report.mostVisits)
    }

    func testActiveVisitIsVisibleButNotYetAQuickCheck() {
        var ledger = Ledger()
        ledger.observe(.youtube, at: start)
        let report = DayActivity(ledger: ledger, interval: day)
        XCTAssertEqual(report.sources[.youtube]?.visits.count, 1)
        XCTAssertEqual(report.statistics.visits, 1)
        XCTAssertEqual(report.statistics.shortVisits, 0)
        XCTAssertEqual(report.sources[.youtube]?.timeShare, 0)
        XCTAssertNil(report.mostTime)
        XCTAssertEqual(report.mostVisits, .youtube)
    }

    func testQuickCheckUsesFullVisitDurationRatherThanClippedDuration() {
        let visit = Visit(service: .youtube, start: day.end.addingTimeInterval(-10), end: day.end.addingTimeInterval(50))
        let report = DayActivity(ledger: Ledger(visits: [visit]), interval: day)
        XCTAssertEqual(report.statistics.shortVisits, 0)
        XCTAssertEqual(report.sources[.youtube]?.longestSeconds, 10)
    }

    func testEmptyDayDoesNotProduceRankingsOrInvalidShares() {
        let report = DayActivity(ledger: Ledger(), interval: day)
        XCTAssertTrue(report.sources.isEmpty)
        XCTAssertNil(report.mostTime)
        XCTAssertNil(report.mostVisits)
        XCTAssertEqual(report.statistics.seconds, 0)
    }

    func testDailySnapshotMatchesLedgerStatisticsIncludingZeroLengthVisits() {
        let ledger = Ledger(visits: [
            Visit(service: .kakao, start: start.addingTimeInterval(-10), end: start.addingTimeInterval(20)),
            Visit(service: .youtube, start: start, end: start),
            Visit(service: .youtube, start: day.end.addingTimeInterval(-5), end: day.end.addingTimeInterval(10)),
            Visit(service: .instagram, start: day.end, end: day.end.addingTimeInterval(15))
        ])
        let report = DayActivity(ledger: ledger, interval: day)
        XCTAssertEqual(report.statistics, ledger.stats(in: day))
        for service in [Service.kakao, .youtube, .instagram, .linkedin] {
            XCTAssertEqual(report.statistics(for: service), ledger.stats(for: service, in: day))
        }
        XCTAssertEqual(report.statistics(for: .linkedin), .zero)
    }

    func testHourlyTotalsClipToDayAndSplitAtHourBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = Date(timeIntervalSince1970: 0)
        let interval = DateInterval(start: midnight, duration: 86400)
        let ledger = Ledger(visits: [
            Visit(service: .kakao, start: midnight.addingTimeInterval(-10), end: midnight.addingTimeInterval(10)),
            Visit(service: .youtube, start: midnight.addingTimeInterval(3590), end: midnight.addingTimeInterval(3620)),
            Visit(service: .kakao, start: interval.end.addingTimeInterval(-5), end: interval.end.addingTimeInterval(10))
        ])
        let report = DayActivity(ledger: ledger, interval: interval)
        let hours = report.hourlyTotals(calendar: calendar)
        XCTAssertEqual(hours[0], 20)
        XCTAssertEqual(hours[1], 20)
        XCTAssertEqual(hours[23], 5)
        XCTAssertEqual(hours.reduce(0, +), report.statistics.seconds)
    }

    func testHourlyTotalsPreserveSpringAndFallDaylightSavingDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (month, day, expectedHours, repeatedHour) in [(3, 8, 23, false), (11, 1, 25, true)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: date))
            let ledger = Ledger(visits: [Visit(service: .youtube, start: interval.start, end: interval.end)])
            let hours = DayActivity(ledger: ledger, interval: interval).hourlyTotals(calendar: calendar)
            XCTAssertEqual(hours.count, 24)
            XCTAssertEqual(hours.reduce(0, +), Double(expectedHours * 3600))
            XCTAssertEqual(hours[repeatedHour ? 1 : 2], repeatedHour ? 7200 : 0)
        }
    }
}
