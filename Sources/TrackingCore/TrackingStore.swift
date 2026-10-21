import Foundation

/// JSON storage shared by the recorder and source catalog. Keep the default
/// Foundation date encoding and filenames compatible with existing installs.
public struct TrackingStore {
    public let directory: URL
    public var visitsURL: URL { directory.appendingPathComponent("visits.json") }
    public var sourcesURL: URL { directory.appendingPathComponent("sources.json") }

    public init(directory: URL) { self.directory = directory }

    public func loadVisits() throws -> [Visit] {
        try read([Visit].self, from: visitsURL) ?? []
    }

    public func loadSources() throws -> [Source] {
        try read([Source].self, from: sourcesURL) ?? Source.defaults
    }

    public func saveVisits(_ visits: [Visit]) throws { try write(visits, to: visitsURL) }
    public func saveSources(_ sources: [Source]) throws { try write(sources, to: sourcesURL) }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
