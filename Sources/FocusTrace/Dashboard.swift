import AppKit
import SwiftUI
import TrackingCore

enum DashboardSection: String, CaseIterable {
    case overview = "Overview", activity = "Activity"
    var icon: String { self == .overview ? "chart.bar.xaxis" : "list.bullet" }
}

struct Dashboard: View {
    @ObservedObject var tracker: Tracker
    @State private var section: DashboardSection = .overview
    @State private var date = Date()
    @State private var period: ActivityPeriod = .day
    @State private var search = ""
    @State private var showingSettings = false
    @State private var showingAdd = false
    @State private var showingCalendar = false
    @State private var detail: Source?
    @State private var detailInterval: DateInterval?
    @AppStorage("sourceFilter") private var sourceFilter = "all"
    @AppStorage("distractingOnly") private var distractingOnly = false
    @AppStorage("sourceSort") private var sourceSort = "time"
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.66, green: 0.60, blue: 0.94) : Color(red: 0.47, green: 0.39, blue: 0.77) }
    private var interval: DateInterval { period.interval(containing: date) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let error = tracker.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.callout).padding(16).textSelection(.enabled)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        periodControls
                        if section == .overview {
                            let sources = tracker.sources.filter(\.isDistracting)
                            let report = PeriodActivity(ledger: tracker.ledger, coverage: tracker.coverage,
                                                        period: period, date: date, includedServices: Set(sources.map(\.id)))
                            OverviewView(report: report, ledger: tracker.ledger, sources: sources, accent: accent,
                                         onSelect: showDetail, onShowActivity: {
                                section = .activity; distractingOnly = false; sourceFilter = "all"; search = ""
                            })
                        } else {
                            let sources = tracker.sources.filter {
                                (!distractingOnly || $0.isDistracting) && (sourceFilter == "all" || $0.kind.rawValue == sourceFilter)
                            }
                            let report = DayActivity(ledger: tracker.ledger, interval: interval,
                                                     includedServices: Set(sources.map(\.id)))
                            Picker("Activity scope", selection: $distractingOnly) {
                                Text("All activity").tag(false)
                                Text("Distractions").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                            SourceListView(sources: sources, report: report, search: $search,
                                           sourceFilter: $sourceFilter, sourceSort: sourceSort, accent: accent,
                                           onSelect: { showDetail($0, interval: interval) }, onAdd: { showingAdd = true },
                                           onSetDistracting: tracker.setDistracting)
                        }
                    }
                    .frame(maxWidth: AppLayout.contentWidth)
                    .padding(AppLayout.pageInset)
                    .frame(maxWidth: .infinity)
                }
            }.background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 620).tint(accent)
        .disabled(dialogIsPresented).accessibilityHidden(dialogIsPresented)
        .overlay {
            if dialogIsPresented { DialogOverlay(width: dialogWidth, dismiss: dismissDialog) { dialogContent } }
        }
        .onChange(of: dialogIsPresented) { presented in
            if presented { showingCalendar = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private func showDetail(_ source: Source, interval: DateInterval) { detail = source; detailInterval = interval }
    private var dialogIsPresented: Bool { showingSettings || showingAdd || detail != nil || tracker.actionError != nil }
    private var dialogWidth: CGFloat {
        if tracker.actionError != nil { return 430 }
        if showingSettings { return 490 }
        return showingAdd ? 430 : 560
    }
    private func dismissDialog() {
        if tracker.actionError != nil { tracker.actionError = nil; return }
        showingSettings = false; showingAdd = false; detail = nil; detailInterval = nil
    }
    @ViewBuilder private var dialogContent: some View {
        if let error = tracker.actionError {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Could not complete action").font(AppType.dialogTitle); Spacer(); DialogCloseButton(action: dismissDialog) }
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(AppLayout.pageInset).frame(width: 430)
        } else if showingSettings {
            PreferencesView(tracker: tracker, dismiss: dismissDialog)
        } else if showingAdd {
            AddSourceView(tracker: tracker, dismiss: dismissDialog)
        } else if let source = detail {
            VisitDetail(tracker: tracker, source: source, day: detailInterval ?? interval,
                        distractingOnly: section == .overview || distractingOnly,
                        sourceFilter: section == .overview ? "all" : sourceFilter, dismiss: dismissDialog)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandIcon().frame(width: 20, height: 20)
                Text("FocusTrace").font(AppType.title)
            }.padding(.horizontal, 8).frame(height: AppLayout.toolbarHeight)
            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases, id: \.self) { item in
                    Button { section = item; search = "" } label: {
                        SidebarLabel(title: item.rawValue, icon: item.icon)
                            .font(.system(size: 13, weight: section == item ? .medium : .regular))
                            .background(section == item ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(QuietButtonStyle())
                }
            }.padding(.top, 12)
            Spacer(minLength: AppLayout.sectionGap)
            Button { showingSettings = true } label: { SidebarLabel(title: "Settings", icon: "gearshape").font(AppType.body) }
                .buttonStyle(QuietButtonStyle()).keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.bottom, 12).frame(width: 160)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(section.rawValue).font(AppType.title)
            Spacer()
            if section == .activity {
                Button { showingAdd = true } label: {
                    Label("Add distraction", systemImage: "plus").padding(.horizontal, 8).frame(height: AppLayout.controlHeight)
                }.buttonStyle(QuietButtonStyle()).keyboardShortcut("n", modifiers: .command)
                Menu {
                    Picker("Show", selection: $sourceFilter) {
                        Text("All sources").tag("all"); Text("Apps").tag("app"); Text("Websites").tag("website")
                    }
                    Picker("Sort by", selection: $sourceSort) {
                        Text("Time spent").tag("time"); Text("Visits").tag("visits"); Text("Name").tag("name")
                    }
                } label: { Label("Display", systemImage: "slider.horizontal.3") }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            Menu { Button("Export all records…", action: tracker.exportCSV) } label: {
                Image(systemName: "ellipsis").frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
        }
        .font(AppType.body).frame(maxWidth: AppLayout.contentWidth).padding(.horizontal, AppLayout.pageInset)
        .frame(maxWidth: .infinity).frame(height: AppLayout.toolbarHeight)
    }
    private var periodControls: some View {
        HStack {
            Picker("Time range", selection: $period) {
                ForEach(ActivityPeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 242)
            Spacer(minLength: 16)
            HStack(spacing: 3) {
                Button { movePeriod(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                }.help("Previous \(period.rawValue.lowercased())").accessibilityLabel("Previous period")
                Button { showingCalendar.toggle() } label: {
                    Text(periodLabel).monospacedDigit().frame(minWidth: 104, minHeight: 28).contentShape(Rectangle())
                }.popover(isPresented: $showingCalendar) {
                    VStack(spacing: 12) {
                        HStack { Text("Date").font(AppType.heading); Spacer(); DialogCloseButton { showingCalendar = false } }
                        DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden().fixedSize()
                        Button("Today") { date = Date(); showingCalendar = false }
                    }.padding(16).frame(width: 220)
                }
                Button { movePeriod(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                }.disabled(interval.end > Date()).help("Next \(period.rawValue.lowercased())").accessibilityLabel("Next period")
            }.buttonStyle(QuietButtonStyle()).font(AppType.caption).foregroundStyle(.secondary)
        }
    }
    private var periodLabel: String {
        let english = Locale(identifier: "en_US")
        switch period {
        case .day: return Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(english))
        case .week:
            let end = interval.end.addingTimeInterval(-1)
            return interval.start.formatted(.dateTime.month(.abbreviated).day().locale(english)) + " – " + end.formatted(.dateTime.month(.abbreviated).day().locale(english))
        case .month: return date.formatted(.dateTime.month(.wide).year().locale(english))
        case .year: return date.formatted(.dateTime.year())
        }
    }
    private func movePeriod(_ count: Int) {
        date = min(Date(), Calendar.current.date(byAdding: period.component, value: count, to: date)!)
    }
}
