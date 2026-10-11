import AppKit
import CoreGraphics

/// Geometry-only placement engine. Negative origins (a display to the left),
/// external displays and portrait monitors are all normal Cartesian coordinates.
enum QuickAccessGeometry {
    struct Display: Equatable {
        let id: UInt32
        let visibleFrame: CGRect
        let fullFrame: CGRect

        init(id: UInt32, visibleFrame: CGRect, fullFrame: CGRect? = nil) {
            self.id = id
            self.visibleFrame = visibleFrame
            self.fullFrame = fullFrame ?? visibleFrame
        }
    }

    static func targetDisplay(_ displays: [Display], preferredID: UInt32?,
                              pointer: CGPoint?, followPointer: Bool) -> Display? {
        guard !displays.isEmpty else { return nil }
        if let preferredID, let found = displays.first(where: { $0.id == preferredID }) {
            return found
        }
        if followPointer, let pointer,
           let found = displays.first(where: { $0.fullFrame.contains(pointer) }) {
            return found
        }
        // If a monitor was disconnected, the overlay should be reachable on
        // the remaining main screen, not stranded at the removed coordinates.
        return displays.first
    }

    static func frame(visible: CGRect, card: CGSize, corner: OverlayCorner,
                      index: Int, count: Int, margin: CGFloat = 20) -> CGRect {
        let width = min(max(1, card.width), max(1, visible.width))
        let height = min(max(1, card.height), max(1, visible.height))
        let maxInset = min(margin, max(0, (visible.width - width) / 2),
                          max(0, (visible.height - height) / 2))
        let x = corner.isLeft ? visible.minX + maxInset : visible.maxX - width - maxInset
        let stride = QuickAccessPolicy.stackStride(
            visibleHeight: visible.height, cardHeight: height,
            count: count, margin: maxInset)
        let amount = CGFloat(max(0, index)) * stride
        let proposedY = corner.isTop ? visible.maxY - height - maxInset - amount
                                     : visible.minY + maxInset + amount
        let y = min(visible.maxY - height, max(visible.minY, proposedY))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func id(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func currentDisplays() -> [Display] {
        NSScreen.screens.map { screen in
            Display(id: id(for: screen) ?? 0, visibleFrame: screen.visibleFrame,
                    fullFrame: screen.frame)
        }
    }
}
