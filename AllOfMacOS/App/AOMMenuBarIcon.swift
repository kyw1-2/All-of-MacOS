import AppKit

/// AOM's own menu bar mark: a trackpad with four fingertips that grow along a
/// rising curve — the swipe from the app icon, caught mid-gesture. Drawn in
/// code so it stays sharp at every scale, and returned as template images so
/// the menu bar tints it for light, dark and tinted backgrounds.
enum AOMMenuBarIcon {
    enum State: CaseIterable {
        case active, paused, disabled

        var accessibilityDescription: String {
            switch self {
            case .active: return "All of MacOS"
            case .paused: return "All of MacOS, triggers paused"
            case .disabled: return "All of MacOS, triggers off"
            }
        }
    }

    static let size = NSSize(width: 20, height: 16)

    /// Fingertip centres and diameters on the 20 × 16 canvas (bottom-left origin).
    static let fingertips: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
        (4.9, 5.5, 1.6), (8.0, 7.9, 2.0), (11.4, 9.6, 2.35), (15.0, 10.5, 2.7)
    ]

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    /// Geometry is in points on the 20 × 16 canvas and scales with `rect`.
    static func draw(_ state: State, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / size.width, yBy: rect.height / size.height)
        transform.concat()
        NSColor.black.set()

        let trackpad = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.75, width: 17.5, height: 12.5), xRadius: 3.6, yRadius: 3.6)
        trackpad.lineWidth = 1.5
        trackpad.stroke()

        switch state {
        case .active:
            drawFingertips()
        case .paused:
            for x in [7.35, 10.75] as [CGFloat] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 4.75, width: 1.9, height: 6.5), xRadius: 0.95, yRadius: 0.95).fill()
            }
        case .disabled:
            NSColor.black.withAlphaComponent(0.38).set()
            drawFingertips()
            NSColor.black.set()
            // SF Symbols-style slash: a clear gap first, then the stroke.
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3.2, y: 15.0))
            slash.line(to: NSPoint(x: 16.8, y: 1.0))
            slash.lineCapStyle = .round
            context.compositingOperation = .clear
            slash.lineWidth = 3.4
            slash.stroke()
            context.compositingOperation = .sourceOver
            slash.lineWidth = 1.5
            slash.stroke()
        }
    }

    private static func drawFingertips() {
        for tip in fingertips {
            NSBezierPath(ovalIn: NSRect(x: tip.x - tip.diameter / 2, y: tip.y - tip.diameter / 2,
                                        width: tip.diameter, height: tip.diameter)).fill()
        }
    }
}
