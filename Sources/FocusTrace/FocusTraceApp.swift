import AppKit
import SwiftUI

@main struct FocusTraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var tracker = Tracker.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    var body: some Scene {
        Window("FocusTrace", id: "dashboard") {
            DashboardScene(tracker: tracker, delegate: delegate)
        }
            .defaultSize(width: 980, height: 720)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(after: .sidebar) {
                    Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { sidebarVisible.toggle() }
                        .keyboardShortcut("s", modifiers: [.command, .control])
                }
            }
        MenuBarExtra {
            MenuContent(tracker: tracker)
        } label: {
            if tracker.storageError == nil {
                Image(nsImage: StatusBarIcon.image)
                    .accessibilityLabel("FocusTrace")
            } else {
                Label("FocusTrace — Storage error", systemImage: "exclamationmark.circle")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openDashboard: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Also updates the role when Launch Services cached an earlier menu-only build.
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openDashboard else { return true }
        openDashboard()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Tracker.shared.finish() }
    }
}

private struct DashboardScene: View {
    @ObservedObject var tracker: Tracker
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Dashboard(tracker: tracker)
            .onAppear {
                // Keep the scene action available after the last window is closed.
                delegate.openDashboard = {
                    openWindow(id: "dashboard")
                    DispatchQueue.main.async {
                        if let window = NSApp.windows.first(where: {
                            $0.identifier?.rawValue == "dashboard" || $0.title == "FocusTrace"
                        }) {
                            if window.isMiniaturized { window.deminiaturize(nil) }
                            window.makeKeyAndOrderFront(nil)
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }
}

struct MenuContent: View {
    @ObservedObject var tracker: Tracker
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(tracker.status)
        Divider()
        Button("Open FocusTrace") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit FocusTrace") { NSApp.terminate(nil) }
    }
}
