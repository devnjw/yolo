import SwiftUI

struct UsageMetric: View {
    let title: String
    let value: String
    let caption: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppType.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: compact ? 22 : 28, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            if !caption.isEmpty {
                Text(caption).font(AppType.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }.accessibilityHidden(true)
    }
}
