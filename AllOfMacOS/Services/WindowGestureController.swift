import AppKit
import ApplicationServices
import SwiftUI

/// Routes the three-finger touch stream: window move/resize/snap goes to
/// SwishGestureSession (the faithful port), while the pinch verbs — maximize
/// toggle and the double-pinch minimize/restore — are detected here, because
/// they resolve on finger spread, not drag.
@MainActor
final class WindowGestureController: ObservableObject {
    static let shared = WindowGestureController()

    static let defaultsEnabledKey = "AOMWindowGesturesEnabled"
    static let defaultsEdgeKey = "AOMWindowGestureEdgeSize"
    static let defaultsModifierKey = "AOMWindowGestureRequireModifier"

    enum Edge: String, Equatable { case minX, maxX, minY, maxY }

    /// Test seams.
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The session that owns move/resize/snap; swapped in tests.
    var session: SwishGestureSession = .shared

    private var inGesture = false
    private var isPinch = false
    private var startCentroid: CGPoint = .zero
    private var startSpread: CGFloat = 0
    private var lastSpread: CGFloat = 0
    private var pinchCount = 0
    private var lastPinchAt: TimeInterval = 0
    private var minimizedDuringBatch: [WindowManager.Target] = []
    private var savedPreMaximize: CGRect?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true
    }
    var anyLayerEnabled: Bool { isEnabled }

    private var requiresModifier: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsModifierKey) as? Bool ?? false
    }

    // MARK: - Frame entry

    func observe(points: [TouchPoint], timestamp: Double) {
        guard isEnabled, !ScreenLock.isLocked,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            end()
            return
        }
        if requiresModifier, !NSEvent.modifierFlags.contains(.control) {
            end()
            return
        }
        if points.count >= 3 {
            let centroid = Self.centroid(points)
            let spread = Self.spread(points)
            if !inGesture {
                inGesture = true
                isPinch = false
                startCentroid = centroid
                startSpread = spread
                lastSpread = spread
                session.begin(cursor: cursorLocation(), centroid: centroid, target: nil)
                return
            }
            lastSpread = spread
            // A pinch begins when three fingers converge/diverge without the
            // centroid travelling — translation is a drag, spread change is a pinch.
            if !isPinch, startSpread > 0.06, abs(spread / startSpread - 1) > 0.22,
               hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y) < 0.045 {
                isPinch = true
                session.cancel()
                return
            }
            if isPinch { return } // pinches resolve on lift
            session.update(cursor: cursorLocation(), centroid: centroid, screen: screenForCursor())
        } else {
            finish(timestamp: timestamp)
        }
    }

    private func finish(timestamp: Double) {
        defer { end() }
        guard inGesture else { return }
        if isPinch {
            let ratio = startSpread > 0 ? lastSpread / startSpread : 1
            guard ratio > 1.15 || ratio < 0.87 else { return }
            if timestamp - lastPinchAt < 2.5 { pinchCount += 1 } else { pinchCount = 1 }
            lastPinchAt = timestamp
            if pinchCount >= 2 {
                pinchCount = 0
                toggleMinimizeAll()
            } else if let target = session.resolveTarget(cursorLocation()) {
                toggleMaximize(target: target)
            }
        } else {
            session.end()
        }
    }

    private func end() {
        if inGesture, !isPinch { session.end() }
        inGesture = false
        isPinch = false
        startSpread = 0
        lastSpread = 0
    }

    // MARK: - Pinch verbs

    private func toggleMaximize(target: WindowManager.Target) {
        guard let frame = WindowManager.shared.frame(of: target) else { return }
        let screens = WindowManager.shared.screens()
        let visible = screens.first { $0.visible.intersects(frame) }?.visible
            ?? screens.first?.visible
        guard let visible else { return }
        if abs(frame.width - visible.width) <= 8, abs(frame.height - visible.height) <= 8,
           let restored = savedPreMaximize {
            _ = WindowManager.shared.setFrame(restored, of: target)
            savedPreMaximize = nil
        } else {
            savedPreMaximize = frame
            _ = WindowManager.shared.setFrame(visible, of: target)
        }
    }

    private func toggleMinimizeAll() {
        if minimizedDuringBatch.isEmpty {
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let ref = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ref, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            for window in windows {
                var minimized: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                      (minimized as? Bool) == false else { continue }
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                minimizedDuringBatch.append(WindowManager.Target(window: window, pid: app.processIdentifier))
            }
        } else {
            for target in minimizedDuringBatch {
                AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            minimizedDuringBatch.removeAll()
        }
    }

    // MARK: - Shared geometry (used by SwishGestureSession and tests)

    /// NSEvent/AppKit point (bottom-left origin) → AX point (top-left origin).
    static func axPoint(_ point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func edges(near point: CGPoint, frame: CGRect, within edge: CGFloat) -> Set<Edge> {
        var edges = Set<Edge>()
        if abs(point.x - frame.minX) <= edge { edges.insert(.minX) }
        if abs(point.x - frame.maxX) <= edge { edges.insert(.maxX) }
        if abs(point.y - frame.minY) <= edge { edges.insert(.minY) }
        if abs(point.y - frame.maxY) <= edge { edges.insert(.maxY) }
        guard !edges.isEmpty else { return edges }
        let inside = frame.insetBy(dx: -edge, dy: -edge).contains(point)
        return inside ? edges : []
    }

    static func centroid(_ points: [TouchPoint]) -> CGPoint {
        let x = points.map(\.x).reduce(0, +) / Float(points.count)
        let y = points.map(\.y).reduce(0, +) / Float(points.count)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    static func spread(_ points: [TouchPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        return points.map { hypot(CGFloat($0.x - first.x), CGFloat($0.y - first.y)) }.max() ?? 0
    }

    private func screenForCursor() -> (frame: CGRect, visible: CGRect)? {
        let axCursor = Self.axPoint(cursorLocation(), primaryTop: Self.primaryTop)
        return WindowManager.shared.screens().first { $0.frame.contains(axCursor) }
            ?? WindowManager.shared.screens().first
    }
}
