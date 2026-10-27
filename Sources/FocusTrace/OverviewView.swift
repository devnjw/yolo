import SwiftUI
import Charts
import TrackingCore

struct OverviewView: View {
    let report: PeriodActivity
    let ledger: Ledger
    let sources: [Source]
    let catalog: CategoryCatalog
    let accent: Color
    let onSelectCategories: (Set<String>?) -> Void
    let onSelect: (ServiceGroup, DateInterval) -> Void
    let onShowServices: () -> Void
    @State private var selection: Int?
    @State private var hover: Int?
    @State private var hoverCategory: String?

    private var categoryMembers: [String: Set<Service>] {
        catalog.members(sources: sources, recordedIDs: Set(ledger.visits.map(\.service)))
    }
    private var includedSourceIDs: Set<Service> {
        catalog.includedSourceIDs(sources: sources, recordedIDs: Set(ledger.visits.map(\.service)))
    }
    private var showsCategoryBreakdown: Bool { catalog.selectedIDs?.count != 1 }

    private var selectedBin: PeriodActivity.Bin? {
        report.bins.first { $0.id == selection }
    }
    private var listInterval: DateInterval {
        selectedBin.map { report.selectionInterval(for: $0) } ?? report.activity.interval
    }
    private var listReport: DayActivity {
        guard selectedBin != nil else { return report.activity }
        return DayActivity(ledger: ledger, interval: listInterval, includedServices: includedSourceIDs)
    }
    private var divisor: Double {
        selectedBin.map { report.period == .year ? Double(max(1, $0.denominator)) : 1 } ?? report.divisor
    }
    private var dailyAverage: Bool { selectedBin == nil ? report.period != .day : report.period == .year }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .firstTextBaseline, spacing: 48) {
                metric("Time", value: overviewTimeLabel(report.seconds), primary: true,
                       help: "Recorded foreground time in the selected categories. " + averageHelp)
                metric("Visits", value: countLabel(report.visits), primary: false,
                       help: "Visits in the selected categories. Switching into an app or site starts a visit; moving within it does not. " + averageHelp)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 30) {
                    timeline.frame(minWidth: 300)
                    breakdown.frame(minWidth: 280)
                }
                VStack(alignment: .leading, spacing: 26) { timeline; breakdown }
            }
        }
        .onChange(of: report.interval) { _ in selection = nil; hover = nil; hoverCategory = nil }
        .onChange(of: report.period) { _ in selection = nil; hover = nil; hoverCategory = nil }
        .onChange(of: catalog.selectedIDs) { _ in hoverCategory = nil }
    }

    private var averageHelp: String {
        report.period == .day ? "Idle and inactive screen time are excluded." :
        "Daily average across \(report.recordedDays) completed days with recording evidence, including days with zero activity in the selected categories. Missing days and today are excluded. Historical data covers only the services recorded at the time."
    }

    private func metric(_ title: String, value: String, primary: Bool, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if primary {
                OverviewCategoryPicker(catalog: catalog, onSelect: onSelectCategories)
            } else {
                HStack(spacing: 6) {
                    Text(title).font(AppType.label)
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }.foregroundStyle(.secondary).help(help)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(value).font(.system(size: primary ? 43 : 30, weight: .medium)).tracking(primary ? -1 : -0.5)
                if report.period != .day { Text("/ day").font(.system(size: 15)).foregroundStyle(.secondary) }
            }.monospacedDigit().frame(height: 52, alignment: .bottom).help(help)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var timeline: some View {
        let members = categoryMembers
        let segments = Dictionary(uniqueKeysWithValues: report.bins.map {
            ($0.id, $0.categorySegments(catalog.visibleCategories, members: members))
        })
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if report.period != .day, let seconds = report.seconds {
                    HStack(spacing: 5) {
                        Rectangle().fill(.secondary).frame(width: 14, height: 1)
                        Text("Avg \(overviewTimeLabel(seconds))")
                    }.font(AppType.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 26, alignment: .top)
            Chart {
                ForEach(report.bins) { bin in
                    if let seconds = bin.seconds {
                        if seconds > 0 {
                            ForEach(segments[bin.id] ?? []) { segment in
                                BarMark(x: .value("Period", bin.id),
                                        yStart: .value("Start minutes", segment.startSeconds / 60),
                                        yEnd: .value("End minutes", segment.endSeconds / 60))
                                    .foregroundStyle(segment.category.color.opacity(selection == nil || selection == bin.id ? 1 : 0.3))
                                    .accessibilityLabel(binLabel(bin) + ", " + segment.category.name)
                                    .accessibilityValue(overviewTimeLabel(segment.seconds))
                            }
                        } else {
                            PointMark(x: .value("Period", bin.id), y: .value("Minutes", 0))
                                .symbol(.square).symbolSize(8).foregroundStyle(CategoryPalette.color(.gray))
                                .accessibilityLabel(binLabel(bin) + ": zero recorded time")
                        }
                    } else if !bin.isFuture {
                        PointMark(x: .value("Period", bin.id), y: .value("Minutes", 0))
                            .symbol(.square).symbolSize(18).foregroundStyle(CategoryPalette.color(.gray).opacity(0.4))
                            .accessibilityLabel(binLabel(bin) + ": no data")
                    }
                }
                if report.period != .day, let seconds = report.seconds {
                    RuleMark(y: .value("Daily average", seconds / 60))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let id = hover ?? selection, let bin = report.bins.first(where: { $0.id == id }) {
                    RuleMark(x: .value("Selected period", id))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, alignment: annotationAlignment(id)) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(binLabel(bin) + " · " + (bin.isFuture ? "Upcoming" : bin.seconds.map { overviewTimeLabel($0) + (report.period == .year ? " / day" : "") } ?? "No data"))
                                if hover == bin.id, let segment = segments[bin.id]?.first(where: { $0.id == hoverCategory }) {
                                    HStack(spacing: 12) {
                                        CategoryLabel(category: segment.category)
                                        Text(overviewTimeLabel(segment.seconds) + (report.period == .year ? " / day" : ""))
                                    }
                                }
                            }.font(.system(size: 11)).padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        }
                }
            }
            .chartXScale(domain: -0.5...Double(max(1, report.bins.count)) - 0.5)
            .chartYScale(domain: 0...chartMaximum)
            .chartXAxis {
                AxisMarks(values: axisIndices) { value in
                    AxisValueLabel(anchor: value.as(Int.self) == report.bins.count - 1 ? .topTrailing : value.as(Int.self) == 0 ? .topLeading : .top) {
                        if let i = value.as(Int.self), report.bins.indices.contains(i) { Text(axisLabel(report.bins[i])) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text("\(Int(minutes))m") }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            if let index = index(at: value.location, proxy: proxy, geometry: geometry), !report.bins[index].isFuture {
                                selection = selection == index ? nil : index
                            }
                        })
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hover = index(at: point, proxy: proxy, geometry: geometry)
                                let plot = geometry[proxy.plotAreaFrame]
                                let minutes: Double? = proxy.value(atY: point.y - plot.minY)
                                hoverCategory = hover.flatMap { id in
                                    guard let minutes else { return nil }
                                    return segments[id]?.first { $0.startSeconds <= minutes * 60 && minutes * 60 < $0.endSeconds }?.id
                                }
                            case .ended: hover = nil; hoverCategory = nil
                            }
                        }
                }
            }
            .frame(height: 215)
            .accessibilityLabel(report.period == .year ? "Daily average time by month, stacked by category" : "Time by \(report.period == .day ? "hour" : "day"), stacked by category")
            .accessibilityRepresentation {
                VStack {
                    ForEach(report.bins.filter { !$0.isFuture }) { bin in
                        Button("\(binLabel(bin)), \(bin.seconds.map { overviewTimeLabel($0) + (report.period == .year ? " per day" : "") } ?? "No data")") {
                            selection = selection == bin.id ? nil : bin.id
                        }.accessibilityValue((segments[bin.id] ?? []).map {
                            $0.category.name + ": " + overviewTimeLabel($0.seconds) + (report.period == .year ? " per day" : "")
                        }.joined(separator: ", "))
                            .accessibilityHint("Show activity in this interval")
                    }
                }
            }
            if report.bins.contains(where: { $0.seconds == nil && !$0.isFuture }) {
                Label("No data", systemImage: "square.dashed")
                    .font(AppType.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    private var chartMaximum: Double {
        max(30, ceil(max(report.bins.compactMap(\.seconds).max() ?? 0, report.period == .day ? 0 : report.seconds ?? 0) / 60 / 30) * 30)
    }
    private var axisIndices: [Int] {
        let count = report.bins.count
        if report.period == .week { return Array(0..<count) }
        let step = report.period == .day ? 6 : report.period == .month ? 7 : 3
        return Array(Set(Array(stride(from: 0, to: count, by: step)) + [max(0, count - 1)])).sorted()
    }
    private func axisLabel(_ bin: PeriodActivity.Bin) -> String {
        let date = bin.interval.start
        switch report.period {
        case .day: return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(Locale(identifier: "en_GB"))) + ":00"
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "en_US")))
        case .month: return date.formatted(.dateTime.day())
        case .year: return date.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "en_US")))
        }
    }
    private func binLabel(_ bin: PeriodActivity.Bin) -> String {
        if report.period == .day { return axisLabel(bin) }
        if report.period == .year { return bin.interval.start.formatted(.dateTime.month(.abbreviated).year().locale(Locale(identifier: "en_US"))) }
        return bin.interval.start.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    }
    private func annotationAlignment(_ id: Int) -> Alignment {
        id < report.bins.count / 3 ? .leading : id > report.bins.count * 2 / 3 ? .trailing : .center
    }
    private func index(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(point), let x: Double = proxy.value(atX: point.x - frame.minX) else { return nil }
        let index = Int(x.rounded())
        return report.bins.indices.contains(index) ? index : nil
    }

    @ViewBuilder private var breakdown: some View {
        if showsCategoryBreakdown { categoryRanking } else { ranking }
    }

    private var listHeading: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bin = selectedBin {
                HStack {
                    Text(binLabel(bin)).font(AppType.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear selection") { selection = nil; hover = nil }.buttonStyle(.plain).font(AppType.caption)
                }.padding(.bottom, 10)
            }
            HStack(spacing: 12) {
                if !showsCategoryBreakdown {
                    Button { onSelectCategories(nil) } label: {
                        Label("All categories", systemImage: "chevron.left")
                    }.buttonStyle(.plain).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Time").frame(width: 72, alignment: .trailing)
                Text("Visits").frame(width: 56, alignment: .trailing)
            }.font(AppType.caption).foregroundStyle(.secondary).frame(height: 26, alignment: .top)
                .help(dailyAverage ? "Daily averages across recorded days in the selected range." : "Totals for the selected period.")
        }
    }

    private var categoryRanking: some View {
        let activity = listReport
        let members = categoryMembers
        let rows = catalog.visibleCategories.sorted {
            let lhs = activity.statistics(for: members[$0.id] ?? []).seconds
            let rhs = activity.statistics(for: members[$1.id] ?? []).seconds
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
        }
        let maximum = rows.map { activity.statistics(for: members[$0.id] ?? []).seconds }.max() ?? 0
        let hasData = selectedBin.map { $0.seconds != nil } ?? report.hasData
        return VStack(alignment: .leading, spacing: 0) {
            listHeading
            ForEach(rows) { category in
                let stats = activity.statistics(for: members[category.id] ?? [])
                Button { onSelectCategories([category.id]) } label: {
                    VStack(spacing: 9) {
                        HStack(spacing: 12) {
                            CategoryLabel(category: category).font(AppType.body).frame(maxWidth: .infinity, alignment: .leading)
                            Text(overviewTimeLabel(hasData ? stats.seconds / divisor : nil)).fixedSize().frame(width: 72, alignment: .trailing)
                            Text(countLabel(hasData ? Double(stats.visits) / divisor : nil)).fixedSize().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }.font(AppType.caption).monospacedDigit()
                        UsageBar(fraction: maximum > 0 ? stats.seconds / maximum : 0, color: category.color)
                            .frame(height: 4).padding(.leading, 13)
                    }.padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle()).accessibilityHint("Show services in \(category.name)")
                Divider().opacity(0.6)
            }
            Button(action: onShowServices) {
                Label("Manage services", systemImage: "arrow.up.right").font(AppType.caption).foregroundStyle(.secondary).padding(.vertical, 14)
            }.buttonStyle(.plain)
        }
    }

    private var ranking: some View {
        let activity = listReport
        let rows = ServiceGrouping.groups(from: sources).filter {
            let stats = activity.statistics(for: $0.sourceIDs)
            return stats.seconds > 0 || stats.visits > 0
        }.sorted {
            let lhs = activity.statistics(for: $0.sourceIDs).seconds, rhs = activity.statistics(for: $1.sourceIDs).seconds
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
        }
        let maximum = rows.map { activity.statistics(for: $0.sourceIDs).seconds }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            listHeading
            ForEach(rows) { source in
                let stats = activity.statistics(for: source.sourceIDs)
                Button { onSelect(source, listInterval) } label: {
                    VStack(spacing: 9) {
                        HStack(spacing: 12) {
                            SourceIcon(source: source.representative, size: 24)
                            Text(source.name).font(AppType.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(overviewTimeLabel(stats.seconds / divisor)).fixedSize().frame(width: 72, alignment: .trailing)
                            Text(countLabel(Double(stats.visits) / divisor)).fixedSize().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }.font(AppType.caption).monospacedDigit()
                        UsageBar(fraction: maximum > 0 ? stats.seconds / maximum : 0, color: catalog.visibleCategories.first?.color ?? accent)
                            .frame(height: 4).padding(.leading, 36)
                    }.padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("\(source.name), \(overviewTimeLabel(stats.seconds / divisor)), \(countLabel(Double(stats.visits) / divisor)) visits\(dailyAverage ? " per day" : "")")
                Divider().opacity(0.6)
            }
            if rows.isEmpty {
                Text((selectedBin.map { $0.seconds != nil } ?? report.hasData) ? "No activity recorded in this category." : "No data for this period.")
                    .font(AppType.body).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            Button(action: onShowServices) {
                HStack(spacing: 5) { Text("Manage services"); Image(systemName: "arrow.up.right") }
                    .font(AppType.caption).foregroundStyle(.secondary).padding(.vertical, 14)
            }.buttonStyle(.plain)
        }
    }
}

func overviewTimeLabel(_ seconds: Double?) -> String {
    guard let seconds else { return "—" }
    if seconds > 0 && seconds < 60 { return "<1m" }
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 60 ? "\(minutes / 60)h" + (minutes % 60 > 0 ? " \(minutes % 60)m" : "") : "\(minutes)m"
}

func countLabel(_ value: Double?) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—"
}
