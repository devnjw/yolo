import Foundation

public enum Browser: String, Codable, CaseIterable, Identifiable, Sendable {
    case chrome, safari
    public var id: String { rawValue }
    public var name: String { self == .chrome ? "Chrome" : "Safari" }
    public var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }

    public static func restoredSelection(saved: [String]?, legacy: String?) -> Set<Browser> {
        // An empty saved selection is intentional. Older versions stored one browser.
        if let saved { return Set(saved.compactMap(Browser.init(rawValue:))) }
        return [legacy.flatMap(Browser.init(rawValue:)) ?? .chrome]
    }

    public static func eligibleBrowser(frontmostID: String?, enabled: Set<Browser>,
                                       blocked: Set<Browser>, websitesEnabled: Bool) -> Browser? {
        guard websitesEnabled else { return nil }
        return allCases.first { $0.bundleID == frontmostID && enabled.contains($0) && !blocked.contains($0) }
    }
}
