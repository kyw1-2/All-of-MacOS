import AppKit
import ApplicationServices
import SwiftUI

/// Routes the multi-finger touch stream: window move/resize/snap/minimize/close
/// goes to SwishGestureSession (the faithful Swish port).
/// Supports:
/// - 2 fingers over window title bar (zero modifier needed, like native Swish)
/// - 2 fingers with modifier (Control / Option) anywhere on window
/// - 3 fingers anywhere on window
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

    /// Checks if the cursor is positioned over the top title bar of the target window.
    func isOverTitleBar(cursor: CGPoint) -> Bool {
        guard let target = session.resolveTarget(cursor),
              let frame = session.frameOf(target) else { return false }
        let axCursor = Self.axPoint(cursor, primaryTop: Self.primaryTop)
        let titlebar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 40)
        return titlebar.contains(axCursor)
    }

    // MARK: - Frame entry

    func observe(points: [TouchPoint], timestamp: Double) {
        // No frontmost-app guard: a global gesture must work while AOM's own
        // window happens to be focused. The session itself refuses AOM windows
        // (blacklist), so our UI can never be dragged by its own gestures.
        guard isEnabled, !ScreenLock.isLocked else {
            end()
            return
        }

        let isThreeFinger = points.count >= 3
        let isTwoFinger = points.count == 2

        if isThreeFinger || isTwoFinger {
            let cursor = cursorLocation()
            let centroid = Self.centroid(points)
            let spread = Self.spread(points)

            if !inGesture {
                // Two fingers requires cursor on titlebar or modifier key held
                if isTwoFinger {
                    let hasModifier = NSEvent.modifierFlags.contains(.control) || NSEvent.modifierFlags.contains(.option)
                    let isTitlebar = isOverTitleBar(cursor: cursor)
                    guard hasModifier || isTitlebar else { return }
                } else if requiresModifier {
                    guard NSEvent.modifierFlags.contains(.control) else { return }
                }

                Self.noteFramesArriving()
                inGesture = true
                isPinch = false
                startCentroid = centroid
                startSpread = spread
                lastSpread = spread
                session.begin(cursor: cursor, centroid: centroid, spread: spread, target: nil)
                return
            }

            lastSpread = spread
            session.update(cursor: cursor, centroid: centroid, spread: spread, screen: screenForCursor())
        } else {
            finish(timestamp: timestamp)
        }
    }

    private func finish(timestamp: Double) {
        defer { end() }
        guard inGesture else { return }
        session.end()
    }

    private func end() {
        if inGesture { session.end() }
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

    /// One-shot runtime evidence: if gestures "don't work", the Gesture
    /// Console shows whether this layer ever saw a touch frame.
    private static var loggedFrames = false
    private static func noteFramesArriving() {
        guard !loggedFrames else { return }
        loggedFrames = true
        GestureLog.shared.logFromAnyThread("Window gestures: touch frames are arriving", level: .detect)
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
