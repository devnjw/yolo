import Foundation

/// Table operations use one precomputed row per service, never scans of visits
/// inside a sort comparator. Filters are local to this directory, not Overview.
public enum ServiceDirectory {
    public enum Kind: String, CaseIterable, Identifiable {
        case app = "App", web = "Web", mixed = "App & Web"
        public var id: String { rawValue }

        public init(group: ServiceGroup) {
            let hasApp = group.sources.contains { $0.kind == .app }
            let hasWeb = group.sources.contains { $0.kind == .website }
            self = hasApp && hasWeb ? .mixed : hasApp ? .app : .web
        }
    }

    public enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", type = "Type", category = "Category"
        case visits = "Total visits", time = "Total time spent"
        public var id: String { rawValue }
        public var prefersDescending: Bool { self == .visits || self == .time }
    }

    public struct SortSelection: Equatable {
        public var column: Sort?
        public var descending: Bool

        public init(column: Sort? = nil, descending: Bool = false) {
            self.column = column
            self.descending = column == nil ? false : descending
        }

        /// Most useful direction, its reverse, then the stable default order.
        public func selecting(_ column: Sort) -> Self {
            guard self.column == column else {
                return Self(column: column, descending: column.prefersDescending)
            }
            return descending == column.prefersDescending
                ? Self(column: column, descending: !descending) : Self()
        }
    }

    public struct Row: Identifiable {
        public let group: ServiceGroup
        public let category: ActivityCategory
        public let kind: Kind
        public let usage: UsageTotals
        public var id: String { group.id }
    }

    public static func rows(groups: [ServiceGroup], totals: [Service: UsageTotals], catalog: CategoryCatalog,
                            search: String = "", kind: Kind? = nil, categoryID: String? = nil,
                            sort: Sort? = .name, descending: Bool = false) -> [Row] {
        let rows = groups.compactMap { group -> Row? in
            let groupKind = Kind(group: group)
            let category = catalog.category(for: group.id)
            guard group.matches(search), kind == nil || groupKind == kind,
                  categoryID == nil || category.id == categoryID else { return nil }
            let usage = group.sourceIDs.reduce(UsageTotals()) { $0 + (totals[$1] ?? UsageTotals()) }
            return Row(group: group, category: category, kind: groupKind, usage: usage)
        }
        return rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sort ?? .name {
            case .name: comparison = lhs.group.name.localizedStandardCompare(rhs.group.name)
            case .type: comparison = lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue)
            case .category: comparison = lhs.category.name.localizedStandardCompare(rhs.category.name)
            case .visits: comparison = compare(lhs.usage.visits, rhs.usage.visits)
            case .time: comparison = compare(lhs.usage.seconds, rhs.usage.seconds)
            }
            if comparison != .orderedSame { return comparison == (sort != nil && descending ? .orderedDescending : .orderedAscending) }
            let nameOrder = lhs.group.name.localizedStandardCompare(rhs.group.name)
            return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
