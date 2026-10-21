import AppKit

enum StatusBarIcon {
    // A vector template keeps the ring and dot crisp at any display scale,
    // while macOS supplies the color for the menu bar and selection state.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.5,
                           startAngle: 75, endAngle: 375, clockwise: false)
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.stroke()

            let dotCenter = 9 + 6.5 / sqrt(2)
            NSBezierPath(ovalIn: NSRect(x: dotCenter - 1.2, y: dotCenter - 1.2,
                                       width: 2.4, height: 2.4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FocusTrace"
        return image
    }()
}
