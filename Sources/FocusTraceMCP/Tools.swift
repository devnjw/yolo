import Foundation
import TrackingCore

struct RecordingContext {
    let databaseURL: URL
    let backups: RecordingBackups?
}

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let run: (Data, RecordingContext) throws -> Data

    init<Query: Decodable, Response: Encodable>(_ name: String, _ description: String,
                                                  properties: [String: Any], required: [String] = [],
                                                  fractionalTimestamps: Bool = true,
                                                  read: @escaping (Query, RecordingContext) throws -> Response) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
        run = { data, context in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            if fractionalTimestamps {
                let timestamps = ISO8601DateFormatter()
                timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                encoder.dateEncodingStrategy = .custom { date, encoder in
                    var value = encoder.singleValueContainer()
                    try value.encode(timestamps.string(from: date))
                }
            } else {
                encoder.dateEncodingStrategy = .iso8601
            }
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(read(decoder.decode(Query.self, from: data), context))
        }
    }

    var schema: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object", "properties": properties, "required": required, "additionalProperties": false
            ],
            "annotations": [
                "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false
            ]
        ]
    }
}

enum FocusTraceTools {
    private struct EmptyQuery: Decodable {}

    private static let dateRange = ["start_date", "end_date"]
    private static let timeZone = string("IANA time zone. Defaults to the Mac's time zone.")
    private static let serviceId = string("Service ID from list_services.")
    private static let categoryIds: [String: Any] = [
        "type": "array", "items": ["type": "string"], "description": "Category IDs from recording_info."
    ]
    private static let range: [String: Any] = [
        "start_date": ["type": "string", "format": "date", "description": "First local date, inclusive (YYYY-MM-DD)."],
        "end_date": ["type": "string", "format": "date", "description": "First excluded local date (YYYY-MM-DD)."],
        "time_zone": timeZone
    ]
    private static let preciseRange = range.merging([
        "start_at": ["type": "string", "format": "date-time", "description": "Optional inclusive RFC 3339 lower bound within the date range."],
        "end_at": ["type": "string", "format": "date-time", "description": "Optional exclusive RFC 3339 upper bound within the date range."]
    ]) { _, new in new }
    private static let offset: [String: Any] = [
        "type": "integer", "minimum": 0, "description": "Use next_offset from the previous page. Defaults to 0."
    ]

    static let all: [MCPTool] = [
        MCPTool("usage_summary", """
            Read saved FocusTrace usage for up to 366 calendar days. Returns tracked seconds and visits,
            recorded days, the last saved observation across all dates, and the requested breakdown.
            Days with no recording evidence have no usage values. The recorded-day average can include
            a partially recorded current day. Use the default category grouping for general summaries.
            """, properties: range.merging([
                "group_by": choices(["category", "service", "day"], "Defaults to category.")
            ]) { _, new in new }, required: dateRange, fractionalTimestamps: false) { (query: UsageQuery, context) in
                try UsageReport.read(query, databaseURL: context.databaseURL)
            },
        MCPTool("usage_overview", """
            Reproduce the FocusTrace Overview using saved data. Day gives hourly bins and totals; week and
            month give daily bins; year gives monthly average bins. Week, month and year headlines are
            averages across completed recorded days, excluding today. Select a service to focus the chart
            and headline, or select a bin to scope the ranking. Unrecorded values are omitted.
            """, properties: [
                "date": ["type": "string", "format": "date", "description": "Any local date within the period."],
                "period": choices(["day", "week", "month", "year"], "Calendar period."),
                "time_zone": timeZone,
                "category_ids": categoryIds.merging([
                    "description": "Omit to use the saved Overview selection. Use [] for all categories."
                ]) { _, new in new },
                "service_id": serviceId,
                "group_by": choices(["category", "service"], "Ranking rows. Defaults to category."),
                "bin_index": ["type": "integer", "minimum": 0, "description": "Optional chart bin to use for the ranking."]
            ], required: ["date", "period"]) { (query: OverviewQuery, context) in
                try OverviewReport.read(query, databaseURL: context.databaseURL)
            },
        MCPTool("list_services", """
            Read the full FocusTrace Services directory with lifetime usage, including registered unused
            services. Can filter, search and sort like the app. Set include_members for individual apps
            and sites, identifiers, aliases and their own lifetime usage. Page with services.next_offset.
            """, properties: [
                "service_id": serviceId,
                "search": string("Match display name, app identifier, domain or alias."),
                "kind": choices(["app", "web", "mixed"], "Filter by service type."),
                "category_id": string("Category ID from recording_info."),
                "sort": choices(["name", "type", "category", "visits", "time"], "Defaults to name."),
                "descending": ["type": "boolean", "description": "Defaults to descending for time and visits, ascending otherwise."],
                "include_members": ["type": "boolean", "default": false],
                "offset": offset,
                "limit": limit(maximum: 100)
            ]) { (query: ServicesQuery, context) in
                try ServicesReport.read(query, databaseURL: context.databaseURL)
            },
        MCPTool("list_visits", """
            Read individual saved visits for up to 366 calendar days, newest first. Returns original
            timestamps, time inside the range, visit counts, longest visit, time share and quick checks.
            Filter by category, service or app/site source. Visit counts use the starting instant;
            time includes overlaps. The latest saved visit could still be in progress. Page using
            next_after_visit_id with the same filters.
            """, properties: preciseRange.merging([
                "category_ids": categoryIds,
                "service_id": serviceId,
                "source_id": string("App/site source ID from list_services with include_members."),
                "after_visit_id": ["type": "string", "format": "uuid", "description": "Cursor from next_after_visit_id."],
                "limit": limit(maximum: 100)
            ]) { _, new in new }, required: dateRange) { (query: VisitsQuery, context) in
                try VisitsReport.read(query, databaseURL: context.databaseURL)
            },
        MCPTool("list_recording_coverage", """
            Read the saved intervals in which FocusTrace was observing, including idle periods.
            The time between intervals is a recording gap. Older records can contain visits without
            coverage. Page with coverage.next_offset.
            """, properties: preciseRange.merging(["offset": offset, "limit": limit(maximum: 200)]) { _, new in new },
                required: dateRange) { (query: CoverageQuery, context) in
                try CoverageReport.read(query, databaseURL: context.databaseURL)
            },
        MCPTool("recording_info", """
            Read category names, IDs, colors and the saved Overview selection, website tracking settings,
            enabled browsers, first and last observed timestamps, record counts and automatic backup dates.
            """, properties: [:]) { (_: EmptyQuery, context) in
                try RecordingInfo.read(databaseURL: context.databaseURL, backups: context.backups)
            }
    ]

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func choices(_ options: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": options, "description": description]
    }

    private static func limit(maximum: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": maximum, "default": 25]
    }
}
