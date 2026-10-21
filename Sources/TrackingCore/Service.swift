import Foundation

/// Stable string IDs preserve existing visit files while allowing new sources.
public struct Service: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: String { rawValue }
    public static let kakao = Service(rawValue: "kakao")
    public static let linkedin = Service(rawValue: "linkedin")
    public static let instagram = Service(rawValue: "instagram")
    public static let youtube = Service(rawValue: "youtube")
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    // Convenience for the default catalog and existing clients.
    public static func website(_ url: String) -> Service? {
        Source.matchWebsite(url, sources: Source.defaults)
    }
}
