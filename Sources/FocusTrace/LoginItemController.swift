import Combine
import ServiceManagement

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    // The system is the source of truth, including changes in System Settings.
    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        error = nil
        refresh()
        do {
            if enabled {
                if needsApproval {
                    openSystemSettings()
                    return
                }
                if !isEnabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = "Could not update launch at login. \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
