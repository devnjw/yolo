import AppKit
import SwiftUI

/// Attach inside a ScrollView's content so only its enclosing scroll view uses
/// native overlay indicators. Keep AppKit's scrolling, dragging and accessibility.
struct OverlayScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollStyleView { ScrollStyleView() }

    func updateNSView(_ nsView: ScrollStyleView, context: Context) {
        nsView.applyStyle()
    }

    final class ScrollStyleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyStyle()
        }

        override func layout() {
            super.layout()
            // SwiftUI configures its scroll view after attaching the content.
            // Reapply once that layout has reached the content's native view.
            applyStyle()
        }

        func applyStyle() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        }
    }
}
