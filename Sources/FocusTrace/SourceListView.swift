import SwiftUI
import TrackingCore

struct SourceListView: View {
    let sources: [Source]
    let report: DayActivity
    @Binding var search: String
    @Binding var sourceFilter: String
    let sourceSort: String
    let accent: Color
    let onSelect: (Source) -> Void
    let onAdd: () -> Void
    let onSetDistracting: (Source, Bool) -> Void

    private var rows: [Source] {
        sources.filter { source in
            (sourceFilter == "all" || source.kind.rawValue == sourceFilter) &&
                (search.isEmpty || source.name.localizedCaseInsensitiveContains(search) || source.identifier.localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            let a = report.statistics(for: lhs.id), b = report.statistics(for: rhs.id)
            if sourceSort == "time", a.seconds != b.seconds { return a.seconds > b.seconds }
            if sourceSort == "visits", a.visits != b.visits { return a.visits > b.visits }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let rows = rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(overviewTimeLabel(report.statistics.seconds)) recorded").font(AppType.body).foregroundStyle(.secondary)
                Spacer()
                SearchField(text: $search).frame(width: 176)
            }.padding(.bottom, 16)
            HStack(spacing: 16) {
                Text("App / Site"); Spacer()
                Text("Time").frame(width: 64, alignment: .trailing)
                Text("Visits").frame(width: 44, alignment: .trailing)
                Text("Distracting").frame(width: 80, alignment: .trailing)
            }.font(AppType.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows) { source in
                    let stats = report.statistics(for: source.id)
                    HStack(spacing: 16) {
                        Button { onSelect(source) } label: {
                            HStack(spacing: 16) {
                                SourceIcon(source: source)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(AppType.label).lineLimit(1)
                                    Text(source.kind == .website ? source.identifier : "Mac app")
                                        .font(AppType.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(overviewTimeLabel(stats.seconds)).frame(width: 64, alignment: .trailing)
                                Text("\(stats.visits)").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            }.font(AppType.body).monospacedDigit().frame(minHeight: 60).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button(source.isDistracting ? "Unmark distraction" : "Mark as distracting") { onSetDistracting(source, !source.isDistracting) }
                        }
                        Toggle("Distracting: \(source.name)", isOn: Binding(
                            get: { source.isDistracting }, set: { onSetDistracting(source, $0) }
                        )).labelsHidden().toggleStyle(.switch).frame(width: 80, alignment: .trailing)
                    }
                    Divider().opacity(0.6)
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "No services in this view" : "No matching services").font(AppType.label)
                    if search.isEmpty { Button("Add distraction", action: onAdd) }
                    else { Button("Clear search") { search = "" } }
                    if sourceFilter != "all" { Button("Show all types") { sourceFilter = "all" } }
                }.frame(maxWidth: .infinity).padding(.vertical, 48)
            }
        }
    }
}
