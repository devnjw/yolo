import XCTest
@testable import TrackingCore

final class PerformanceRegressionTests: XCTestCase {
    /// Opt-in, reproducible workload; elapsed time is evidence, not a flaky CI threshold.
    func testLargeHistoryReportBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOCUSTRACE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOCUSTRACE_BENCHMARK=1 for the large-history benchmark")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_700_006_400)
        let visits = (0..<200_000).map { i in
            Visit(service: i.isMultiple(of: 2) ? .youtube : .kakao,
                  start: base.addingTimeInterval(Double(i * 120)),
                  end: base.addingTimeInterval(Double(i * 120 + 60)))
        }
        let ledger = Ledger(visits: visits)
        let date = visits.last!.start
        let now = date.addingTimeInterval(86400)
        for period in [ActivityPeriod.day, .month, .year] {
            let start = ProcessInfo.processInfo.systemUptime
            var checksum = 0.0
            for _ in 0..<3 {
                let report = PeriodActivity(ledger: ledger, period: period, date: date, now: now,
                                            includedServices: [.youtube, .kakao], calendar: calendar)
                checksum += report.seconds ?? 0
            }
            print("BENCHMARK report=\(period.rawValue) visits=\(visits.count) iterations=3 seconds=\(ProcessInfo.processInfo.systemUptime - start) checksum=\(checksum)")
            XCTAssertGreaterThan(checksum, 0)
        }
    }

    func testLargeHistorySaveBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOCUSTRACE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOCUSTRACE_BENCHMARK=1 for the large-history benchmark")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try RecordingDatabase(directory: directory)
        let legacy = TrackingStore(directory: directory)
        var visits = (0..<200_000).map { i in
            Visit(service: .youtube, start: Date(timeIntervalSinceReferenceDate: Double(i * 120)),
                  end: Date(timeIntervalSinceReferenceDate: Double(i * 120 + 60)))
        }
        try database.save(visits: visits.enumerated().map { ($0.offset, $0.element) }, coverage: [])
        let originalTail = visits.last!
        let startJSON = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 {
            visits[visits.count - 1].end = visits.last!.end.addingTimeInterval(1)
            try legacy.saveVisits(visits)
        }
        let jsonSeconds = ProcessInfo.processInfo.systemUptime - startJSON
        var tail = originalTail
        let startSQLite = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 {
            tail.end = tail.end.addingTimeInterval(1)
            try database.save(visits: [(visits.count - 1, tail)], coverage: [])
        }
        let sqliteSeconds = ProcessInfo.processInfo.systemUptime - startSQLite
        print("BENCHMARK save visits=200000 iterations=3 JSON_seconds=\(jsonSeconds) SQLite_delta_seconds=\(sqliteSeconds)")
        XCTAssertEqual(try database.loadVisits(), visits)
    }

}
