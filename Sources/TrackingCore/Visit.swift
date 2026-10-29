import Foundation

public struct Visit: Codable, Identifiable, Equatable {
    public let id: UUID
    public let service: Service
    public let start: Date
    public var end: Date
    public init(service: Service, start: Date, end: Date) {
        id = UUID(); self.service = service; self.start = start; self.end = end
    }
    init(id: UUID, service: Service, start: Date, end: Date) {
        self.id = id; self.service = service; self.start = start; self.end = end
    }
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public func seconds(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
}
