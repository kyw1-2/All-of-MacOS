import AppKit
import ApplicationServices
import SwiftUI

/// Swish-parity window gestures, fed from the multitouch stream:
///
/// - **Three-finger drag** moves the window under the cursor. Near a screen
///   edge or corner a live preview of the snap target appears (Swish's
///   signature "expected shape"); releasing there snaps the window, releasing
///   mid-screen leaves it wherever it was dragged.
/// - **Edge contact at gesture start** resizes instead, in eight directions.
/// - **Three-finger pinch** toggles maximize; two pinches minimize/restore the
///   frontmost app's windows.
@MainActor
final class WindowGestureController: ObservableObject {
    static let shared = WindowGestureController()

    static let defaultsEnabledKey = "AOMWindowGesturesEnabled"
    static let defaultsEdgeKey = "AOMWindowGestureEdgeSize"
    static let defaultsModifierKey = "AOMWindowGestureRequireModifier"

    enum Edge: String, Equatable { case minX, maxX, minY, maxY }
    enum Mode: Equatable { case idle, move, resize(Set<Edge>), pinch }

    /// Test seams.
    var captureTarget: (CGPoint) -> WindowManager.Target? = { WindowManager.shared.captureTarget(atMousePoint: $0) }
    var applyFrame: (WindowManager.Target, CGRect) -> Bool = { target, frame in
        WindowManager.shared.setFrame(frame, of: target)
    }
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Preview + bezel presentation seam so unit tests never build panels.
    var presentation: WindowGesturePresenting = LiveGesturePresenter()

    private(set) var mode: Mode = .idle
    private var target: WindowManager.Target?
    private var startFrame: CGRect = .zero
    private var startCentroid: CGPoint = .zero
    private var lastCentroid: CGPoint = .zero
    private var startSpread: CGFloat = 0
    private var lastSpread: CGFloat = 0
    private var lastApplyAt: TimeInterval = 0
    private var snapTarget: CGRect?
    private var minimizedDuringBatch: [WindowManager.Target] = []
    private var savedPreMaximize: CGRect?

    var isDragging: Bool { mode != .idle }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true
    }
    var anyLayerEnabled: Bool { isEnabled }

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
                begin(at: centroid)
            } else {
                update(centroid: centroid, points: points, timestamp: timestamp)
            }
        } else {
            finish(timestamp: timestamp)
        }
    }

    // MARK: - Gesture state machine

    private func begin(at centroid: CGPoint) {
        let cursor = cursorLocation()
        guard let target = captureTarget(cursor),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == target.pid }),
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular,
              let frame = WindowManager.shared.frame(of: target) else { return }
        self.target = target
        startFrame = frame
        startCentroid = centroid
        lastCentroid = centroid
        // Starting on a window edge resizes; starting inside moves.
        let edges = Self.edges(near: cursor, frame: frame, within: edgeSize)
        mode = edges.isEmpty ? .move : .resize(edges)
        presentation.showBezel(frame: frame)
    }

    private func update(centroid: CGPoint, points: [TouchPoint], timestamp: Double) {
        guard let target else { end(); return }
        // A pinch begins when three fingers converge/diverge without the
        // centroid travelling — translation is a drag, spread change is a pinch.
        let spread = Self.spread(points)
        if startSpread == 0 { startSpread = spread }
        lastSpread = spread
        let travel = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)
        if case .move = mode, startSpread > 0.06,
           abs(spread / startSpread - 1) > 0.22, travel < 0.045 {
            mode = .pinch
            presentation.hideSnapPreview()
            snapTarget = nil
            lastCentroid = centroid
            return // pinches resolve on lift
        }
        if case .pinch = mode {
            lastCentroid = centroid
            return
        }
        guard let current = WindowManager.shared.frame(of: target),
              let screen = screenForCursor() else { end(); return }
        var frame = current
        switch mode {
        case .move:
            let dx = (centroid.x - lastCentroid.x) * screen.visible.width
            let dy = (centroid.y - lastCentroid.y) * screen.visible.height
            frame.origin.x += dx
            frame.origin.y -= dy // trackpad y grows downward, screen y upward
            // The snap target follows the cursor, not the window: Swish decides
            // from where your fingers are pointing.
            snapTarget = Self.snapTarget(cursor: cursorLocation(), screen: screen)
            if let snapTarget { presentation.showSnapPreview(snapTarget) } else { presentation.hideSnapPreview() }
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
        case .pinch, .idle: return
        }
        lastCentroid = centroid
        // Throttle AX writes: 60 Hz touch frames would flood the AX server.
        if timestamp - lastApplyAt >= 0.016 {
            lastApplyAt = timestamp
            if applyFrame(target, frame) { presentation.showBezel(frame: frame) }
        }
    }

    private func finish(timestamp: Double) {
        defer { end() }
        switch mode {
        case .pinch:
            let ratio = startSpread > 0 ? lastSpread / startSpread : 1
            guard ratio > 1.15 || ratio < 0.87 else { return }
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
        case .move:
            // Release over a snap zone: apply the previewed frame.
            if let snapTarget, let target {
                _ = applyFrame(target, snapTarget)
            }
        case .resize, .idle: break
        }
    }
    private var pinchCount = 0
    private var lastPinchAt: TimeInterval = 0

    private func end() {
        mode = .idle
        target = nil
        startSpread = 0
        lastSpread = 0
        snapTarget = nil
        presentation.hideSnapPreview()
        presentation.hideBezel()
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
            _ = applyFrame(target, restored)
            savedPreMaximize = nil
        } else {
            savedPreMaximize = frame
            _ = applyFrame(target, visible)
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

    // MARK: - Snap geometry (Swish grammar, pure and unit-tested)

    /// The snap frame the cursor is currently pointing at, or nil mid-screen.
    /// Left/right thirds of the screen edges give halves, the corners give
    /// quarters, the top center gives maximize — with a 24 pt dead band at the
    /// exact screen corners so the corner intent stays unambiguous.
    static func snapTarget(cursor: CGPoint, screen: (frame: CGRect, visible: CGRect)) -> CGRect? {
        let frame = screen.frame
        let visible = screen.visible
        guard frame.insetBy(dx: -2, dy: -2).contains(cursor) else { return nil }
        let edge: CGFloat = 24
        let nearLeft = cursor.x <= frame.minX + edge
        let nearRight = cursor.x >= frame.maxX - edge
        let nearTop = cursor.y >= frame.maxY - edge
        let nearBottom = cursor.y <= frame.minY + edge
        // Corners: quarters (top corners only in Swish; bottom corners too —
        // users expect symmetry, and Swish supports them via the outer thirds).
        if nearTop && nearLeft { return CGRect(origin: visible.origin, size: CGSize(width: visible.width / 2, height: visible.height / 2)) }
        if nearTop && nearRight { return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height / 2) }
        if nearBottom && nearLeft { return CGRect(x: visible.minX, y: visible.midY, width: visible.width / 2, height: visible.height / 2) }
        if nearBottom && nearRight { return CGRect(x: visible.midX, y: visible.midY, width: visible.width / 2, height: visible.height / 2) }
        if nearLeft { return CGRect(origin: visible.origin, size: CGSize(width: visible.width / 2, height: visible.height)) }
        if nearRight { return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height) }
        if nearTop { return visible }
        return nil
    }

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

    private func screenForCursor() -> (frame: CGRect, visible: CGRect)? {
        WindowManager.shared.screens().first { $0.frame.contains(cursorLocation()) }
            ?? WindowManager.shared.screens().first
    }
}

// MARK: - Presentation

/// The live gestures' on-screen furniture: the target bezel and the snap
/// preview (Swish's translucent "expected shape"). Extracted so tests verify
/// the geometry without panels.
@MainActor
protocol WindowGesturePresenting: AnyObject {
    func showBezel(frame: CGRect)
    func hideBezel()
    func showSnapPreview(_ frame: CGRect)
    func hideSnapPreview()
}

@MainActor
final class LiveGesturePresenter: WindowGesturePresenting {
    private var bezel: NSPanel?
    private var snapPreview: NSPanel?

    private func flipped(_ frame: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    private func makePanel(content: some View, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    func showBezel(frame: CGRect) {
        let target = flipped(frame).insetBy(dx: -3, dy: -3)
        if let bezel {
            bezel.setFrame(target, display: true, animate: false)
            return
        }
        let panel = makePanel(content: GestureBezelShape(), level: .floating + 1)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        bezel = panel
    }

    func hideBezel() {
        bezel?.orderOut(nil)
        bezel = nil
    }

    func showSnapPreview(_ frame: CGRect) {
        let target = flipped(frame)
        if let snapPreview {
            snapPreview.setFrame(target, display: true, animate: false)
            if !snapPreview.isVisible { snapPreview.orderFrontRegardless() }
            return
        }
        let panel = makePanel(content: SnapPreviewShape(), level: .floating + 2)
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        snapPreview = panel
    }

    func hideSnapPreview() {
        snapPreview?.orderOut(nil)
        snapPreview = nil
    }
}

private struct GestureBezelShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Swish's expected-shape preview: a soft accent fill with a bright edge.
private struct SnapPreviewShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2))
    }
}
