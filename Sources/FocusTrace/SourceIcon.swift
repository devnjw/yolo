import AppKit
import SwiftUI
import TrackingCore

struct SourceIcon: View {
    let source: Source
    var size: CGFloat = 32
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(3) }
            else {
                Image(systemName: source.kind == .website ? "globe" : "app")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
        .task(id: source.identifier) {
            icon = nil
            if source.kind == .app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.identifier) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            } else if source.kind == .website {
                let data = await WebsiteIconLoader.shared.icon(for: source.identifier)
                guard !Task.isCancelled else { return }
                icon = data.flatMap(NSImage.init(data:))
            }
        }
    }
}
