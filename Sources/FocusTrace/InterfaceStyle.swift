import SwiftUI

/// Shared rhythm for the dashboard, source lists, and dialogs.
enum AppLayout {
    static let pageInset: CGFloat = 24
    static let contentWidth: CGFloat = 1200
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 28
    static let sidebarWidth: CGFloat = 192
    static let columnGap: CGFloat = 16
    static let visitsWidth: CGFloat = 64
    static let usageWidth: CGFloat = 144
    static let rowHeight: CGFloat = 60
}

enum AppSurface {
    static let chromeColor = NSColor(name: NSColor.Name("FocusTraceChrome")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.075, alpha: 1)
            : NSColor(calibratedWhite: 0.95, alpha: 1)
    }
    static let chrome = Color(nsColor: chromeColor)
    static let content = Color(nsColor: .controlBackgroundColor)
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
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isEnabled
                        ? (configuration.isPressed ? 0.12 : hovering ? 0.08 : 0) : 0))
            }
            .onHover { hovering = $0 }
    }
}

struct SidebarLabel: View {
    let title: String
    let icon: String
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 10)
        .foregroundStyle(selected ? .primary : .secondary)
        .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
