import Foundation

/// Resolves every observation, reusing historical IDs even for removed sources.
public enum SourceCatalog {
    public static func app(identifier: String, name: String, sources: [Source]) -> Source {
        sources.first { $0.kind == .app && $0.identifier == identifier }
            ?? Source(name: name, kind: .app, identifier: identifier)
    }

    /// Only the host leaves the browser reader; paths, queries and titles are discarded.
    public static func website(url: String, sources: [Source]) -> Source? {
        guard let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              var host = parsed.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        guard !host.isEmpty else { return nil }
        // Resolve the observed host before any explicit alias. A parent domain
        // must not absorb newly discovered services such as meet.google.com.
        // Known services can still combine sources in the presentation layer.
        return sources.first { $0.kind == .website && $0.identifier == host }
            ?? sources.first { $0.kind == .website && $0.aliases.contains(host) }
            ?? Source(name: host, kind: .website, identifier: host)
    }
}
