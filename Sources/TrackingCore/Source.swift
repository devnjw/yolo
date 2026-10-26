import Foundation

public struct Source: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case app, website }
    public let id: Service
    public let name: String
    public let kind: Kind
    public let identifier: String
    public var aliases: [String]
    public var archived: Bool
    public var isDistracting: Bool

    public init(id: Service = Service(rawValue: UUID().uuidString.lowercased()), name: String,
                kind: Kind, identifier: String, aliases: [String] = [], archived: Bool = false,
                isDistracting: Bool = false) {
        self.id = id; self.name = name; self.kind = kind
        self.identifier = identifier; self.aliases = aliases; self.archived = archived
        self.isDistracting = isDistracting
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, identifier, aliases, archived, isDistracting
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Service.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        identifier = try values.decode(String.self, forKey: .identifier)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        // The old catalog was a manually selected watchlist. Keep its selection.
        isDistracting = try values.decodeIfPresent(Bool.self, forKey: .isDistracting) ?? !archived
    }

    public static let defaults: [Source] = [
        Source(id: .kakao, name: "KakaoTalk", kind: .app, identifier: "com.kakao.KakaoTalkMac", isDistracting: true),
        Source(id: .linkedin, name: "LinkedIn", kind: .website, identifier: "linkedin.com", isDistracting: true),
        Source(id: .instagram, name: "Instagram", kind: .website, identifier: "instagram.com", isDistracting: true),
        Source(id: .youtube, name: "YouTube", kind: .website, identifier: "youtube.com", aliases: ["youtu.be"], isDistracting: true)
    ]

    public static func normalizedDomain(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }),
              let url = URL(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard host.count <= 253, labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              let tld = labels.last, tld.count >= 2, tld.contains(where: { $0.isLetter }) else { return nil }
        return host
    }

    public static func matchWebsite(_ url: String, sources: [Source]) -> Service? {
        guard let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host?.lowercased() else { return nil }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        var match: Service?
        var specificity = 0
        for source in sources where source.kind == .website && !source.archived {
            for domain in [source.identifier] + source.aliases {
                if domain.count > specificity && (normalizedHost == domain || normalizedHost.hasSuffix("." + domain)) {
                    match = source.id
                    specificity = domain.count
                }
            }
        }
        return match
    }

    public static func matchApp(_ bundleID: String?, sources: [Source]) -> Service? {
        sources.first { !$0.archived && $0.kind == .app && $0.identifier == bundleID }?.id
    }
}
