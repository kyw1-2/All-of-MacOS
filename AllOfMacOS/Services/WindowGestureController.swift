import AppKit
import ApplicationServices
import SwiftUI

/// Swish-parity continuous window gestures: three-finger drag moves the window
/// under the cursor, edge contact resizes it, a three-finger pinch toggles
/// maximize (two pinches minimize/restore the frontmost app's windows).
///
/// Feed every multitouch frame with three or more contacts — or an empty frame
/// that ends a drag — into `observe`. Screen-space deltas come from the
/// trackpad's normalized centroid movement scaled by the display under the
/// cursor; the target window is captured at gesture start via AX and driven
/// with kAXPosition/kAXSize, exactly the path Swish uses.
@MainActor
final class WindowGestureController: ObservableObject {
    static let shared = WindowGestureController()

    static let defaultsEnabledKey = "AOMWindowGesturesEnabled"
    static let defaultsEdgeKey = "AOMWindowGestureEdgeSize"
    static let defaultsModifierKey = "AOMWindowGestureRequireModifier"

    enum Edge: String, Equatable { case minX, maxX, minY, maxY }
    enum Mode: Equatable { case idle, move, resize(Set<Edge>), pinch }

    /// Test seam: resolves the window under a screen point.
    var captureTarget: (CGPoint) -> WindowManager.Target? = { WindowManager.shared.captureTarget(atMousePoint: $0) }
    /// Test seam: applies frame changes. The default writes through AX.
    var applyFrame: (WindowManager.Target, CGRect) -> Bool = { target, frame in
        WindowManager.shared.setFrame(frame, of: target)
    }
    /// Test seam: the cursor location (mouse events are hard to fake in tests).
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }

    private(set) var mode: Mode = .idle
    private var target: WindowManager.Target?
    private var startFrame: CGRect = .zero
    private var startCursor: CGPoint = .zero
    private var startCentroid: CGPoint = .zero
    private var lastCentroid: CGPoint = .zero
    private var startSpread: CGFloat = 0
    private var lastSpread: CGFloat = 0
    private var pinchSettled = false
    private var pinchCount = 0
    private var lastPinchAt: TimeInterval = 0
    private var lastApplyAt: TimeInterval = 0
    private var minimizedDuringBatch: [WindowManager.Target] = []

    var isDragging: Bool { mode != .idle }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true
    }
    private var edgeSize: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: Self.defaultsEdgeKey) as? Double ?? 40)
    }
    private var requiresModifier: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsModifierKey) as? Bool ?? false
    }

    // MARK: - Frame entry

    func observe(points: [TouchPoint], timestamp: Double) {
        guard isEnabled, !ScreenLock.isLocked,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            end(); return
        }
        if requiresModifier, !NSEvent.modifierFlags.contains(.control) {
            end(); return
        }
        if points.count >= 3 {
            let centroid = Self.centroid(points)
            if mode == .idle {
                begin(at: centroid, timestamp: timestamp)
            } else {
                update(centroid: centroid, points: points, timestamp: timestamp)
            }
        } else if points.isEmpty || points.count < 3 {
            finish(timestamp: timestamp)
        }
    }

    // MARK: - Gesture state machine

    private func begin(at centroid: CGPoint, timestamp: Double) {
        let cursor = cursorLocation()
        guard let target = captureTarget(cursor),
              NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == target.pid })?.bundleIdentifier != Bundle.main.bundleIdentifier,
              let frame = WindowManager.shared.frame(of: target) else { return }
        self.target = target
        startFrame = frame
        startCursor = cursor
        startCentroid = centroid
        lastCentroid = centroid
        let spread = lastSpread
        _ = spread
        // Edge detection decides move vs resize: the cursor must sit within
        // `edgeSize` of a window edge to resize; corners win over edges.
        let edges = Self.edges(near: cursor, frame: frame, within: edgeSize)
        if edges.isEmpty {
            mode = .move
        } else {
            mode = .resize(edges)
        }
        startSpread = 0
        showBezel(frame: frame)
    }

    private func update(centroid: CGPoint, points: [TouchPoint], timestamp: Double) {
        guard let target, let current = WindowManager.shared.frame(of: target) else { end(); return }
        let screen = screenForCursor()
        guard let screen else { end(); return }
        var frame = current
        switch mode {
        case .move:
            let dx = (centroid.x - lastCentroid.x) * screen.visible.width
            let dy = (centroid.y - lastCentroid.y) * screen.visible.height
            frame.origin.x += dx
            frame.origin.y -= dy // trackpad y grows downward, screen y upward
        case .resize(let edges):
            let dx = (centroid.x - lastCentroid.x) * screen.visible.width
            let dy = (centroid.y - lastCentroid.y) * screen.visible.height
            let minSize = CGSize(width: 220, height: 140)
            if edges.contains(.minX) {
                let newWidth = max(minSize.width, frame.width - dx)
                frame.origin.x += frame.width - newWidth
                frame.size.width = newWidth
            }
            if edges.contains(.maxX) { frame.size.width = max(minSize.width, frame.width + dx) }
            if edges.contains(.minY) {
                let newHeight = max(minSize.height, frame.height + dy)
                frame.origin.y -= newHeight - frame.height
                frame.size.height = newHeight
            }
            if edges.contains(.maxY) { frame.size.height = max(minSize.height, frame.height - dy) }
        case .pinch:
            let spread = Self.spread(points)
            if startSpread == 0 { startSpread = spread }
            lastSpread = spread
            lastCentroid = centroid
            return // pinch resolves on lift
        case .idle: return
        }
        lastCentroid = centroid
        // Throttle AX writes: 60 Hz touch frames would flood the AX server.
        if timestamp - lastApplyAt >= 0.016 {
            lastApplyAt = timestamp
            if applyFrame(target, frame) { showBezel(frame: frame) }
        }
    }

    private func finish(timestamp: Double) {
        defer { end() }
        switch mode {
        case .pinch:
            let ratio = startSpread > 0 ? lastSpread / startSpread : 1
            guard !pinchSettled, ratio > 1.15 || ratio < 0.87 else { return }
            pinchSettled = true
            if timestamp - lastPinchAt < 2.5 {
                pinchCount += 1
            } else {
                pinchCount = 1
            }
            lastPinchAt = timestamp
            if pinchCount >= 2 {
                pinchCount = 0
                toggleMinimizeAll()
            } else if let target = target {
                toggleMaximize(target: target)
            }
        default: break
        }
    }

    private func end() {
        mode = .idle
        target = nil
        startSpread = 0
        lastSpread = 0
        pinchSettled = false
        hideBezel()
    }

    /// Three-finger pinch on a window toggles its zoom (macOS zoom semantics:
    /// fill the visible screen, restore on the second pinch).
    private func toggleMaximize(target: WindowManager.Target) {
        guard let frame = WindowManager.shared.frame(of: target) else { return }
        let screens = WindowManager.shared.screens()
        let visible = screens.first { $0.visible.intersects(frame) }?.visible
            ?? screens.first?.visible
        guard let visible else { return }
        if abs(frame.width - visible.width) <= 8, abs(frame.height - visible.height) <= 8,
           let restored = savedPreMaximize {
            _ = applyFrame(target, restored)
            savedPreMaximize = nil
        } else {
            savedPreMaximize = frame
            _ = applyFrame(target, visible)
        }
    }
    private var savedPreMaximize: CGRect?

    /// Two consecutive pinches minimize the frontmost app's windows; the next
    /// double pinch restores them.
    private func toggleMinimizeAll() {
        if minimizedDuringBatch.isEmpty {
            // AX path: NSRunningApplication exposes no window list, and the AX
            // elements double as the restore handles.
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

    // MARK: - Helpers

    private static func centroid(_ points: [TouchPoint]) -> CGPoint {
        let x = points.map(\.x).reduce(0, +) / Float(points.count)
        let y = points.map(\.y).reduce(0, +) / Float(points.count)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static func spread(_ points: [TouchPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        return points.map { hypot(CGFloat($0.x - first.x), CGFloat($0.y - first.y)) }.max() ?? 0
    }

    static func edges(near point: CGPoint, frame: CGRect, within edge: CGFloat) -> Set<Edge> {
        var edges = Set<Edge>()
        if abs(point.x - frame.minX) <= edge { edges.insert(.minX) }
        if abs(point.x - frame.maxX) <= edge { edges.insert(.maxX) }
        if abs(point.y - frame.minY) <= edge { edges.insert(.minY) }
        if abs(point.y - frame.maxY) <= edge { edges.insert(.maxY) }
        // Corners only resize when the point actually sits in both edge bands,
        // otherwise every interior point near an edge line would resize.
        guard !edges.isEmpty else { return edges }
        let inside = frame.insetBy(dx: -edge, dy: -edge).contains(point)
        return inside ? edges : []
    }

    private func screenForCursor() -> (frame: CGRect, visible: CGRect)? {
        WindowManager.shared.screens().first { $0.visible.contains(cursorLocation()) }
            ?? WindowManager.shared.screens().first
    }

    // MARK: - Bezel feedback (Swish's highlight, AOM's floating surface)

    private var bezel: NSPanel?

    private func showBezel(frame: CGRect) {
        // AX frames are top-left based; AppKit windows are bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let flipped = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        if let bezel {
            bezel.setFrame(flipped.insetBy(dx: -4, dy: -4), display: true)
            return
        }
        let panel = NSPanel(contentRect: flipped.insetBy(dx: -4, dy: -4),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating + 1
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: BezelShape())
        panel.orderFrontRegardless()
        self.bezel = panel
    }

    private func hideBezel() {
        bezel?.orderOut(nil)
        bezel = nil
    }
}

/// The gesture target's outline: an accent border with a faint wash.
private struct BezelShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
