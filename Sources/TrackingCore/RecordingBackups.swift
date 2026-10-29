import Foundation

/// Only the Automatic subdirectory is pruned. Manual and recovery backups are
/// kept separately and are never included in automatic retention.
public final class RecordingBackups: Sendable {
    public let directory: URL
    public var automaticDirectory: URL { directory.appendingPathComponent("Automatic", isDirectory: true) }
    public var recoveryDirectory: URL { directory.appendingPathComponent("Recovery", isDirectory: true) }
    public init(directory: URL) { self.directory = directory.resolvingSymlinksInPath().standardizedFileURL }

    public struct Entry {
        public let url: URL
        public let date: Date
    }

    public func automaticEntries() throws -> [Entry] {
        let files = FileManager.default
        guard files.fileExists(atPath: automaticDirectory.path) else { return [] }
        return try files.contentsOfDirectory(at: automaticDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .compactMap { url -> Entry? in
                let name = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "sqlite3", name.hasPrefix("automatic-"),
                      let token = name.dropFirst("automatic-".count).split(separator: "_").first,
                      let milliseconds = Int64(token) else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return Entry(url: url.resolvingSymlinksInPath().standardizedFileURL, date: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
            }.sorted { $0.date > $1.date }
    }

    public func automaticBackupIfNeeded(database: RecordingDatabase, now: Date = Date(), calendar: Calendar = .current) throws -> Entry {
        let existing = try automaticEntries()
        if let today = existing.first(where: { calendar.isDate($0.date, inSameDayAs: now) }),
           (try? RecordingDatabase.validateBackup(at: today.url)) != nil { return today }
        try prepare(automaticDirectory)
        let target = automaticDirectory.appendingPathComponent(filename(prefix: "automatic", date: now))
        try database.backup(to: target)
        // Cleanup happens only after a complete, validated backup is published.
        for entry in try automaticEntries().dropFirst(7) { try FileManager.default.removeItem(at: entry.url) }
        return Entry(url: target.resolvingSymlinksInPath().standardizedFileURL, date: now)
    }

    public func recoveryURL(now: Date = Date()) throws -> URL {
        try prepare(recoveryDirectory)
        return recoveryDirectory.appendingPathComponent(filename(prefix: "before-restore", date: now))
    }
    private func prepare(_ url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func filename(prefix: String, date: Date) -> String {
        "\(prefix)-\(Int64(date.timeIntervalSince1970 * 1000))_\(UUID().uuidString).sqlite3"
    }
}
