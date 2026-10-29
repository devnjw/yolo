import Foundation

public struct ActivityCategory: Codable, Equatable, Identifiable, Sendable {
    public enum Tint: String, Codable, CaseIterable, Sendable {
        case blue, teal, orange, purple, pink, green, gray, red, yellow, indigo
    }
    public let id: String
    public var name: String
    public var tint: Tint
    /// Opaque sRGB override; nil uses the appearance-aware preset.
    public var customHex: UInt32?

    public init(id: String, name: String, tint: Tint, customHex: UInt32? = nil) {
        self.id = id; self.name = name; self.tint = tint; self.customHex = customHex
    }

    public static let uncategorized = ActivityCategory(id: "uncategorized", name: "Other", tint: .gray)
    public static let defaults: [ActivityCategory] = [
        .init(id: "work", name: "Work", tint: .green),
        .init(id: "learning", name: "Learning", tint: .teal),
        .init(id: "communication", name: "Communication", tint: .blue),
        .init(id: "social", name: "Social", tint: .orange),
        .init(id: "entertainment", name: "Entertainment", tint: .pink),
        .init(id: "personal", name: "Personal", tint: .purple)
    ]
}

/// Categories, service names/grouping and the Overview selection are committed
/// atomically together. Display edits preserve source and visit identities.
public struct CategoryCatalog: Codable, Equatable, Sendable {
    public private(set) var categories: [ActivityCategory]
    public private(set) var fallbackCategory: ActivityCategory
    public private(set) var assignments: [String: String]
    private var servicePreferences = ServicePreferences()
    /// nil means all categories, including categories created in the future.
    public private(set) var selectedIDs: Set<String>?
    public var options: [ActivityCategory] { categories + [fallbackCategory] }
    public var visibleCategories: [ActivityCategory] {
        options.filter { selectedIDs?.contains($0.id) ?? true }
    }
    public var selectionName: String {
        guard let selectedIDs else { return "All categories" }
        return selectedIDs.count == 1 ? category(id: selectedIDs.first!).name : "\(selectedIDs.count) categories"
    }

    public init(legacySources: [Source] = []) {
        categories = ActivityCategory.defaults
        fallbackCategory = .uncategorized
        assignments = [:]
        selectedIDs = nil
        applyServiceDefaults(to: legacySources)
    }

    /// Populate only unset services. Explicit Uncategorized is persisted as an
    /// override, and deleted categories are never recreated by the suggestions.
    public mutating func applyServiceDefaults(to sources: [Source]) {
        let legacyID = "legacy-distractions"
        if categories.contains(where: { $0.id == legacyID }) {
            categories.removeAll { $0.id == legacyID }
            for key in Array(assignments.keys) where assignments[key] == legacyID {
                assignments[key] = nil
            }
            if var selected = selectedIDs {
                selected.remove(legacyID)
                selectedIDs = selected.isEmpty ? nil : selected
            }
        }
        for group in serviceGroups(from: sources) where assignments[group.id] == nil {
            let suggestions = Set(group.sources.compactMap { ServiceCategoryDefaults.categoryID(for: $0) })
            guard suggestions.count == 1, let id = suggestions.first,
                  categories.contains(where: { $0.id == id }) else { continue }
            assignments[group.id] = id
        }
    }

    public func category(id: String) -> ActivityCategory {
        categories.first { $0.id == id } ?? fallbackCategory
    }
    public func categoryID(for groupID: String) -> String {
        guard let id = assignments[groupID], categories.contains(where: { $0.id == id }) else {
            return ActivityCategory.uncategorized.id
        }
        return id
    }
    public func category(for groupID: String) -> ActivityCategory { category(id: categoryID(for: groupID)) }

    public func serviceGroups(from sources: [Source]) -> [ServiceGroup] { servicePreferences.groups(from: sources) }
    public func serviceID(for source: Source) -> String { servicePreferences.identity(for: source) }

    public mutating func renameService(_ id: String, to input: String, sources: [Source]) throws {
        guard serviceGroups(from: sources).contains(where: { $0.id == id }) else { throw ServiceEditError("This service is no longer available.") }
        servicePreferences.rename(id, name: try ServicePreferences.validatedName(input))
    }

    /// The destination retains its stable identity; both current and future
    /// members of the source group resolve to it. All validation precedes edits.
    public mutating func mergeService(_ id: String, into destination: String, name: String,
                                      categoryID: String, sources: [Source]) throws {
        let groups = serviceGroups(from: sources)
        guard id != destination, groups.contains(where: { $0.id == id }),
              let target = groups.first(where: { $0.id == destination }) else { throw ServiceEditError("Choose a different existing service to merge with.") }
        let name = try ServicePreferences.validatedName(name)
        guard options.contains(where: { $0.id == categoryID }) else { throw ServiceEditError("Choose a category for the merged service.") }
        servicePreferences.merge(id, into: destination, name: name, representative: target.representative.id)
        assignments[id] = nil
        assignments[destination] = categoryID
    }

    @discardableResult public mutating func splitServiceMember(_ sourceID: Service, from groupID: String,
                                                               name: String, sources: [Source]) throws -> String {
        guard let group = serviceGroups(from: sources).first(where: { $0.id == groupID }), group.sources.count > 1,
              let source = group.sources.first(where: { $0.id == sourceID }) else {
            throw ServiceEditError("Choose an app or website from a service with multiple members.")
        }
        let name = try ServicePreferences.validatedName(name)
        let id = servicePreferences.split(source, name: name)
        assignments[id] = categoryID(for: groupID)
        return id
    }

    /// Includes orphaned historical IDs in Uncategorized so All never loses time.
    public func members(sources: [Source], recordedIDs: Set<Service> = []) -> [String: Set<Service>] {
        var result = Dictionary(uniqueKeysWithValues: options.map { ($0.id, Set<Service>()) })
        for source in sources {
            result[categoryID(for: serviceID(for: source)), default: []].insert(source.id)
        }
        result[ActivityCategory.uncategorized.id, default: []].formUnion(recordedIDs.subtracting(sources.map(\.id)))
        return result
    }
    public func includedSourceIDs(sources: [Source], recordedIDs: Set<Service> = []) -> Set<Service> {
        let members = members(sources: sources, recordedIDs: recordedIDs)
        return visibleCategories.reduce(into: Set<Service>()) { $0.formUnion(members[$1.id] ?? []) }
    }

    public mutating func assign(_ categoryID: String, to groupID: String) throws {
        guard options.contains(where: { $0.id == categoryID }) else { throw CategoryError("Choose an existing category.") }
        assignments[groupID] = categoryID
    }
    @discardableResult public mutating func create(name: String, tint: ActivityCategory.Tint? = nil, customHex: UInt32? = nil, assigning groupID: String? = nil) throws -> String {
        let name = try validatedName(name)
        try validateColor(customHex)
        let id = UUID().uuidString.lowercased()
        let palette = ActivityCategory.Tint.allCases.filter { $0 != .gray }
        categories.append(ActivityCategory(id: id, name: name, tint: tint ?? palette[categories.count % palette.count], customHex: customHex))
        if let groupID { assignments[groupID] = id }
        return id
    }
    public mutating func rename(_ id: String, to name: String) throws {
        guard let category = options.first(where: { $0.id == id }) else { throw CategoryError("This category cannot be renamed.") }
        try update(id, name: name, tint: category.tint, customHex: category.customHex)
    }
    public mutating func update(_ id: String, name: String, tint: ActivityCategory.Tint, customHex: UInt32?) throws {
        guard options.contains(where: { $0.id == id }) else { throw CategoryError("This category cannot be edited.") }
        let name = try validatedName(name, excluding: id)
        try validateColor(customHex)
        let edited = ActivityCategory(id: id, name: name, tint: tint, customHex: customHex)
        if id == fallbackCategory.id {
            fallbackCategory = edited
        } else if let index = categories.firstIndex(where: { $0.id == id }) {
            categories[index] = edited
        }
    }
    private func validateColor(_ hex: UInt32?) throws {
        if let hex, hex > 0xFFFFFF { throw CategoryError("Choose a valid RGB color.") }
    }
    public mutating func remove(_ id: String, movingTo destination: String = ActivityCategory.uncategorized.id) throws {
        guard categories.contains(where: { $0.id == id }) else { throw CategoryError("This category cannot be deleted.") }
        guard destination != id, options.contains(where: { $0.id == destination }) else { throw CategoryError("Choose a different destination category.") }
        categories.removeAll { $0.id == id }
        for key in Array(assignments.keys) where assignments[key] == id {
            assignments[key] = destination
        }
        if var selected = selectedIDs {
            selected.remove(id)
            selectedIDs = selected.isEmpty ? nil : selected
        }
    }
    public mutating func select(_ ids: Set<String>?) throws {
        if let ids {
            guard !ids.isEmpty, ids.isSubset(of: Set(options.map(\.id))) else { throw CategoryError("Select at least one category, or All categories.") }
        }
        selectedIDs = ids
    }

    private func validatedName(_ input: String, excluding id: String? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CategoryError("Use a category name between 1 and 40 characters.")
        }
        let names = options.filter { $0.id != id }.map(\.name) + ["All categories"]
        guard !names.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw CategoryError("A category with this name already exists.")
        }
        return name
    }

    private enum CodingKeys: String, CodingKey { case categories, assignments, selectedIDs, fallbackCategory, servicePreferences }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categories = try values.decode([ActivityCategory].self, forKey: .categories)
        if let saved = try values.decodeIfPresent(ActivityCategory.self, forKey: .fallbackCategory) {
            fallbackCategory = saved
        } else {
            var initialFallback = ActivityCategory.uncategorized
            // Older files allowed a user-created "Other". Keep that category
            // and give the fallback a distinct initial label.
            var suffix = 2
            while categories.contains(where: { $0.name.compare(initialFallback.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                initialFallback.name = "Other \(suffix)"
                suffix += 1
            }
            fallbackCategory = initialFallback
        }
        assignments = try values.decode([String: String].self, forKey: .assignments)
        selectedIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedIDs)
        // One-time migration: Codex used to share ChatGPT's automatic group.
        // Preserve that category, including Other, without recreating obsolete
        // assignments after later manual merges.
        if !values.contains(.servicePreferences), assignments["known:codex"] == nil {
            assignments["known:codex"] = assignments["known:chatgpt"]
        }
        servicePreferences = values.contains(.servicePreferences)
            ? try values.decode(ServicePreferences.self, forKey: .servicePreferences) : ServicePreferences()
        try validateSavedState()
    }

    struct DatabaseSettings: Codable {
        let servicePreferences: ServicePreferences
        let selectedIDs: Set<String>?
    }
    var databaseSettings: DatabaseSettings {
        DatabaseSettings(servicePreferences: servicePreferences, selectedIDs: selectedIDs)
    }
    init(storedCategories: [ActivityCategory], fallback: ActivityCategory,
         assignments: [String: String], settings: DatabaseSettings) throws {
        categories = storedCategories; fallbackCategory = fallback
        self.assignments = assignments
        servicePreferences = settings.servicePreferences; selectedIDs = settings.selectedIDs
        try validateSavedState()
    }

    private mutating func validateSavedState() throws {
        try servicePreferences.validate()
        let ids = Set(categories.map(\.id))
        guard fallbackCategory.id == ActivityCategory.uncategorized.id, ids.count == categories.count, !ids.contains(ActivityCategory.uncategorized.id), !ids.contains(""),
              Set(assignments.values).isSubset(of: ids.union([ActivityCategory.uncategorized.id])) else { throw CategoryError("Saved category data is invalid.") }
        for category in options {
            _ = try validatedName(category.name, excluding: category.id)
            try validateColor(category.customHex)
        }
        if let selectedIDs { try select(selectedIDs) }
    }
}

public struct CategoryError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
