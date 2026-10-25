import Foundation
import CoreGraphics
import AppKit

/// Core Swish gesture interpreter and execution engine for AOM.
/// Orchestrates target resolution, continuous move/resize, snap detection, and history tracking.
@MainActor
final class SwishGestureSession {
    static let shared = SwishGestureSession()

    enum Mode {
        case idle
        case moving(target: WindowManager.Target, startFrame: CGRect, startCentroid: CGPoint, lastCentroid: CGPoint, startSpread: CGFloat)
        case resizing(target: WindowManager.Target, edges: Set<WindowGestureController.Edge>, startFrame: CGRect, startCentroid: CGPoint, lastCentroid: CGPoint)
    }

    private(set) var mode: Mode = .idle
    var config: SwishConfiguration = .shared
    var history: SwishWindowHistory = .shared
    var presenter: SwishFeedbackPresenting = LiveSwishFeedbackPresenter.shared

    /// Test seams: window resolution, frame reads and frame writes.
    var resolveTarget: (CGPoint) -> WindowManager.Target? = { WindowManager.shared.captureTarget(atMousePoint: $0) }
    var frameOf: (WindowManager.Target) -> CGRect? = { WindowManager.shared.frame(of: $0) }
    var setFrame: (WindowManager.Target, CGRect) -> Bool = { WindowManager.shared.setFrame($1, of: $0) }

    private var activeSnapTarget: CGRect?
    private var activeResult: SwishSnapGrid.GestureResult?
    private var lastHapticSnapTarget: CGRect?

    init() {}

    private static var lastFailureLog = ""
    private static func noteBeginFailure(_ reason: String) {
        guard reason != lastFailureLog else { return }
        lastFailureLog = reason
        GestureLog.shared.logFromAnyThread("Swish gesture not started: \(reason)", level: .noMatch)
    }

    // MARK: - Lifecycle

    /// Begins a Swish gesture session at the given trackpad centroid and cursor position.
    func begin(cursor: CGPoint, centroid: CGPoint, spread: CGFloat = 0, target: WindowManager.Target?) {
        guard config.isEnabled else { Self.noteBeginFailure("disabled") ; return }
        
        // 1. Modifier key validation if required
        if config.requireModifier {
            let currentModifiers = NSEvent.modifierFlags.rawValue
            guard (currentModifiers & config.modifierFlag) != 0 else { return }
        }

        // 2. Resolve target window
        guard let windowTarget = target ?? resolveTarget(cursor) else {
            Self.noteBeginFailure("no window under cursor")
            return
        }

        // 3. Blacklist validation
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == windowTarget.pid }),
           config.isBlacklisted(bundleID: app.bundleIdentifier) {
            return
        }

        // 4. Retrieve initial frame
        guard let frame = frameOf(windowTarget) else {
            Self.noteBeginFailure("no frame")
            return
        }

        // 5. Determine whether starting on an edge (resize) or interior (move)
        let axCursor = WindowGestureController.axPoint(cursor, primaryTop: WindowGestureController.primaryTop)
        let edges = WindowGestureController.edges(near: axCursor, frame: frame, within: config.edgeTriggerBand)

        if edges.isEmpty {
            mode = .moving(target: windowTarget, startFrame: frame, startCentroid: centroid, lastCentroid: centroid, startSpread: spread)
        } else {
            mode = .resizing(target: windowTarget, edges: edges, startFrame: frame, startCentroid: centroid, lastCentroid: centroid)
        }

        activeSnapTarget = nil
        activeResult = nil
        lastHapticSnapTarget = nil
        presenter.showTargetBezel(frame: frame)
    }

    func begin(cursor: CGPoint, centroid: CGPoint, target: WindowManager.Target?) {
        begin(cursor: cursor, centroid: centroid, spread: 0, target: target)
    }

    /// Updates the continuous drag position.
    func update(cursor: CGPoint, centroid: CGPoint, spread: CGFloat = 0, screen: (frame: CGRect, visible: CGRect)?) {
        guard let screen else { return }

        switch mode {
        case .moving(let target, let startFrame, let startCentroid, _, let startSpread):
            let dx = centroid.x - startCentroid.x
            let dy = centroid.y - startCentroid.y
            let spreadRatio = startSpread > 0.04 ? spread / startSpread : 1.0
            let isOptionPressed = NSEvent.modifierFlags.contains(.option)

            if let result = SwishSnapGrid.resolveGesture(
                deltaX: dx,
                deltaY: dy,
                spreadRatio: spreadRatio,
                targetFrame: startFrame,
                screenVisible: screen.visible,
                useThirds: isOptionPressed
            ) {
                activeSnapTarget = result.frame
                activeResult = result
                presenter.showSnapPreview(targetFrame: result.frame, title: result.title, symbol: result.symbol)
                if lastHapticSnapTarget != result.frame {
                    presenter.playSnapHaptic()
                    lastHapticSnapTarget = result.frame
                }
            } else {
                // Fallback to cursor edge snapping if gesture distance is small
                let axCursor = WindowGestureController.axPoint(cursor, primaryTop: WindowGestureController.primaryTop)
                if let edgeSnap = SwishSnapGrid.resolveTarget(
                    cursor: axCursor,
                    screen: screen,
                    edgeBand: config.edgeTriggerBand,
                    useThirdsModifier: isOptionPressed
                ) {
                    activeSnapTarget = edgeSnap
                    activeResult = SwishSnapGrid.GestureResult(action: .snapLeftHalf, frame: edgeSnap, title: "Snap", symbol: "macwindow")
                    presenter.showSnapPreview(targetFrame: edgeSnap, title: "Snap", symbol: "macwindow")
                    if lastHapticSnapTarget != edgeSnap {
                        presenter.playSnapHaptic()
                        lastHapticSnapTarget = edgeSnap
                    }
                } else {
                    activeSnapTarget = nil
                    activeResult = nil
                    lastHapticSnapTarget = nil
                    presenter.hideSnapPreview()

                    var liveFrame = startFrame
                    liveFrame.origin.x += dx * screen.visible.width
                    liveFrame.origin.y += dy * screen.visible.height
                    _ = setFrame(target, liveFrame)
                }
            }

            mode = .moving(target: target, startFrame: startFrame, startCentroid: startCentroid, lastCentroid: centroid, startSpread: startSpread)

        case .resizing(let target, let edges, let startFrame, let startCentroid, let lastCentroid):
            let dx = (centroid.x - lastCentroid.x) * screen.visible.width
            let dy = (centroid.y - lastCentroid.y) * screen.visible.height

            var frame = startFrame
            let minSize = CGSize(width: 220, height: 140)

            if edges.contains(.minX) {
                let w = max(minSize.width, frame.width - dx)
                frame.origin.x += frame.width - w
                frame.size.width = w
            }
            if edges.contains(.maxX) {
                frame.size.width = max(minSize.width, frame.width + dx)
            }
            if edges.contains(.minY) {
                let h = max(minSize.height, frame.height - dy)
                frame.origin.y += frame.height - h
                frame.size.height = h
            }
            if edges.contains(.maxY) {
                frame.size.height = max(minSize.height, frame.height + dy)
            }

            _ = setFrame(target, frame)
            mode = .resizing(target: target, edges: edges, startFrame: startFrame, startCentroid: startCentroid, lastCentroid: centroid)

        case .idle:
            break
        }
    }

    func update(cursor: CGPoint, centroid: CGPoint, screen: (frame: CGRect, visible: CGRect)?) {
        update(cursor: cursor, centroid: centroid, spread: 0, screen: screen)
    }

    /// Commits the active gesture or applies the resolved snap target.
    func end() {
        defer {
            presenter.hideTargetBezel()
            presenter.hideSnapPreview()
            mode = .idle
            activeSnapTarget = nil
            activeResult = nil
            lastHapticSnapTarget = nil
        }

        switch mode {
        case .moving(let target, let startFrame, _, _, _):
            if let result = activeResult {
                switch result.action {
                case .snapLeftHalf, .snapRightHalf, .snapTopHalf, .snapBottomHalf,
                     .snapLeftThird, .snapRightThird,
                     .snapTopLeftQuarter, .snapTopRightQuarter, .snapBottomLeftQuarter, .snapBottomRightQuarter,
                     .maximize:
                    history.recordPreSnap(pid: target.pid, initialFrame: startFrame, targetSnapFrame: result.frame)
                    _ = setFrame(target, result.frame)
                case .minimize:
                    history.recordPreSnap(pid: target.pid, initialFrame: startFrame, targetSnapFrame: startFrame)
                    WindowManager.shared.execute(.minimizeWindow, target: target) { _ in }
                case .close:
                    WindowManager.shared.execute(.closeWindow, target: target) { _ in }
                case .fullscreen:
                    WindowManager.shared.execute(.toggleFullscreenWindow, target: target) { _ in }
                }
            } else if let snapTarget = activeSnapTarget {
                history.recordPreSnap(pid: target.pid, initialFrame: startFrame, targetSnapFrame: snapTarget)
                _ = setFrame(target, snapTarget)
            }
        case .resizing:
            break
        case .idle:
            break
        }
    }

    /// Cancels gesture tracking and restores the initial frame.
    func cancel() {
        if case .moving(let target, let startFrame, _, _, _) = mode {
            _ = setFrame(target, startFrame)
        }
        presenter.hideTargetBezel()
        presenter.hideSnapPreview()
        mode = .idle
        activeSnapTarget = nil
        activeResult = nil
        lastHapticSnapTarget = nil
    }
}
