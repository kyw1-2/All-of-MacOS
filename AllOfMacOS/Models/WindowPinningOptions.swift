import Foundation
import CoreGraphics

/// AOM's live-window preferences. No pins or capture sessions survive a launch.
struct WindowPinningOptions: Codable, Equatable {
    enum Activation: String, Codable, CaseIterable {
        case hover, click, doubleClick
        var title: String {
            switch self { case .hover: return "Cursor Hover"; case .click: return "Click"; case .doubleClick: return "Double Click" }
        }
    }
    enum Corner: String, Codable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var title: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }
    var activation: Activation = .hover
    var corner: Corner = .topLeft
    var maximumFPS = 60 // 0 follows the display's refresh rate.
    var duckOverlappingWindows = true
    var translucentBorder = false
    var showUntitledWindows = true
    var excludedBundleIDs: [String] = []

    static let defaultsKey = "AOMWindowPinningOptionsV1"

    func allows(bundleID: String, title: String, ownPID: pid_t, pid: pid_t,
                layer: Int, frame: CGRect) -> Bool {
        pid != ownPID && pid > 0 && layer == 0 && frame.width > 40 && frame.height > 40 &&
        !excludedBundleIDs.contains(bundleID) && (showUntitledWindows || !title.isEmpty) &&
        !["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
          "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.screencaptureui"].contains(bundleID)
    }

    func frameRate(displayRate: Int) -> Int {
        let rate = max(1, displayRate)
        return maximumFPS == 0 ? rate : min(rate, max(1, maximumFPS))
    }
}

enum WindowPinningGeometry {
    /// Parking target for translucent pins (Topit's approach): the window sits
    /// a 2 pt sliver inside the desktop's left edge, off its original spot but
    /// still on-screen — a fully off-screen window stops receiving
    /// ScreenCaptureKit frames and the pin would freeze on its last image.
    static func parkTarget(original: CGRect, desktop: CGRect) -> CGPoint {
        CGPoint(x: desktop.minX - original.width + 2,
                y: min(max(original.minY, desktop.minY), desktop.maxY - original.height))
    }

    /// The conversion is its own inverse and preserves negative monitor origins.
    static func appKitFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func controls(in frame: CGRect, corner: WindowPinningOptions.Corner) -> CGRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? frame.minX + 5 : frame.maxX - 29,
                      y: top ? frame.maxY - 29 : frame.minY + 5, width: 24, height: 24)
    }

    static func pixelSize(_ size: CGSize, scale: CGFloat) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return CGSize(width: 2, height: 2) }
        let factor = min(scale, 7680 / max(size.width, size.height))
        return CGSize(width: max(2, ceil(size.width * factor)), height: max(2, ceil(size.height * factor)))
    }

    static func shouldDuck(_ frame: CGRect, activeFrame: CGRect?, enabled: Bool) -> Bool {
        guard enabled, let activeFrame else { return false }
        let overlap = frame.intersection(activeFrame)
        return !overlap.isNull && !overlap.isEmpty
    }
}
