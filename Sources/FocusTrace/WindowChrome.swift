import AppKit
import SwiftUI

/// Keep the toolbar item's width stable while the sidebar changes. Position its
/// contents during AppKit layout, before drawing, rather than feeding measured
/// coordinates back into SwiftUI state on a later run-loop turn.
struct ToolbarPageTitle: NSViewRepresentable {
    let title: String
    let systemImage: String
    let sidebarVisible: Bool

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ nsView: TitleView, context: Context) {
        nsView.update(title: title, systemImage: systemImage, sidebarVisible: sidebarVisible)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class TitleView: NSView {
        private let content = NSHostingView(rootView: TitleContent(title: "", systemImage: "chart.bar.xaxis"))
        private var title = ""
        private var systemImage = ""
        private var sidebarVisible = true

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(content)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var intrinsicContentSize: NSSize {
            // Reserve the expanded position in both states. The toolbar's
            // flexible space absorbs the unused width when the sidebar closes.
            NSSize(width: AppLayout.sidebarWidth + content.fittingSize.width,
                   height: AppLayout.controlHeight)
        }

        func update(title: String, systemImage: String, sidebarVisible: Bool) {
            if self.title != title || self.systemImage != systemImage {
                self.title = title
                self.systemImage = systemImage
                content.rootView = TitleContent(title: title, systemImage: systemImage)
                invalidateIntrinsicContentSize()
            }
            self.sidebarVisible = sidebarVisible
            needsLayout = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            positionTitle()
        }

        override func viewWillDraw() {
            // AppKit can also move the toolbar's ancestors (e.g. entering full
            // screen) without changing this item's size. Use the final origin.
            positionTitle()
            super.viewWillDraw()
        }

        private func positionTitle() {
            guard let contentView = window?.contentView, bounds.width > 0 else { return }
            let origin = convert(bounds, to: contentView).minX
            let leading = sidebarVisible ? max(8, AppLayout.sidebarWidth - origin) : 8
            let size = content.fittingSize
            content.frame = NSRect(x: leading, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height)
        }
    }

    private struct TitleContent: View {
        let title: String
        let systemImage: String

        var body: some View {
            HStack(spacing: 12) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 14).accessibilityHidden(true)
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
            }.fixedSize()
        }
    }
}

/// Match the native toolbar to the navigation surface. AppKit owns toolbar
/// hit testing, window dragging, double-click behavior and the system buttons.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            window.backgroundColor = AppSurface.chromeColor
        }
    }
}
