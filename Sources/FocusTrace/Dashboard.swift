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
    @State private var hoveringPeriod = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    private var accent: Color { CategoryPalette.color(.purple) }
    private var interval: DateInterval { period.interval(containing: date) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if sidebarVisible { sidebar }
                content
                    .background(AppSurface.content)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, sidebarVisible ? 0 : 8)
                    .padding(.trailing, 8).padding(.bottom, 8)
            }
        }
        .background(AppSurface.chrome)
        .background(WindowChrome())
        .toolbar { toolbar }
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

    private var content: some View {
        VStack(spacing: 0) {
            if let error = tracker.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).padding(16).textSelection(.enabled)
            }
            if section == .settings {
                PreferencesView(tracker: tracker, selection: $settingsSection)
            } else if section == .overview {
                let sources = tracker.sources
                let included = tracker.categories.includedSourceIDs(sources: sources, recordedIDs: Set(tracker.ledger.visits.map(\.service)))
                let report = PeriodActivity(ledger: tracker.ledger, coverage: tracker.coverage,
                                            period: period, date: date, includedServices: included)
                OverviewView(report: report, ledger: tracker.ledger, sources: sources, catalog: tracker.categories,
                             onSelectCategories: tracker.selectCategories)
                    .frame(maxWidth: AppLayout.contentWidth)
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 8).padding(.bottom, AppLayout.pageInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ServicesView(tracker: tracker, groups: ServiceGrouping.groups(from: tracker.sources), search: $search)
                        .frame(maxWidth: AppLayout.contentWidth)
                        .padding(.horizontal, AppLayout.pageInset)
                        .padding(.top, 8).padding(.bottom, AppLayout.pageInset)
                        .frame(maxWidth: .infinity)
                        .background(OverlayScrollStyle())
                }.id(section)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dialogIsPresented: Bool { showingAdd || tracker.actionError != nil }
    private var dialogWidth: CGFloat { 430 }
    private func dismissDialog() {
        if tracker.actionError != nil { tracker.actionError = nil; return }
        showingAdd = false
    }
    @ViewBuilder private var dialogContent: some View {
        if let error = tracker.actionError {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Could not complete action").font(AppType.dialogTitle); Spacer(); DialogCloseButton(action: dismissDialog) }
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(AppLayout.pageInset).frame(width: 430)
        } else if showingAdd {
            AddSourceView(tracker: tracker, dismiss: dismissDialog)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                ForEach([DashboardSection.overview, .services], id: \.self) { item in
                    Button { section = item; search = "" } label: {
                        SidebarLabel(title: item.rawValue, icon: item.icon, selected: section == item)
                    }.buttonStyle(QuietButtonStyle())
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer(minLength: AppLayout.sectionGap)
            Button { section = .settings } label: {
                SidebarLabel(title: "Settings", icon: "gearshape", selected: section == .settings)
            }.buttonStyle(QuietButtonStyle()).keyboardShortcut(",", modifiers: .command)
                .accessibilityAddTraits(section == .settings ? .isSelected : [])
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 16)
        .frame(width: AppLayout.sidebarWidth)
        .accessibilityElement(children: .contain).accessibilityLabel("Sidebar")
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
                .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
                .disabled(dialogIsPresented)
        }
        ToolbarItem(placement: .navigation) {
            ToolbarPageTitle(title: section.rawValue, systemImage: section.icon, sidebarVisible: sidebarVisible)
                .fixedSize()
        }
        ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 0) {
                if section == .overview { periodControls }
                if section == .services {
                    Menu {
                        Button("Add service…") { showingAdd = true }.keyboardShortcut("n", modifiers: .command)
                        Button("Manage categories…") { settingsSection = .categories; section = .settings }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
                }
            }.font(AppType.body).disabled(dialogIsPresented)
        }
    }
    private var periodControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ActivityPeriod.allCases) { item in
                    Button { period = item } label: {
                        if period == item { Label(item.rawValue, systemImage: "checkmark") }
                        else { Text(item.rawValue) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(period.rawValue)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                }.padding(.horizontal, 10)
                    .frame(minWidth: 84, minHeight: AppLayout.controlHeight)
                    .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(hoveringPeriod ? 0.08 : 0))
                }
                .onHover { hoveringPeriod = $0 }
                .accessibilityLabel("Time range").accessibilityValue(period.rawValue)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 14)
            HStack(spacing: 3) {
                Button { movePeriod(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                }.help("Previous \(period.rawValue.lowercased())").accessibilityLabel("Previous period")
                Button { showingCalendar.toggle() } label: {
                    Text(periodLabel).monospacedDigit().lineLimit(1).frame(width: 128, height: 28).contentShape(Rectangle())
                }.popover(isPresented: $showingCalendar) {
                    DateSelectionPopover(date: date) { selected in
                        date = selected
                        showingCalendar = false
                    }
                }
                Button { movePeriod(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                }.disabled(interval.end > Date()).help("Next \(period.rawValue.lowercased())").accessibilityLabel("Next period")
            }.buttonStyle(QuietButtonStyle()).font(AppType.caption).foregroundStyle(.secondary)
        }.fixedSize()
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
