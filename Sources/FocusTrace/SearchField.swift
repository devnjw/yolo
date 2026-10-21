import AppKit
import SwiftUI

/// Search is opt-in: opening a window or dismissing a dialog must not start editing.
struct SearchField: View {
    @Binding var text: String
    @State private var focusRequest = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .frame(width: 14)
                .foregroundStyle(.secondary).accessibilityHidden(true)
            SearchTextField(text: $text, focusRequest: focusRequest)
                .frame(maxWidth: .infinity).frame(height: 18)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: AppLayout.controlHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .font(AppType.body)
        .padding(.horizontal, 8)
        .frame(height: AppLayout.controlHeight)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusRequest += 1 }
    }
}

private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> ExplicitSearchField {
        let field = ExplicitSearchField()
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isBordered = false
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search sources")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: ExplicitSearchField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = context.environment.isEnabled
        if field.stringValue != text { field.stringValue = text }
        if !field.isEnabled { field.endSearchEditing() }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.beginSearchEditing()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest = 0
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? ExplicitSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? ExplicitSearchField)?.allowsExplicitFocus = false
        }
    }
}

private final class ExplicitSearchField: NSTextField {
    fileprivate var allowsExplicitFocus = false
    private var mouseMonitor: Any?

    override var acceptsFirstResponder: Bool { allowsExplicitFocus && super.acceptsFirstResponder }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        beginSearchEditing()
        super.mouseDown(with: event)
    }

    fileprivate func beginSearchEditing() {
        guard isEnabled, currentEditor() == nil else { return }
        allowsExplicitFocus = true
        window?.makeFirstResponder(self)
    }

    // Assistive technology can explicitly focus search without a physical click.
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { allowsExplicitFocus = true }
        super.setAccessibilityFocused(focused)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard window != nil else { return }
        // Observe only this app's clicks and pass them through, so the first
        // outside click both ends search editing and activates its destination.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.endSearchEditing()
            return event
        }
    }

    fileprivate func endSearchEditing() {
        allowsExplicitFocus = false
        if currentEditor() != nil { window?.makeFirstResponder(nil) }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
}
