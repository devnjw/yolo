import SwiftUI

/// Draw the small in-app mark at the display's native scale instead of
/// resampling a Dock icon representation and its fine raster highlights.
struct BrandIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing),
                                          lineWidth: size * 0.022)
                    }
                    .padding(size * 0.07)
                BrandRing()
                    .stroke(.white, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.09, height: size * 0.09)
                    .position(x: size * (0.5 + 0.25 / sqrt(2)),
                              y: size * (0.52 - 0.25 / sqrt(2)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct BrandRing: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + size * 0.52),
                    radius: size * 0.25, startAngle: .degrees(-20),
                    endAngle: .degrees(285), clockwise: false)
        return path
    }
}
