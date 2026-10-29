import Foundation

/// Recording preferences travel with the data; presentation and macOS permissions do not.
public struct TrackingOptions: Codable, Equatable {
    public var websitesEnabled: Bool
    public var enabledBrowsers: Set<Browser>
    public var idleMinutes: Int
    public init(websitesEnabled: Bool = false, enabledBrowsers: Set<Browser> = [.chrome], idleMinutes: Int = 5) {
        self.websitesEnabled = websitesEnabled; self.enabledBrowsers = enabledBrowsers; self.idleMinutes = idleMinutes
    }
    func validate() throws {
        guard idleMinutes >= 0 && idleMinutes <= 1440 else {
            throw RecordingDatabaseError("Saved idle time is invalid.")
        }
    }
}

public struct RecordingSnapshot: Equatable {
    public let visits: [Visit]
    public let coverage: RecordingCoverage
    public let sources: [Source]
    public let categories: CategoryCatalog
    public let options: TrackingOptions
}
