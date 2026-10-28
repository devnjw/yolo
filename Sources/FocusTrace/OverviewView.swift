import SwiftUI
import Charts
import TrackingCore

struct OverviewView: View {
    private enum Breakdown: String, CaseIterable, Identifiable {
        case categories = "Categories", services = "Services"
        var id: String { rawValue }
    }

    let report: PeriodActivity
    let ledger: Ledger
    let sources: [Source]
    let catalog: CategoryCatalog
    let onSelectCategories: (Set<String>?) -> Void
    @AppStorage("overviewBreakdown") private var grouping: Breakdown = .categories
    @State private var selectedServiceID: String?
    @State private var selection: Int?
    @State private var hover: Int?
    @State private var hoverCategory: String?

    private var categoryMembers: [String: Set<Service>] {
        catalog.members(sources: sources, recordedIDs: Set(ledger.visits.map(\.service)))
    }
    private var includedSourceIDs: Set<Service> {
        catalog.includedSourceIDs(sources: sources, recordedIDs: Set(ledger.visits.map(\.service)))
    }
    private var showsCategoryBreakdown: Bool { grouping == .categories }

    private var selectedService: ServiceGroup? {
        guard !showsCategoryBreakdown else { return nil }
        return ServiceGrouping.groups(from: sources).first {
            $0.id == selectedServiceID && !$0.sourceIDs.isDisjoint(with: includedSourceIDs)
        }
    }
    private var chartBins: [PeriodActivity.Bin] {
        guard let service = selectedService else { return report.bins }
        return report.bins.map { $0.filtered(to: service.sourceIDs) }
    }
    private var displayedSeconds: Double? {
        guard let service = selectedService else { return report.seconds }
        return report.hasData ? report.activity.statistics(for: service.sourceIDs).seconds / report.divisor : nil
    }
    private var displayedVisits: Double? {
        guard let service = selectedService else { return report.visits }
        return report.hasData ? Double(report.activity.statistics(for: service.sourceIDs).visits) / report.divisor : nil
    }
    private var metricScope: String { selectedService.map { "for \($0.name)" } ?? "in the selected categories" }

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
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(alignment: .top, spacing: 28) {
                    summary(chartHeight: min(300, max(200, geometry.size.height - 220)))
                        .frame(width: (geometry.size.width - 57) * 0.48)
                    Divider().opacity(0.5)
                    breakdown
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        summary(chartHeight: 220)
                        VStack(alignment: .leading, spacing: 0) {
                            breakdownHeader
                            listHeading.padding(.top, 14).padding(.bottom, 8)
                            rankingRows
                        }
                    }.padding(.trailing, 8)
                        .background(OverlayScrollStyle())
                }
            }
        }
        .onChange(of: report.interval) { _ in selection = nil; hover = nil; hoverCategory = nil }
        .onChange(of: report.period) { _ in selection = nil; hover = nil; hoverCategory = nil }
        .onChange(of: catalog.selectedIDs) { _ in selectedServiceID = nil; hoverCategory = nil }
        .onChange(of: grouping) { _ in selectedServiceID = nil; hover = nil; hoverCategory = nil }
    }

    private func summary(chartHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            OverviewCategoryPicker(catalog: catalog, onSelect: onSelectCategories)
                .frame(height: 32, alignment: .leading)
            HStack(alignment: .top, spacing: 28) {
                metric("Time", value: overviewTimeLabel(displayedSeconds), primary: true,
                       help: "Recorded foreground time \(metricScope). " + averageHelp)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric("Visits", value: countLabel(displayedVisits), primary: false,
                       help: "Visits \(metricScope). Switching into an app or site starts a visit; moving within it does not. " + averageHelp)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            timeline(chartHeight: chartHeight)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var averageHelp: String {
        report.period == .day ? "Idle and inactive screen time are excluded." :
        "Daily average across \(report.recordedDays) completed days with recording evidence, including days with zero activity in the selected categories. Missing days and today are excluded. Historical data covers only the services recorded at the time."
    }

    private func metric(_ title: String, value: String, primary: Bool, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(AppType.caption)
                if !primary { Image(systemName: "info.circle").font(.system(size: 10)) }
            }.foregroundStyle(.secondary).frame(height: 18).help(help)
            Text(value).font(.system(size: primary ? 36 : 30, weight: .medium)).tracking(primary ? -1 : -0.5)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 44, alignment: .leading).help(help)
            if report.period != .day {
                Text("Daily average").font(AppType.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timeline(chartHeight: CGFloat) -> some View {
        let bins = chartBins
        let members = categoryMembers
        let segments = Dictionary(uniqueKeysWithValues: bins.map {
            ($0.id, $0.categorySegments(catalog.visibleCategories, members: members))
        })
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let service = selectedService {
                    HStack(spacing: 6) {
                        SourceIcon(source: service.representative, size: 16)
                        Text(service.name).font(AppType.heading).lineLimit(1)
                        Button { selectedServiceID = nil; hoverCategory = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 18)
                        }.buttonStyle(QuietButtonStyle()).help("Show all activity in the selected categories")
                            .accessibilityLabel("Clear service selection")
                    }.font(AppType.caption)
                } else { Text("Activity").font(AppType.heading) }
                Spacer()
                if report.period != .day, let seconds = displayedSeconds {
                    HStack(spacing: 5) {
                        Rectangle().fill(.secondary).frame(width: 14, height: 1)
                        Text("Avg \(overviewTimeLabel(seconds))")
                    }.font(AppType.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 20, alignment: .top)
            Chart {
                ForEach(bins) { bin in
                    if let seconds = bin.seconds {
                        if seconds > 0 {
                            ForEach(segments[bin.id] ?? []) { segment in
                                BarMark(x: .value("Period", bin.id),
                                        yStart: .value("Start minutes", segment.startSeconds / 60),
                                        yEnd: .value("End minutes", segment.endSeconds / 60))
                                    .cornerRadius(0)
                                    .clipShape(StackedBarShape(seconds: segment.seconds, end: segment.endSeconds,
                                                              total: segments[bin.id]?.last?.endSeconds ?? segment.endSeconds))
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
                if report.period != .day, let seconds = displayedSeconds {
                    RuleMark(y: .value("Daily average", seconds / 60))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let id = hover ?? selection, let bin = bins.first(where: { $0.id == id }) {
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
                AxisMarks(position: .leading, values: chartTicks) { value in
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
            .frame(height: chartHeight)
            .accessibilityLabel((report.period == .year ? "Daily average time by month" : "Time by \(report.period == .day ? "hour" : "day")") + (selectedService.map { ", for \($0.name)" } ?? ", stacked by category"))
            .accessibilityRepresentation {
                VStack {
                    ForEach(bins.filter { !$0.isFuture }) { bin in
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

    private var chartTicks: AxisMarkValues {
        report.period == .day ? .stride(by: 30.0) : .automatic(desiredCount: 3)
    }
    private var chartMaximum: Double {
        if report.period == .day { return 60 }
        return max(30, ceil(max(chartBins.compactMap(\.seconds).max() ?? 0, displayedSeconds ?? 0) / 60 / 30) * 30)
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

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            breakdownHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        rankingRows
                    } header: {
                        listHeading.padding(.top, 14).padding(.bottom, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                    }
                }.background(OverlayScrollStyle())
            }.id(grouping)
        }
    }

    private var breakdownHeader: some View {
        HStack(spacing: 4) {
            ForEach(Breakdown.allCases) { item in
                Button { grouping = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: grouping == item ? .semibold : .medium))
                        .foregroundStyle(grouping == item ? .primary : .secondary)
                        .padding(.horizontal, 12).frame(minWidth: 88, minHeight: 32)
                        .overlay(alignment: .bottom) {
                            if grouping == item {
                                Capsule().fill(Color.primary.opacity(0.85)).frame(height: 2)
                                    .padding(.horizontal, 12)
                            }
                        }.contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Show \(item.rawValue.lowercased())")
                    .accessibilityAddTraits(grouping == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }.accessibilityElement(children: .contain).accessibilityLabel("Group usage by")
    }

    @ViewBuilder private var rankingRows: some View {
        if showsCategoryBreakdown { categoryRanking } else { ranking }
    }

    private func rowDivider() -> some View {
        Divider().opacity(0.35).padding(.leading, 50).padding(.trailing, 12)
    }

    private func usageRow(name: String, seconds: Double?, visits: Double?, fraction: Double,
                          color: Color, icon: some View) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(AppType.body).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                UsageBar(fraction: fraction, color: color).frame(height: 3)
            }
            Text(overviewTimeLabel(seconds)).font(AppType.caption).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(countLabel(visits)).font(AppType.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var listHeading: some View {
        HStack(spacing: 12) {
            if let bin = selectedBin {
                HStack(spacing: 6) {
                    Text(binLabel(bin)).lineLimit(1)
                    Button { selection = nil; hover = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 18)
                    }.buttonStyle(QuietButtonStyle()).help("Clear selection").accessibilityLabel("Clear selection")
                }
            } else if catalog.selectedIDs != nil {
                Button { onSelectCategories(nil) } label: {
                    Label("All categories", systemImage: "chevron.left")
                }.buttonStyle(.plain).lineLimit(1)
            } else { Text("Name") }
            Spacer(minLength: 0)
            Text("Time").frame(width: 64, alignment: .trailing)
            Text("Visits").frame(width: 44, alignment: .trailing)
        }.font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 20)
            .padding(.horizontal, 12)
            .help(dailyAverage ? "Daily averages across recorded days in the selected range." : "Totals for the selected period.")
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
            ForEach(rows) { category in
                let stats = activity.statistics(for: members[category.id] ?? [])
                Button { onSelectCategories([category.id]); grouping = .services } label: {
                    usageRow(name: category.name, seconds: hasData ? stats.seconds / divisor : nil,
                             visits: hasData ? Double(stats.visits) / divisor : nil,
                             fraction: maximum > 0 ? stats.seconds / maximum : 0, color: category.color,
                             icon: Circle().fill(category.color).frame(width: 8, height: 8))
                }.buttonStyle(QuietButtonStyle()).accessibilityHint("Show services in \(category.name)")
                rowDivider()
            }
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
        let selectedID = selectedService?.id
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { source in
                let stats = activity.statistics(for: source.sourceIDs)
                Button {
                    selectedServiceID = selectedServiceID == source.id ? nil : source.id
                    hoverCategory = nil
                } label: {
                    usageRow(name: source.name, seconds: stats.seconds / divisor, visits: Double(stats.visits) / divisor,
                             fraction: maximum > 0 ? stats.seconds / maximum : 0,
                             color: catalog.category(for: source.id).color,
                             icon: SourceIcon(source: source.representative, size: 24))
                        .background(selectedID == source.id ? Color.primary.opacity(0.06) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("\(source.name), \(overviewTimeLabel(stats.seconds / divisor)), \(countLabel(Double(stats.visits) / divisor)) visits\(dailyAverage ? " per day" : "")")
                    .accessibilityAddTraits(selectedID == source.id ? .isSelected : [])
                    .accessibilityHint(selectedID == source.id ? "Show all activity in the selected categories" : "Show usage in the timeline")
                rowDivider()
            }
            if rows.isEmpty {
                Text((selectedBin.map { $0.seconds != nil } ?? report.hasData) ? "No activity recorded in the selected categories." : "No data for this period.")
                    .font(AppType.body).foregroundStyle(.secondary).padding(.vertical, 24)
            }
        }
    }
}

/// Clip each segment against the whole stack, so even a very thin top segment
/// shares the same rounded cap. Interior joins and the baseline stay square.
private struct StackedBarShape: Shape {
    let seconds: Double
    let end: Double
    let total: Double

    func path(in bounds: CGRect) -> Path {
        let scale = bounds.height / seconds
        let rect = CGRect(x: bounds.minX, y: bounds.minY - (total - end) * scale,
                          width: bounds.width, height: total * scale)
        let r = min(3, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
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
