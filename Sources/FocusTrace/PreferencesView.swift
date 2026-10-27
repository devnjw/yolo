import AppKit
import SwiftUI
import TrackingCore

enum SettingsSection: String, CaseIterable {
    case general = "General", categories = "Categories", privacy = "Privacy & data"
}

struct PreferencesView: View {
    @ObservedObject var tracker: Tracker
    @StateObject private var loginItem = LoginItemController()
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button { selection = item } label: {
                        Text(item.rawValue)
                            .font(selection == item ? AppType.label : AppType.body)
                            .foregroundStyle(selection == item ? .primary : .secondary)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if selection == item { Rectangle().fill(Color.primary.opacity(0.65)).frame(height: 2) }
                            }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selection == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.overlay(alignment: .bottom) { Divider() }
                .frame(maxWidth: AppLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, AppLayout.pageInset).padding(.top, 12)
                .frame(maxWidth: .infinity)
            ScrollView {
                Group {
                    switch selection {
                    case .general: general
                    case .categories: CategoriesView(tracker: tracker)
                    case .privacy: privacy
                    }
                }.frame(maxWidth: AppLayout.contentWidth, alignment: .leading)
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 8).padding(.bottom, AppLayout.pageInset)
                    .frame(maxWidth: .infinity)
            }.id(selection)
        }.font(AppType.body)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow("Launch at login") {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if loginItem.needsApproval {
                HStack {
                    Text("Allow FocusTrace in Login Items to start automatically.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings", action: loginItem.openSystemSettings)
                }.font(AppType.caption).padding(.bottom, 16)
            }
            if let error = loginItem.error { Text(error).foregroundStyle(.red).padding(.bottom, 16) }
            Divider()
            Text("Tracking").font(AppType.heading).padding(.top, 20).padding(.bottom, 4)
                .help("All foreground apps are recorded automatically.")
            settingRow("Website tracking", detail: "Record sites separately from browser time.") {
                Toggle("Website tracking", isOn: $tracker.websitesEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if tracker.websitesEnabled {
                VStack(spacing: 0) {
                    ForEach(Browser.allCases) { browser in
                        Divider()
                        settingRow(browser.name, detail: tracker.enabledBrowsers.contains(browser)
                                   ? tracker.browserStatuses[browser] ?? "Access is requested when first used." : nil) {
                            if tracker.blockedBrowsers.contains(browser) { Button("Retry") { tracker.retryBrowser(browser) } }
                            Toggle(browser.name, isOn: Binding(
                                get: { tracker.enabledBrowsers.contains(browser) },
                                set: { tracker.setBrowser(browser, enabled: $0) }
                            )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                }.padding(.leading, 20)
                if tracker.enabledBrowsers.isEmpty {
                    Text("Select a browser to record individual sites.")
                        .font(AppType.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                }
            }
            Divider()
            settingRow("Exclude idle time after", detail: "Watching without keyboard or mouse input can count as idle.") {
                Picker("Exclude idle time after", selection: $tracker.idleMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("Never").tag(0)
                }.labelsHidden().frame(width: 120)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow("Export records", detail: "CSV · all dates and categories") {
                Button("Export all records…", action: tracker.exportCSV)
            }
            Divider()
            settingRow("Local storage", detail: "Records and settings are stored on this Mac.") {
                Button("Open data folder") { NSWorkspace.shared.open(tracker.dataURL.deletingLastPathComponent()) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy").font(AppType.heading).foregroundStyle(.primary)
                Text("Only source names and visit times are saved. Page contents, full URLs, and keystrokes are not recorded.")
                Text("Website icons are downloaded from public sites and cached locally. Browser cookies and visit records are never sent.")
                Text("Private browsing may be included. Foreground time is an estimate, not a measure of attention.")
            }.font(AppType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 20)
        }
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail { Text(detail).font(AppType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }.padding(.vertical, 12).frame(minHeight: 44)
    }
}
