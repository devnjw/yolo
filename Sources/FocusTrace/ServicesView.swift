import SwiftUI
import TrackingCore

struct ServicesView: View {
    @ObservedObject var tracker: Tracker
    let groups: [ServiceGroup]
    @Binding var search: String
    @AppStorage("services.sort") private var sortValue = ""
    @AppStorage("services.descending") private var descending = false
    @AppStorage("services.inspectorFraction") private var inspectorFraction = 0.26
    @AppStorage("services.typeFilter") private var typeFilter = ""
    @AppStorage("services.categoryFilter") private var categoryFilter = ""
    @State private var selectedID: String?
    @State private var showingFilters = false
    @State private var resizingWidth: CGFloat?

    private var sort: ServiceDirectory.Sort? { ServiceDirectory.Sort(rawValue: sortValue) }
    private var kind: ServiceDirectory.Kind? { ServiceDirectory.Kind(rawValue: typeFilter) }
    private var categoryID: String? {
        tracker.categories.options.contains { $0.id == categoryFilter } ? categoryFilter : nil
    }
    private var filterCount: Int { (kind == nil ? 0 : 1) + (categoryID == nil ? 0 : 1) }
    private var hasQuery: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var columnGap: CGFloat { selectedID == nil ? 16 : 12 }
    private var minimumTableWidth: CGFloat { selectedID == nil ? 780 : 660 }
    private var viewOptions: [String] { [search, typeFilter, categoryFilter, sortValue, String(descending)] }

    var body: some View {
        let rows = ServiceDirectory.rows(groups: groups, totals: tracker.ledger.lifetimeTotals,
                                         catalog: tracker.categories, search: search, kind: kind,
                                         categoryID: categoryID, sort: sort, descending: descending)
        GeometryReader { geometry in
            let selected = groups.first(where: { $0.id == selectedID })
            let panelWidth = clampedInspectorWidth(resizingWidth ?? geometry.size.width * inspectorFraction,
                                                  available: geometry.size.width)
            let tableWidth = selected == nil ? geometry.size.width : max(0, geometry.size.width - panelWidth - 25)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    controls(count: rows.count, compact: tableWidth < 460)
                    if filterCount > 0 { activeFilters.padding(.bottom, 10) }
                    directory(rows: rows)
                }.frame(width: tableWidth)
                if let selected {
                    InspectorDivider(width: panelWidth, resize: {
                        resizingWidth = clampedInspectorWidth($0, available: geometry.size.width)
                    }, finish: {
                        if let resizingWidth, geometry.size.width > 0 {
                            inspectorFraction = resizingWidth / geometry.size.width
                        }
                        resizingWidth = nil
                    })
                    ServiceInspector(tracker: tracker, group: selected, groups: groups,
                                     select: { selectedID = $0 }, dismiss: { selectedID = nil })
                        .id(selected.id)
                        .frame(width: panelWidth)
                }
            }
        }.coordinateSpace(name: "service-directory")
        .onAppear(perform: validateFilters)
        .onChange(of: tracker.categories.options.map(\.id)) { _ in validateFilters() }
    }

    private func directory(rows: [ServiceDirectory.Row]) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Color.clear.frame(height: 0).id("services-table-top")
                        Section(header: columnHeaders) {
                            ForEach(rows) { row in
                                serviceRow(row)
                                Divider().opacity(0.5)
                            }
                            if rows.isEmpty { emptyState }
                        }
                    }
                    .frame(width: max(geometry.size.width, minimumTableWidth), alignment: .leading)
                    .padding(.bottom, 16)
                    .background(OverlayScrollStyle())
                }
                .modifier(DirectoryScrollAnchor())
                .onAppear { proxy.scrollTo("services-table-top", anchor: .topLeading) }
                .onChange(of: viewOptions) { _ in proxy.scrollTo("services-table-top", anchor: .topLeading) }
            }
        }
    }

    private func controls(count: Int, compact: Bool) -> some View {
        // Keep search and popover identity when the list narrows beside the
        // inspector; only the arrangement changes, not the controls themselves.
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 10) {
                SearchField(text: $search).frame(minWidth: compact ? 120 : 150, idealWidth: 238, maxWidth: 238)
                Text("\(count) \(count == 1 ? "service" : "services")").foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(-1)
            }.frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            directoryActions
        }.font(AppType.caption).padding(.vertical, 10)
    }

    private var directoryActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("All time").foregroundStyle(.secondary).fixedSize()
                .help("All usage recorded by FocusTrace on this Mac, including the current visit. Overview date and category filters do not apply.")
            Button { showingFilters.toggle() } label: {
                Label(filterCount == 0 ? "Filter" : "Filter · \(filterCount)", systemImage: "line.3.horizontal.decrease")
                    .padding(.horizontal, 9).frame(height: 30).fixedSize()
            }.buttonStyle(QuietButtonStyle()).accessibilityLabel("Filter services")
                .popover(isPresented: $showingFilters, arrowEdge: .top) { filterPopover }
        }
    }

    private var activeFilters: some View {
        HStack(spacing: 8) {
            if let kind { filterChip("Type: \(kind.rawValue)") { typeFilter = "" } }
            if let categoryID {
                filterChip("Category: \(tracker.categories.category(id: categoryID).name)") { categoryFilter = "" }
            }
        }
    }
    private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }.font(AppType.caption).padding(.horizontal, 9).frame(height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(QuietButtonStyle()).accessibilityLabel("Remove \(title) filter")
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filters").font(AppType.heading)
                Spacer()
                Button { typeFilter = ""; categoryFilter = "" } label: {
                    Text("Clear all").font(AppType.caption).padding(.horizontal, 8).frame(height: 28)
                }.buttonStyle(QuietButtonStyle()).disabled(filterCount == 0)
                    .accessibilityLabel("Clear all service filters")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Type").font(AppType.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    filterOption(selected: kind == nil, accessibilityLabel: "Type: All types", action: { typeFilter = "" }) {
                        Text("All types")
                    }
                    ForEach(ServiceDirectory.Kind.allCases) { item in
                        filterOption(selected: kind == item, accessibilityLabel: "Type: \(item.rawValue)", action: { typeFilter = item.rawValue }) {
                            Text(item.rawValue)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Category").font(AppType.caption).foregroundStyle(.secondary)
                filterOption(selected: categoryID == nil, accessibilityLabel: "Category: All categories", action: { categoryFilter = "" }) {
                    Text("All categories").padding(.leading, 13)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tracker.categories.options) { category in
                            filterOption(selected: categoryID == category.id, accessibilityLabel: "Category: \(category.name)", action: { categoryFilter = category.id }) {
                                CategoryLabel(category: category)
                            }
                        }
                    }.background(OverlayScrollStyle())
                }.frame(height: min(238, CGFloat(tracker.categories.options.count * 34)))
            }
        }.font(AppType.body).padding(14).frame(width: 300)
    }

    private func filterOption<Label: View>(selected: Bool, accessibilityLabel: String,
                                           action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label().lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .medium))
                    .frame(width: 12).opacity(selected ? 1 : 0)
            }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                .background(selected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(QuietButtonStyle()).accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var columnHeaders: some View {
        VStack(spacing: 0) {
            HStack(spacing: columnGap) {
                ForEach(ServiceDirectory.Sort.allCases) { column in
                    Button { selectSort(column) } label: {
                        HStack(spacing: 5) {
                            Text(columnTitle(column)).lineLimit(1)
                            Image(systemName: descending ? "arrow.down" : "arrow.up")
                                .font(.system(size: 9, weight: .medium)).frame(width: 10)
                                .opacity(sort == column ? 1 : 0)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 6).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                        .foregroundStyle(sort == column ? .primary : .secondary)
                        .frame(width: columnWidth(column))
                        .frame(maxWidth: column == .name ? .infinity : nil)
                        .accessibilityLabel("Sort by \(column.rawValue.lowercased())")
                        .accessibilityValue(sort == column ? (descending ? "Descending" : "Ascending") : "Not sorted")
                        .help(sort == column && descending != column.prefersDescending
                              ? "Clear sorting and restore name order" : "Sort by \(column.rawValue.lowercased())")
                }
            }.font(AppType.caption).padding(.horizontal, 8)
            Divider()
        }.background(AppSurface.content)
    }

    private func serviceRow(_ row: ServiceDirectory.Row) -> some View {
        Button { selectedID = selectedID == row.id ? nil : row.id } label: {
            HStack(spacing: columnGap) {
                HStack(spacing: 10) {
                    SourceIcon(source: row.group.representative, size: 24)
                    Text(row.group.name).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                typeLabel(row.kind).frame(width: columnWidth(.type), alignment: .leading)
                CategoryLabel(category: row.category).font(AppType.caption).padding(.horizontal, 8)
                    .frame(width: columnWidth(.category), alignment: .leading)
                usageCell(row.usage, column: .visits)
                usageCell(row.usage, column: .time)
            }.font(AppType.body).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .background(selectedID == row.id ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(QuietButtonStyle()).help("\(selectedID == row.id ? "Close" : "Open") details for \(row.group.name)")
            .accessibilityLabel(row.group.name)
            .accessibilityValue("\(row.kind.rawValue), \(row.category.name), \(tracker.storageError == nil ? "\(row.usage.visits.formatted()) visits, \(overviewTimeLabel(row.usage.seconds))" : "Usage unavailable")\(selectedID == row.id ? ", Selected" : "")")
            .accessibilityHint(selectedID == row.id ? "Close service details" : "Open service details to edit its name or category, merge, or separate apps and websites")
    }

    private func typeLabel(_ kind: ServiceDirectory.Kind) -> some View {
        Text(kind.rawValue).font(AppType.caption).foregroundStyle(.secondary).padding(.leading, 6)
    }
    private func usageCell(_ usage: UsageTotals, column: ServiceDirectory.Sort) -> some View {
        let available = tracker.storageError == nil
        return Text(available ? (column == .visits ? usage.visits.formatted() : overviewTimeLabel(usage.seconds)) : "—")
            .monospacedDigit().lineLimit(1)
            .padding(.horizontal, 6).frame(width: columnWidth(column), alignment: .leading)
            .help(available ? (column == .visits ? "\(usage.visits.formatted()) recorded visits" : "\(usage.seconds.formatted(.number.precision(.fractionLength(0)))) recorded seconds") : "Recorded usage is unavailable because of a storage error.")
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(groups.isEmpty ? "Services appear here as you use them." : "No matching services.")
                .font(AppType.body).foregroundStyle(.secondary)
            if hasQuery || filterCount > 0 {
                Button("Clear search and filters") { search = ""; typeFilter = ""; categoryFilter = "" }
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }
    private func selectSort(_ column: ServiceDirectory.Sort) {
        let next = ServiceDirectory.SortSelection(column: sort, descending: descending).selecting(column)
        sortValue = next.column?.rawValue ?? ""
        descending = next.descending
    }
    private func clampedInspectorWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        // Keep the inspector usable and leave room for the directory's controls.
        // Its table can scroll horizontally when the user makes it narrower.
        min(max(proposed.isFinite ? proposed : 304, 280), max(280, available - 265))
    }
    private func columnTitle(_ column: ServiceDirectory.Sort) -> String {
        guard selectedID != nil else { return column.rawValue }
        switch column {
        case .visits: return "Visits"
        case .time: return "Time spent"
        default: return column.rawValue
        }
    }
    private func columnWidth(_ column: ServiceDirectory.Sort) -> CGFloat? {
        switch column {
        case .name: return nil
        case .type: return selectedID == nil ? 92 : 76
        case .category: return selectedID == nil ? 150 : 128
        case .visits: return selectedID == nil ? 98 : 76
        case .time: return selectedID == nil ? 132 : 110
        }
    }
    private func validateFilters() {
        if kind == nil { typeFilter = "" }
        if categoryID == nil { categoryFilter = "" }
    }
}

/// Two-axis scroll views otherwise begin centered on older macOS releases.
private struct DirectoryScrollAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.defaultScrollAnchor(.topLeading) }
        else { content }
    }
}
