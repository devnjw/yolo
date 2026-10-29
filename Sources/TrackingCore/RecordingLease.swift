import Foundation
import Darwin

/// The app holds this advisory lock for its lifetime, including startup-error
/// recovery. Database replacement is unsafe if another app copy is recording.
public final class RecordingLease {
    private var descriptor: Int32 = -1
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".recording.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw RecordingDatabaseError("Could not open the recording lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failed = descriptor; descriptor = -1; close(failed)
            throw RecordingDatabaseError("Another copy of FocusTrace is using this data. Quit that copy first.")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
