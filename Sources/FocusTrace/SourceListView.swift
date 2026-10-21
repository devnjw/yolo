import SwiftUI
import TrackingCore

struct SourceListView: View {
    let sources: [Source]
    let report: DayActivity
    @Binding var section: DashboardSection
    @Binding var search: String
    @Binding var sourceFilter: String
    let sourceSort: String
    let accent: Color
    let onSelect: (Source) -> Void
    let onAdd: () -> Void
    let onRemove: (Source) -> Void

    private var rows: [Source] {
        sources.filter { source in
            let recorded = report.statistics(for: source.id)
            let included = section == .sources ? !source.archived : (!source.archived || recorded.seconds > 0 || recorded.visits > 0)
            return included && (sourceFilter == "all" || source.kind.rawValue == sourceFilter) &&
                (search.isEmpty || source.name.localizedCaseInsensitiveContains(search) || source.identifier.localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            if section == .overview {
                let a = report.statistics(for: lhs.id)
                let b = report.statistics(for: rhs.id)
                if sourceSort == "time", a.seconds != b.seconds { return a.seconds > b.seconds }
                if sourceSort == "visits", a.visits != b.visits { return a.visits > b.visits }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let stats = report.statistics
        let rows = rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                if section == .overview {
                    Text("Time by source").font(AppType.heading)
                } else {
                    Text("\(sources.filter { !$0.archived }.count) tracked").font(AppType.body).foregroundStyle(.secondary)
                }
                Spacer()
                SearchField(text: $search).frame(width: 176)
            }.padding(.bottom, 12)
            HStack(spacing: AppLayout.columnGap) {
                Text(sourceFilter == "all" ? "Source" : (sourceFilter == "app" ? "App" : "Website"))
                Spacer()
                if section == .overview {
                    Text("Visits").frame(width: AppLayout.visitsWidth, alignment: .trailing)
                    Text("Time · share").frame(width: AppLayout.usageWidth, alignment: .trailing)
                        .help("Share of time recorded across all tracked sources on this day.")
                } else { Text("Type").frame(width: 80, alignment: .trailing) }
            }.font(AppType.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows) { source in
                    let item = report.statistics(for: source.id)
                    Button { onSelect(source) } label: {
                        HStack(spacing: AppLayout.columnGap) {
                            HStack(spacing: 12) {
                                SourceIcon(source: source)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(AppType.label).lineLimit(1)
                                    Text(source.kind == .website ? source.identifier : "Mac app")
                                        .font(AppType.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if section == .overview {
                                Text("\(item.visits)").foregroundStyle(.secondary).frame(width: AppLayout.visitsWidth, alignment: .trailing)
                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(timeLabel(item.seconds))
                                        Text(shareLabel(stats.seconds > 0 ? item.seconds / stats.seconds : 0))
                                            .font(AppType.caption).foregroundStyle(.secondary)
                                            .frame(width: 40, alignment: .trailing)
                                    }.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    UsageBar(fraction: stats.seconds > 0 ? item.seconds / stats.seconds : 0, color: accent)
                                        .frame(width: AppLayout.usageWidth, height: 3)
                                }.frame(width: AppLayout.usageWidth, alignment: .trailing)
                            } else {
                                Text(source.kind == .app ? "App" : "Website").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                        }
                        .font(AppType.body).monospacedDigit()
                        .padding(.vertical, 12)
                        .frame(minHeight: AppLayout.rowHeight).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        if section == .sources, !source.archived {
                            Button("Remove source") { onRemove(source) }
                        }
                    }
                    Divider().opacity(0.6)
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "No sources" : "No matching sources").font(AppType.label)
                    if search.isEmpty, section == .sources {
                        Button("Add source") { onAdd() }
                    } else if search.isEmpty {
                        Button("Manage sources") { section = .sources }
                    } else {
                        Button("Clear search") { search = "" }
                    }
                    if sourceFilter != "all" { Button("Show all types") { sourceFilter = "all" } }
                }.frame(maxWidth: .infinity).padding(.vertical, 48)
            }
        }
    }

}
