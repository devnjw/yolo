import SwiftUI
import Charts
import TrackingCore

struct OverviewView: View {
    let report: PeriodActivity
    let ledger: Ledger
    let sources: [Source]
    let accent: Color
    let onSelect: (ServiceGroup, DateInterval) -> Void
    let onShowServices: () -> Void
    @State private var selection: Int?
    @State private var hover: Int?

    private var selectedBin: PeriodActivity.Bin? {
        report.bins.first { $0.id == selection }
    }
    private var listInterval: DateInterval {
        selectedBin.map { report.selectionInterval(for: $0) } ?? report.activity.interval
    }
    private var listReport: DayActivity {
        guard selectedBin != nil else { return report.activity }
        return DayActivity(ledger: ledger, interval: listInterval, includedServices: Set(sources.map(\.id)))
    }
    private var divisor: Double {
        selectedBin.map { report.period == .year ? Double(max(1, $0.denominator)) : 1 } ?? report.divisor
    }
    private var dailyAverage: Bool { selectedBin == nil ? report.period != .day : report.period == .year }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .firstTextBaseline, spacing: 48) {
                metric("Distracted time", value: overviewTimeLabel(report.seconds), primary: true,
                       help: "Recorded foreground time on services marked as distracting. " + averageHelp)
                metric("Visits", value: countLabel(report.visits), primary: false,
                       help: "Recorded visits to services marked as distracting. Switching into a source starts a visit; moving within it does not. " + averageHelp)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 30) {
                    timeline.frame(minWidth: 300)
                    ranking.frame(minWidth: 280)
                }
                VStack(alignment: .leading, spacing: 26) { timeline; ranking }
            }
        }
        .onChange(of: report.interval) { _ in selection = nil; hover = nil }
        .onChange(of: report.period) { _ in selection = nil; hover = nil }
    }

    private var averageHelp: String {
        report.period == .day ? "Idle and inactive screen time are excluded." :
        "Daily average across \(report.recordedDays) completed days with recording evidence, including days with zero distracting activity. Missing days and today are excluded. Historical data covers only the services recorded at the time."
    }

    private func metric(_ title: String, value: String, primary: Bool, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(AppType.label)
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }.foregroundStyle(primary ? Color.primary : Color.secondary).help(help)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(value).font(.system(size: primary ? 43 : 30, weight: .medium)).tracking(primary ? -1 : -0.5)
                if report.period != .day { Text("/ day").font(.system(size: 15)).foregroundStyle(.secondary) }
            }.monospacedDigit().frame(height: 52, alignment: .bottom)
        }.fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine).accessibilityHint(help)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                            BarMark(x: .value("Period", bin.id), y: .value("Minutes", seconds / 60))
                                .foregroundStyle(accent.opacity(selection == nil || selection == bin.id ? 0.85 : 0.35))
                                .cornerRadius(3)
                                .accessibilityLabel(binLabel(bin))
                                .accessibilityValue(overviewTimeLabel(seconds))
                        } else {
                            PointMark(x: .value("Period", bin.id), y: .value("Minutes", 0))
                                .symbol(.square).symbolSize(8).foregroundStyle(accent)
                                .accessibilityLabel(binLabel(bin) + ": zero distracting time")
                        }
                    } else if !bin.isFuture {
                        PointMark(x: .value("Period", bin.id), y: .value("Minutes", 0))
                            .symbol(.square).symbolSize(18).foregroundStyle(.secondary.opacity(0.4))
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
                            Text(binLabel(bin) + " · " + (bin.isFuture ? "Upcoming" : bin.seconds.map { overviewTimeLabel($0) + (report.period == .year ? " / day" : "") } ?? "No data"))
                                .font(.system(size: 11)).padding(6)
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
                            case .active(let point): hover = index(at: point, proxy: proxy, geometry: geometry)
                            case .ended: hover = nil
                            }
                        }
                }
            }
            .frame(height: 215)
            .accessibilityLabel(report.period == .year ? "Daily average distracted time by month" : "Distracted time by \(report.period == .day ? "hour" : "day")")
            .accessibilityRepresentation {
                VStack {
                    ForEach(report.bins.filter { !$0.isFuture }) { bin in
                        Button("\(binLabel(bin)), \(bin.seconds.map { overviewTimeLabel($0) + (report.period == .year ? " per day" : "") } ?? "No data")") {
                            selection = selection == bin.id ? nil : bin.id
                        }.accessibilityHint("Show services in this interval")
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
            if let bin = selectedBin {
                HStack {
                    Text(binLabel(bin)).font(AppType.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear selection") { selection = nil; hover = nil }.buttonStyle(.plain).font(AppType.caption)
                }.padding(.bottom, 10)
            }
            HStack(spacing: 12) {
                Spacer()
                Text("Time").frame(width: 72, alignment: .trailing)
                Text("Visits").frame(width: 56, alignment: .trailing)
            }.font(AppType.caption).foregroundStyle(.secondary).frame(height: 26, alignment: .top)
                .help(dailyAverage ? "Daily averages across recorded days in the selected range." : "Totals for the selected period.")
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
                        UsageBar(fraction: maximum > 0 ? stats.seconds / maximum : 0, color: accent)
                            .frame(height: 4).padding(.leading, 36)
                    }.padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("\(source.name), \(overviewTimeLabel(stats.seconds / divisor)), \(countLabel(Double(stats.visits) / divisor)) visits\(dailyAverage ? " per day" : "")")
                Divider().opacity(0.6)
            }
            if rows.isEmpty {
                Text((selectedBin.map { $0.seconds != nil } ?? report.hasData) ? "No distracting activity recorded." : "No data for this period.")
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
