import AppKit

extension WindowGeometry {
    /// Frame for Move / Resize Window (BTT's "Custom Move/Resize").
    ///
    /// Offsets are measured inward from the anchored edge: with a right anchor,
    /// `x` is the gap to the display's right edge; with a center anchor, positive
    /// `x` moves right of center. Width/height of nil keep the window's current
    /// size. The result is clamped to stay inside `visible`.
    static func customFrame(current: CGRect, visible: CGRect, unit: String, anchor: String,
                            x: Double, y: Double, width: Double?, height: Double?) -> CGRect? {
        guard [x, y].allSatisfy({ $0.isFinite }), (width ?? 1).isFinite, (height ?? 1).isFinite,
              visible.width > 0, visible.height > 0,
              ActionParameterValidation.anchors.contains(anchor), ["percent", "pixels"].contains(unit) else { return nil }
        let percent = unit == "percent"
        func length(_ value: Double, of whole: CGFloat) -> CGFloat { percent ? whole * CGFloat(value) / 100 : CGFloat(value) }
        let w = width.map { length($0, of: visible.width) } ?? current.width
        let h = height.map { length($0, of: visible.height) } ?? current.height
        guard w > 0, h > 0 else { return nil }
        let size = CGSize(width: min(w, visible.width), height: min(h, visible.height))
        let ox = length(x, of: visible.width), oy = length(y, of: visible.height)

        let horizontal: String, vertical: String
        switch anchor {
        case "topLeft": (horizontal, vertical) = ("left", "top")
        case "top": (horizontal, vertical) = ("center", "top")
        case "topRight": (horizontal, vertical) = ("right", "top")
        case "left": (horizontal, vertical) = ("left", "center")
        case "right": (horizontal, vertical) = ("right", "center")
        case "bottomLeft": (horizontal, vertical) = ("left", "bottom")
        case "bottom": (horizontal, vertical) = ("center", "bottom")
        case "bottomRight": (horizontal, vertical) = ("right", "bottom")
        default: (horizontal, vertical) = ("center", "center")
        }
        let originX: CGFloat
        switch horizontal {
        case "left": originX = visible.minX + ox
        case "right": originX = visible.maxX - ox - size.width
        default: originX = visible.midX + ox - size.width / 2
        }
        let originY: CGFloat
        switch vertical {
        case "top": originY = visible.minY + oy
        case "bottom": originY = visible.maxY - oy - size.height
        default: originY = visible.midY + oy - size.height / 2
        }
        return CGRect(x: min(max(originX, visible.minX), visible.maxX - size.width),
                      y: min(max(originY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func topHalf(of visible: CGRect) -> CGRect {
        CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height / 2)
    }
    static func bottomHalf(of visible: CGRect) -> CGRect {
        CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: visible.height / 2)
    }
}

/// Frame math for "window follows the pointer". Coordinates are top-left (AX/CG).
enum WindowDragMath {
    static let minimumSize = CGSize(width: 120, height: 80)

    static func moved(start: CGRect, pointerStart: CGPoint, pointer: CGPoint) -> CGRect {
        CGRect(x: start.minX + (pointer.x - pointerStart.x), y: start.minY + (pointer.y - pointerStart.y),
               width: start.width, height: start.height)
    }

    /// The pointer drags the nearest edge on each axis: grabbing the right half
    /// moves the right edge, the left half the left edge, likewise top/bottom.
    static func resized(start: CGRect, pointerStart: CGPoint, pointer: CGPoint) -> CGRect {
        let dx = pointer.x - pointerStart.x, dy = pointer.y - pointerStart.y
        var frame = start
        if pointerStart.x >= start.midX {
            frame.size.width = max(minimumSize.width, start.width + dx)
        } else {
            let width = max(minimumSize.width, start.width - dx)
            frame.origin.x = start.maxX - width; frame.size.width = width
        }
        if pointerStart.y >= start.midY {
            frame.size.height = max(minimumSize.height, start.height + dy)
        } else {
            let height = max(minimumSize.height, start.height - dy)
            frame.origin.y = start.maxY - height; frame.size.height = height
        }
        return frame
    }

    enum Mode: Equatable { case moving, resizing }
    enum Outcome: Equatable { case start(Mode), stop, none }

    /// What Start / Stop / Toggle should do given what is running now.
    static func outcome(active: Mode?, requested: Mode, verb: String) -> Outcome {
        switch (verb, active) {
        case ("start", _): return .start(requested)
        case ("stop", let current): return current == requested ? .stop : .none
        default: return active == requested ? .stop : .start(requested) // toggle
        }
    }

    static func verb(for type: ActionType) -> (verb: String, mode: Mode)? {
        switch type {
        case .startMovingWindow: return ("start", .moving)
        case .stopMovingWindow: return ("stop", .moving)
        case .toggleMovingWindow: return ("toggle", .moving)
        case .startResizingWindow: return ("start", .resizing)
        case .stopResizingWindow: return ("stop", .resizing)
        case .toggleResizingWindow: return ("toggle", .resizing)
        default: return nil
        }
    }
}

/// Moves or resizes the window under the pointer by following the pointer,
/// until stopped, until a mouse button is pressed (which commits the placement),
/// or until the safety timeout. Polls at ~60 Hz on the main run loop; it needs
/// only Accessibility, not an event tap.
final class WindowDragController {
    static let shared = WindowDragController()
    private(set) var mode: WindowDragMath.Mode?
    private var timer: Timer?
    private var target: WindowManager.Target?
    private var startFrame = CGRect.zero
    private var pointerStart = CGPoint.zero
    private var deadline = Date.distantFuture
    var isActive: Bool { mode != nil }

    func perform(_ type: ActionType, timeout: Double?, target: WindowManager.Target?) -> Bool {
        guard let (verb, requested) = WindowDragMath.verb(for: type) else { return false }
        switch WindowDragMath.outcome(active: mode, requested: requested, verb: verb) {
        case .start(let mode): return start(mode, timeout: timeout ?? 60, target: target)
        case .stop: stop(); return true
        case .none: return true
        }
    }

    private func pointerLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: top - location.y)
    }

    private func start(_ newMode: WindowDragMath.Mode, timeout: Double, target explicit: WindowManager.Target?) -> Bool {
        stop()
        guard timeout.isFinite, (1...600).contains(timeout),
              let window = WindowManager.shared.captureTarget(atMousePoint: NSEvent.mouseLocation) ?? explicit,
              let frame = WindowManager.shared.frame(of: window) else { return false }
        target = window; startFrame = frame; pointerStart = pointerLocation()
        mode = newMode; deadline = Date().addingTimeInterval(timeout)
        let wasPressed = NSEvent.pressedMouseButtons != 0
        var sawRelease = !wasPressed
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pressed = NSEvent.pressedMouseButtons != 0
            if !pressed { sawRelease = true }
            // A fresh click commits the placement; a button already down when we started does not.
            if pressed && sawRelease || Date() >= self.deadline { self.stop(); return }
            self.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    private func step() {
        guard let target, let mode else { return }
        guard NSRunningApplication(processIdentifier: target.pid) != nil else { stop(); return }
        let pointer = pointerLocation()
        switch mode {
        case .moving:
            var position = WindowDragMath.moved(start: startFrame, pointerStart: pointerStart, pointer: pointer).origin
            if let value = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, value)
            }
        case .resizing:
            let frame = WindowDragMath.resized(start: startFrame, pointerStart: pointerStart, pointer: pointer)
            var position = frame.origin, size = frame.size
            if let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, s)
                if frame.origin != startFrame.origin { AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, p) }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        mode = nil; target = nil
    }
}
