import Foundation

public enum VisitCSV {
    public static func export(_ visits: [Visit], sources: [Source]) -> String {
        let names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let format = ISO8601DateFormatter()
        let rows = visits.map { visit in
            let name = names[visit.service] ?? visit.service.rawValue
            return "\(quoted(name)),\(format.string(from: visit.start)),\(format.string(from: visit.end)),\(Int(visit.duration))"
        }
        return "service,start_utc,end_utc,seconds\n" + rows.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        // Source names are user supplied. Prevent spreadsheet formula execution.
        let text: String
        if let first = value.unicodeScalars.first, "=+-@\t\r\n".unicodeScalars.contains(first) { text = "'" + value }
        else { text = value }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
