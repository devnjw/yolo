import Foundation

/// A display/selection group. Original source and visit IDs remain unchanged.
public struct ServiceGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sources: [Source]
    public var sourceIDs: Set<Service> { Set(sources.map(\.id)) }
    public var isDistracting: Bool { sources.contains(where: \.isDistracting) }
    /// Prefer a local app icon when both forms have been discovered.
    public var representative: Source { sources[0] }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([name] + sources.flatMap { [$0.name, $0.identifier] + $0.aliases })
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

public enum ServiceGrouping {
    private struct Definition {
        let key: String
        let name: String
        let apps: [String]
        let domains: [String]

        func matches(_ source: Source) -> Bool {
            let identifier = source.identifier.lowercased()
            if source.kind == .app { return apps.contains(identifier) }
            return domains.contains { identifier == $0 || identifier.hasSuffix("." + $0) }
        }
    }

    // Explicit identities only: never infer ownership from a display name,
    // a common domain suffix, or a user-supplied alias.
    private static let definitions: [Definition] = [
        .init(key: "chatgpt", name: "ChatGPT", apps: ["com.openai.chat"], domains: ["chatgpt.com", "chat.openai.com"]),
        .init(key: "codex", name: "Codex", apps: ["com.openai.codex"], domains: []),
        .init(key: "figma", name: "Figma", apps: ["com.figma.desktop"], domains: ["figma.com"]),
        .init(key: "github", name: "GitHub", apps: [], domains: ["github.com"]),
        .init(key: "instagram", name: "Instagram", apps: [], domains: ["instagram.com"]),
        .init(key: "linkedin", name: "LinkedIn", apps: [], domains: ["linkedin.com"]),
        .init(key: "notion", name: "Notion", apps: ["notion.id"], domains: ["notion.so", "notion.com"]),
        .init(key: "slack", name: "Slack", apps: ["com.tinyspeck.slackmacgap"], domains: ["slack.com"]),
        .init(key: "spotify", name: "Spotify", apps: ["com.spotify.client"], domains: ["spotify.com"]),
        .init(key: "vscode", name: "VS Code", apps: ["com.microsoft.vscode"], domains: ["vscode.dev"]),
        .init(key: "youtube", name: "YouTube", apps: [], domains: ["youtube.com", "youtu.be"])
    ]

    public static func identity(for source: Source) -> String {
        definitions.first { $0.matches(source) }.map { "known:" + $0.key } ?? "source:" + source.id.rawValue
    }

    public static func groups(from sources: [Source]) -> [ServiceGroup] {
        grouped(sources, identity: identity, name: defaultName)
    }

    public static func sourceName(for source: Source) -> String {
        source.kind == .website ? source.identifier : (definitions.first { $0.matches(source) }?.name ?? source.name)
    }

    static func defaultName(for id: String, representative: Source) -> String {
        definitions.first { "known:" + $0.key == id }?.name ?? representative.name
    }

    static func grouped(_ sources: [Source], identity: (Source) -> String,
                        name: (String, Source) -> String) -> [ServiceGroup] {
        Dictionary(grouping: sources, by: identity).map { id, members in
            let ordered = members.sorted {
                if $0.kind != $1.kind { return $0.kind == .app }
                if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
                return $0.id.rawValue < $1.id.rawValue
            }
            return ServiceGroup(id: id, name: name(id, ordered[0]), sources: ordered)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Preserve any existing selection when previously separate members join.
    public static func normalizedSelection(_ sources: [Source]) -> [Source] {
        let selected = Set(sources.filter(\.isDistracting).map(identity))
        return sources.map { source in
            var source = source
            source.isDistracting = selected.contains(identity(for: source))
            return source
        }
    }

    public static func settingDistracting(_ enabled: Bool, for groupID: String, in sources: [Source]) -> [Source] {
        sources.map { source in
            var source = source
            if identity(for: source) == groupID { source.isDistracting = enabled }
            return source
        }
    }
}
