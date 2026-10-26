import AppKit
import SwiftUI
import TrackingCore

struct VisitDetail: View {
    @ObservedObject var tracker: Tracker
    let source: Source
    let day: DateInterval
    let distractingOnly: Bool
    let sourceFilter: String
    let dismiss: () -> Void
    private var activity: DayActivity {
        let services = Set(tracker.sources.filter {
            (!distractingOnly || $0.isDistracting) && (sourceFilter == "all" || $0.kind.rawValue == sourceFilter)
        }.map(\.id))
        return DayActivity(ledger: tracker.ledger, interval: day,
                           includedServices: distractingOnly || sourceFilter != "all" ? services : nil)
    }

    var body: some View {
        let item = activity.sources[source.id]
        let visits = item?.visits ?? []
        let stats = item?.statistics ?? .zero
        let longest = item?.longestSeconds ?? 0
        return VStack(alignment: .leading, spacing: AppLayout.sectionGap) {
            HStack(spacing: 12) {
                SourceIcon(source: source)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(AppType.dialogTitle)
                    Text(source.kind == .website ? source.identifier : "Mac app")
                        .font(AppType.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                DialogCloseButton(action: dismiss)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(dayLabel(day.start)).font(AppType.label).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 20) {
                    UsageMetric(title: "Time spent", value: timeLabel(stats.seconds), caption: "\(shareLabel(item?.timeShare ?? 0)) of time in this view", compact: true)
                    UsageMetric(title: "Visits", value: "\(stats.visits)", caption: visits.contains(where: { $0.start < day.start }) ? "Excludes visits started earlier" : "", compact: true)
                    UsageMetric(title: "Longest visit", value: timeLabel(longest), caption: "", compact: true)
                        .help("The longest recorded visit, counting only time within this day.")
                }
                if stats.shortVisits > 0 {
                    Text("Quick checks · \(stats.shortVisits) of \(stats.visits) visits (30s or less)")
                        .font(AppType.body).foregroundStyle(.secondary)
                }
            }
            Divider()
            if visits.isEmpty {
                Text("No visits recorded for this day.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        SwiftUI.Section {
                            ForEach(visits) { visit in
                                visitRow(visit, longest: longest)
                                if visit.id != visits.last?.id { Divider().opacity(0.5) }
                            }
                        } header: {
                            HStack {
                                Text("Visit history")
                                Spacer()
                                Text("Duration")
                            }
                            .font(AppType.caption).foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }.frame(height: min(244, CGFloat(visits.count) * (AppLayout.rowHeight + 1) - 1 + 24))
            }
            Toggle("Mark as distracting", isOn: Binding(
                get: { tracker.source(for: source.id)?.isDistracting ?? false },
                set: {
                    tracker.setDistracting(source, enabled: $0)
                    if distractingOnly, !$0, tracker.actionError == nil { dismiss() }
                }
            ))
            Text("This selection filters past and future activity. All services continue to be recorded.")
                .font(AppType.caption).foregroundStyle(.secondary)
        }.padding(AppLayout.pageInset).frame(width: 560)
    }

    private func visitRow(_ visit: Visit, longest: Double) -> some View {
        let duration = visit.seconds(in: day)
        let isActive = visit.id == tracker.ledger.activeID
        let isLongest = duration > 30 && duration == longest
        let quick = !isActive && visit.duration <= 30
        let carriedOver = visit.start < day.start
        let continues = visit.end > day.end
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(clockLabel(max(visit.start, day.start))) – \(isActive ? "Now" : clockLabel(min(visit.end, day.end)))")
                        .font(AppType.label).monospacedDigit()
                    if isActive { Circle().fill(.green).frame(width: 5, height: 5) }
                }
                if carriedOver || continues {
                    Text(carriedOver ? "Continued from previous day" : "Continues into next day")
                        .font(AppType.caption).foregroundStyle(.secondary)
                } else if quick || isLongest {
                    Text(quick ? "Quick check" : "Longest visit")
                        .font(AppType.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Text(timeLabel(duration)).font(AppType.label).monospacedDigit()
                UsageBar(fraction: longest > 0 ? duration / longest : 0, color: .primary.opacity(0.5))
                    .frame(width: 110, height: 3)
            }
        }.frame(height: AppLayout.rowHeight)
            .help("\(visit.start.formatted(date: .abbreviated, time: .standard)) – \(visit.end.formatted(date: .abbreviated, time: .standard))")
            .accessibilityElement(children: .combine)
    }
}
