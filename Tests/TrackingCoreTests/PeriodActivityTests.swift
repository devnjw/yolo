import XCTest
@testable import TrackingCore

final class PeriodActivityTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }
    private func date(_ day: Int, month: Int = 10, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func visit(_ day: Int, service: Service = .youtube, seconds: Double = 60, month: Int = 10) -> Visit {
        Visit(service: service, start: date(day, month: month, hour: 12), end: date(day, month: month, hour: 12).addingTimeInterval(seconds))
    }
    private func report(_ visits: [Visit], period: ActivityPeriod = .week, coverage: RecordingCoverage = RecordingCoverage()) -> PeriodActivity {
        PeriodActivity(ledger: Ledger(visits: visits), coverage: coverage, period: period,
                       date: date(25), now: date(25, hour: 18), includedServices: [.youtube], calendar: calendar)
    }

    func testAverageExcludesTodayAndMissingDaysButIncludesRecordedZeroDays() {
        let result = report([visit(19, seconds: 120), visit(20, service: .kakao), visit(25, seconds: 600)])
        XCTAssertEqual(result.recordedDays, 2)
        XCTAssertEqual(result.seconds, 60)
        XCTAssertEqual(result.visits, 0.5)
        XCTAssertEqual(result.activity.statistics(for: .youtube).seconds / result.divisor, 60)
        XCTAssertEqual(result.bins[1].seconds, 0)
        XCTAssertNil(result.bins[2].seconds)
        XCTAssertEqual(result.bins[6].seconds, 600, "Today remains visible as a partial day in the chart")
        XCTAssertEqual(result.activity.interval.end, date(25))
    }

    func testCoverageIncludesIdleDayWithoutInventingMissingDays() {
        var coverage = RecordingCoverage()
        coverage.observe(at: date(20, hour: 12))
        let result = report([visit(19, seconds: 120)], coverage: coverage)
        XCTAssertEqual(result.recordedDays, 2)
        XCTAssertEqual(result.seconds, 60)
        XCTAssertEqual(result.bins[1].seconds, 0)
        XCTAssertNil(result.bins[2].seconds)
    }

    func testOnlyTodayHasNoCompletedDayAverageButDayShowsTotals() {
        let visits = [visit(25, seconds: 120)]
        XCTAssertNil(report(visits).seconds)
        XCTAssertNil(report(visits).visits)
        let day = report(visits, period: .day)
        XCTAssertEqual(day.seconds, 120)
        XCTAssertEqual(day.visits, 1)
        XCTAssertEqual(day.bins.compactMap(\.seconds).reduce(0, +), 120)
        XCTAssertTrue(day.bins[19].isFuture)
    }

    func testYearAverageIsWeightedByDaysNotByMonthsAndUsesSameSourceDenominator() {
        let result = report([visit(1, seconds: 600, month: 1), visit(19, seconds: 120), visit(20, seconds: 120)], period: .year)
        XCTAssertEqual(result.recordedDays, 3)
        XCTAssertEqual(result.seconds, 280)
        XCTAssertEqual(result.visits, 1)
        XCTAssertEqual(result.bins[0].seconds, 600)
        XCTAssertEqual(result.bins[9].seconds, 120)
        XCTAssertEqual(result.bins[9].denominator, 2)
        XCTAssertNil(result.bins[1].seconds)
        XCTAssertTrue(result.bins[11].isFuture)
    }

    func testMidnightVisitTimeIsSplitButEntryCountIsNotDuplicated() {
        let entry = Visit(service: .youtube, start: date(19).addingTimeInterval(-30), end: date(19).addingTimeInterval(30))
        let result = report([entry])
        XCTAssertEqual(result.seconds, 30)
        XCTAssertEqual(result.visits, 0)
        XCTAssertEqual(result.recordedDays, 1)
    }

    func testHourSelectionClipsTimeAndCountsOnlyEntriesInThatHour() {
        let entry = Visit(service: .youtube, start: date(25, hour: 11).addingTimeInterval(3590), end: date(25, hour: 12).addingTimeInterval(20))
        let ledger = Ledger(visits: [entry])
        let result = report([entry], period: .day)
        let interval = result.selectionInterval(for: result.bins[12], now: date(25, hour: 18), calendar: calendar)
        let selected = DayActivity(ledger: ledger, interval: interval, includedServices: [.youtube])
        XCTAssertEqual(selected.statistics.seconds, 20)
        XCTAssertEqual(selected.statistics.visits, 0)
        XCTAssertEqual(result.seconds, 30)
        XCTAssertEqual(result.visits, 1)
    }

    func testDaylightSavingHas23Or25HourBinsWithoutLosingDuration() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = local.date(from: DateComponents(year: 2026, month: month, day: day))!
            let interval = local.dateInterval(of: .day, for: start)!
            let visit = Visit(service: .youtube, start: start, end: interval.end)
            let result = PeriodActivity(ledger: Ledger(visits: [visit]), period: .day, date: start,
                                        now: interval.end, includedServices: [.youtube], calendar: local)
            XCTAssertEqual(result.bins.count, hours)
            XCTAssertEqual(result.bins.compactMap(\.seconds).reduce(0, +), Double(hours * 3600))
        }
    }

    func testCoverageDoesNotFillSleepGapAndRoundTrips() throws {
        var coverage = RecordingCoverage()
        coverage.observe(at: date(19))
        coverage.observe(at: date(19).addingTimeInterval(1))
        coverage.observe(at: date(21))
        XCTAssertEqual(coverage.intervals.count, 2)
        XCTAssertEqual(coverage.intervals[0].duration, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrackingStore(directory: directory)
        XCTAssertEqual(try store.loadCoverage(), RecordingCoverage())
        try store.saveCoverage(coverage)
        XCTAssertEqual(try store.loadCoverage(), coverage)
    }
}
