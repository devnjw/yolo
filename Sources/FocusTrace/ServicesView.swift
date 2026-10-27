import SwiftUI
import TrackingCore

struct ServicesView: View {
    @ObservedObject var tracker: Tracker
    let groups: [ServiceGroup]
    @Binding var search: String
    @State private var expandedID: String?

    var body: some View {
        let rows = groups.filter { $0.matches(search) }
        return VStack(alignment: .leading, spacing: 0) {
            SearchField(text: $search).frame(width: 238).padding(.bottom, 24)
            HStack {
                Spacer()
                Text("Category").font(AppType.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 10)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Button { expandedID = expandedID == group.id ? nil : group.id } label: {
                                HStack(spacing: 11) {
                                    SourceIcon(source: group.representative, size: 27)
                                    Text(group.name).font(AppType.body).lineLimit(1)
                                    Image(systemName: expandedID == group.id ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, minHeight: 51, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(QuietButtonStyle())
                                .accessibilityLabel(group.name)
                                .accessibilityValue(expandedID == group.id ? "Expanded" : "Collapsed")
                                .accessibilityHint("Show the apps and websites included in this service")
                            ServiceCategoryPicker(tracker: tracker, group: group)
                                .frame(maxWidth: 190, alignment: .trailing)
                        }
                        if expandedID == group.id {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(group.sources) { source in
                                    Label {
                                        Text(source.kind == .app ? "\(source.name) · Mac app" : source.identifier)
                                            .textSelection(.enabled)
                                    } icon: {
                                        Image(systemName: source.kind == .app ? "macwindow" : "globe").frame(width: 14)
                                    }.help(source.identifier)
                                    ForEach(source.aliases, id: \.self) { alias in
                                        Label(alias, systemImage: "globe").textSelection(.enabled)
                                    }
                                }
                                if group.sources.count > 1 || group.sources.contains(where: { !$0.aliases.isEmpty }) {
                                    Text("One category for this service.").padding(.top, 4)
                                }
                            }.font(AppType.caption).foregroundStyle(.secondary)
                                .padding(.leading, 38).padding(.top, 2).padding(.bottom, 18)
                        }
                    }
                    Divider().opacity(0.6)
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "Services appear here as you use them." : "No matching services.")
                        .font(AppType.body).foregroundStyle(.secondary)
                    if !search.isEmpty { Button("Clear search") { search = "" } }
                }.frame(maxWidth: .infinity).padding(.vertical, 48)
            }
        }
    }
}
