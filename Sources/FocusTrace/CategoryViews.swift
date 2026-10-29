import SwiftUI
import TrackingCore

extension ActivityCategory {
    var color: Color { customHex.map(CategoryPalette.customColor) ?? CategoryPalette.color(tint) }
}

/// Screen Time-inspired category colors shared by charts, rows and pickers.
/// Light appearance uses deeper values against white surfaces.
enum CategoryPalette {
    static let presets: [ActivityCategory.Tint] = [.green, .teal, .blue, .indigo, .purple, .pink, .red, .orange, .yellow, .gray]
    static func customColor(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }

    static func color(_ tint: ActivityCategory.Tint) -> Color {
        let light: UInt32
        let dark: UInt32
        switch tint {
        case .blue:   (light, dark) = (0x0087EF, 0x009AFF)
        case .teal:   (light, dark) = (0x00A8B5, 0x00C7D2)
        case .orange: (light, dark) = (0xE78328, 0xFF942F)
        case .purple: (light, dark) = (0x805AD5, 0x9474E4)
        case .pink:   (light, dark) = (0xD94F7D, 0xF06491)
        case .green:  (light, dark) = (0x239D60, 0x34C77B)
        case .gray:   (light, dark) = (0x86868B, 0x636366)
        case .red:    (light, dark) = (0xE34D49, 0xFF625B)
        case .yellow: (light, dark) = (0xB58A16, 0xEAC54F)
        case .indigo: (light, dark) = (0x525BC6, 0x717BEC)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255,
                           green: Double((hex >> 8) & 0xff) / 255,
                           blue: Double(hex & 0xff) / 255, alpha: 1)
        })
    }
}

struct CategoryColorPicker: View {
    @Binding var tint: ActivityCategory.Tint
    @Binding var customHex: UInt32?

    private var customSelection: Binding<Color> {
        Binding(get: { customHex.map(CategoryPalette.customColor) ?? CategoryPalette.color(tint) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            customHex = (byte(rgb.redComponent) << 16) | (byte(rgb.greenComponent) << 8) | byte(rgb.blueComponent)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(AppType.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { swatches }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 5), alignment: .leading, spacing: 8) { swatches }
                    .frame(width: 172)
            }
            ColorPicker("Custom color", selection: customSelection, supportsOpacity: false)
                .fixedSize().font(AppType.caption)
                .accessibilityValue(customHex.map { String(format: "#%06X", $0) } ?? "Preset")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onDisappear { NSColorPanel.shared.orderOut(nil) }
    }

    private var swatches: some View {
        ForEach(CategoryPalette.presets, id: \.self) { preset in
            Button { tint = preset; customHex = nil } label: {
                Circle().fill(CategoryPalette.color(preset)).frame(width: 20, height: 20)
                    .overlay {
                        if customHex == nil && tint == preset {
                            Circle().strokeBorder(Color.primary, lineWidth: 1.5).frame(width: 26, height: 26)
                        }
                    }.frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help(preset.rawValue.capitalized)
                .accessibilityLabel(preset.rawValue.capitalized)
                .accessibilityAddTraits(customHex == nil && tint == preset ? .isSelected : [])
        }
    }
}

struct CategoryLabel: View {
    let category: ActivityCategory
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(category.color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(category.name).lineLimit(1).help(category.name)
        }
    }
}

/// Assignment is at the service group level, including future members.
struct ServiceCategoryPicker: View {
    @ObservedObject var tracker: Tracker
    let group: ServiceGroup
    @State private var showing = false
    var body: some View {
        let category = tracker.categories.category(for: group.id)
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                CategoryLabel(category: category)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(AppType.caption).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Category for \(group.name)").accessibilityValue(category.name)
            .popover(isPresented: $showing) {
                CategoryAssignmentPopover(tracker: tracker, group: group, dismiss: { showing = false })
            }
    }
}

private struct CategoryAssignmentPopover: View {
    @ObservedObject var tracker: Tracker
    let group: ServiceGroup
    let dismiss: () -> Void
    @State private var search = ""
    @State private var creating = false
    @State private var name = ""
    @State private var tint: ActivityCategory.Tint = .blue
    @State private var customHex: UInt32?
    @State private var error: String?
    private enum Field: Hashable { case search, name }
    @FocusState private var focusedField: Field?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if creating {
                HStack {
                    Text("New category").font(AppType.heading)
                    Spacer()
                    Button("Cancel") { creating = false; error = nil }
                }
                TextField("Category name", text: $name).textFieldStyle(.roundedBorder).focused($focusedField, equals: .name).onSubmit(create)
                CategoryColorPicker(tint: $tint, customHex: $customHex)
                if let error { Text(error).font(AppType.caption).foregroundStyle(.red) }
                HStack { Spacer(); Button("Create", action: create).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            } else {
                TextField("Search categories", text: $search).textFieldStyle(.roundedBorder).focused($focusedField, equals: .search)
                let options = tracker.categories.options.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(options) { category in
                            Button {
                                tracker.setCategory(category.id, for: group.id)
                                dismiss()
                            } label: {
                                HStack {
                                    CategoryLabel(category: category)
                                    Spacer()
                                    if tracker.categories.categoryID(for: group.id) == category.id {
                                        Image(systemName: "checkmark").font(AppType.caption)
                                    }
                                }.padding(.horizontal, 7).frame(height: 32).contentShape(Rectangle())
                            }.buttonStyle(QuietButtonStyle()).accessibilityLabel(category.name)
                        }
                        if options.isEmpty { Text("No matching categories").foregroundStyle(.secondary).padding(8) }
                    }
                }.frame(height: min(256, CGFloat(max(1, options.count)) * 34))
                Divider()
                Button {
                    name = search; tint = .blue; customHex = nil; creating = true
                } label: { Label("New category…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(7) }
                    .buttonStyle(QuietButtonStyle())
            }
        }.font(AppType.body).padding(12).frame(width: 260)
            .onAppear { focusedField = .search }
            .onChange(of: creating) { focusedField = $0 ? .name : .search }
    }
    private func create() {
        do { try tracker.createCategory(name: name, tint: tint, customHex: customHex, assigning: group.id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct OverviewCategoryPicker: View {
    let catalog: CategoryCatalog
    let onSelect: (Set<String>?) -> Void
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Text(catalog.selectionName).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(AppType.label).padding(.horizontal, 10)
                .frame(height: 32).frame(maxWidth: 245, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle()).help(catalog.visibleCategories.map(\.name).joined(separator: ", "))
            .accessibilityLabel("Overview categories").accessibilityValue(catalog.selectionName)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Button { onSelect(nil); showing = false } label: {
                        HStack {
                            Text("All categories")
                            Spacer()
                            if catalog.selectedIDs == nil { Image(systemName: "checkmark") }
                        }.frame(height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(catalog.options) { category in
                                Toggle(isOn: Binding(get: {
                                    catalog.selectedIDs?.contains(category.id) ?? false
                                }, set: { enabled in
                                    var ids = catalog.selectedIDs ?? []
                                    if enabled { ids.insert(category.id) } else { ids.remove(category.id) }
                                    if !ids.isEmpty { onSelect(ids.count == catalog.options.count ? nil : ids) }
                                })) { CategoryLabel(category: category) }
                                    .toggleStyle(.checkbox)
                                    .disabled(catalog.selectedIDs == [category.id])
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(280, CGFloat(catalog.options.count) * 31))
                    HStack { Spacer(); Button("Done") { showing = false } }
                }.font(AppType.body).padding(16).frame(width: 280)
            }
    }
}

struct CategoriesView: View {
    @ObservedObject var tracker: Tracker
    @State private var editingID: String?
    @State private var creating = false
    @State private var deleting: ActivityCategory?
    @State private var destination = ActivityCategory.uncategorized.id
    @State private var name = ""
    @State private var tint: ActivityCategory.Tint = .blue
    @State private var customHex: UInt32?
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var isEditing: Bool { creating || editingID != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if deleting != nil || isEditing {
                Text(deleting != nil ? "Delete category" : creating ? "New category" : "Edit category")
                    .font(AppType.heading)
            }
            if let deleting {
                Text("Move services in \(deleting.name) to:").font(AppType.body)
                Picker("Destination", selection: $destination) {
                    ForEach(tracker.categories.options.filter { $0.id != deleting.id }) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Text("Visit records will be kept.").font(AppType.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(AppType.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel", action: reset)
                    Button("Delete", role: .destructive) {
                        do { try tracker.removeCategory(deleting.id, movingTo: destination); reset() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } else if isEditing {
                TextField("Category name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit(save)
                CategoryColorPicker(tint: $tint, customHex: $customHex)
                if let error { Text(error).font(AppType.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel", action: reset)
                    Button(creating ? "Create" : "Save", action: save).buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                let groups = tracker.categories.serviceGroups(from: tracker.sources)
                HStack {
                    Button { creating = true; name = ""; tint = .blue; customHex = nil } label: { Label("New category…", systemImage: "plus") }
                        .buttonStyle(.plain)
                    Spacer()
                    Text("Services").font(AppType.caption).foregroundStyle(.secondary).padding(.trailing, 40)
                }
                VStack(spacing: 0) {
                    ForEach(tracker.categories.options) { category in
                        HStack(spacing: 12) {
                            CategoryLabel(category: category)
                            Spacer()
                            let count = groups.filter { tracker.categories.categoryID(for: $0.id) == category.id }.count
                            Text("\(count)").font(AppType.caption).monospacedDigit().foregroundStyle(.secondary)
                                .help("\(count) services")
                            Menu {
                                Button("Edit…") { editingID = category.id; name = category.name; tint = category.tint; customHex = category.customHex }
                                if category.id != ActivityCategory.uncategorized.id {
                                    Button("Delete…", role: .destructive) { deleting = category; destination = ActivityCategory.uncategorized.id }
                                }
                            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel("Edit \(category.name)")
                        }.frame(minHeight: 44)
                        Divider().opacity(0.6)
                    }

                }
            }
        }.font(AppType.body)
            .onChange(of: isEditing) { nameFocused = $0 }
    }
    private func reset() { creating = false; editingID = nil; deleting = nil; error = nil; name = "" }
    private func save() {
        do {
            if let editingID { try tracker.updateCategory(editingID, name: name, tint: tint, customHex: customHex) }
            else { try tracker.createCategory(name: name, tint: tint, customHex: customHex) }
            reset()
        } catch { self.error = error.localizedDescription }
    }
}
