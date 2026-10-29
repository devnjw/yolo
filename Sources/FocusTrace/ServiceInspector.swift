import SwiftUI
import TrackingCore

/// An inspector stays alongside the directory; edits never expand table rows.
struct ServiceInspector: View {
    @ObservedObject var tracker: Tracker
    let group: ServiceGroup
    let groups: [ServiceGroup]
    let select: (String) -> Void
    let dismiss: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var merging = false
    @State private var mergeSearch = ""
    @State private var destinationID: String?
    @State private var mergedName = ""
    @State private var mergedCategoryID = ""
    @State private var showingMergeCategories = false
    @State private var splittingID: Service?
    @State private var splitName = ""

    private var destination: ServiceGroup? { groups.first { $0.id == destinationID && $0.id != group.id } }
    private var splitSource: Source? { group.sources.first { $0.id == splittingID } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usage: UsageTotals { total(for: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(merging ? "Merge services" : "Service details").font(AppType.heading)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle()).help("Close service details")
                    .accessibilityLabel("Close service details")
            }.frame(height: 50)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(AppType.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("service-inspector-top")
                        if merging { mergeEditor }
                        else { details }
                    }.padding(.bottom, 20).padding(.trailing, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OverlayScrollStyle(controlSize: .small))
                }
                .onChange(of: merging) { _ in proxy.scrollTo("service-inspector-top", anchor: .top) }
                .onChange(of: destinationID) { _ in proxy.scrollTo("service-inspector-top", anchor: .top) }
            }
        }.font(AppType.body)
            .background(InspectorFocusDismissal())
            .onAppear { name = group.name }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                SourceIcon(source: group.representative, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(AppType.heading).lineLimit(2).textSelection(.enabled)
                    Text(ServiceDirectory.Kind(group: group).rawValue)
                        .font(AppType.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Name")
                HStack(spacing: 8) {
                    TextField("Service name", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Service name").onSubmit(saveName)
                    Button("Save", action: saveName)
                        .disabled(trimmedName.isEmpty || trimmedName == group.name || tracker.storageError != nil)
                }
            }
            HStack {
                fieldLabel("Category")
                Spacer()
                ServiceCategoryPicker(tracker: tracker, group: group)
                    .disabled(tracker.storageError != nil)
            }
            HStack(spacing: 28) {
                metric("Total visits", value: usage.visits.formatted())
                metric("Total time spent", value: overviewTimeLabel(usage.seconds))
            }
            if group.sources.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Apps & websites").font(AppType.heading)
                        Spacer()
                        Text("\(group.sources.count)").foregroundStyle(.secondary)
                    }
                    ForEach(group.sources) { source in member(source) }
                    Text("Separate an app or website to give it its own service and usage totals.")
                        .font(AppType.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Button {
                merging = true; error = nil; splittingID = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                    Text("Merge with another service…")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle())
                .disabled(groups.count < 2 || tracker.storageError != nil)
        }
    }

    private func member(_ source: Source) -> some View {
        let usage = tracker.ledger.lifetimeTotals[source.id] ?? UsageTotals()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                SourceIcon(source: source, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ServiceGrouping.sourceName(for: source)).lineLimit(2).textSelection(.enabled)
                    Text(source.kind == .app ? source.identifier : "Website")
                        .font(AppType.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                Text(tracker.storageError == nil ? "\(usage.visits.formatted()) \(usage.visits == 1 ? "visit" : "visits") · \(overviewTimeLabel(usage.seconds))" : "Usage unavailable")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                if group.sources.count > 1 {
                    Button {
                        splittingID = source.id
                        splitName = ServiceGrouping.sourceName(for: source)
                        error = nil
                    } label: {
                        Text("Separate…").padding(.horizontal, 7).frame(height: 28).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("Separate \(ServiceGrouping.sourceName(for: source))")
                        .disabled(tracker.storageError != nil)
                }
            }.font(AppType.caption).padding(.leading, 30)
            if !source.aliases.isEmpty {
                Text("Aliases: " + source.aliases.joined(separator: ", "))
                    .font(AppType.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .help("These aliases share one recorded source and cannot be separated into historical usage totals.")
            }
            if splittingID == source.id { splitEditor }
        }.padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var splitEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            fieldLabel("New service name")
            TextField("New service name", text: $splitName).textFieldStyle(.roundedBorder)
                .accessibilityLabel("New service name")
            Text("Keeps the \(tracker.categories.category(for: group.id).name) category and its own usage history.")
                .font(AppType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { splittingID = nil; error = nil }
                Button("Separate", action: split)
                    .disabled(splitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tracker.storageError != nil)
            }
        }
    }

    private var mergeEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                merging = false; destinationID = nil; mergeSearch = ""; error = nil
            } label: {
                Label("Back to details", systemImage: "chevron.left").padding(.horizontal, 6).frame(height: 28)
            }.buttonStyle(QuietButtonStyle())
            Text("Merge \(group.name) with…").font(AppType.heading).fixedSize(horizontal: false, vertical: true)
            if let destination {
                HStack(spacing: 8) {
                    SourceIcon(source: destination.representative, size: 24)
                    Text(destination.name).lineLimit(2)
                    Spacer()
                    Button("Change") { destinationID = nil; error = nil }
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Merged service name")
                    TextField("Merged service name", text: $mergedName).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Merged service name")
                }
                mergeCategoryPicker
                if tracker.categories.categoryID(for: group.id) != tracker.categories.categoryID(for: destination.id) {
                    Text("These services have different categories. Choose one for the combined service.")
                        .font(AppType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                let combined = usage + total(for: destination)
                Text("\(group.sources.count + destination.sources.count) apps & websites")
                    .font(AppType.heading)
                HStack(spacing: 20) {
                    metric("Total visits", value: combined.visits.formatted())
                    metric("Total time spent", value: overviewTimeLabel(combined.seconds))
                }
                Text("All recorded usage will appear under this name and category. You can separate individual apps and websites later.")
                    .font(AppType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Merge services", action: merge).buttonStyle(.borderedProminent)
                    .disabled(mergedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mergedCategoryID.isEmpty || tracker.storageError != nil)
            } else {
                TextField("Search services", text: $mergeSearch).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search merge targets")
                let candidates = groups.filter { $0.id != group.id && $0.matches(mergeSearch) }
                if candidates.isEmpty {
                    Text("No matching services.").foregroundStyle(.secondary).padding(.vertical, 12)
                }
                LazyVStack(spacing: 2) {
                    ForEach(candidates) { candidate in
                        Button { choose(candidate) } label: {
                            HStack(spacing: 8) {
                                SourceIcon(source: candidate.representative, size: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.name).lineLimit(1)
                                    Text(candidate.representative.identifier).font(AppType.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(QuietButtonStyle()).accessibilityLabel("Merge with \(candidate.name)")
                    }
                }
            }
        }
    }

    private var mergeCategoryPicker: some View {
        HStack {
            fieldLabel("Category")
            Spacer()
            Button { showingMergeCategories.toggle() } label: {
                HStack(spacing: 7) {
                    if let category = tracker.categories.options.first(where: { $0.id == mergedCategoryID }) {
                        CategoryLabel(category: category)
                    } else { Text("Choose a category") }
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }.font(AppType.caption).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle()).accessibilityLabel("Merged service category")
                .accessibilityValue(mergedCategoryID.isEmpty ? "Choose a category" : tracker.categories.category(id: mergedCategoryID).name)
                .popover(isPresented: $showingMergeCategories) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(tracker.categories.options) { category in
                                Button { mergedCategoryID = category.id; showingMergeCategories = false } label: {
                                    HStack {
                                        CategoryLabel(category: category)
                                        Spacer()
                                        if mergedCategoryID == category.id { Image(systemName: "checkmark") }
                                    }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                                }.buttonStyle(QuietButtonStyle())
                            }
                        }.padding(8).background(OverlayScrollStyle())
                    }.frame(width: 230, height: min(320, CGFloat(tracker.categories.options.count * 34 + 16)))
                }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(AppType.caption).foregroundStyle(.secondary)
    }
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            Text(tracker.storageError == nil ? value : "—").font(.system(size: 18, weight: .medium)).monospacedDigit()
        }
    }
    private func total(for group: ServiceGroup) -> UsageTotals {
        group.sourceIDs.reduce(UsageTotals()) { $0 + (tracker.ledger.lifetimeTotals[$1] ?? UsageTotals()) }
    }
    private func saveName() {
        guard trimmedName != group.name else { return }
        do { try tracker.renameService(group.id, to: name); name = trimmedName; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func choose(_ candidate: ServiceGroup) {
        destinationID = candidate.id; mergedName = candidate.name; error = nil
        let sourceCategory = tracker.categories.categoryID(for: group.id)
        mergedCategoryID = sourceCategory == tracker.categories.categoryID(for: candidate.id) ? sourceCategory : ""
    }
    private func merge() {
        guard let destination else { return }
        do {
            try tracker.mergeService(group.id, into: destination.id, name: mergedName, categoryID: mergedCategoryID)
            select(destination.id)
        } catch { self.error = error.localizedDescription }
    }
    private func split() {
        guard let source = splitSource else { return }
        do {
            let id = try tracker.splitServiceMember(source, from: group.id, name: splitName)
            select(id)
        } catch { self.error = error.localizedDescription }
    }
}
