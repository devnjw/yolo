import Foundation
import SQLite3

/// Incremental recording storage. Calls must be serialized by the owner.
/// Legacy JSON is imported once, transactionally, and never deleted or rewritten.
public final class RecordingDatabase {
    public let url: URL
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        url = directory.appendingPathComponent("recording.sqlite3")
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !files.fileExists(atPath: url.path) {
            do { try Data().write(to: url, options: .withoutOverwriting) }
            catch CocoaError.fileWriteFileExists { /* Another instance created it. */ }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = error()
            sqlite3_close(database); database = nil
            throw message
        }
        do {
            sqlite3_busy_timeout(database, 2_000)
            // A single database file is easier to back up after quitting. The
            // rollback journal is transient and inherits the database permissions.
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw error() }
            let schemaVersion = sqlite3_column_int(version, 0)
            guard schemaVersion == 0 || schemaVersion == 1 else {
                throw RecordingDatabaseError("Unsupported recording database version: \(schemaVersion).")
            }
            // Finish the PRAGMA read before starting the migration transaction.
            sqlite3_reset(version)
            try execute("""
                CREATE TABLE IF NOT EXISTS visits (
                    ordinal INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                    service TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS visits_start ON visits(start);
                CREATE TABLE IF NOT EXISTS coverage (
                    ordinal INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            if try !hasImportedLegacy() {
                let legacy = TrackingStore(directory: directory)
                // Decode both before the transaction. Malformed legacy data must
                // stop startup, never turn into an apparently empty recording.
                let visits = try legacy.loadVisits()
                let coverage = try legacy.loadCoverage()
                try transaction {
                    try upsertVisits(visits.enumerated().map { ($0.offset, $0.element) })
                    try upsertCoverage(coverage.intervals.enumerated().map { ($0.offset, $0.element) })
                    try execute("INSERT INTO metadata(key,value) VALUES ('legacy_import','complete'); PRAGMA user_version=1;")
                }
            }
        } catch {
            sqlite3_close(database); database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func loadVisits() throws -> [Visit] {
        let query = try statement("SELECT id,service,start,end FROM visits ORDER BY ordinal")
        defer { sqlite3_finalize(query) }
        var result: [Visit] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error() }
            guard let id = UUID(uuidString: text(query, 0)) else {
                throw RecordingDatabaseError("Invalid saved visit identifier.")
            }
            result.append(Visit(id: id, service: Service(rawValue: text(query, 1)),
                                start: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 2)),
                                end: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 3))))
        }
    }

    public func loadCoverage() throws -> RecordingCoverage {
        let query = try statement("SELECT start,end FROM coverage ORDER BY ordinal")
        defer { sqlite3_finalize(query) }
        var intervals: [DateInterval] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return RecordingCoverage(intervals: intervals) }
            guard code == SQLITE_ROW else { throw error() }
            let start = sqlite3_column_double(query, 0), end = sqlite3_column_double(query, 1)
            guard start.isFinite, end.isFinite, end >= start else {
                throw RecordingDatabaseError("Invalid saved recording interval.")
            }
            intervals.append(DateInterval(start: Date(timeIntervalSinceReferenceDate: start),
                                          end: Date(timeIntervalSinceReferenceDate: end)))
        }
    }

    public func save(visits: [(ordinal: Int, visit: Visit)],
                     coverage: [(ordinal: Int, interval: DateInterval)]) throws {
        guard !visits.isEmpty || !coverage.isEmpty else { return }
        try transaction {
            try upsertVisits(visits)
            try upsertCoverage(coverage)
        }
    }

    private func upsertVisits(_ visits: [(ordinal: Int, visit: Visit)]) throws {
        let query = try statement("""
            INSERT INTO visits(ordinal,id,service,start,end) VALUES (?,?,?,?,?)
            ON CONFLICT(ordinal) DO UPDATE SET id=excluded.id,service=excluded.service,start=excluded.start,end=excluded.end
            """)
        defer { sqlite3_finalize(query) }
        for (ordinal, visit) in visits {
            guard ordinal >= 0, visit.start.timeIntervalSinceReferenceDate.isFinite,
                  visit.end.timeIntervalSinceReferenceDate.isFinite else {
                throw RecordingDatabaseError("Invalid visit update.")
            }
            sqlite3_bind_int64(query, 1, Int64(ordinal))
            try bind(visit.id.uuidString, to: query, at: 2)
            try bind(visit.service.rawValue, to: query, at: 3)
            sqlite3_bind_double(query, 4, visit.start.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(query, 5, visit.end.timeIntervalSinceReferenceDate)
            guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
            sqlite3_reset(query); sqlite3_clear_bindings(query)
        }
    }

    private func upsertCoverage(_ coverage: [(ordinal: Int, interval: DateInterval)]) throws {
        let query = try statement("""
            INSERT INTO coverage(ordinal,start,end) VALUES (?,?,?)
            ON CONFLICT(ordinal) DO UPDATE SET start=excluded.start,end=excluded.end
            """)
        defer { sqlite3_finalize(query) }
        for (ordinal, interval) in coverage {
            guard ordinal >= 0, interval.start.timeIntervalSinceReferenceDate.isFinite,
                  interval.end.timeIntervalSinceReferenceDate.isFinite else {
                throw RecordingDatabaseError("Invalid recording interval update.")
            }
            sqlite3_bind_int64(query, 1, Int64(ordinal))
            sqlite3_bind_double(query, 2, interval.start.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(query, 3, interval.end.timeIntervalSinceReferenceDate)
            guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
            sqlite3_reset(query); sqlite3_clear_bindings(query)
        }
    }

    private func hasImportedLegacy() throws -> Bool {
        let query = try statement("SELECT value FROM metadata WHERE key='legacy_import'")
        defer { sqlite3_finalize(query) }
        switch sqlite3_step(query) {
        case SQLITE_ROW:
            guard text(query, 0) == "complete" else { throw RecordingDatabaseError("Invalid import marker.") }
            return true
        case SQLITE_DONE: return false
        default: throw error()
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else { throw error() }
        return query
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func bind(_ value: String, to query: OpaquePointer, at index: Int32) throws {
        guard value.withCString({ sqlite3_bind_text(query, index, $0, -1, transient) }) == SQLITE_OK else { throw error() }
    }
    private func text(_ query: OpaquePointer, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(query, index))
    }
    private func error() -> RecordingDatabaseError {
        RecordingDatabaseError(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the recording database.")
    }
}

public struct RecordingDatabaseError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
