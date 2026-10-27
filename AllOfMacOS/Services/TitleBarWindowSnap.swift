import AppKit

// Swish-style window snapping: rest the pointer over a window's title bar and
// swipe with two fingers on the trackpad; a translucent preview shows where the
// window will land, and lifting the fingers commits it (with a haptic tap).
//
// Behaviour recovered from Swish 1.13.3 (REA/Ghidra on Oracle — the strings and
// metadata named `SnappingTabController`, `AccessibilityWindowController`, the
// per-layout `GestureView`/`snappingView` overlays, a `gestureTimeout`
// `gestureDispatchItem`, `NSHapticFeedbackManager`, and the rounded-rect overlay
// animated with `setFrame:display:animate:`). This is AOM's own implementation
// of that interaction, not Swish code.
//
// Stability first: the recognizer is pure and runs on the multitouch callback
// thread doing only float maths; it never blocks the existing gesture pipeline,
// only engages over a title bar (so it does not fight AOM's own trackpad
// gestures), resets on a timeout, and is off until the user turns it on.

// MARK: - Pure recognition (unit-tested)

enum SwishSnap {
    enum Direction: Equatable { case left, right, up, down }

    /// The layout a swipe maps to. Tier 1 is a short swipe; tier 2 is a longer
    /// swipe in the same direction, so one gesture refines from half → third
    /// (horizontal) or maximize/centre → top/bottom half (vertical).
    static func layout(for direction: Direction, tier: Int) -> CustomSnapZone.Layout {
        switch (direction, tier >= 2) {
        case (.left, false): return .leftHalf
        case (.left, true): return .leftThird
        case (.right, false): return .rightHalf
        case (.right, true): return .rightThird
        case (.up, false): return .maximize
        case (.up, true): return .topHalf
        case (.down, false): return .center
        case (.down, true): return .bottomHalf
        }
    }

    /// The dominant swipe direction, or nil while the movement is too small or
    /// too diagonal to be sure. Distances are in normalised trackpad units
    /// (0…1 across the pad), so they are independent of trackpad size.
    static func direction(dx: Float, dy: Float, engage: Float, ratio: Float) -> Direction? {
        let ax = abs(dx), ay = abs(dy)
        if ax >= ay {
            guard ax >= engage, ax >= ay * ratio else { return nil }
            return dx < 0 ? .left : .right
        } else {
            guard ay >= engage, ay >= ax * ratio else { return nil }
            // Trackpad Y grows downward (top of pad = 0), so dy > 0 is a swipe
            // down the pad, which the user feels as pulling the window down.
            return dy > 0 ? .down : .up
        }
    }

    /// Tier from the dominant-axis displacement.
    static func tier(dx: Float, dy: Float, tier2: Float) -> Int {
        max(abs(dx), abs(dy)) >= tier2 ? 2 : 1
    }

    /// Whether a top-left pointer sits in a window's title-bar band.
    static func titleBarHit(pointerTopLeft: CGPoint, windowFrame: CGRect, band: CGFloat = 30) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }
        let strip = CGRect(x: windowFrame.minX, y: windowFrame.minY,
                           width: windowFrame.width, height: min(band, windowFrame.height))
        return strip.contains(pointerTopLeft)
    }

    /// The window's target frame for a layout, in Accessibility (top-left)
    /// coordinates within the given visible display area.
    static func targetFrame(layout: CustomSnapZone.Layout, visible: CGRect, margin: CGFloat) -> CGRect {
        let unit = AOMTilingGeometry.rect(for: layout, in: CGSize(width: 1, height: 1))
        var rect = CGRect(x: visible.minX + unit.minX * visible.width,
                          y: visible.minY + unit.minY * visible.height,
                          width: unit.width * visible.width,
                          height: unit.height * visible.height)
        guard margin > 0 else { return rect }
        rect = rect.insetBy(dx: margin, dy: margin)
        return rect
    }

    /// Accessibility (top-left) rect → AppKit (bottom-left) screen rect for the
    /// overlay window.
    static func appKitRect(_ axRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: axRect.minX, y: primaryTop - axRect.minY - axRect.height,
               width: axRect.width, height: axRect.height)
    }
}

/// Classifies a two-finger swipe from raw contact frames. Lives on the
/// multitouch callback thread only; it allocates nothing per frame and reports
/// state transitions through closures (which the service hops to the main
/// thread). A frame with other than two contacts ends the gesture.
final class TitleBarSnapRecognizer {
    var engage: Float = 0.05
    var tier2: Float = 0.16
    var ratio: Float = 1.3

    /// Engaged with a direction and tier; the service captures the window.
    var onBegin: ((SwishSnap.Direction, Int) -> Void)?
    /// Direction or tier changed while engaged; the service moves the preview.
    var onUpdate: ((SwishSnap.Direction, Int) -> Void)?
    /// Two fingers lifted after engaging; commit the current preview.
    var onCommit: (() -> Void)?
    /// The gesture fell apart before committing; hide the preview.
    var onCancel: (() -> Void)?

    private var startX: Float = 0
    private var startY: Float = 0
    private var hasStart = false
    private var engaged = false
    private var lastDirection: SwishSnap.Direction?
    private var lastTier = 1

    func feed(contacts: [TouchPoint], timestamp: Double) {
        guard contacts.count == 2 else {
            // Any count other than two ends (or never starts) the gesture.
            if engaged { engaged = false; onCommit?() }
            else if hasStart { onCancel?() }
            hasStart = false
            lastDirection = nil
            return
        }
        let cx = (contacts[0].x + contacts[1].x) / 2
        let cy = (contacts[0].y + contacts[1].y) / 2
        if !hasStart {
            hasStart = true
            startX = cx; startY = cy
            return
        }
        let dx = cx - startX
        let dy = cy - startY
        guard let direction = SwishSnap.direction(dx: dx, dy: dy, engage: engage, ratio: ratio) else { return }
        let tier = SwishSnap.tier(dx: dx, dy: dy, tier2: tier2)
        if !engaged {
            engaged = true
            lastDirection = direction; lastTier = tier
            onBegin?(direction, tier)
        } else if direction != lastDirection || tier != lastTier {
            lastDirection = direction; lastTier = tier
            onUpdate?(direction, tier)
        }
    }

    func reset() {
        hasStart = false; engaged = false; lastDirection = nil; lastTier = 1
    }
}

// MARK: - Service

/// Set once on the main actor; read from the multitouch callback thread, so the
/// frame handler never has to reach the main-actor singleton. A nil handler
/// (feature never initialised) simply does nothing.
nonisolated(unsafe) var aomTitleBarSnapFeed: (([TouchPoint], Double) -> Void)?

/// Owns the recognizer, the preview overlay and the commit. The `handle`
/// entry point is called from `TrackpadMonitor`'s multitouch callback; all UI
/// and Accessibility work hops to the main actor.
final class TitleBarWindowSnap {
    @MainActor static let shared = TitleBarWindowSnap()

    static let enabledKey = "AOMTitleBarSnapEnabled"
    static let hapticKey = "AOMTitleBarSnapHaptic"
    static let marginKey = "AOMTitleBarSnapMargin"

    /// Read on the multitouch thread, written on main. A stale bool for one
    /// frame is harmless.
    private nonisolated(unsafe) var active = false
    private let recognizer = TitleBarSnapRecognizer()

    @MainActor private var target: WindowManager.Target?
    @MainActor private var targetVisible: CGRect?
    @MainActor private var currentLayout: CustomSnapZone.Layout?
    @MainActor private var overlay = SnapPreviewOverlay()
    @MainActor private var timeout: DispatchWorkItem?

    @MainActor
    private init() {
        recognizer.onBegin = { direction, tier in
            DispatchQueue.main.async { TitleBarWindowSnap.shared.begin(direction: direction, tier: tier) }
        }
        recognizer.onUpdate = { direction, tier in
            DispatchQueue.main.async { TitleBarWindowSnap.shared.update(direction: direction, tier: tier) }
        }
        recognizer.onCommit = { DispatchQueue.main.async { TitleBarWindowSnap.shared.commit() } }
        recognizer.onCancel = { DispatchQueue.main.async { TitleBarWindowSnap.shared.cancel() } }
        aomTitleBarSnapFeed = { [weak self] contacts, timestamp in
            self?.handle(contacts: contacts, timestamp: timestamp)
        }
        refreshEnabled()
    }

    @MainActor
    func refreshEnabled() {
        let on = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        active = on && AXIsProcessTrusted()
        if !on { cancel() }
    }

    /// From `TrackpadMonitor.source.onFrame` (multitouch thread). Cheap and
    /// non-blocking: it forwards to the recognizer only when enabled.
    nonisolated func handle(contacts: [TouchPoint], timestamp: Double) {
        guard active else { return }
        recognizer.feed(contacts: contacts, timestamp: timestamp)
    }

    // MARK: Transitions (main actor)

    @MainActor
    private func begin(direction: SwishSnap.Direction, tier: Int) {
        // Only engage over a window's title bar, so the gesture never competes
        // with AOM's other two-finger gestures elsewhere on screen.
        guard active else { return }
        let mouse = NSEvent.mouseLocation
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let pointerTopLeft = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        guard let window = WindowManager.shared.captureTarget(atMousePoint: mouse),
              let frame = WindowManager.shared.frame(of: window),
              SwishSnap.titleBarHit(pointerTopLeft: pointerTopLeft, windowFrame: frame) else {
            overlay.hide(); target = nil; return
        }
        let screens = WindowManager.shared.screens()
        guard let index = WindowGeometry.screenIndex(for: frame, screens: screens.map(\.frame)) else {
            target = nil; return
        }
        target = window
        targetVisible = screens[index].visible
        scheduleTimeout()
        showPreview(direction: direction, tier: tier, primaryTop: primaryTop)
    }

    @MainActor
    private func update(direction: SwishSnap.Direction, tier: Int) {
        guard target != nil else { return }
        scheduleTimeout()
        showPreview(direction: direction, tier: tier, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    @MainActor
    private func showPreview(direction: SwishSnap.Direction, tier: Int, primaryTop: CGFloat) {
        guard let visible = targetVisible else { return }
        let layout = SwishSnap.layout(for: direction, tier: tier)
        currentLayout = layout
        let axRect = SwishSnap.targetFrame(layout: layout, visible: visible, margin: margin)
        overlay.show(frame: SwishSnap.appKitRect(axRect, primaryTop: primaryTop))
    }

    @MainActor
    private func commit() {
        timeout?.cancel(); timeout = nil
        defer { reset() }
        guard active, let target, let visible = targetVisible, let layout = currentLayout else { overlay.hide(); return }
        let axRect = SwishSnap.targetFrame(layout: layout, visible: visible, margin: margin)
        if WindowManager.shared.setFrame(axRect, of: target) {
            if UserDefaults.standard.object(forKey: Self.hapticKey) as? Bool ?? true {
                _ = GestureHaptics.shared.feedback(enabled: true)
            }
        }
        overlay.commitFlash()
    }

    @MainActor
    private func cancel() {
        timeout?.cancel(); timeout = nil
        overlay.hide()
        reset()
    }

    @MainActor
    private func reset() {
        target = nil; targetVisible = nil; currentLayout = nil
    }

    @MainActor
    private func scheduleTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem { TitleBarWindowSnap.shared.cancel() }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    @MainActor
    private var margin: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: Self.marginKey) as? Double ?? 0)
    }
}

// MARK: - Preview overlay

/// The translucent rounded rectangle shown while swiping, in a borderless,
/// non-activating, click-through window at a floating level — the mechanism
/// Swish uses for its snapping preview. Frame changes animate briefly.
@MainActor
final class SnapPreviewOverlay {
    private var panel: NSPanel?
    private let view = SnapPreviewView()

    func show(frame: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame == .zero || !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// A quick confirmation pulse, then hide.
    func commitFlash() {
        guard let panel else { return }
        view.setCommitted(true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.view.setCommitted(false)
            self?.panel?.orderOut(nil)
        })
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.panel?.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        return panel
    }
}

/// A rounded accent rectangle; the fill deepens on commit.
private final class SnapPreviewView: NSView {
    private var committed = false
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { nil }

    func setCommitted(_ value: Bool) { committed = value; needsDisplay = true }

    override func updateLayer() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        layer.backgroundColor = accent.withAlphaComponent(committed ? 0.34 : 0.20).cgColor
        layer.borderColor = accent.withAlphaComponent(0.95).cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
    }
}
