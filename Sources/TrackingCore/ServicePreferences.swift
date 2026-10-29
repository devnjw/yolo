import Foundation

/// Display-only overrides. Sources and visits always keep their original IDs.
/// Group redirects also apply to sources discovered after a manual merge;
/// per-source assignments take precedence so a split survives rediscovery.
struct ServicePreferences: Codable, Equatable, Sendable {
    private var names: [String: String] = [:]
    private var redirects: [String: String] = [:]
    private var sourceAssignments: [String: String] = [:]
    private var representatives: [String: String]?

    func identity(for source: Source) -> String {
        resolved(sourceAssignments[source.id.rawValue] ?? ServiceGrouping.identity(for: source))
    }

    func groups(from sources: [Source]) -> [ServiceGroup] {
        ServiceGrouping.grouped(sources, identity: identity) { id, source in
            names[id] ?? ServiceGrouping.defaultName(for: id, representative: source)
        }.map { group in
            guard let preferredID = representatives?[group.id],
                  let preferred = group.sources.first(where: { $0.id.rawValue == preferredID }) else { return group }
            return ServiceGroup(id: group.id, name: group.name,
                                sources: [preferred] + group.sources.filter { $0.id != preferred.id })
        }
    }

    mutating func rename(_ id: String, name: String) { names[id] = name }

    mutating func merge(_ id: String, into destination: String, name: String, representative: Service) {
        redirects[id] = destination
        // Flatten chains so resolving a service stays constant-time after edits.
        for key in Array(redirects.keys) { redirects[key] = resolved(key) }
        for key in Array(sourceAssignments.keys) { sourceAssignments[key] = resolved(sourceAssignments[key]!) }
        names[id] = nil
        names[destination] = name
        if representatives == nil { representatives = [:] }
        representatives?[id] = nil
        representatives?[destination] = representative.rawValue
    }

    mutating func split(_ source: Source, name: String) -> String {
        let id = "custom:" + UUID().uuidString.lowercased()
        sourceAssignments[source.id.rawValue] = id
        names[id] = name
        return id
    }

    private func resolved(_ id: String) -> String {
        var result = id
        var visited: Set<String> = []
        while let next = redirects[result], visited.insert(result).inserted { result = next }
        return result
    }

    static func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 253,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceEditError("Use a service name between 1 and 253 characters.")
        }
        return name
    }

    func validate() throws {
        guard !names.keys.contains(""), !redirects.keys.contains(""), !redirects.values.contains(""),
              !sourceAssignments.keys.contains(""), !sourceAssignments.values.contains(""),
              !(representatives ?? [:]).keys.contains(""), !(representatives ?? [:]).values.contains("") else {
            throw ServiceEditError("Saved service settings are invalid.")
        }
        for name in names.values { _ = try Self.validatedName(name) }
        for id in redirects.keys {
            var visited: Set<String> = []
            var current = id
            while let next = redirects[current] {
                guard visited.insert(current).inserted else { throw ServiceEditError("Saved service settings contain a circular merge.") }
                current = next
            }
        }
    }
}

public struct ServiceEditError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
