import AppKit

/// Swish keeps each window's frame from before its first snap so the window
/// can be unsnapped. Pure; the service keys windows by `pid:CFHash(window)`.
struct SwishSnapHistory {
    struct Entry: Equatable {
        /// Where the window was before the first snap of the current chain.
        var original: CGRect
        /// The frame the window really took at its last snap.
        var snapped: CGRect
        /// The place AOM snapped it to (a grid cell, the centre or
        /// almost-maximize), so the next swipe moves on from there even when
        /// a size-limited app is not exactly the cell's size.
        var place: SwishSnap.Place? = nil

        /// The tiling layout of `place`, when it has one.
        var layout: CustomSnapZone.Layout? { place?.layout }
    }

    private(set) var entries: [String: Entry] = [:]
    private var order: [String] = []
    var limit = 64

    mutating func recordSnap(key: String, from start: CGRect, to actual: CGRect, place: SwishSnap.Place?) {
        if var entry = entries[key] {
            if !WindowGeometry.close(entry.snapped, start) { entry.original = start }
            entry.snapped = actual
            entry.place = place
            entries[key] = entry
            return
        }
        entries[key] = Entry(original: start, snapped: actual, place: place)
        order.append(key)
        if order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
    }

    /// The window was moved for it, not by hand (re-snapped after a display
    /// change, or following a neighbour's resize): it stays snapped in its
    /// place, and an unsnap still restores the frame from before the chain.
    mutating func moveSnapped(key: String, to actual: CGRect) {
        entries[key]?.snapped = actual
    }

    /// The cell AOM last snapped the window to, while it still sits there.
    func cell(key: String, current: CGRect) -> CustomSnapZone.Layout? {
        place(key: key, current: current)?.layout
    }

    /// The place AOM last snapped the window to, while it still sits there.
    func place(key: String, current: CGRect) -> SwishSnap.Place? {
        guard let entry = entries[key], WindowGeometry.close(entry.snapped, current) else { return nil }
        return entry.place
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

/// Classifies a two-finger swipe from raw contact frames, plus the other
/// title-bar gestures: a pinch in or out (only from a touch that has not engaged a
/// swipe, and never turning into one), a tap (the service pairs taps into a
/// double tap), and tap-and-hold (fingers resting `holdTime` before the swipe
/// mark its strokes `held`). It is fed from one thread only, allocates nothing
/// per frame and reports state transitions through closures (which the service
/// hops to the main thread).
///
/// Only lifting the fingers commits: going from two contacts to none or one.
/// Activity is measured in contact frames: while two fingers stay on the pad
/// the gesture stays alive, and the recognizer tells the service so
/// (`onActive`). Fingers held perfectly still for `holdCancelTime` (Swish's
/// 2 s) cancel on purpose, with the preview fading over the last second; any
/// movement keeps the gesture.
///
/// Everything else that ends a gesture cancels it, and a cancelled gesture
/// stays spent until the fingers lift, so its remains can never start a new
/// snap:
/// - a third finger (the start of Mission Control or a three-finger trigger);
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
    /// Two fingers must have rested this long before a swipe can engage, so
    /// the settling of a touch-down is never read as a swipe.
    var settleTime: Double = 0.04
    /// Fingers that lift within `tapTime` of landing without ever travelling
    /// `tapTravel` made a tap: it cancels instead of snapping (3.3.2: a
    /// two-finger tap on a title bar used to maximize the window).
    var tapTime: Double = 0.18
    var tapTravel: Float = 0.065
    /// A contact whose size falls below this share of its peak is lifting.
    /// Its last positions slide towards the top of the pad, which read as a
    /// swipe up, so those frames never engage or change the stroke.
    var liftShare: Float = 0.55
    /// Swish's hold-still cancel (3.3.2): fingers that stay still for this
    /// long, before or after the swipe engaged, cancel the gesture. The
    /// preview fades out and lifting does nothing. 0 turns it off.
    var holdCancelTime: Double = 2.0
    /// How far (pad units) the centroid or the finger spread may wander and
    /// still count as held still. Resting fingers jitter by about 0.003, but
    /// a resting hand drifts further over 2 s: 0.012 (about 1.2–1.9 mm) let
    /// that drift restart the hold clock (3.3.2 review), so 0.018.
    var stillRadius: Float = 0.018
    /// Swish's tap and hold (3.3.2): fingers resting this long, on the same
    /// still clock as the hold-still cancel, before a swipe or pinch make the
    /// touch a held one for the rest of it; its strokes carry `held`. 0
    /// turns it off. 2 s of stillness still spends the touch.
    var holdTime: Double = 0.45
    /// A pinch needs the fingers to land at least this far apart (pad
    /// units); closer together, a spread ratio means nothing.
    var pinchMinSpread: Float = 0.05
    /// Spread ratios (now ÷ at touch-down) that make a pinch in or out, and
    /// the band the ratio must come back into to let the pinch go again.
    var pinchInRatio: Float = 0.72
    var pinchOutRatio: Float = 1.38
    var pinchRelease: ClosedRange<Float> = 0.85...1.18
    /// Swish's multi-motion engine (3.3.3, audit F01): "you can swipe and
    /// pinch in the same direction multiple times in a row without lifting
    /// your fingers. Just pause your movement briefly and haptic feedback will
    /// let you know when it's time to continue." An engaged swipe or a pinch
    /// whose fingers rest this long is locked in (`onMotionReady`). The next
    /// movement from there commits it (`onCommit` or `onPinch`, as a lift
    /// would) and starts another swipe or pinch from where the fingers paused,
    /// in the same touch. Lifting still commits, a third finger still cancels
    /// the gesture on show, and resting on to `holdCancelTime` still cancels
    /// it; motions already committed stay. 0 turns it off (3.3.2: one gesture
    /// per touch).
    var motionPause: Double = 0.25

    /// Two fingers landed: the service can look up the window under the
    /// pointer now, before the swipe engages (the pointer does not move
    /// while two fingers rest or scroll).
    var onTouchDown: (() -> Void)?
    /// Engaged with a stroke; the service captures the window.
    var onBegin: ((SwishSnap.Stroke) -> Void)?
    /// The stroke changed while engaged; the service moves the preview.
    var onUpdate: ((SwishSnap.Stroke) -> Void)?
    /// Still engaged or pinching, fingers on the pad (at most every
    /// `activeInterval`), with how long they have been held still, in seconds.
    var onActive: ((Double) -> Void)?
    /// The fingers lifted after engaging; commit the current preview.
    var onCommit: (() -> Void)?
    /// The gesture fell apart before committing; hide the preview.
    var onCancel: (() -> Void)?
    /// The fingers were held still for `holdCancelTime` after engaging,
    /// pinching or a tap-and-hold. The gesture is spent until they lift.
    /// Without a handler `onCancel` runs.
    var onHoldCancel: (() -> Void)?
    /// The fingers came together (`.in`) or apart (`.out`) far enough to be
    /// a pinch, or (nil) went back to about where they landed. Only a touch
    /// that never engaged a swipe can pinch, and a pinch never swipes.
    var onPinchChange: ((SwishSnap.Pinch?) -> Void)?
    /// The fingers lifted while pinching.
    var onPinch: ((SwishSnap.Pinch) -> Void)?
    /// A tap (lifted within `tapTime` without travelling `tapTravel`), with
    /// the lift's timestamp. Reported right after the tap's `onCancel`.
    var onTap: ((Double) -> Void)?
    /// The fingers rested `holdTime` before swiping: the touch is held.
    var onHoldBegan: (() -> Void)?
    /// The swipe or pinch on show rested `motionPause`: the next movement
    /// commits it and starts another gesture (Swish answers with a haptic).
    var onMotionReady: (() -> Void)?
    /// The touch that `onTouchDown` reported is over: its fingers lifted, the
    /// stream had a gap, or another trackpad took over. Runs after the
    /// commit, pinch, tap or cancel callbacks of that lift.
    var onTouchEnd: (() -> Void)?
    /// The fingers lifted after a tap and hold that never swiped or pinched
    /// (after its `onCancel`): the tab detach (F02) acts on it.
    var onHoldLift: (() -> Void)?
    /// N335: the fingers took an engaged swipe back to where it started
    /// (within `withdrawShare` of the engage distance): nothing is on show,
    /// and lifting now does nothing (its `onCommit` finds no plan). Swiping
    /// out past the engage distance again, any way, re-engages with
    /// `onUpdate`.
    var onWithdraw: (() -> Void)?
    /// How close to where it started (a share of `engage`) a swipe must come
    /// back to be withdrawn. Re-engaging needs the whole engage distance, so
    /// fingers resting at the edge do not flicker in and out.
    var withdrawShare: Float = 0.5

    /// N338: whether a sideways swipe that rested may turn its corner into
    /// an L (`cornerTurn`). The service clears it while ⌥ or ⌘ make the
    /// sideways swipe an action (a Space or display move), so those keep
    /// committing before the next motion. Written on main as a gesture
    /// begins and read here a pause later; a stale value for a frame is
    /// harmless, as with `motionPause`.
    var cornerTurns = true
    /// N338: the step the centroid's path is cut into to find an L's vertical
    /// leg (`trackTurn`), in pad units: well above resting jitter (0.003).
    var turnStep: Float = 0.01
    /// tan 35°: how far from vertical on the glass a step may lean and still
    /// be the vertical leg of an L (the 10–20° drift of a hand going up), and
    /// from horizontal and still be the sideways leg.
    static let turnSlope: Float = 0.7

    /// How many motions the current touch has committed before the one in
    /// progress (0: its first gesture). Only a first gesture can be a tap.
    private(set) var motionIndex = 0

    /// Whether the current touch (or, inside the callbacks of its lift, the
    /// touch that just ended) rested `holdTime` before swiping or pinching.
    /// Reset when the next touch lands.
    private(set) var isHeld = false

    private enum Phase { case idle, tracking, engaged, pinching, spent }
    private var phase: Phase = .idle
    private var startX: Float = 0
    private var startY: Float = 0
    private var axis: SwishSnap.Axis = .horizontal
    private var last: SwishSnap.Stroke?
    /// The trackpad that owns the current gesture; nil while idle.
    private var device: UInt64?
    private var lastFrameAt: Double = 0
    private var lastActiveAt: Double = 0
    private var startedAt: Double = 0
    /// The furthest the centroid has been from the start (pad units).
    private var maxTravel: Float = 0
    /// Peak contact sizes by contact id, for the lift-off guard.
    private var peakID: (Int, Int) = (-1, -1)
    private var peakSize: (Float, Float) = (0, 0)
    /// Where the fingers last moved to, and since when they have been still.
    private var stillX: Float = 0
    private var stillY: Float = 0
    private var stillSpread: Float = 0
    private var stillSince: Double = 0
    /// The finger spread at touch-down, and the pinch on show (nil: released).
    private var startSpread: Float = 0
    private var pinch: SwishSnap.Pinch?
    /// Multi-motion: the gesture on show rested `motionPause` and waits for
    /// the next movement, which is measured from where the fingers paused.
    private var locked = false
    private var pauseX: Float = 0
    private var pauseY: Float = 0
    private var pauseSpread: Float = 0
    /// `onTouchDown` ran for the current touch, so `onTouchEnd` is owed.
    private var touchReported = false
    /// The service asked to start the touch over (`rearm`); applied on the
    /// next two-finger frame.
    private var rearmPending = false
    /// N335: the engaged swipe was taken back to its start (`onWithdraw`).
    private var withdrawn = false
    /// N338: where the current step of the path began, and the vertical
    /// travel of the L's vertical leg so far (`trackTurn`).
    private var turnAnchorX: Float = 0
    private var turnAnchorY: Float = 0
    private var turnTravel: Float = 0
    /// The travel began straight off the sideways leg, not as a reversal.
    private var turnFromSideways = true

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
        if rearmPending, count == 2, phase == .tracking || phase == .engaged || phase == .pinching {
            rearmPending = false
            restart(contacts, at: timestamp)
            return
        }
        switch phase {
        case .idle:
            rearmPending = false
            if count >= 3 { phase = .spent; self.device = device; return }
            guard count == 2 else { return }
            phase = .tracking
            self.device = device
            startedAt = timestamp
            maxTravel = 0
            isHeld = false
            pinch = nil
            locked = false
            motionIndex = 0
            peakID = (contacts[0].id, contacts[1].id)
            peakSize = (contacts[0].size, contacts[1].size)
            (startX, startY) = Self.centroid(contacts)
            startSpread = Self.spread(contacts)
            (stillX, stillY, stillSpread) = (startX, startY, startSpread)
            stillSince = timestamp
            touchReported = true
            onTouchDown?()
        case .tracking:
            guard count == 2 else {
                // Lifted soon after landing without travelling: a tap. A
                // third finger is never one.
                let tap = count <= 1 && isTap(at: timestamp)
                let heldLift = count <= 1 && isHeld && motionIndex == 0
                onCancel?()
                if count >= 3 { phase = .spent } else { endTouch() }
                if tap { onTap?(timestamp) }
                if heldLift { onHoldLift?() }
                if count <= 1 { touchEnded() }
                return
            }
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            let still = stillTime(cx, cy, spread, at: timestamp)
            // Resting on the title bar without swiping: after the hold time
            // nothing this touch does can act any more. A tap-and-hold that
            // never swiped is told, so the service can drop what it showed.
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                if isHeld { holdCancelled() }
                return
            }
            if !isHeld, holdTime > 0, still >= holdTime {
                isHeld = true
                onHoldBegan?()
            }
            let dx = cx - startX, dy = cy - startY
            let travel = (dx * dx + dy * dy).squareRoot()
            maxTravel = max(maxTravel, travel)
            guard timestamp - startedAt >= settleTime else { return }
            if let kind = pinchKind(from: startSpread, spread: spread, travel: travel) {
                phase = .pinching
                pinch = kind
                lastActiveAt = timestamp
                restartPauseClock(cx, cy, spread, at: timestamp)
                onPinchChange?(kind)
                return
            }
            guard let stroke = engagedStroke(dx: dx, dy: dy) else { return }
            phase = .engaged
            axis = stroke.direction.axis
            last = stroke
            lastActiveAt = timestamp
            restartPauseClock(cx, cy, spread, at: timestamp)
            restartTurn(cx, cy)
            onBegin?(stroke)
        case .engaged:
            if count <= 1 {
                let tap = isTap(at: timestamp)
                endTouch()
                if tap { onCancel?(); onTap?(timestamp) } else { onCommit?() }
                touchEnded()
                return
            }
            if count >= 3 { phase = .spent; locked = false; onCancel?(); return }
            // Two fingers are still down: this frame is activity, whether or
            // not the stroke changed.
            reportActivity(at: timestamp)
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            // Swish: holding the fingers still cancels the snap on show.
            let still = stillTime(cx, cy, spread, at: timestamp)
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                locked = false
                holdCancelled()
                return
            }
            if locked { continueMotion(cx, cy, spread, at: timestamp); return }
            if motionPause > 0, last != nil, pauseTime(cx, cy, spread, at: timestamp) >= motionPause {
                lock(cx, cy, spread); return
            }
            let dx = cx - startX, dy = cy - startY
            let distance = (dx * dx + dy * dy).squareRoot()
            maxTravel = max(maxTravel, distance)
            if withdrawn {
                // N335: out again past the engage distance, any way.
                guard let stroke = engagedStroke(dx: dx, dy: dy) else { return }
                withdrawn = false
                axis = stroke.direction.axis
                last = stroke
                restartPauseClock(cx, cy, spread, at: timestamp)
                restartTurn(cx, cy)
                onUpdate?(stroke)
                return
            }
            if last != nil, distance < engage * withdrawShare {
                // N335: back where it started: the swipe is taken back.
                withdrawn = true
                last = nil
                onWithdraw?()
                return
            }
            trackTurn(cx, cy)
            guard var stroke = SwishSnap.refine(dx: dx, dy: dy, axis: axis, previous: last,
                                                engage: engage, tier2: tier2, ratio: ratio,
                                                crossEngage: crossEngage, crossShare: crossShare,
                                                turn: turn(dy: dy)) else { return }
            stroke.held = isHeld
            if stroke.direction.axis != axis { restartTurn(cx, cy) }
            axis = stroke.direction.axis
            if stroke != last {
                last = stroke
                onUpdate?(stroke)
            }
        case .pinching:
            if count <= 1 {
                let kind = pinch
                endTouch()
                if let kind { onPinch?(kind) } else { onCancel?() }
                touchEnded()
                return
            }
            if count >= 3 { phase = .spent; locked = false; onCancel?(); return }
            reportActivity(at: timestamp)
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            let still = stillTime(cx, cy, spread, at: timestamp)
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                locked = false
                holdCancelled()
                return
            }
            if locked { continueMotion(cx, cy, spread, at: timestamp); return }
            if motionPause > 0, pinch != nil, pauseTime(cx, cy, spread, at: timestamp) >= motionPause {
                lock(cx, cy, spread); return
            }
            // Hysteresis: a pinch in holds until the fingers are back near
            // where they landed, and the same for a pinch out.
            let ratio = spread / startSpread
            var next = pinch
            if ratio <= pinchInRatio { next = .in }
            else if ratio >= pinchOutRatio { next = .out }
            else if pinchRelease.contains(ratio) { next = nil }
            if next != pinch {
                pinch = next
                onPinchChange?(next)
            }
        case .spent:
            if count <= 1 { endTouch(); touchEnded() }
        }
    }

    /// The stroke a movement of (dx, dy) from the start engages, or nil: a
    /// diagonal goes straight into its quarter; otherwise the dominant axis,
    /// once it is clear enough.
    private func engagedStroke(dx: Float, dy: Float) -> SwishSnap.Stroke? {
        var stroke: SwishSnap.Stroke
        if let diagonal = SwishSnap.diagonal(dx: dx, dy: dy, engage: engage) {
            stroke = diagonal
        } else if let direction = SwishSnap.direction(dx: dx, dy: dy, engage: engage, ratio: ratio) {
            stroke = SwishSnap.Stroke(direction)
        } else { return nil }
        stroke.tier = SwishSnap.tier(dx: dx, dy: dy, tier2: tier2)
        stroke.held = isHeld
        return stroke
    }

    /// Multi-motion: the gesture on show rested `motionPause`. It stays what
    /// it is; the next movement is measured from here.
    private func lock(_ cx: Float, _ cy: Float, _ spread: Float) {
        locked = true
        (pauseX, pauseY, pauseSpread) = (cx, cy, spread)
        onMotionReady?()
    }

    /// Multi-motion: a locked gesture and fingers on the move again. Once
    /// they pinch or swipe from where they paused (the same thresholds as a
    /// new touch, no settle or tap: the touch is long past both), the locked
    /// gesture commits and the new one begins from the pause point.
    private func continueMotion(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) {
        let dx = cx - pauseX, dy = cy - pauseY
        let travel = (dx * dx + dy * dy).squareRoot()
        if let kind = pinchKind(from: pauseSpread, spread: spread, travel: travel) {
            commitLocked()
            phase = .pinching
            startSpread = pauseSpread
            (startX, startY) = (pauseX, pauseY)
            pinch = kind
            last = nil
            lastActiveAt = timestamp
            restartPauseClock(cx, cy, spread, at: timestamp)
            onPinchChange?(kind)
            return
        }
        guard let stroke = engagedStroke(dx: dx, dy: dy) else { return }
        if let corner = cornerTurn(from: last, into: stroke) {
            // N338: the sideways swipe on show turns its corner instead of
            // committing: one L, as if the fingers had never rested.
            locked = false
            last = corner
            lastActiveAt = timestamp
            restartPauseClock(cx, cy, spread, at: timestamp)
            (turnAnchorX, turnAnchorY, turnTravel, turnFromSideways) = (cx, cy, dy, true)
            onUpdate?(corner)
            return
        }
        commitLocked()
        phase = .engaged
        withdrawn = false
        (startX, startY) = (pauseX, pauseY)
        startSpread = pauseSpread
        pinch = nil
        axis = stroke.direction.axis
        last = stroke
        lastActiveAt = timestamp
        restartPauseClock(cx, cy, spread, at: timestamp)
        restartTurn(cx, cy)
        onBegin?(stroke)
    }

    /// N338 (the user's rule): within one touch, a plain sideways swipe that
    /// rested `motionPause` and then goes up is an L, the top quarter of that
    /// side, as the same turn made without resting is (3.3.7 committed the
    /// half and maximized: an up starting a new motion maximizes). Only a
    /// plain up after a plain sideways swipe (no cross leg, not held, no ⌥
    /// or ⌘ while `cornerTurns`); every other next motion commits the one on
    /// show and starts afresh. Down keeps that order (the half, then its
    /// bottom quarter), so its results stay what they were.
    private func cornerTurn(from locked: SwishSnap.Stroke?, into next: SwishSnap.Stroke) -> SwishSnap.Stroke? {
        guard phase == .engaged, cornerTurns, let locked, locked.direction.axis == .horizontal,
              locked.cross == nil, !locked.held, !next.held, next.direction == .up, next.cross == nil else { return nil }
        return SwishSnap.Stroke(locked.direction, tier: locked.tier, cross: .up)
    }

    /// N338: the vertical leg of an L that began sideways. The centroid's
    /// path is cut into steps of `turnStep`; a step within `turnSlope` of
    /// vertical on the glass adds its vertical travel, and a step within it
    /// of horizontal (the sideways leg going on, or the arc of a straight
    /// swipe) clears it. Steps in between leave it as it is. A vertical step
    /// the other way starts the travel again as a reversal (`turn(dy:)`).
    private func trackTurn(_ cx: Float, _ cy: Float) {
        guard axis == .horizontal else { turnTravel = 0; return }
        let sx = cx - turnAnchorX, sy = cy - turnAnchorY
        guard (sx * sx + sy * sy).squareRoot() >= turnStep else { return }
        (turnAnchorX, turnAnchorY) = (cx, cy)
        let glassX = abs(sx) * SwishSnap.padAspect, glassY = abs(sy)
        if glassX <= glassY * Self.turnSlope {
            if turnTravel == 0 {
                turnTravel = sy
                turnFromSideways = true
            } else if (turnTravel < 0) == (sy < 0) {
                turnTravel += sy
            } else {
                turnTravel = sy
                turnFromSideways = false
            }
        } else if glassY <= glassX * Self.turnSlope {
            turnTravel = 0
        }
    }

    /// The L's vertical leg for `refine`: the travel straight off the
    /// sideways leg, wherever the sideways leg drifted (left drifting down,
    /// then up, is still the top quarter). A reversal (up, then back down)
    /// only counts once it is past the start line (`dy` from the start) that
    /// way, so coming back down after an up leg first releases the corner.
    private func turn(dy: Float) -> Float {
        turnFromSideways || (turnTravel < 0) == (dy < 0) ? turnTravel : 0
    }

    private func restartTurn(_ cx: Float, _ cy: Float) {
        (turnAnchorX, turnAnchorY, turnTravel, turnFromSideways) = (cx, cy, 0, true)
    }

    /// Commits the locked gesture as its lift would have (N337: also when the
    /// fingers swipe on the same way; 3.3.5–3.3.6 held a swipe up or down
    /// back for the double swipe).
    private func commitLocked() {
        locked = false
        motionIndex += 1
        switch phase {
        case .engaged:
            onCommit?()
        case .pinching:
            if let kind = pinch { onPinch?(kind) }
        default:
            break
        }
    }

    /// The service handed this touch to another window (`beginChain`) or the
    /// tab it detached: whatever the fingers do next starts a new gesture from
    /// where they are, as a further motion of the touch (never a tap, never
    /// held). Applied on the next two-finger frame; only a live touch (not a
    /// spent one) is restarted. No callbacks.
    func rearm() { rearmPending = true }

    private func restart(_ contacts: [TouchPoint], at timestamp: Double) {
        phase = .tracking
        locked = false
        withdrawn = false
        isHeld = false
        pinch = nil
        last = nil
        axis = .horizontal
        motionIndex += 1
        maxTravel = 0
        startedAt = timestamp - settleTime
        (startX, startY) = Self.centroid(contacts)
        startSpread = Self.spread(contacts)
        (stillX, stillY, stillSpread) = (startX, startY, startSpread)
        stillSince = timestamp
        lastActiveAt = timestamp
        restartPauseClock(startX, startY, startSpread, at: timestamp)
        restartTurn(startX, startY)
    }

    /// A lift soon after landing that never travelled `tapTravel` is a tap.
    /// Once a swipe has engaged (its preview is up) a lift is a tap only if
    /// the fingers moved less than `min(tapTravel, engagedTapShare × engage)`
    /// (3.3.2 review): under `tapTravel` alone, every quick flick between the
    /// engage distance (4 % of the pad at "Quick", 3.1 % at "Instant") and
    /// 6.5 % flashed a preview and then did nothing, which read as "the snap
    /// reacts slowly". The lift-slide behind 3.3.1's "a tap maximizes" is
    /// stopped by `liftShare`, the touch-down settle by `settleTime`.
    private func isTap(at timestamp: Double) -> Bool {
        // A further motion of a touch (multi-motion, a re-armed touch) is long past a tap.
        guard motionIndex == 0 else { return false }
        let travel = phase == .engaged ? min(tapTravel, Self.engagedTapShare * engage) : tapTravel
        return timestamp - startedAt < tapTime && maxTravel < travel
    }

    /// The share of the engage distance an engaged swipe's lift may have
    /// travelled and still count as a tap.
    static let engagedTapShare: Float = 0.6

    private func reportActivity(at timestamp: Double) {
        guard timestamp - lastActiveAt >= activeInterval else { return }
        lastActiveAt = timestamp
        onActive?(timestamp - stillSince)
    }

    private func holdCancelled() {
        if let onHoldCancel { onHoldCancel() } else { onCancel?() }
    }

    /// A pinch: fingers that were apart enough at `base` (touch-down, or
    /// where a multi-motion paused), whose spread changed past a pinch ratio
    /// and by more than their centroid travelled (a swipe moves the centroid;
    /// a pinch mostly changes the spread).
    private func pinchKind(from base: Float, spread: Float, travel: Float) -> SwishSnap.Pinch? {
        guard base > pinchMinSpread, abs(spread - base) > travel else { return nil }
        let ratio = spread / base
        if ratio <= pinchInRatio { return .in }
        if ratio >= pinchOutRatio { return .out }
        return nil
    }

    /// Tracks each contact's peak size; true while either contact has shrunk
    /// below `liftShare` of it (the finger is coming off the pad). Contacts
    /// that report no size (0) never count as lifting.
    private func isLifting(_ contacts: [TouchPoint]) -> Bool {
        var lifting = false
        for contact in contacts.prefix(2) {
            if contact.id == peakID.0 {
                peakSize.0 = max(peakSize.0, contact.size)
                if peakSize.0 > 0, contact.size < peakSize.0 * liftShare { lifting = true }
            } else if contact.id == peakID.1 {
                peakSize.1 = max(peakSize.1, contact.size)
                if peakSize.1 > 0, contact.size < peakSize.1 * liftShare { lifting = true }
            }
        }
        return lifting
    }

    /// Follows the fingers for the hold gestures: any move of the centroid or
    /// the spread beyond `stillRadius` restarts the clock. Returns how long
    /// they have stayed put (`holdTime` holds the touch, `holdCancelTime`
    /// cancels it).
    private func stillTime(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) -> Double {
        let wx = cx - stillX, wy = cy - stillY
        if (wx * wx + wy * wy).squareRoot() > stillRadius || abs(spread - stillSpread) > stillRadius {
            (stillX, stillY, stillSpread) = (cx, cy, spread)
            stillSince = timestamp
            return 0
        }
        return timestamp - stillSince
    }

    /// How far (pad units) the fingers may move and still count as the
    /// multi-motion pause. Tighter than `stillRadius`, which allows for a
    /// resting hand drifting over 2 s: a slow swipe moving less than that in
    /// `motionPause` must not lock half-way.
    var pauseRadius: Float = 0.008
    private var pauseAnchorX: Float = 0
    private var pauseAnchorY: Float = 0
    private var pauseAnchorSpread: Float = 0
    private var pauseSince: Double = 0

    /// The multi-motion clock: how long the fingers have stayed within
    /// `pauseRadius` (centroid and spread).
    private func pauseTime(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) -> Double {
        let wx = cx - pauseAnchorX, wy = cy - pauseAnchorY
        if (wx * wx + wy * wy).squareRoot() > pauseRadius || abs(spread - pauseAnchorSpread) > pauseRadius {
            restartPauseClock(cx, cy, spread, at: timestamp)
            return 0
        }
        return timestamp - pauseSince
    }

    private func restartPauseClock(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) {
        (pauseAnchorX, pauseAnchorY, pauseAnchorSpread) = (cx, cy, spread)
        pauseSince = timestamp
    }

    /// Silently forgets any gesture in progress (the service is already
    /// hiding its preview, e.g. because the feature or AOM was turned off).
    func reset() { clear(); touchReported = false; rearmPending = false }

    /// The service has already cancelled (its watchdog fired, or the Mac is
    /// going to sleep): end the gesture without callbacks and ignore the
    /// fingers until they lift, so the remains cannot start a new snap.
    func cancelUntilLift() {
        if phase == .tracking || phase == .engaged || phase == .pinching { phase = .spent; locked = false }
    }

    /// Ends an interrupted gesture, telling the service if it had begun.
    private func abandon() {
        if phase == .tracking || phase == .engaged || phase == .pinching { onCancel?() }
        clear()
        touchEnded()
    }

    private func clear() {
        phase = .idle; device = nil; last = nil; axis = .horizontal; pinch = nil; locked = false; withdrawn = false
        turnTravel = 0
    }

    /// The touch's fingers lifted: back to idle (callbacks follow).
    private func endTouch() { clear() }

    /// Reports the end of a touch that `onTouchDown` announced, once.
    private func touchEnded() {
        guard touchReported else { return }
        touchReported = false
        onTouchEnd?()
    }

    /// The centroid in the pad coordinates `SwishSnap` works in: x grows to
    /// the right and y toward the BOTTOM of the pad, like the screen, so dy > 0
    /// is a swipe down. TouchPoint's y grows toward the top of the pad (the
    /// MultitouchSupport and NSTouch convention, which `LiveTouchView`, the
    /// gesture engine uses: a swipe up is +y), so
    /// it is flipped here. Until 3.3.2 it was not, and every vertical title-bar
    /// swipe ran the other way on a real trackpad: a swipe down maximized or
    /// went to the top quarter, so a window at the top never reached a bottom
    /// quarter, and a swipe up centred or minimized it.
    private static func centroid(_ contacts: [TouchPoint]) -> (Float, Float) {
        ((contacts[0].x + contacts[1].x) / 2, 1 - (contacts[0].y + contacts[1].y) / 2)
    }

    private static func spread(_ contacts: [TouchPoint]) -> Float {
        let dx = contacts[0].x - contacts[1].x, dy = contacts[0].y - contacts[1].y
        return (dx * dx + dy * dy).squareRoot()
    }
}
