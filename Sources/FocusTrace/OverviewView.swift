import SwiftUI
import Charts
import TrackingCore

struct OverviewView: View {
    let report: DayActivity
    let sources: [Source]
    let showTimeline: Bool
    let accent: Color
    let onSelect: (Source) -> Void

    var body: some View {
        let stats = report.statistics
        return VStack(alignment: .leading, spacing: AppLayout.sectionGap) {
            HStack(alignment: .top, spacing: AppLayout.sectionGap) {
                UsageMetric(title: "Time spent", value: timeLabel(stats.seconds), caption: "On tracked apps & sites")
                    .help("Time tracked apps or websites were in the foreground. This is not total Mac usage.")
                UsageMetric(title: "Visits", value: "\(stats.visits)", caption: "Switches to tracked sources")
                    .help("Switching to a tracked app or website starts a visit. Moving within the same source does not.")
                UsageMetric(title: "Quick checks", value: "\(stats.shortVisits)", caption: "Visits of 30s or less")
                    .help("Completed visits lasting 30 seconds or less. A short visit does not necessarily mean a distraction.")
            }
            if report.mostTime != nil || report.mostVisits != nil {
                Divider()
                HStack(alignment: .top, spacing: AppLayout.sectionGap) {
                    sourceHighlight("Most time", service: report.mostTime, report: report, byTime: true)
                    sourceHighlight("Most visits", service: report.mostVisits, report: report, byTime: false)
                }
            }
            if showTimeline {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Time of day").font(AppType.label)
                        Spacer()
                        Text("Minutes per hour").font(AppType.caption).foregroundStyle(.secondary)
                    }
                    if stats.seconds > 0 {
                        let hours = report.hourlyTotals()
                        Chart(0..<24, id: \.self) { hour in
                            BarMark(x: .value("Hour", hour), y: .value("Minutes", hours[hour] / 60))
                                .foregroundStyle(accent.opacity(0.8)).cornerRadius(2)
                                .accessibilityLabel(String(format: "%02d:00", hour))
                                .accessibilityValue(timeLabel(hours[hour]))
                        }
                        .chartXScale(domain: -0.5...23.5)
                        .chartYScale(domain: 0...max(1, (hours.max() ?? 0) / 60))
                        .chartXAxis {
                            AxisMarks(values: [0, 6, 12, 18]) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let hour = value.as(Int.self) { Text(String(format: "%02d:00", hour)) }
                                }
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .frame(height: 110)
                        .accessibilityLabel("Time spent by hour, all tracked sources")
                    } else {
                        Text("No time recorded on tracked sources for this day.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    }
                }
            }
        }
    }

    private func sourceHighlight(_ title: String, service: Service?, report: DayActivity, byTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppType.caption).foregroundStyle(.secondary)
            if let service, let source = sources.first(where: { $0.id == service }),
               let item = report.sources[service] {
                Button { onSelect(source) } label: {
                    HStack(spacing: 12) {
                        SourceIcon(source: source)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(AppType.label).lineLimit(1)
                            Text(byTime
                                 ? "\(timeLabel(item.statistics.seconds)) · \(shareLabel(item.timeShare)) of tracked time"
                                 : "\(item.statistics.visits) \(item.statistics.visits == 1 ? "visit" : "visits") · \(timeLabel(item.statistics.seconds)) total")
                                .font(AppType.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).help("View visits for \(source.name)")
            } else {
                Text("No visits started this day").font(AppType.body).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}
