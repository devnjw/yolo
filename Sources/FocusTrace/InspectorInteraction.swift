import AppKit
import SwiftUI

/// The divider has a generous hit area while retaining a one-point visual rule.
struct InspectorDivider: View {
    let width: CGFloat
    let resize: (CGFloat) -> Void
    let finish: () -> Void
    @State private var origin: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(Color.primary.opacity(hovering || origin != nil ? 0.3 : 0.12))
            .frame(width: 1).frame(width: 25)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(ResizeCursor())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("service-directory"))
                .onChanged { value in
                    if origin == nil { origin = width }
                    resize((origin ?? width) - value.translation.width)
                }
                .onEnded { _ in origin = nil; finish() })
            .accessibilityElement()
            .accessibilityLabel("Resize service details")
            .accessibilityValue("\(Int(width)) points wide")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(width + 24)
                case .decrement: resize(width - 24)
                @unknown default: return
                }
                finish()
            }
            .help("Drag to resize service details")
    }
}

private struct ResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}

/// End only this inspector's field editing. Observe clicks without swallowing
/// them, so a single click can both dismiss focus and activate another control.
struct InspectorFocusDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {}
    static func dismantleNSView(_ view: FocusView, coordinator: ()) { view.stopObserving() }

    final class FocusView: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      let field = editor.delegate as? NSTextField,
                      self.bounds.intersects(self.convert(field.bounds, from: field)),
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopObserving() }
    }
}
