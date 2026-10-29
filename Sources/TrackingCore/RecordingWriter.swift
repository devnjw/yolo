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

    private func write(visits: [(ordinal: Int, visit: Visit)],
                       coverage: [(ordinal: Int, interval: DateInterval)]) -> Result<Void, Error> {
        if let failure { return .failure(failure) }
        do { try database.save(visits: visits, coverage: coverage); return .success(()) }
        catch { failure = error; return .failure(error) }
    }
}
