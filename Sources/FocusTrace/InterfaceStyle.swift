import SwiftUI

/// Shared rhythm for the dashboard, source lists, and dialogs.
enum AppLayout {
    static let pageInset: CGFloat = 24
    static let contentWidth: CGFloat = 1200
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 56
    static let sidebarWidth: CGFloat = 184
    static let columnGap: CGFloat = 16
    static let visitsWidth: CGFloat = 64
    static let usageWidth: CGFloat = 144
    static let rowHeight: CGFloat = 60
}

enum AppType {
    static let title = Font.system(size: 14, weight: .semibold)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let dialogTitle = Font.system(size: 18, weight: .semibold)
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.35)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isEnabled && (hovering || configuration.isPressed) ? 0.07 : 0))
            }
            .onHover { hovering = $0 }
    }
}

struct SidebarLabel: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
