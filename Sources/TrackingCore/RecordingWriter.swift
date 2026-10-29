import Foundation

/// Serial disk I/O, with failure latching: a failed batch cannot be overtaken by
/// later saves or by the final synchronous drain at application termination.
public final class RecordingWriter {
    private let queue = DispatchQueue(label: "FocusTrace.recording", qos: .utility)
    private let database: RecordingDatabase
    private var failure: Error?

    public init(database: RecordingDatabase) { self.database = database }

    public func submit(visits: [(ordinal: Int, visit: Visit)],
                       coverage: [(ordinal: Int, interval: DateInterval)],
                       completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { completion(self.write(visits: visits, coverage: coverage)) }
    }

    /// Waits for queued writes, then commits the latest tail before quitting.
    public func finish(visits: [(ordinal: Int, visit: Visit)],
                       coverage: [(ordinal: Int, interval: DateInterval)]) throws {
        try queue.sync { try write(visits: visits, coverage: coverage).get() }
    }

    public func saveCatalog(sources: [Source], categories: CategoryCatalog) throws {
        try queue.sync {
            if let failure { throw failure }
            try database.saveCatalog(sources: sources, categories: categories)
        }
    }

    public func saveOptions(_ options: TrackingOptions) throws {
        try queue.sync {
            if let failure { throw failure }
            try database.saveOptions(options)
        }
    }

    public func backup(visits: [(ordinal: Int, visit: Visit)], coverage: [(ordinal: Int, interval: DateInterval)],
                       destination: URL?, repository: RecordingBackups, now: Date = Date(),
                       completion: @escaping (Result<RecordingBackups.Entry, Error>) -> Void) {
        queue.async {
            do { try self.write(visits: visits, coverage: coverage).get() }
            catch { completion(.failure(RecordingWriteFailure(underlying: error))); return }
            do {
                if let destination {
                    try self.database.backup(to: destination, overwrite: true)
                    completion(.success(.init(url: destination, date: now)))
                } else {
                    completion(.success(try repository.automaticBackupIfNeeded(database: self.database, now: now)))
                }
            } catch { completion(.failure(error)) }
        }
    }

    public struct Restored {
        public let snapshot: RecordingSnapshot
        public let recoveryURL: URL
    }
    public func restore(visits: [(ordinal: Int, visit: Visit)], coverage: [(ordinal: Int, interval: DateInterval)],
                        from source: URL, repository: RecordingBackups,
                        completion: @escaping (Result<Restored, Error>) -> Void) {
        queue.async {
            do { try self.write(visits: visits, coverage: coverage).get() }
            catch { completion(.failure(RecordingWriteFailure(underlying: error))); return }
            do {
                let recoveryURL = try repository.recoveryURL()
                let snapshot = try self.database.restore(from: source, recoveryURL: recoveryURL)
                completion(.success(Restored(snapshot: snapshot, recoveryURL: recoveryURL)))
            } catch {
                if error is RecordingRestoreRecoveryError { self.failure = error }
                completion(.failure(error))
            }
        }
    }

    private func write(visits: [(ordinal: Int, visit: Visit)],
                       coverage: [(ordinal: Int, interval: DateInterval)]) -> Result<Void, Error> {
        if let failure { return .failure(failure) }
        do { try database.save(visits: visits, coverage: coverage); return .success(()) }
        catch { failure = error; return .failure(error) }
    }
}

public struct RecordingWriteFailure: LocalizedError {
    public let underlying: Error
    public var errorDescription: String? { underlying.localizedDescription }
}
