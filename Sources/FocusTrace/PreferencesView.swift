import AppKit
import SwiftUI
import TrackingCore

private struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var tracker: Tracker
    @StateObject private var loginItem = LoginItemController()
    let dismiss: () -> Void
    @State private var privacyExpanded = false
    @State private var advancedExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(AppType.dialogTitle)
                Spacer()
                DialogCloseButton(action: dismiss)
            }.padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack(alignment: .top) {
                        Text("Allow FocusTrace in Login Items to start automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings", action: loginItem.openSystemSettings)
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("All foreground apps are recorded automatically. Website tracking separates browser time into individual sites.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Website tracking", isOn: $tracker.websitesEnabled)
                if tracker.websitesEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Browser.allCases) { browser in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(browser.name, isOn: Binding(
                                    get: { tracker.enabledBrowsers.contains(browser) },
                                    set: { tracker.setBrowser(browser, enabled: $0) }
                                ))
                                if tracker.enabledBrowsers.contains(browser) {
                                    HStack(alignment: .top) {
                                        Text(tracker.browserStatuses[browser] ?? "Access is requested when first used.")
                                            .font(AppType.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if tracker.blockedBrowsers.contains(browser) {
                                            Spacer()
                                            Button("Retry") { tracker.retryBrowser(browser) }
                                        }
                                    }.padding(.leading, 20)
                                }
                            }
                        }
                    }.padding(.leading, 20)
                    if tracker.enabledBrowsers.isEmpty {
                        Text("Select a browser to track websites. Otherwise, its time is recorded as app activity.")
                            .font(AppType.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Exclude idle time after", selection: $tracker.idleMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("Never").tag(0)
                    }
                    Text("Watching without keyboard or mouse input can count as idle.")
                        .font(AppType.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
            Divider()
            DisclosureGroup("Privacy & data", isExpanded: $privacyExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Source names and visit times stay on this Mac. Page contents, full URLs, and keystrokes are not saved.")
                    Text("Website icons are discovered from public homepages, downloaded from their icon URLs, and cached on this Mac. Browser cookies and visit records are never sent.")
                    Text("Private browsing may be included. Foreground time is an estimate, not a measure of attention.")
                    Button("Open data folder") { NSWorkspace.shared.open(tracker.dataURL.deletingLastPathComponent()) }
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            }
        }.font(AppType.body)
            .disclosureGroupStyle(SettingsDisclosureStyle())
            .padding(AppLayout.pageInset).frame(width: 490)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItem.refresh()
            }
    }
}
