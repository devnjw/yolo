import AppKit
import SwiftUI
import TrackingCore

enum DashboardSection: String, CaseIterable {
    case overview = "Overview", services = "Services", settings = "Settings"
    var icon: String {
        switch self {
        case .overview: return "chart.bar.xaxis"
        case .services: return "square.3.layers.3d"
        case .settings: return "gearshape"
        }
    }
}

struct Dashboard: View {
    @ObservedObject var tracker: Tracker
    @State private var section: DashboardSection = .overview
    @State private var date = Date()
    @State private var period: ActivityPeriod = .day
    @State private var search = ""
    @State private var settingsSection: SettingsSection = .general
    @State private var showingAdd = false
    @State private var showingCalendar = false
    @State private var detail: ServiceGroup?
    @State private var detailInterval: DateInterval?
    @State private var detailSourceIDs: Set<Service> = []
    private var accent: Color { CategoryPalette.color(.purple) }
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
                if section == .settings {
                    PreferencesView(tracker: tracker, selection: $settingsSection)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if section == .overview {
                                periodControls
                                let sources = tracker.sources
                                let included = tracker.categories.includedSourceIDs(sources: sources, recordedIDs: Set(tracker.ledger.visits.map(\.service)))
                                let report = PeriodActivity(ledger: tracker.ledger, coverage: tracker.coverage,
                                                            period: period, date: date, includedServices: included)
                                OverviewView(report: report, ledger: tracker.ledger, sources: sources, catalog: tracker.categories, accent: accent,
                                             onSelectCategories: tracker.selectCategories,
                                             onSelect: showDetail, onShowServices: {
                                    section = .services; search = ""
                                })
                            } else {
                                ServicesView(tracker: tracker, groups: ServiceGrouping.groups(from: tracker.sources), search: $search)
                            }
                        }
                        .frame(maxWidth: AppLayout.contentWidth)
                        .padding(AppLayout.pageInset)
                        .frame(maxWidth: .infinity)
                    }.id(section)
                }
            }.background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 620).tint(accent)
        .disabled(dialogIsPresented).accessibilityHidden(dialogIsPresented)
        .overlay {
            if dialogIsPresented { DialogOverlay(width: dialogWidth, dismiss: dismissDialog) { dialogContent } }
        }
        .onChange(of: section) { _ in
            showingCalendar = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: dialogIsPresented) { presented in
            if presented { showingCalendar = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private func showDetail(_ group: ServiceGroup, interval: DateInterval) {
        detail = group; detailInterval = interval
        detailSourceIDs = tracker.categories.includedSourceIDs(sources: tracker.sources, recordedIDs: Set(tracker.ledger.visits.map(\.service)))
    }
    private var dialogIsPresented: Bool { showingAdd || detail != nil || tracker.actionError != nil }
    private var dialogWidth: CGFloat {
        if tracker.actionError != nil { return 430 }
        return showingAdd ? 430 : 560
    }
    private func dismissDialog() {
        if tracker.actionError != nil { tracker.actionError = nil; return }
        showingAdd = false; detail = nil; detailInterval = nil
    }
    @ViewBuilder private var dialogContent: some View {
        if let error = tracker.actionError {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Could not complete action").font(AppType.dialogTitle); Spacer(); DialogCloseButton(action: dismissDialog) }
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(AppLayout.pageInset).frame(width: 430)
        } else if showingAdd {
            AddSourceView(tracker: tracker, dismiss: dismissDialog)
        } else if let group = detail {
            VisitDetail(tracker: tracker, group: group, day: detailInterval ?? interval, includedServices: detailSourceIDs, dismiss: dismissDialog)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandIcon().frame(width: 20, height: 20)
                Text("FocusTrace").font(AppType.title)
            }.padding(.horizontal, 8).frame(height: AppLayout.toolbarHeight)
            VStack(spacing: 4) {
                ForEach([DashboardSection.overview, .services], id: \.self) { item in
                    Button { section = item; search = "" } label: {
                        SidebarLabel(title: item.rawValue, icon: item.icon)
                            .font(.system(size: 13, weight: section == item ? .medium : .regular))
                            .background(section == item ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(QuietButtonStyle())
                }
            }.padding(.top, 12)
            Spacer(minLength: AppLayout.sectionGap)
            Button { section = .settings } label: {
                SidebarLabel(title: "Settings", icon: "gearshape")
                    .font(.system(size: 13, weight: section == .settings ? .medium : .regular))
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
                .accessibilityAddTraits(section == .settings ? .isSelected : [])
        }
        .padding(.horizontal, 12).padding(.bottom, 12).frame(width: 160)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(section.rawValue).font(AppType.title)
            Spacer()
            if section == .services {
                Menu {
                    Button("Add service…") { showingAdd = true }.keyboardShortcut("n", modifiers: .command)
                    Button("Manage categories…") { settingsSection = .categories; section = .settings }
                } label: {
                    Image(systemName: "ellipsis").frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight).contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
            }
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
