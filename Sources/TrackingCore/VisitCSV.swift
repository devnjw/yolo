import Foundation

public enum VisitCSV {
    public static func export(_ visits: [Visit], sources: [Source], categories: CategoryCatalog? = nil) -> String {
        let names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(sources.map { ($0.id, categories?.serviceID(for: $0) ?? ServiceGrouping.identity(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let format = ISO8601DateFormatter()
        let rows = visits.map { visit in
            let name = names[visit.service] ?? visit.service.rawValue
            let row = "\(quoted(name)),\(format.string(from: visit.start)),\(format.string(from: visit.end)),\(Int(visit.duration))"
            guard let categories else { return row }
            let category = categories.category(for: groups[visit.service] ?? "source:" + visit.service.rawValue)
            return row + "," + quoted(category.name)
        }
        return "service,start_utc,end_utc,seconds" + (categories == nil ? "\n" : ",category\n") + rows.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        // Source names are user supplied. Prevent spreadsheet formula execution.
        let text: String
        if let first = value.unicodeScalars.first, "=+-@\t\r\n".unicodeScalars.contains(first) { text = "'" + value }
        else { text = value }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
