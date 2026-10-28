import AppKit

// Swish-style window snapping: rest the pointer over a window's title bar and
// swipe with two fingers on the trackpad; a translucent preview shows where the
// window will land, and lifting the fingers commits it (with a haptic tap).
//
// 3.2.0 recovered the interaction from Swish 1.13.3's strings and metadata
// (REA/Ghidra on Oracle: `SnappingTabController`, `AccessibilityWindowController`,
// the per-layout `GestureView`/`snappingView` overlays, a `gestureTimeout`
// `gestureDispatchItem`, `NSHapticFeedbackManager`, the rounded-rect overlay
// animated with `setFrame:display:animate:`).
//
// 3.3.0 applies the DeepSeek Harness Ghidra pass of the same build
// (`/data/rea-targets-swish-20261027/report`, kept in `work/rea-swish/dsh-20261027`):
// - The commit follows Swish's frame setter (`FUN_1000329c8`): AXEnhancedUserInterface
//   is suspended, size → position → size is written and read back, and a window
//   that keeps its own size is anchored to the snapped edge (`WindowManager.applySnap`).
// - The preview settles on the frame the window really took before fading.
// - Swish keeps each window's pre-snap frame (`ActionSnapUnsnap`, "Unsnap"): a swipe
//   down on a window AOM snapped restores it.
// - "Swipe horizontally and vertically to snap to a quarter. Both orders work."
// - Haptics on zone changes and commit, `activateAfterSnapping`, and the optional
//   `snappingMoveCursor` warp (`CGWarpMouseCursorPosition`) back to the title bar.
// - Readiness checks phrased the way Swish's settings explain them (Accessibility,
//   haptic feedback, Mission Control shortcuts).
// This is AOM's own implementation of that behaviour, not Swish code.
//
// Stability first: the recognizer is pure and runs on the multitouch callback
// thread doing only float maths; it never blocks the existing gesture pipeline,
// only engages over a title bar (so it does not fight AOM's own trackpad
// gestures), resets on a timeout, and is off until the user turns it on.

// MARK: - Pure recognition (unit-tested)

enum SwishSnap {
    enum Axis: Equatable { case horizontal, vertical }

    enum Direction: Equatable {
        case left, right, up, down
        var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    }

    /// One recognised swipe: its primary direction and tier, plus an optional
    /// leg along the other axis that turns a half into a quarter.
    struct Stroke: Equatable {
        var direction: Direction
        var tier: Int
        var cross: Direction?

        init(_ direction: Direction, tier: Int = 1, cross: Direction? = nil) {
            self.direction = direction
            self.tier = tier
            self.cross = cross
        }
    }

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

    /// A stroke with a perpendicular leg is a quarter, whichever axis came
    /// first (Swish: "Swipe horizontally and vertically to snap to a quarter.
    /// Both orders work.").
    static func layout(for stroke: Stroke) -> CustomSnapZone.Layout {
        guard let cross = stroke.cross, cross.axis != stroke.direction.axis else {
            return layout(for: stroke.direction, tier: stroke.tier)
        }
        let horizontal = stroke.direction.axis == .horizontal ? stroke.direction : cross
        let vertical = stroke.direction.axis == .vertical ? stroke.direction : cross
        switch (horizontal, vertical) {
        case (.left, .up): return .topLeft
        case (.right, .up): return .topRight
        case (.left, _): return .bottomLeft
        default: return .bottomRight
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

    /// Follows an engaged swipe. The primary axis was fixed when the gesture
    /// engaged and the tier comes from the distance along it. A deliberate leg
    /// along the other axis — past `crossEngage` and at least `crossShare` of
    /// the primary distance, so the natural arc of a long swipe never counts —
    /// adds the cross direction; once held it is released only below 60% of
    /// that. Back near the start, a clear swipe along the other axis re-picks
    /// the axis; anything less returns nil so the preview holds still.
    static func refine(dx: Float, dy: Float, axis: Axis, previous: Stroke?,
                       engage: Float, tier2: Float, ratio: Float,
                       crossEngage: Float = 0.06, crossShare: Float = 0.45) -> Stroke? {
        let primary = axis == .horizontal ? dx : dy
        let other = axis == .horizontal ? dy : dx
        if abs(primary) < engage * 0.5 {
            guard let fresh = direction(dx: dx, dy: dy, engage: engage, ratio: ratio),
                  fresh.axis != axis else { return nil }
            return Stroke(fresh, tier: tier(dx: dx, dy: dy, tier2: tier2))
        }
        let direction: Direction = axis == .horizontal
            ? (primary < 0 ? .left : .right)
            : (primary > 0 ? .down : .up)
        let held = previous?.cross != nil && previous?.direction.axis == axis
        let needed = max(crossEngage, abs(primary) * crossShare) * (held ? 0.6 : 1)
        var cross: Direction?
        if abs(other) >= needed {
            cross = axis == .horizontal ? (other > 0 ? .down : .up) : (other < 0 ? .left : .right)
        }
        return Stroke(direction, tier: abs(primary) >= tier2 ? 2 : 1, cross: cross)
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

    /// Where the pointer goes after a snap when "Keep pointer on title bar" is
    /// on: the middle of the title-bar band, so the next swipe chains. Swish
    /// warps to its title bar the same way. Global top-left coordinates.
    static func titleBarRestPoint(for frame: CGRect, band: CGFloat = 30) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.minY + min(band, frame.height) / 2)
    }
}

/// Swish keeps each window's frame from before its first snap so the window
/// can be unsnapped. Pure; the service keys windows by `pid:CFHash(window)`.
struct SwishSnapHistory {
    struct Entry: Equatable {
        /// Where the window was before the first snap of the current chain.
        var original: CGRect
        /// The frame the window really took at its last snap.
        var snapped: CGRect
    }

    private(set) var entries: [String: Entry] = [:]
    private var order: [String] = []
    var limit = 64

    /// Records a snap. A chain of snaps keeps the first starting frame, so a
    /// restore goes back to where the window began; a window moved by hand
    /// since its last snap starts a new chain.
    mutating func recordSnap(key: String, from start: CGRect, to actual: CGRect) {
        if var entry = entries[key] {
            if !WindowGeometry.close(entry.snapped, start) { entry.original = start }
            entry.snapped = actual
            entries[key] = entry
            return
        }
        entries[key] = Entry(original: start, snapped: actual)
        order.append(key)
        if order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
    }

    /// The frame to restore, while the window still sits where it was snapped.
    /// Nothing to restore when the snap never moved the window (it was already
    /// in that cell), so a swipe down then centres it as usual.
    func restoreFrame(key: String, current: CGRect) -> CGRect? {
        guard let entry = entries[key], WindowGeometry.close(entry.snapped, current),
              !WindowGeometry.close(entry.original, current) else { return nil }
        return entry.original
    }

    mutating func forget(key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}

/// The prerequisites Swish's settings spell out ("Haptic Feedback needs to be
/// enabled for your Magic Trackpad", "Mission Control shortcuts are set
/// correctly / to a custom combination / disabled"), checked read-only for
/// AOM's trackpad gestures. Nothing here writes system preferences.
enum TrackpadReadiness {
    struct Item: Identifiable, Equatable {
        enum Fix: Equatable { case accessibility, trackpad, keyboardShortcuts }
        let id: String
        let title: String
        let detail: String
        let ready: Bool
        let fix: Fix?
    }

    /// Force Click and haptic feedback: `ForceSuppressed` = 1 turns it off and
    /// `ActuateDetents` = 0 silences the detents. Missing keys are the default (on).
    static func hapticsEnabled(actuateDetents: Any?, forceSuppressed: Any?) -> Bool {
        func flag(_ value: Any?) -> Bool? {
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }
        return flag(forceSuppressed) != true && flag(actuateDetents) != false
    }

    /// The Mission Control "Move left/right a space" shortcuts the top-bar
    /// Space swipe posts. A custom combination works too: AOM posts whatever
    /// the shortcut is set to.
    static func spaceShortcuts(left: SymbolicHotKey?, right: SymbolicHotKey?) -> (ready: Bool, detail: String) {
        guard let left, let right, left.isEnabled, right.isEnabled else {
            return (false, "Turn on Move left/right a space in Keyboard Shortcuts › Mission Control.")
        }
        let standard = left.keyCode == 123 && right.keyCode == 124
            && left.flags.contains(.maskControl) && right.flags.contains(.maskControl)
        return (true, standard ? "⌃← and ⌃→ are on." : "On, set to a custom combination.")
    }

    @MainActor
    static func current(hapticsWanted: Bool, spaceSwipeOn: Bool) -> [Item] {
        let trusted = AXIsProcessTrusted()
        var items = [Item(id: "accessibility", title: "Accessibility",
                          detail: trusted ? "Allowed — windows can be moved." : "Needed to move windows.",
                          ready: trusted, fix: trusted ? nil : .accessibility)]
        if hapticsWanted {
            let domain = "com.apple.AppleMultitouchTrackpad" as CFString
            let on = hapticsEnabled(actuateDetents: CFPreferencesCopyAppValue("ActuateDetents" as CFString, domain),
                                    forceSuppressed: CFPreferencesCopyAppValue("ForceSuppressed" as CFString, domain))
            items.append(Item(id: "haptics", title: "Haptic feedback",
                              detail: on ? "On (Force Touch trackpads)." : "Turn on Force Click and haptic feedback in Trackpad settings.",
                              ready: on, fix: on ? nil : .trackpad))
        }
        if spaceSwipeOn {
            let table = SymbolicHotKeys.load()
            let state = spaceShortcuts(left: SymbolicHotKeys.hotKey(id: SymbolicHotKeys.spaceLeft, in: table),
                                       right: SymbolicHotKeys.hotKey(id: SymbolicHotKeys.spaceRight, in: table))
            items.append(Item(id: "spaces", title: "Space shortcuts", detail: state.detail,
                              ready: state.ready, fix: state.ready ? nil : .keyboardShortcuts))
        }
        return items
    }

    static func open(_ fix: Item.Fix) {
        let address: String
        switch fix {
        case .accessibility: address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .trackpad: address = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case .keyboardShortcuts: address = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// Classifies a two-finger swipe from raw contact frames. It is fed from one
/// thread only, allocates nothing per frame and reports state transitions
/// through closures (which the service hops to the main thread).
///
/// Only lifting the fingers commits: going from two contacts to none or one.
/// Activity is measured in contact frames: while two fingers stay on the
/// pad the gesture stays alive, however long the preview is held, and the
/// recognizer tells the service so (`onActive`). Until 3.3.0 only a zone
/// change refreshed the service's 1.2 s timer, so holding one preview hid it
/// and the later lift had nothing to apply (audit 2026-10-28 F05).
///
/// Everything else that ends a gesture cancels it, and a cancelled gesture
/// stays spent until the fingers lift, so its remains can never start a new
/// snap:
/// - a third finger (the start of Mission Control or a three-finger trigger;
///   until 3.3.0 this committed the snap);
/// - a gap of more than `frameGap` between frames (sleep and wake, a device
///   reset, a lost lift frame), so a stale start position cannot turn the
///   next touch into an instant swipe;
/// - the service giving up on its own (`cancelUntilLift`), e.g. when frames
///   stopped altogether or the Mac went to sleep;
/// - frames from a second trackpad are ignored while the gesture's own
///   trackpad is live.
final class TitleBarSnapRecognizer {
    var engage: Float = 0.05
    var tier2: Float = 0.16
    var ratio: Float = 1.3
    var crossEngage: Float = 0.06
    var crossShare: Float = 0.45
    /// Frames arrive at 60 Hz or more while fingers rest on the pad; a longer
    /// silence means the touch sequence was interrupted.
    var frameGap: Double = 0.25
    /// How often an engaged gesture reports that it is still held.
    var activeInterval: Double = 0.25

    /// Engaged with a stroke; the service captures the window.
    var onBegin: ((SwishSnap.Stroke) -> Void)?
    /// The stroke changed while engaged; the service moves the preview.
    var onUpdate: ((SwishSnap.Stroke) -> Void)?
    /// Still engaged, fingers on the pad (at most every `activeInterval`).
    var onActive: (() -> Void)?
    /// The fingers lifted after engaging; commit the current preview.
    var onCommit: (() -> Void)?
    /// The gesture fell apart before committing; hide the preview.
    var onCancel: (() -> Void)?

    private enum Phase { case idle, tracking, engaged, spent }
    private var phase: Phase = .idle
    private var startX: Float = 0
    private var startY: Float = 0
    private var axis: SwishSnap.Axis = .horizontal
    private var last: SwishSnap.Stroke?
    /// The trackpad that owns the current gesture; nil while idle.
    private var device: UInt64?
    private var lastFrameAt: Double = 0
    private var lastActiveAt: Double = 0

    func feed(contacts: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        if let owner = self.device {
            if owner != device {
                // Another trackpad: ignore it while the gesture's own is live.
                guard timestamp - lastFrameAt > frameGap else { return }
                abandon()
            } else if timestamp - lastFrameAt > frameGap {
                abandon()
            }
        }
        lastFrameAt = timestamp
        let count = contacts.count
        switch phase {
        case .idle:
            if count >= 3 { phase = .spent; self.device = device; return }
            guard count == 2 else { return }
            phase = .tracking
            self.device = device
            (startX, startY) = Self.centroid(contacts)
        case .tracking:
            guard count == 2 else {
                onCancel?()
                if count >= 3 { phase = .spent } else { clear() }
                return
            }
            let (cx, cy) = Self.centroid(contacts)
            let dx = cx - startX, dy = cy - startY
            guard let direction = SwishSnap.direction(dx: dx, dy: dy, engage: engage, ratio: ratio) else { return }
            phase = .engaged
            axis = direction.axis
            let stroke = SwishSnap.Stroke(direction, tier: SwishSnap.tier(dx: dx, dy: dy, tier2: tier2))
            last = stroke
            lastActiveAt = timestamp
            onBegin?(stroke)
        case .engaged:
            if count <= 1 { clear(); onCommit?(); return }
            if count >= 3 { phase = .spent; onCancel?(); return }
            // Two fingers are still down: this frame is activity, whether or
            // not the stroke changed.
            if timestamp - lastActiveAt >= activeInterval {
                lastActiveAt = timestamp
                onActive?()
            }
            let (cx, cy) = Self.centroid(contacts)
            guard let stroke = SwishSnap.refine(dx: cx - startX, dy: cy - startY, axis: axis, previous: last,
                                                engage: engage, tier2: tier2, ratio: ratio,
                                                crossEngage: crossEngage, crossShare: crossShare) else { return }
            axis = stroke.direction.axis
            if stroke != last {
                last = stroke
                onUpdate?(stroke)
            }
        case .spent:
            if count <= 1 { clear() }
        }
    }

    /// Silently forgets any gesture in progress (the service is already
    /// hiding its preview, e.g. because the feature or AOM was turned off).
    func reset() { clear() }

    /// The service has already cancelled (its watchdog fired, or the Mac is
    /// going to sleep): end the gesture without callbacks and ignore the
    /// fingers until they lift, so the remains cannot start a new snap.
    func cancelUntilLift() {
        if phase == .tracking || phase == .engaged { phase = .spent }
    }

    /// Ends an interrupted gesture, telling the service if it had begun.
    private func abandon() {
        if phase == .tracking || phase == .engaged { onCancel?() }
        clear()
    }

    private func clear() {
        phase = .idle; device = nil; last = nil; axis = .horizontal
    }

    private static func centroid(_ contacts: [TouchPoint]) -> (Float, Float) {
        ((contacts[0].x + contacts[1].x) / 2, (contacts[0].y + contacts[1].y) / 2)
    }
}

// MARK: - Service

/// Set once on the main actor; read from the multitouch frame handler, so the
/// handler never has to reach the main-actor singleton. A nil handler
/// (feature never initialised) simply does nothing. Arguments: the contacts,
/// the frame timestamp and the trackpad's device ID.
nonisolated(unsafe) var aomTitleBarSnapFeed: (([TouchPoint], Double, UInt64) -> Void)?

/// Owns the recognizer, the preview overlay, the pre-snap history and the
/// commit. The `handle` entry point is called from `TrackpadMonitor`'s
/// multitouch callback; all UI and Accessibility work hops to the main actor.
final class TitleBarWindowSnap {
    @MainActor static let shared = TitleBarWindowSnap()

    static let enabledKey = "AOMTitleBarSnapEnabled"
    static let hapticKey = "AOMTitleBarSnapHaptic"
    static let marginKey = "AOMTitleBarSnapMargin"
    /// Swish `activateAfterSnapping`: raise and focus the snapped window. Default on.
    static let activateKey = "AOMTitleBarSnapActivate"
    /// Swish `snappingMoveCursor`: put the pointer back on the snapped window's
    /// title bar so the next swipe chains. Default off.
    static let keepPointerKey = "AOMTitleBarSnapKeepPointer"

    /// What lifting the fingers will do: move to a layout cell, or (layout nil)
    /// restore the frame the window had before AOM snapped it.
    struct Plan: Equatable {
        var layout: CustomSnapZone.Layout?
        var rect: CGRect
    }

    /// Read on the multitouch thread, written on main. A stale bool for one
    /// frame is harmless.
    private nonisolated(unsafe) var active = false
    private let recognizer = TitleBarSnapRecognizer()

    @MainActor private var target: WindowManager.Target?
    @MainActor private var targetVisible: CGRect?
    @MainActor private var startFrame: CGRect?
    @MainActor private var plan: Plan?
    @MainActor private var committing = false
    @MainActor private var history = SwishSnapHistory()
    @MainActor private var overlay = SnapPreviewOverlay()
    @MainActor private var timeout: DispatchWorkItem?

    @MainActor
    private init() {
        recognizer.onBegin = { stroke in
            DispatchQueue.main.async { TitleBarWindowSnap.shared.begin(stroke) }
        }
        recognizer.onUpdate = { stroke in
            DispatchQueue.main.async { TitleBarWindowSnap.shared.update(stroke) }
        }
        recognizer.onActive = { DispatchQueue.main.async { TitleBarWindowSnap.shared.stillHeld() } }
        recognizer.onCommit = { DispatchQueue.main.async { TitleBarWindowSnap.shared.commit() } }
        recognizer.onCancel = { DispatchQueue.main.async { TitleBarWindowSnap.shared.cancel() } }
        aomTitleBarSnapFeed = { [weak self] contacts, timestamp, device in
            self?.handle(contacts: contacts, timestamp: timestamp, device: device)
        }
        // Settings › General can flip the feature too; pick that up live. The
        // permission watchdog reports Accessibility being granted after launch
        // (or revoked), which used to leave the snap off until the next
        // settings change or relaunch.
        for name in [Notification.Name.aomSettingChanged, PermissionWatchdog.accessibilityLost,
                     PermissionWatchdog.accessibilityRecovered] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.refreshEnabled() }
            }
        }
        // A gesture never survives sleep: the trackpad stream stops without a
        // lift, and the window may be elsewhere on wake.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.abandonGesture() }
            }
        }
        refreshEnabled()
    }

    @MainActor
    func refreshEnabled() {
        let on = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        active = on && AXIsProcessTrusted() && AutomationGate.isOn
        if !active { cancel() }
    }

    /// From `TrackpadMonitor.source.onFrame`. Cheap and non-blocking: it
    /// forwards to the recognizer only while the snap is on and AOM is not
    /// switched off; otherwise any half-seen gesture is forgotten so it
    /// cannot resume with a stale start when the snap comes back.
    nonisolated func handle(contacts: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        guard Self.feedsRecognizer(active: active, automationOn: AutomationGate.isOn) else { recognizer.reset(); return }
        // The service cancelled on its own since the last frame: the
        // recognizer drops the gesture too, so both reset together.
        if cancelRequests != handledCancelRequests {
            handledCancelRequests = cancelRequests
            recognizer.cancelUntilLift()
        }
        recognizer.feed(contacts: contacts, timestamp: timestamp, device: device)
    }

    /// Bumped on main by `abandonGesture`, read on the multitouch thread
    /// (like `active`, a stale value for one frame is harmless).
    private nonisolated(unsafe) var cancelRequests = 0
    /// Multitouch-thread only.
    private nonisolated(unsafe) var handledCancelRequests = 0

    /// The pause rules of the snap (audit 2026-10-28 F04), shared by the
    /// frame handler and the two places that act on a window, so the gate
    /// cannot drift out of one of them. The test host cannot run the AX part.
    nonisolated static func feedsRecognizer(active: Bool, automationOn: Bool) -> Bool { active && automationOn }
    nonisolated static func mayMoveWindow(active: Bool, gateAllows: Bool) -> Bool { active && gateAllows }

    /// The common pause check, consulted where the snap would act: when it
    /// captures a window and again when it moves it.
    @MainActor private var allowedNow: Bool { Self.mayMoveWindow(active: active, gateAllows: AutomationGate.allows(.trackpad)) }

    // MARK: Transitions (main actor)

    @MainActor
    private func begin(_ stroke: SwishSnap.Stroke) {
        // Only engage over a window's title bar, so the gesture never competes
        // with AOM's other two-finger gestures elsewhere on screen. A swipe that
        // starts while the previous snap is still settling is ignored.
        guard !committing else { return }
        guard allowedNow else { hideOwnPreview(); reset(); return }
        let mouse = NSEvent.mouseLocation
        let pointerTopLeft = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        guard let window = WindowManager.shared.captureTarget(atMousePoint: mouse),
              let frame = WindowManager.shared.frame(of: window),
              SwishSnap.titleBarHit(pointerTopLeft: pointerTopLeft, windowFrame: frame) else {
            hideOwnPreview(); reset(); return
        }
        let screens = WindowManager.shared.screens()
        guard let index = WindowGeometry.screenIndex(for: frame, screens: screens.map(\.frame)) else {
            reset(); return
        }
        target = window
        targetVisible = screens[index].visible
        startFrame = frame
        scheduleTimeout()
        showPreview(for: stroke, zoneHaptic: false)
    }

    @MainActor
    private func update(_ stroke: SwishSnap.Stroke) {
        guard target != nil, !committing else { return }
        scheduleTimeout()
        showPreview(for: stroke, zoneHaptic: true)
    }

    /// Fingers still on the pad with the preview up: keep it.
    @MainActor
    private func stillHeld() {
        guard target != nil, !committing else { return }
        scheduleTimeout()
    }

    /// The service gives up on its own (no frames, sleep): hide the preview
    /// and make the recognizer drop the gesture as well.
    @MainActor
    private func abandonGesture() {
        cancel()
        cancelRequests &+= 1
    }

    @MainActor
    private func showPreview(for stroke: SwishSnap.Stroke, zoneHaptic: Bool) {
        guard let target, let visible = targetVisible, let start = startFrame else { return }
        let next = plan(for: stroke, target: target, visible: visible, start: start)
        // Swish taps the trackpad as the preview moves to a new zone.
        if zoneHaptic, next != plan, hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        plan = next
        overlay.show(frame: SwishSnap.appKitRect(next.rect, primaryTop: primaryTop), restoring: next.layout == nil)
    }

    /// A plain swipe down on a window that still sits where AOM snapped it
    /// unsnaps it; every other stroke maps to its layout cell.
    @MainActor
    private func plan(for stroke: SwishSnap.Stroke, target: WindowManager.Target,
                      visible: CGRect, start: CGRect) -> Plan {
        if stroke == SwishSnap.Stroke(.down),
           let original = history.restoreFrame(key: Self.key(target), current: start) {
            return Plan(layout: nil, rect: original)
        }
        let layout = SwishSnap.layout(for: stroke)
        return Plan(layout: layout, rect: SwishSnap.targetFrame(layout: layout, visible: visible, margin: margin))
    }

    @MainActor
    private func commit() {
        timeout?.cancel(); timeout = nil
        // A lift that arrives while the previous snap is still landing belongs
        // to a gesture that never engaged; leave the in-flight commit alone.
        guard !committing else { return }
        // Paused (or switched off) while the fingers were down: never move the window.
        guard allowedNow, let target, let visible = targetVisible,
              let plan, let start = startFrame else {
            hideOwnPreview(); reset(); return
        }
        committing = true
        let restoring = plan.layout == nil
        let key = Self.key(target)
        // Anchor inside the margin-inset area, so a gap the user asked for is
        // kept when an app refuses the cell's size.
        let anchorArea = margin > 0 ? visible.insetBy(dx: margin, dy: margin) : visible
        WindowManager.shared.applySnap(plan.rect, target: target, visible: restoring ? nil : anchorArea) { actual in
            // `applySnap` reports on the main thread (its settle polling runs there).
            MainActor.assumeIsolated {
                TitleBarWindowSnap.shared.finishCommit(actual, target: target, key: key,
                                                       start: start, restoring: restoring)
            }
        }
    }

    @MainActor
    private func finishCommit(_ actual: CGRect?, target: WindowManager.Target, key: String,
                              start: CGRect, restoring: Bool) {
        committing = false
        defer { reset() }
        guard let actual else { hideOwnPreview(); return }
        if restoring { history.forget(key: key) } else { history.recordSnap(key: key, from: start, to: actual) }
        if hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        overlay.settle(on: SwishSnap.appKitRect(actual, primaryTop: primaryTop))
        if Self.flag(Self.activateKey, default: true) { bringForward(target) }
        if Self.flag(Self.keepPointerKey, default: false) {
            CGWarpMouseCursorPosition(SwishSnap.titleBarRestPoint(for: actual))
            // A warp briefly suppresses local mouse events; re-associate so
            // the pointer moves again immediately.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    @MainActor
    private func cancel() {
        timeout?.cancel(); timeout = nil
        hideOwnPreview()
        reset()
    }

    /// Hides the preview only when this gesture put one up, so a gesture that
    /// never engaged cannot cut the previous snap's settle animation short.
    @MainActor
    private func hideOwnPreview() {
        if overlay.isShowing { overlay.hide() }
    }

    @MainActor
    private func reset() {
        target = nil; targetVisible = nil; startFrame = nil; plan = nil
    }

    @MainActor
    private func scheduleTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem {
            // A commit in flight owns the overlay until it lands.
            guard !TitleBarWindowSnap.shared.committing else { return }
            TitleBarWindowSnap.shared.abandonGesture()
        }
        timeout = item
        // A held stroke reports itself every 0.25 s (`stillHeld`), so this
        // watchdog only fires when contact frames stop arriving altogether
        // (a trackpad that vanished mid-gesture).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Swish raises and activates the window it snapped; a background window
    /// would otherwise land in place but stay hidden behind others.
    @MainActor
    private func bringForward(_ target: WindowManager.Target) {
        _ = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return }
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    @MainActor private static func key(_ target: WindowManager.Target) -> String {
        "\(target.pid):\(CFHash(target.window))"
    }

    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    @MainActor private var hapticsOn: Bool { Self.flag(Self.hapticKey, default: true) }

    @MainActor private var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    @MainActor
    private var margin: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: Self.marginKey) as? Double ?? 0)
    }
}

// MARK: - Preview overlay

/// The translucent rounded rectangle shown while swiping, in a borderless,
/// non-activating, click-through window at a floating level — the mechanism
/// Swish uses for its snapping preview. Frame changes animate briefly, and not
/// at all under Reduce Motion (the preview then jumps and fades).
@MainActor
final class SnapPreviewOverlay {
    private var panel: NSPanel?
    private let view = SnapPreviewView()
    /// Bumped by every `show()`. Fade completions from an earlier gesture
    /// check it, so a swipe that starts while the last snap is still fading
    /// keeps its own preview.
    private var generation = 0
    /// Whether the current gesture has put a preview on screen.
    private(set) var isShowing = false

    func show(frame: CGRect, restoring: Bool = false) {
        generation += 1
        isShowing = true
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view.setStyle(committed: false, restoring: restoring)
        if panel.frame == .zero || !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if AOMDesign.reduceMotion {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Swish animates its preview to the frame the window really took
    /// (`setFrame:display:animate:` after reading `AXFrame` back), then hides
    /// it; a size-limited window therefore shows where it actually landed.
    func settle(on frame: CGRect) {
        guard let panel, panel.isVisible else { return }
        isShowing = false
        let started = generation
        view.setStyle(committed: true, restoring: false)
        let fade = { [weak self] in
            guard let self, self.generation == started else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == started else { return }
                self.view.setStyle(committed: false, restoring: false)
                self.panel?.orderOut(nil)
            })
        }
        guard !AOMDesign.reduceMotion, !WindowGeometry.close(panel.frame, frame) else {
            panel.setFrame(frame, display: true)
            fade()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { fade() })
    }

    func hide() {
        isShowing = false
        guard let panel, panel.isVisible else { return }
        let started = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == started else { return }
            self.panel?.orderOut(nil)
        })
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
        panel.setAccessibilityElement(false)
        panel.contentView = view
        return panel
    }
}

/// A rounded accent rectangle: the fill deepens on commit, and a restore of
/// the pre-snap frame draws a dashed outline so it reads as "put it back"
/// rather than another snap. Increase Contrast and Reduce Transparency get a
/// stronger fill and a solid edge.
private final class SnapPreviewView: NSView {
    private var committed = false
    private var restoring = false
    private let outline = CAShapeLayer()

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = nil
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { nil }

    func setStyle(committed: Bool, restoring: Bool) {
        guard committed != self.committed || restoring != self.restoring else { return }
        self.committed = committed
        self.restoring = restoring
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateOutlinePath()
    }

    private func updateOutlinePath() {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: inset, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    override func updateLayer() {
        guard let layer else { return }
        let workspace = NSWorkspace.shared
        let strong = workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
        let accent = NSColor.controlAccentColor
        let base: CGFloat = restoring ? 0.12 : 0.20
        layer.backgroundColor = accent.withAlphaComponent(committed ? 0.34 : (strong ? base + 0.12 : base)).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        updateOutlinePath()
        outline.strokeColor = accent.withAlphaComponent(strong ? 1 : 0.95).cgColor
        outline.lineWidth = strong ? 3 : 2
        outline.lineDashPattern = restoring ? [7, 5] : nil
    }
}
