import AppKit
import SwiftUI
import TrackingCore

enum DashboardSection: String, CaseIterable {
    case overview = "Overview", sources = "Sources"
    var icon: String { self == .overview ? "chart.bar.xaxis" : "square.stack.3d.up" }
}

struct Dashboard: View {
    @ObservedObject var tracker: Tracker
    @State private var section: DashboardSection = .overview
    @State private var date = Date()
    @State private var search = ""
    @State private var showingSettings = false
    @State private var showingAdd = false
    @State private var showingCalendar = false
    @State private var detail: Source?
    @AppStorage("showTimeline") private var showTimeline = true
    @AppStorage("sourceFilter") private var sourceFilter = "all"
    @AppStorage("distractingOnly") private var distractingOnly = false
    @AppStorage("sourceSort") private var sourceSort = "time"
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.66, green: 0.65, blue: 0.98) : Color(red: 0.36, green: 0.34, blue: 0.76) }
    private var day: DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }
    var body: some View {
        let visibleSources = tracker.sources.filter {
            (!distractingOnly || $0.isDistracting) && (sourceFilter == "all" || $0.kind.rawValue == sourceFilter)
        }
        let includedServices = distractingOnly || sourceFilter != "all" ? Set(visibleSources.map(\.id)) : nil
        let report = DayActivity(ledger: tracker.ledger, interval: day, includedServices: includedServices)
        return HStack(spacing: 0) {
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
                    VStack(alignment: .leading, spacing: AppLayout.sectionGap) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Activity scope", selection: $distractingOnly) {
                                Text("All activity").tag(false)
                                Text("Distractions only").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                            Text(section == .sources
                                 ? "Apps and sites are added automatically. Select the services that distract you."
                                 : (distractingOnly ? "Showing activity for services you marked as distracting." : "Showing recorded foreground activity."))
                                .font(AppType.caption).foregroundStyle(.secondary)
                        }
                        if section == .overview {
                            OverviewView(report: report, sources: visibleSources, distractingOnly: distractingOnly,
                                         showTimeline: showTimeline, accent: accent) { detail = $0 }
                        }
                        SourceListView(sources: visibleSources, report: report, section: $section,
                                       search: $search, sourceFilter: $sourceFilter, sourceSort: sourceSort,
                                       accent: accent, onSelect: { detail = $0 },
                                       onAdd: { showingAdd = true }, onSetDistracting: tracker.setDistracting)
                    }
                    .frame(maxWidth: AppLayout.contentWidth)
                    .padding(AppLayout.pageInset)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 620)
        .tint(accent)
        .disabled(dialogIsPresented)
        .accessibilityHidden(dialogIsPresented)
        .overlay {
            if dialogIsPresented {
                DialogOverlay(width: dialogWidth, dismiss: dismissDialog) { dialogContent }
            }
        }
        .onChange(of: dialogIsPresented) { presented in
            if presented {
                showingCalendar = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var dialogIsPresented: Bool {
        showingSettings || showingAdd || detail != nil || tracker.actionError != nil
    }

    private var dialogWidth: CGFloat {
        if tracker.actionError != nil { return 430 }
        if showingSettings { return 490 }
        return showingAdd ? 430 : 560
    }

    private func dismissDialog() {
        if tracker.actionError != nil { tracker.actionError = nil; return }
        showingSettings = false
        showingAdd = false
        detail = nil
    }

    @ViewBuilder private var dialogContent: some View {
        if let error = tracker.actionError {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Could not complete action").font(AppType.dialogTitle)
                    Spacer()
                    DialogCloseButton(action: dismissDialog)
                }
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(AppLayout.pageInset).frame(width: 430)
        } else if showingSettings {
            PreferencesView(tracker: tracker, dismiss: dismissDialog)
        } else if showingAdd {
            AddSourceView(tracker: tracker, dismiss: dismissDialog)
        } else if let source = detail {
            VisitDetail(tracker: tracker, source: source, day: day, distractingOnly: distractingOnly,
                        sourceFilter: sourceFilter, dismiss: dismissDialog)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandIcon().frame(width: 20, height: 20)
                Text("FocusTrace").font(AppType.title)
            }
            .padding(.horizontal, 8)
            .frame(height: AppLayout.toolbarHeight)

            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases, id: \.self) { item in
                    Button {
                        section = item; search = ""
                    } label: {
                        SidebarLabel(title: item.rawValue, icon: item.icon)
                            .font(.system(size: 13, weight: section == item ? .medium : .regular))
                            .background(section == item ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(QuietButtonStyle())
                }
            }.padding(.top, 12)
            Spacer(minLength: AppLayout.sectionGap)
            Button { showingSettings = true } label: {
                SidebarLabel(title: "Settings", icon: "gearshape").font(AppType.body)
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: AppLayout.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(section.rawValue).font(AppType.title)
            Spacer()
            if section == .overview {
                HStack(spacing: 0) {
                    Button { moveDay(-1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight).contentShape(Rectangle())
                    }
                        .help("Previous day").accessibilityLabel("Previous day")
                    Button { showingCalendar.toggle() } label: {
                        Text(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US"))))
                            .monospacedDigit()
                            .frame(width: 60, height: AppLayout.controlHeight).contentShape(Rectangle())
                    }
                    .popover(isPresented: $showingCalendar) {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Date").font(AppType.heading)
                                Spacer()
                                DialogCloseButton { showingCalendar = false }
                            }
                            DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.graphical).labelsHidden().fixedSize()
                            Button("Today") { date = Date(); showingCalendar = false }
                        }.padding(16).frame(width: 200)
                    }
                    Button { moveDay(1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight).contentShape(Rectangle())
                    }
                        .disabled(Calendar.current.isDateInToday(date))
                        .help("Next day").accessibilityLabel("Next day")
                }.buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary)
            } else {
                Button { showingAdd = true } label: {
                    Label("Add distraction", systemImage: "plus")
                        .frame(height: AppLayout.controlHeight).padding(.horizontal, 8).contentShape(Rectangle())
                }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut("n", modifiers: .command)
            }
            Menu {
                Picker("Show", selection: $sourceFilter) {
                    Text("All sources").tag("all")
                    Text("Apps").tag("app")
                    Text("Websites").tag("website")
                }
                if section == .overview {
                    Picker("Sort by", selection: $sourceSort) {
                        Text("Time spent").tag("time")
                        Text("Visits").tag("visits")
                        Text("Name").tag("name")
                    }
                    Divider()
                    Toggle("Timeline", isOn: $showTimeline)
                }
            } label: {
                Label("Display", systemImage: "slider.horizontal.3")
                    .padding(.horizontal, 8).frame(height: AppLayout.controlHeight).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            Menu {
                Button("Export all records…", action: tracker.exportCSV)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight).contentShape(Rectangle())
            }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More options")
        }
        .font(AppType.body)
        .frame(maxWidth: AppLayout.contentWidth)
        .padding(.horizontal, AppLayout.pageInset)
        .frame(maxWidth: .infinity)
        .frame(height: AppLayout.toolbarHeight)
    }

    private func moveDay(_ count: Int) { date = Calendar.current.date(byAdding: .day, value: count, to: date)! }
}
