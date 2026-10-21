import SwiftUI

struct DialogCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: AppLayout.controlHeight, height: AppLayout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }
}

/// The backdrop consumes the dismissal click so it cannot activate dashboard controls.
struct DialogOverlay<Content: View>: View {
    let width: CGFloat
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 400

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                ScrollView {
                    content()
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(width: min(width, geometry.size.width - 32),
                       height: min(contentHeight, max(0, geometry.size.height - 48)))
                .modifier(DialogSurface())
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct DialogSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            .accessibilityElement(children: .contain)
    }
}
