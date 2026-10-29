import Foundation
import SQLite3
import Darwin

/// Incremental recording storage. Calls must be serialized by the owner.
/// Legacy JSON is imported once, transactionally, and never deleted or rewritten.
public final class RecordingDatabase {
    public let url: URL
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, legacyOptions: TrackingOptions = TrackingOptions(), migrationBackupDirectory: URL? = nil) throws {
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
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw error() }
            let schemaVersion = sqlite3_column_int(version, 0)
            guard (0...2).contains(schemaVersion) else {
                throw RecordingDatabaseError("Unsupported recording database version: \(schemaVersion).")
            }
            // Finish the PRAGMA read before starting the migration transaction.
            sqlite3_reset(version)
            if schemaVersion == 0 {
                let existing = try statement("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('visits','coverage','metadata')")
                defer { sqlite3_finalize(existing) }
                guard sqlite3_step(existing) == SQLITE_ROW, sqlite3_column_int(existing, 0) == 0 else {
                    throw RecordingDatabaseError("The recording file is not a FocusTrace database.")
                }
                sqlite3_reset(existing)
                try execute("""
                    CREATE TABLE IF NOT EXISTS visits (
                        ordinal INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                        service TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);
                    CREATE INDEX IF NOT EXISTS visits_start ON visits(start);
                    CREATE TABLE IF NOT EXISTS coverage (
                        ordinal INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """)
            } else if try !hasImportedLegacy() {
                throw RecordingDatabaseError("The recording database is missing its import marker.")
            }
            if schemaVersion < 2 {
                let legacy = TrackingStore(directory: directory)
                let sources = try legacy.loadSources()
                let categories = try legacy.loadCategories(legacySources: sources)
                try legacyOptions.validate()
                let importRecording = try !hasImportedLegacy()
                let visits = importRecording ? try legacy.loadVisits() : []
                let coverage = importRecording ? try legacy.loadCoverage() : RecordingCoverage()
                if schemaVersion == 1, let migrationBackupDirectory {
                    try archiveBeforeMigration(in: migrationBackupDirectory, options: legacyOptions)
                }
                // Catalog, preferences, import markers and version change commit
                // together. In particular, a malformed catalog cannot partially
                // upgrade a v1 recording database.
                try transaction {
                    try createCatalogTables()
                    if importRecording {
                        try upsertVisits(visits.enumerated().map { ($0.offset, $0.element) })
                        try upsertCoverage(coverage.intervals.enumerated().map { ($0.offset, $0.element) })
                        try execute("INSERT INTO metadata(key,value) VALUES ('legacy_import','complete')")
                    }
                    try replaceCatalog(sources: sources, categories: categories)
                    try replaceOptions(legacyOptions)
                    try execute("PRAGMA application_id=0x46545243; PRAGMA user_version=2;")
                }
            }
            // Existing v2 databases are authoritative. Never fall back to JSON
            // or silently rebuild a missing/corrupt catalog.
            try validateFormat()
            _ = try loadSources(); _ = try loadCategories(); _ = try loadOptions()
        } catch {
            sqlite3_close(database); database = nil
            throw error
        }
    }

    private init(readOnlyURL: URL) throws {
        url = readOnlyURL
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = error(); sqlite3_close(database); database = nil; throw message
        }
        sqlite3_busy_timeout(database, 2_000)
    }

    deinit { sqlite3_close(database) }

    public func loadVisits() throws -> [Visit] {
        let query = try statement("SELECT ordinal,id,service,start,end FROM visits ORDER BY ordinal")
        defer { sqlite3_finalize(query) }
        var result: [Visit] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error() }
            guard sqlite3_column_int64(query, 0) == result.count,
                  let id = UUID(uuidString: text(query, 1)),
                  sqlite3_column_double(query, 3).isFinite, sqlite3_column_double(query, 4).isFinite else {
                throw RecordingDatabaseError("Invalid saved visit identifier.")
            }
            result.append(Visit(id: id, service: Service(rawValue: text(query, 2)),
                                start: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 3)),
                                end: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(query, 4))))
        }
    }

    public func loadCoverage() throws -> RecordingCoverage {
        let query = try statement("SELECT ordinal,start,end FROM coverage ORDER BY ordinal")
        defer { sqlite3_finalize(query) }
        var intervals: [DateInterval] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return RecordingCoverage(intervals: intervals) }
            guard code == SQLITE_ROW else { throw error() }
            let start = sqlite3_column_double(query, 1), end = sqlite3_column_double(query, 2)
            guard sqlite3_column_int64(query, 0) == intervals.count, start.isFinite, end.isFinite, end >= start else {
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
            ON CONFLICT(ordinal) DO UPDATE SET end=excluded.end
            WHERE visits.id=excluded.id AND visits.service=excluded.service AND visits.start=excluded.start
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
            guard sqlite3_changes(database) == 1 else {
                throw RecordingDatabaseError("Recording identity changed unexpectedly. Restart FocusTrace before continuing.")
            }
            sqlite3_reset(query); sqlite3_clear_bindings(query)
        }
    }

    private func upsertCoverage(_ coverage: [(ordinal: Int, interval: DateInterval)]) throws {
        let query = try statement("""
            INSERT INTO coverage(ordinal,start,end) VALUES (?,?,?)
            ON CONFLICT(ordinal) DO UPDATE SET end=excluded.end WHERE coverage.start=excluded.start
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
            guard sqlite3_changes(database) == 1 else {
                throw RecordingDatabaseError("Recording identity changed unexpectedly. Restart FocusTrace before continuing.")
            }
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
        guard value.utf8.count <= Int32.max,
              value.withCString({ sqlite3_bind_text(query, index, $0, Int32(value.utf8.count), transient) }) == SQLITE_OK else { throw error() }
    }
    private func text(_ query: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(query, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(query, index))), as: UTF8.self)
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

extension RecordingDatabase {
    private func createCatalogTables() throws {
        try execute("""
            CREATE TABLE sources (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL UNIQUE,
                name TEXT NOT NULL, kind TEXT NOT NULL, identifier TEXT NOT NULL,
                archived INTEGER NOT NULL, distracting INTEGER NOT NULL);
            CREATE TABLE source_aliases (
                source_id TEXT NOT NULL REFERENCES sources(id), position INTEGER NOT NULL,
                alias TEXT NOT NULL, PRIMARY KEY(source_id,position));
            CREATE TABLE categories (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL UNIQUE,
                name TEXT NOT NULL, tint TEXT NOT NULL, custom_hex INTEGER,
                fallback INTEGER NOT NULL);
            CREATE TABLE category_assignments (service_id TEXT PRIMARY KEY NOT NULL, category_id TEXT NOT NULL REFERENCES categories(id));
            CREATE TABLE catalog_settings (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL);
            CREATE TABLE tracking_options (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL);
            """)
    }

    public func loadSources() throws -> [Source] {
        let aliasesQuery = try statement("SELECT source_id,alias FROM source_aliases ORDER BY position")
        defer { sqlite3_finalize(aliasesQuery) }
        var aliases: [String: [String]] = [:]
        while true {
            let code = sqlite3_step(aliasesQuery)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            aliases[text(aliasesQuery, 0), default: []].append(text(aliasesQuery, 1))
        }
        let query = try statement("SELECT id,name,kind,identifier,archived,distracting FROM sources ORDER BY position")
        defer { sqlite3_finalize(query) }
        var sources: [Source] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return sources }
            guard code == SQLITE_ROW, let kind = Source.Kind(rawValue: text(query, 2)) else {
                throw RecordingDatabaseError("Saved source data is invalid.")
            }
            let id = text(query, 0)
            sources.append(Source(id: Service(rawValue: id), name: text(query, 1), kind: kind,
                                  identifier: text(query, 3), aliases: aliases[id] ?? [],
                                  archived: sqlite3_column_int(query, 4) != 0,
                                  isDistracting: sqlite3_column_int(query, 5) != 0))
        }
    }

    public func loadCategories() throws -> CategoryCatalog {
        let query = try statement("SELECT id,name,tint,custom_hex,fallback FROM categories ORDER BY position")
        defer { sqlite3_finalize(query) }
        var categories: [ActivityCategory] = [], fallback: ActivityCategory?
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let tint = ActivityCategory.Tint(rawValue: text(query, 2)) else {
                throw RecordingDatabaseError("Saved category data is invalid.")
            }
            let hex: UInt32?
            if sqlite3_column_type(query, 3) == SQLITE_NULL { hex = nil }
            else {
                let value = sqlite3_column_int64(query, 3)
                guard value >= 0 && value <= 0xFFFFFF else { throw RecordingDatabaseError("Invalid saved category color.") }
                hex = UInt32(value)
            }
            let category = ActivityCategory(id: text(query, 0), name: text(query, 1), tint: tint, customHex: hex)
            if sqlite3_column_int(query, 4) != 0 {
                guard fallback == nil else { throw RecordingDatabaseError("Duplicate fallback category.") }
                fallback = category
            } else { categories.append(category) }
        }
        guard let fallback else { throw RecordingDatabaseError("Missing fallback category.") }
        let assignmentQuery = try statement("SELECT service_id,category_id FROM category_assignments")
        defer { sqlite3_finalize(assignmentQuery) }
        var assignments: [String: String] = [:]
        while true {
            let code = sqlite3_step(assignmentQuery)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            assignments[text(assignmentQuery, 0)] = text(assignmentQuery, 1)
        }
        let settings: CategoryCatalog.DatabaseSettings = try readDocument(from: "catalog_settings")
        return try CategoryCatalog(storedCategories: categories, fallback: fallback, assignments: assignments, settings: settings)
    }

    public func loadOptions() throws -> TrackingOptions {
        let options: TrackingOptions = try readDocument(from: "tracking_options")
        try options.validate()
        return options
    }

    public func loadSnapshot() throws -> RecordingSnapshot {
        let ownsTransaction = sqlite3_get_autocommit(database) != 0
        if ownsTransaction { try execute("BEGIN DEFERRED") }
        do {
            let snapshot = RecordingSnapshot(visits: try loadVisits(), coverage: try loadCoverage(), sources: try loadSources(),
                                             categories: try loadCategories(), options: try loadOptions())
            if ownsTransaction { try execute("COMMIT") }
            return snapshot
        } catch {
            if ownsTransaction { try? execute("ROLLBACK") }
            throw error
        }
    }

    public func saveCatalog(sources: [Source], categories: CategoryCatalog) throws {
        try transaction { try replaceCatalog(sources: sources, categories: categories) }
    }

    public func saveOptions(_ options: TrackingOptions) throws {
        try options.validate()
        try transaction { try replaceOptions(options) }
    }

    private func replaceCatalog(sources: [Source], categories: CategoryCatalog) throws {
        // Validate the same invariants as JSON imports before touching live rows.
        _ = try JSONDecoder().decode(CategoryCatalog.self, from: JSONEncoder().encode(categories))
        try execute("DELETE FROM source_aliases; DELETE FROM sources; DELETE FROM category_assignments; DELETE FROM categories;")
        let sourceQuery = try statement("INSERT INTO sources VALUES (?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(sourceQuery) }
        let aliasQuery = try statement("INSERT INTO source_aliases VALUES (?,?,?)")
        defer { sqlite3_finalize(aliasQuery) }
        let categoryQuery = try statement("INSERT INTO categories VALUES (?,?,?,?,?,?)")
        defer { sqlite3_finalize(categoryQuery) }
        let assignmentQuery = try statement("INSERT INTO category_assignments VALUES (?,?)")
        defer { sqlite3_finalize(assignmentQuery) }
        for (position, source) in sources.enumerated() {
            try bind(source.id.rawValue, to: sourceQuery, at: 1)
            sqlite3_bind_int64(sourceQuery, 2, Int64(position))
            try bind(source.name, to: sourceQuery, at: 3)
            try bind(source.kind.rawValue, to: sourceQuery, at: 4)
            try bind(source.identifier, to: sourceQuery, at: 5)
            sqlite3_bind_int(sourceQuery, 6, source.archived ? 1 : 0)
            sqlite3_bind_int(sourceQuery, 7, source.isDistracting ? 1 : 0)
            try run(sourceQuery)
            for (index, alias) in source.aliases.enumerated() {
                try bind(source.id.rawValue, to: aliasQuery, at: 1)
                sqlite3_bind_int64(aliasQuery, 2, Int64(index))
                try bind(alias, to: aliasQuery, at: 3)
                try run(aliasQuery)
            }
        }
        for (position, category) in categories.options.enumerated() {
            try bind(category.id, to: categoryQuery, at: 1)
            sqlite3_bind_int64(categoryQuery, 2, Int64(position))
            try bind(category.name, to: categoryQuery, at: 3)
            try bind(category.tint.rawValue, to: categoryQuery, at: 4)
            if let hex = category.customHex { sqlite3_bind_int64(categoryQuery, 5, Int64(hex)) }
            else { sqlite3_bind_null(categoryQuery, 5) }
            sqlite3_bind_int(categoryQuery, 6, category.id == categories.fallbackCategory.id ? 1 : 0)
            try run(categoryQuery)
        }
        for (id, category) in categories.assignments {
            try bind(id, to: assignmentQuery, at: 1); try bind(category, to: assignmentQuery, at: 2)
            try run(assignmentQuery)
        }
        try writeDocument(categories.databaseSettings, into: "catalog_settings")
    }

    private func replaceOptions(_ options: TrackingOptions) throws {
        try writeDocument(options, into: "tracking_options")
    }
    private func readDocument<Value: Decodable>(from table: String) throws -> Value {
        let query = try statement("SELECT payload FROM \(table) WHERE id=1")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw RecordingDatabaseError("Missing saved \(table).") }
        return try JSONDecoder().decode(Value.self, from: Data(text(query, 0).utf8))
    }
    private func writeDocument<Value: Encodable>(_ value: Value, into table: String) throws {
        let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let query = try statement("INSERT INTO \(table)(id,payload) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(query) }
        try bind(payload, to: query, at: 1); try run(query)
    }
    private func run(_ query: OpaquePointer) throws {
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
        sqlite3_reset(query); sqlite3_clear_bindings(query)
    }
    private func validateFormat() throws {
        let query = try statement("SELECT (SELECT user_version FROM pragma_user_version), (SELECT application_id FROM pragma_application_id)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) == 2,
              sqlite3_column_int(query, 1) == 0x46545243, try hasImportedLegacy() else {
            throw RecordingDatabaseError("Choose a complete FocusTrace backup in the current format.")
        }
    }
}

extension RecordingDatabase {
    /// A backup is published only after SQLite and the complete application model
    /// have validated it. Temporary files stay in a private sibling directory.
    public func backup(to destination: URL, overwrite: Bool = false) throws {
        try rejectLiveFile(destination)
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".focustrace-backup-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("recording.sqlite3")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RecordingDatabaseError("Could not prepare the backup file.")
        }
        var output: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(output); throw RecordingDatabaseError("Could not open the backup file.")
        }
        do { try Self.copy(from: database, to: output) }
        catch { sqlite3_close(output); throw error }
        sqlite3_close(output)
        _ = try Self.validateBackup(at: temporary)
        if overwrite {
            guard rename(temporary.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else { try files.moveItem(at: temporary, to: destination) }
    }

    public static func validateBackup(at url: URL) throws -> RecordingSnapshot {
        let source = try RecordingDatabase(readOnlyURL: url)
        try source.execute("BEGIN DEFERRED")
        defer { try? source.execute("ROLLBACK") }
        try source.checkIntegrityAndFormat()
        return try source.loadSnapshot()
    }

    /// Source validation uses a held read transaction, so the bytes copied cannot
    /// change between validation and replacement. SQLite rolls back incomplete
    /// backup writes; a separate recovery copy also covers post-copy failures.
    public func restore(from sourceURL: URL, recoveryURL: URL) throws -> RecordingSnapshot {
        try rejectLiveFile(sourceURL)
        let source = try RecordingDatabase(readOnlyURL: sourceURL)
        try source.execute("BEGIN DEFERRED")
        defer { try? source.execute("ROLLBACK") }
        try source.checkIntegrityAndFormat()
        let expected = try source.loadSnapshot()
        try backup(to: recoveryURL)
        do {
            try Self.copy(from: source.database, to: database)
            let restored = try loadSnapshot()
            guard restored == expected else { throw RecordingDatabaseError("Restored data did not match the selected backup.") }
            return restored
        } catch {
            let originalError = error
            do {
                let recovery = try RecordingDatabase(readOnlyURL: recoveryURL)
                try Self.copy(from: recovery.database, to: database)
                try checkIntegrityAndFormat()
                _ = try loadSnapshot()
            } catch {
                throw RecordingRestoreRecoveryError(message: "Restore and automatic rollback failed. Your recovery backup is at \(recoveryURL.path). \(error.localizedDescription)")
            }
            throw originalError
        }
    }

    private func rejectLiveFile(_ candidate: URL) throws {
        let samePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
        var left = stat(), right = stat()
        let sameInode = stat(candidate.path, &left) == 0 && stat(url.path, &right) == 0 &&
            left.st_ino == right.st_ino && left.st_dev == right.st_dev
        guard !samePath && !sameInode else { throw RecordingDatabaseError("Choose a separate backup file, not the active database.") }
    }
    private func checkIntegrityAndFormat() throws {
        let query = try statement("PRAGMA quick_check")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, text(query, 0) == "ok", sqlite3_step(query) == SQLITE_DONE else {
            throw RecordingDatabaseError("The selected backup failed the database integrity check.")
        }
        let relations = try statement("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(relations) }
        guard sqlite3_step(relations) == SQLITE_DONE else { throw RecordingDatabaseError("The selected backup contains broken data relationships.") }
        try validateFormat()
    }
    private static func copy(from source: OpaquePointer?, to destination: OpaquePointer?) throws {
        guard let operation = sqlite3_backup_init(destination, "main", source, "main") else {
            throw RecordingDatabaseError("Could not begin the database copy: \(String(cString: sqlite3_errmsg(destination)))")
        }
        let code = sqlite3_backup_step(operation, -1)
        let finish = sqlite3_backup_finish(operation)
        guard code == SQLITE_DONE, finish == SQLITE_OK else {
            throw RecordingDatabaseError("Database copy failed (\(code), \(finish)): \(String(cString: sqlite3_errmsg(destination)))")
        }
    }
}

public struct RecordingRestoreRecoveryError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

extension RecordingDatabase {
    /// Startup recovery when no live connection could be opened. The app must
    /// hold RecordingLease. Incomplete SQLite journals are never discarded.
    public static func recoverClosedDatabase(at liveURL: URL, from sourceURL: URL, recoveryURL: URL) throws -> RecordingDatabase {
        let source = try RecordingDatabase(readOnlyURL: sourceURL)
        try source.rejectLiveFile(liveURL)
        try source.execute("BEGIN DEFERRED")
        defer { try? source.execute("ROLLBACK") }
        try source.checkIntegrityAndFormat()
        _ = try source.loadSnapshot()
        let files = FileManager.default
        for suffix in ["-journal", "-wal", "-shm"] where files.fileExists(atPath: liveURL.path + suffix) {
            throw RecordingDatabaseError("An unfinished database journal is present. Preserve the data folder and restart FocusTrace before restoring.")
        }
        let staging = liveURL.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let prepared = staging.appendingPathComponent("recording.sqlite3")
        try source.backup(to: prepared)
        let hadOriginal = files.fileExists(atPath: liveURL.path)
        if hadOriginal {
            try files.copyItem(at: liveURL, to: recoveryURL)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        }
        guard rename(prepared.path, liveURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do { return try RecordingDatabase(directory: liveURL.deletingLastPathComponent()) }
        catch {
            let originalError = error
            do {
                if hadOriginal {
                    let rollback = staging.appendingPathComponent("rollback.sqlite3")
                    try files.copyItem(at: recoveryURL, to: rollback)
                    guard rename(rollback.path, liveURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else { try files.removeItem(at: liveURL) }
            } catch {
                throw RecordingRestoreRecoveryError(message: "Could not roll back recovery. The previous database is at \(recoveryURL.path). \(error.localizedDescription)")
            }
            throw originalError
        }
    }
}

extension RecordingDatabase {
    private func archiveBeforeMigration(in directory: URL, options: TrackingOptions) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".migration-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let databaseURL = temporary.appendingPathComponent("recording.sqlite3")
        guard files.createFile(atPath: databaseURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RecordingDatabaseError("Could not prepare the pre-upgrade backup.")
        }
        var output: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &output) == SQLITE_OK else {
            sqlite3_close(output); throw RecordingDatabaseError("Could not open the pre-upgrade backup.")
        }
        do { try Self.copy(from: database, to: output) }
        catch { sqlite3_close(output); throw error }
        sqlite3_close(output)
        for name in ["sources.json", "categories.json", "visits.json", "coverage.json"] {
            let original = url.deletingLastPathComponent().appendingPathComponent(name)
            guard files.fileExists(atPath: original.path) else { continue }
            let destination = temporary.appendingPathComponent(name)
            try files.copyItem(at: original, to: destination)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let preferences = temporary.appendingPathComponent("tracking-options.json")
        try JSONEncoder().encode(options).write(to: preferences)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferences.path)
        try files.moveItem(at: temporary, to: directory.appendingPathComponent("before-schema-2-" + UUID().uuidString, isDirectory: true))
    }
}
