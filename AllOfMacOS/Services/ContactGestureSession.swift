import AppKit

/// One independent state machine per physical device. Raw contact states have
/// already been filtered; neither pointer clicks nor another device can change
/// the identities/counts in this session.
struct ContactGestureSession {
    var points: [TouchPoint] = []
    private(set) var peak = 0
    private var peakTime: Double = 0
    private var origins: [Int: TouchPoint] = [:]
    private var travel: Float = 0
    private var consumed = false
    private var lastTimestamp: Double?
    private var restSince: Double = 0
    private var restOrigins: [Int: TouchPoint] = [:]
    private var tip: Tip?
    private var lastTipTime = -Double.infinity
    private var swipe = ContactSwipeRecognizer()
    private var pinchStart: (distance: Float, angle: Float)?
    private var pairIDs: [Int] = []
    // BTT parity additions: touch start / long touch / release / edge swipe.
    private var countSince: Double = 0
    private var holdSince: Double = 0
    private var holdAnchors: [Int: TouchPoint] = [:]
    private var touchStartFired = Set<Int>()
    private var longTouchFired = Set<String>()
    private var edgeOrigin2: PadEdge?
    private var edgeSwipeFired = false
    private var consumedByLongTouch = false
    /// The Long Touch duration (seconds) that produced the most recent
    /// `*LongTouch` result, so the caller can route it to the triggers that
    /// configured exactly that duration.
    private(set) var lastLongTouchDuration: Double?
    /// Fingers must stay in the same place this much (normalized) to count as resting.
    static let longTouchMoveTolerance: Float = 0.03
    /// A finger count must persist this long before Touch Start fires, so
    /// fingers that land a frame apart report the final count only.
    static let touchStartSettle: Double = 0.05
    /// Fingers within this distance of a pad side count as "on the edge".
    static let edgeZone: Float = 0.12
    /// Inward travel needed for "2 Finger Swipe From Edge".
    static let edgeSwipeDistance: Float = 0.10

    enum PadEdge { case left, right, top, bottom }

    /// The pad side both fingers started on, or nil when they began in the interior.
    static func twoFingerEdge(_ points: [TouchPoint]) -> PadEdge? {
        guard points.count == 2 else { return nil }
        let zone = edgeZone
        let candidates: [(PadEdge, Bool, Float)] = [
            (.left, points.allSatisfy { $0.x < zone }, points.map(\.x).max() ?? 1),
            (.right, points.allSatisfy { $0.x > 1 - zone }, 1 - (points.map(\.x).min() ?? 0)),
            (.top, points.allSatisfy { $0.y > 1 - zone }, 1 - (points.map(\.y).min() ?? 0)),
            (.bottom, points.allSatisfy { $0.y < zone }, points.map(\.y).max() ?? 1)]
        return candidates.filter { $0.1 }.min { $0.2 < $1.2 }?.0
    }

    /// Where a 3-finger tap landed: nil for the middle band.
    static func threeFingerTapRegion(centroidY: Float) -> TrackpadGesture? {
        if centroidY > 0.60 { return .threeFingerTapTop }
        if centroidY < 0.40 { return .threeFingerTapBottom }
        return nil
    }
    private struct Tip {
        var rest: [Int: TouchPoint]
        var tapper: TouchPoint
        var started: Double
        var gesture: TrackpadGesture
        var interruptedAt: Double?
    }

    mutating func consume() { consumed = true; tip = nil }

    /// A single-finger tap resolved by where the finger rested, following
    /// BTT's zone map. Corners win over the side/middle strips, exactly as the
    /// click zones do, so a tap and a click in the same spot agree.
    static func positionalTap(at point: TouchPoint) -> TrackpadGesture {
        let x = point.x, y = point.y
        let corner: Float = 0.18, middle: Float = 0.20
        if x < corner && y > 1 - corner { return .oneFingerTapTopLeft }
        if x > 1 - corner && y > 1 - corner { return .oneFingerTapTopRight }
        if x < corner && y < corner { return .oneFingerTapBottomLeft }
        if x > 1 - corner && y < corner { return .oneFingerTapBottomRight }
        if y > 1 - middle {
            return abs(x - 0.5) < 0.2 ? .oneFingerTapTopMiddle : (x < 0.5 ? .oneFingerTapTopLeft : .oneFingerTapTopRight)
        }
        if y < middle {
            return abs(x - 0.5) < 0.2 ? .oneFingerTapBottomMiddle : (x < 0.5 ? .oneFingerTapBottomLeft : .oneFingerTapBottomRight)
        }
        if x < middle { return .oneFingerTapLeftSideMiddle }
        if x > 1 - middle { return .oneFingerTapRightSideMiddle }
        return .oneFingerTap
    }

    /// The edge swipe for a 1-finger swipe that started on an edge, or nil for
    /// a swipe that began on the body of the pad. The edge decides which axis
    /// counts, so a diagonal drag along the top edge is a horizontal swipe.
    static func edgeSwipe(origin: TouchPoint, dx: Float, dy: Float) -> TrackpadGesture? {
        let edge: Float = 0.12
        let horizontal = abs(dx) > abs(dy)
        if origin.x < edge { return dy > 0 ? .oneFingerSwipeUpOnLeftEdge : .oneFingerSwipeDownOnLeftEdge }
        if origin.x > 1 - edge { return dy > 0 ? .oneFingerSwipeUpOnRightEdge : .oneFingerSwipeDownOnRightEdge }
        if origin.y > 1 - edge {
            return horizontal ? (dx > 0 ? .oneFingerSwipeRightOnTopEdge : .oneFingerSwipeLeftOnTopEdge) : nil
        }
        if origin.y < edge {
            return horizontal ? (dx > 0 ? .oneFingerSwipeRightOnBottomEdge : .oneFingerSwipeLeftOnBottomEdge) : nil
        }
        return nil
    }

    /// The click gesture for a pressed contact at this finger count, or nil
    /// when the count has no click. A single finger is deliberately excluded:
    /// it is an ordinary click, which the window server already handles.
    static func clickGesture(fingers: Int) -> TrackpadGesture? {
        switch fingers {
        case 2: return .twoFingerClick
        case 3: return .threeFingerClick
        case 4: return .fourFingerClick
        case 5: return .fiveFingerClick
        default: return nil
        }
    }
    mutating func reset() { self = Self() }

    /// Maps a finger count and direction to the pinch case, or nil when the
    /// count has no pinch gesture (which is why the caller guards on it).
    private func pinchGesture(fingers: Int, outward: Bool) -> TrackpadGesture? {
        switch fingers {
        case 2: return outward ? .twoFingerPinchOut : .twoFingerPinchIn
        case 3: return outward ? .threeFingerPinchOut : .threeFingerPinchIn
        case 4: return outward ? .fourFingerPinchOut : .fourFingerPinchIn
        case 5: return outward ? .fiveFingerPinchOut : .fiveFingerPinchIn
        default: return nil
        }
    }

    private func rotateGesture(fingers: Int, clockwise: Bool) -> TrackpadGesture? {
        switch fingers {
        case 2: return clockwise ? .twoFingerRotateLeft : .twoFingerRotateRight
        case 3: return clockwise ? .threeFingerRotateLeft : .threeFingerRotateRight
        case 4: return clockwise ? .fourFingerRotateLeft : .fourFingerRotateRight
        case 5: return clockwise ? .fiveFingerRotateLeft : .fiveFingerRotateRight
        default: return nil
        }
    }

    mutating func update(_ next: [TouchPoint], timestamp: Double, pressed: Bool,
                         enabled: Set<TrackpadGesture>, restTime: Double,
                         minVelocity: (TrackpadGesture) -> CGFloat,
                         longTouchDurations: (TrackpadGesture) -> [Double] = { _ in [0.5] }) -> [TrackpadGesture] {
        guard timestamp.isFinite else { return [] }
        if let lastTimestamp, timestamp < lastTimestamp { return [] }
        let previous = points
        defer { points = next; lastTimestamp = timestamp }
        var result: [TrackpadGesture] = []
        let ids = Set(next.map(\.id))
        let previousIDs = Set(previous.map(\.id))
        lastLongTouchDuration = nil
        if previous.isEmpty && !next.isEmpty {
            peak = 0; travel = 0; consumed = false; origins = [:]; swipe = ContactSwipeRecognizer()
            pinchStart = nil; pairIDs = []
            touchStartFired.removeAll(); longTouchFired.removeAll(); edgeOrigin2 = nil; edgeSwipeFired = false; consumedByLongTouch = false
            if let pending = tip, timestamp - (pending.interruptedAt ?? timestamp) > 0.08 { tip = nil }
        }
        if next.count != previous.count {
            countSince = timestamp; holdSince = timestamp
            holdAnchors = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if next.count > peak {
            peak = next.count; peakTime = timestamp
            origins = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            travel = 0
            edgeOrigin2 = next.count == 2 ? Self.twoFingerEdge(next) : nil
        }
        for point in next {
            if let origin = origins[point.id] { travel = max(travel, hypot(point.x - origin.x, point.y - origin.y)) }
        }
        if pressed { consume() }

        // A TipTap must preserve the resting identities and positions. A third
        // finger outside the resting pair is not a "middle" tap.
        if var candidate = tip {
            if timestamp - candidate.started > 0.35 || pressed {
                tip = nil
            } else if next.isEmpty {
                candidate.interruptedAt = timestamp; tip = candidate
            } else {
                let restIDs = Set(candidate.rest.keys)
                let restStable = next.filter { restIDs.contains($0.id) }.allSatisfy {
                    guard let origin = candidate.rest[$0.id] else { return false }
                    return hypot($0.x - origin.x, $0.y - origin.y) < 0.035
                }
                if ids == restIDs, restStable {
                    // A rejected release is finished too. Retaining it through
                    // cooldown would fire later from stationary anchor frames.
                    if timestamp - lastTipTime >= 0.25, enabled.contains(candidate.gesture) {
                        result.append(candidate.gesture); consumed = true; lastTipTime = timestamp
                    }
                    tip = nil; restSince = timestamp
                } else if !restStable || !ids.isSubset(of: restIDs.union([candidate.tapper.id])) || !restIDs.isSubset(of: ids) {
                    tip = nil
                } else if let moving = next.first(where: { $0.id == candidate.tapper.id }),
                          hypot(moving.x - candidate.tapper.x, moving.y - candidate.tapper.y) > 0.045 {
                    tip = nil
                }
            }
        }
        if !pressed, tip == nil, (previous.count == 1 || previous.count == 2),
           next.count == previous.count + 1, previousIDs.isSubset(of: ids), timestamp - restSince >= restTime,
           let tapper = next.first(where: { !previousIDs.contains($0.id) }) {
            let resting = previous.sorted { $0.x < $1.x }
            let gesture: TrackpadGesture?
            if resting.count == 1 { gesture = tapper.x < resting[0].x ? .tipTapLeft : .tipTapRight }
            else { gesture = tapper.x > resting[0].x && tapper.x < resting[1].x ? .tipTapMiddle : nil }
            if let gesture, enabled.contains(gesture) {
                tip = Tip(rest: Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                          tapper: tapper, started: timestamp, gesture: gesture)
            }
        }
        if next.count <= 2 && tip == nil {
            let stable = ids == previousIDs && next.allSatisfy {
                guard let origin = restOrigins[$0.id] else { return false }
                return hypot($0.x - origin.x, $0.y - origin.y) < 0.025
            }
            if !stable {
                restSince = timestamp
                restOrigins = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }

        // Pinch/rotate and translation compete for ONE action per contact
        // session. Using pair identities avoids rotation when array order flips.
        //
        // Any finger count from two to five is recognized, not just two: a
        // three-finger pinch is a distinct, commonly bound gesture, and
        // restricting this to a pair left those fingers with no pinch at all.
        // The centroid and mean radius generalize the two-finger distance and
        // angle, and for a pair they reduce to exactly the old behavior.
        if !consumed, !pressed, (2...5).contains(peak), next.count == peak, peak >= 2 {
            let sorted = next.sorted { $0.id < $1.id }
            let ids = sorted.map(\.id)
            let centroidX = sorted.reduce(Float(0)) { $0 + $1.x } / Float(sorted.count)
            let centroidY = sorted.reduce(Float(0)) { $0 + $1.y } / Float(sorted.count)
            // Mean radius stands in for the pair's half-distance; the angle to
            // the first finger is a stable rotation reference for any count.
            let radius = sorted.reduce(Float(0)) {
                $0 + hypot($1.x - centroidX, $1.y - centroidY)
            } / Float(sorted.count)
            let angle = atan2(sorted[0].y - centroidY, sorted[0].x - centroidX)

            if ids != pairIDs || pinchStart == nil {
                pairIDs = ids; pinchStart = (radius, angle)
            } else if let initial = pinchStart, initial.distance > 0.02 {
                let scale = radius / initial.distance - 1
                var rotation = angle - initial.angle
                if rotation > .pi { rotation -= 2 * .pi }
                if rotation < -.pi { rotation += 2 * .pi }
                // A three-finger pinch moves the radius less than a two-finger
                // one for the same finger travel, so the bar scales down.
                let scaleThreshold: Float = peak == 2 ? 0.15 : 0.12
                let pinch = pinchGesture(fingers: peak, outward: scale > 0)
                let rotate = rotateGesture(fingers: peak, clockwise: rotation > 0)
                if abs(scale) >= scaleThreshold, let pinch, enabled.contains(pinch) {
                    result.append(pinch); consume()
                } else if abs(rotation) >= .pi / 18, let rotate, enabled.contains(rotate) {
                    result.append(rotate); consume()
                }
            }
        }
        // Touch Start: the Nth finger has landed and the count has settled.
        if !pressed, !next.isEmpty, next.count == peak,
           let start = TrackpadGesture.touchStart(fingers: next.count), enabled.contains(start),
           !touchStartFired.contains(next.count), timestamp - countSince >= Self.touchStartSettle {
            touchStartFired.insert(next.count)
            result.append(start)
        }
        // Long Touch: resting (not moving) for the configured duration. Movement restarts the clock.
        // Another gesture consuming the touch blocks a long touch, but a long touch
        // that already fired must not stop a longer-configured one from firing.
        if !pressed, !consumed || consumedByLongTouch, !next.isEmpty, next.count == peak {
            let moved = next.contains { point in
                guard let anchor = holdAnchors[point.id] else { return true }
                return hypot(point.x - anchor.x, point.y - anchor.y) > Self.longTouchMoveTolerance
            }
            if moved {
                holdSince = timestamp
                holdAnchors = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            } else if let long = TrackpadGesture.longTouch(fingers: next.count), enabled.contains(long) {
                let due = longTouchDurations(long).sorted().first {
                    !longTouchFired.contains("\(next.count):\(Int(($0 * 1000).rounded()))") && timestamp - holdSince >= $0 - 1e-6
                }
                if let due {
                    longTouchFired.insert("\(next.count):\(Int((due * 1000).rounded()))")
                    lastLongTouchDuration = due
                    result.append(long); consume(); consumedByLongTouch = true
                }
            }
        }
        // 2-finger swipe from a pad edge takes priority over the plain swipe it would also match.
        var swipeEnabled = enabled
        if let edge = edgeOrigin2, peak == 2 {
            let edgeGestures: [PadEdge: TrackpadGesture] = [.left: .twoFingerSwipeFromLeftEdge, .right: .twoFingerSwipeFromRightEdge,
                                                            .top: .twoFingerSwipeFromTopEdge, .bottom: .twoFingerSwipeFromBottomEdge]
            if let gesture = edgeGestures[edge], enabled.contains(gesture) {
                swipeEnabled.subtract([.twoFingerSwipeUp, .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight])
                if !consumed, !pressed, !edgeSwipeFired, next.count == 2 {
                    let dx = next.reduce(Float(0)) { $0 + ($1.x - (origins[$1.id]?.x ?? $1.x)) } / 2
                    let dy = next.reduce(Float(0)) { $0 + ($1.y - (origins[$1.id]?.y ?? $1.y)) } / 2
                    let inward: Float, across: Float
                    switch edge {
                    case .left: inward = dx; across = dy
                    case .right: inward = -dx; across = dy
                    case .top: inward = -dy; across = dx
                    case .bottom: inward = dy; across = dx
                    }
                    if inward >= Self.edgeSwipeDistance, inward > abs(across) * 1.2 {
                        edgeSwipeFired = true
                        result.append(gesture); consume()
                    }
                }
            }
        }
        if !consumed, !pressed, let detected = swipe.update(next, peak: peak, timestamp: timestamp,
                                                            enabled: swipeEnabled, minVelocity: minVelocity) {
            result.append(detected); consume()
        }
        if next.isEmpty && !previous.isEmpty {
            // Release Last Finger fires however the touch ended (tap, swipe, hold).
            if let release = TrackpadGesture.releaseLast(after: peak), enabled.contains(release) { result.append(release) }
            if enabled.contains(.releaseLastFingerRegardless) { result.append(.releaseLastFingerRegardless) }
            let elapsed = timestamp - peakTime
            let tap: TrackpadGesture?
            switch peak {
            // A single finger resting and lifting without a click is a tap in
            // its own right; BTT distinguishes it from the click that a
            // pressed contact produces, and so does this.
            // A single-finger tap is resolved by where it landed.
            case 1: tap = ContactGestureSession.positionalTap(at: origins.values.first ?? TouchPoint(id: 0, x: 0.5, y: 0.5, size: 0))
            case 2: tap = .twoFingerTap
            case 3:
                // A tap in the top or bottom band is its own gesture when bound.
                let centroidY = origins.isEmpty ? 0.5 : origins.values.reduce(Float(0)) { $0 + $1.y } / Float(origins.count)
                if let region = Self.threeFingerTapRegion(centroidY: centroidY), enabled.contains(region) { tap = region }
                else { tap = .threeFingerTap }
            case 4: tap = .fourFingerTap
            case 5: tap = .fiveFingerTap
            default: tap = nil
            }
            // The tap and swipe travel regions deliberately do not overlap.
            if let tap, !consumed, tip == nil, elapsed >= 0, elapsed < 0.45,
               travel < 0.05 { result.append(tap) }
            origins.removeAll(); restOrigins.removeAll(); pinchStart = nil
        }
        return result
    }
}

struct ContactSwipeRecognizer {
    private var count = 0
    private var origins: [Int: TouchPoint] = [:]
    private var previousDisplacement: (Float, Float) = (0, 0)
    private var lastTime: Double?
    private var recent: [(Double, Float, Float)] = []
    private var fired = false

    mutating func update(_ points: [TouchPoint], peak: Int, timestamp: Double,
                         enabled: Set<TrackpadGesture>, minVelocity: (TrackpadGesture) -> CGFloat) -> TrackpadGesture? {
        guard !fired, (2...5).contains(peak) else { return nil }
        if peak != count {
            count = peak
            origins = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            recent = [(timestamp, 0, 0)]; lastTime = timestamp; previousDisplacement = (0, 0)
            return nil
        }
        let deltas = points.compactMap { p -> (Float, Float)? in
            guard let start = origins[p.id] else { return nil }
            return (p.x - start.x, p.y - start.y)
        }
        // Four and five fingers need three agreeing fingers to steer; a pair
        // needs both, so a wandering finger cannot fake a swipe.
        let required = count >= 4 ? 3 : 2
        guard deltas.count >= required else { return nil }
        // Median prevents one wandering finger/pinky from steering the hand.
        func median(_ values: [Float]) -> Float {
            let s = values.sorted(); return (s[(s.count - 1) / 2] + s[s.count / 2]) / 2
        }
        let dx = median(deltas.map { $0.0 }), dy = median(deltas.map { $0.1 })
        let horizontal = abs(dx) > abs(dy)
        let dominant = horizontal ? dx : dy, secondary = horizontal ? dy : dx
        // Estimate speed over recent physical time, not time spent resting.
        recent.removeAll { timestamp - $0.0 > 0.12 }
        if recent.isEmpty, let lastTime { recent = [(lastTime, previousDisplacement.0, previousDisplacement.1)] }
        let sample = recent.first ?? (timestamp, dx, dy)
        recent.append((timestamp, dx, dy))
        if recent.count > 32 { recent.removeFirst(recent.count - 32) }
        lastTime = timestamp; previousDisplacement = (dx, dy)
        guard abs(dominant) >= 0.055, abs(dominant) > abs(secondary) * 1.2 else { return nil }
        let agreeing = deltas.filter {
            let axis = horizontal ? $0.0 : $0.1
            return axis * dominant > 0 && abs(axis) >= 0.02
        }.count
        guard agreeing >= required else { return nil }
        let direction: SwipeResolver.Direction = horizontal ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
        guard let gesture = SwipeResolver.gesture(fingers: count, direction: direction), enabled.contains(gesture) else { return nil }
        let duration = timestamp - sample.0
        guard duration > 0 else { return nil }
        let distance = horizontal ? dx - sample.1 : dy - sample.2
        // Keep the velocity calculation in Double until the final conversion.
        // macOS 15 toolchains otherwise see ambiguous Float/CGFloat operators.
        let velocity = CGFloat(Double(abs(distance)) * 1000.0 / duration)
        guard velocity >= minVelocity(gesture) else { return nil }
        fired = true
        return gesture
    }
}
