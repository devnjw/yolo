import XCTest
@testable import TrackingCore

final class VisitCSVTests: XCTestCase {
    private func visit(_ service: Service) -> Visit {
        Visit(service: service, start: Date(timeIntervalSince1970: 0),
              end: Date(timeIntervalSince1970: 90.5))
    }

    func testEmptyExportIncludesHeader() {
        XCTAssertEqual(VisitCSV.export([], sources: []), "service,start_utc,end_utc,seconds\n")
    }

    func testEscapesCommasQuotesAndNewlinesWithUTCTimestamps() {
        let source = Source(name: "Example, \"work\"\nsite", kind: .website, identifier: "example.com")
        XCTAssertEqual(VisitCSV.export([visit(source.id)], sources: [source]),
            "service,start_utc,end_utc,seconds\n\"Example, \"\"work\"\"\nsite\",1970-01-01T00:00:00Z,1970-01-01T00:01:30Z,90")
    }

    func testFormulaPrefixesAreNeutralized() {
        for prefix in ["=", "+", "-", "@", "\t", "\r", "\n", "\r\n"] {
            let source = Source(name: prefix + "formula", kind: .app, identifier: "test.app")
            XCTAssertTrue(VisitCSV.export([visit(source.id)], sources: [source]).contains("\"'\(prefix)formula\""))
        }
    }

    func testArchivedAndUnknownSourcesKeepTheirRecords() {
        let archived = Source(name: "Archived", kind: .app, identifier: "test.app", archived: true)
        let unknown = Service(rawValue: "unknown-id")
        let csv = VisitCSV.export([visit(archived.id), visit(unknown)], sources: [archived])
        XCTAssertTrue(csv.contains("\"Archived\","))
        XCTAssertTrue(csv.contains("\"unknown-id\","))
        XCTAssertEqual(csv.split(separator: "\n").count, 3)
    }
}
