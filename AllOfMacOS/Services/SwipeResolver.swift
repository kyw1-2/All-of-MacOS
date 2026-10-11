import Foundation

/// The decision a trackpad scroll resolves to once it ends.
///
/// The swipe rule — how far the fingers travelled, which axis won, and whether
/// they moved fast enough to count as a flick rather than a scroll — lived
/// inside `TrackpadMonitor.handleScroll`, which is private and driven by
/// NSEvent phases, so none of it was reachable from a test. Pull the decision
/// out as a pure function so the thresholds, the axis tie-break and the
/// direction sign convention can be pinned down directly.
enum SwipeResolver {

    enum Direction { case up, down, left, right }

    struct Decision: Equatable {
        let gesture: TrackpadGesture
        let velocity: CGFloat
        let minVelocity: CGFloat
    }

    /// The gesture for a finger count and direction, or nil when no gesture is
    /// defined for that combination (e.g. a five-finger swipe).
    static func gesture(fingers: Int, direction: Direction) -> TrackpadGesture? {
        switch (fingers, direction) {
        case (2, .up): return .twoFingerSwipeUp
        case (2, .down): return .twoFingerSwipeDown
        case (2, .left): return .twoFingerSwipeLeft
        case (2, .right): return .twoFingerSwipeRight
        case (3, .up): return .threeFingerSwipeUp
        case (3, .down): return .threeFingerSwipeDown
        case (3, .left): return .threeFingerSwipeLeft
        case (3, .right): return .threeFingerSwipeRight
        case (4, .up): return .fourFingerSwipeUp
        case (4, .down): return .fourFingerSwipeDown
        case (4, .left): return .fourFingerSwipeLeft
        case (4, .right): return .fourFingerSwipeRight
        case (5, .up): return .fiveFingerSwipeUp
        case (5, .down): return .fiveFingerSwipeDown
        case (5, .left): return .fiveFingerSwipeLeft
        case (5, .right): return .fiveFingerSwipeRight
        default: return nil
        }
    }

    /// Resolves an ended scroll into the gesture to fire, or nil when it was
    /// too short, has no gesture for its finger count, or was too slow.
    ///
    /// `minVelocityFor` supplies the per-gesture flick threshold; it is a
    /// parameter rather than a lookup so the rule stays free of UserDefaults
    /// and can be exercised with fixed thresholds.
    static func decide(
        deltaX: CGFloat,
        deltaY: CGFloat,
        fingerCount: Int,
        duration: TimeInterval,
        distanceThreshold: CGFloat,
        minVelocityFor: (TrackpadGesture) -> CGFloat
    ) -> Decision? {
        let absX = abs(deltaX)
        let absY = abs(deltaY)
        let maxDelta = max(absX, absY)

        // Distance gates first: below it this was a scroll, not a swipe.
        guard maxDelta > distanceThreshold else { return nil }

        // The dominant axis wins; a positive delta means the content moved
        // left/up, which is a left/up swipe of the fingers.
        let direction: Direction
        if absX > absY {
            direction = deltaX > 0 ? .left : .right
        } else {
            direction = deltaY > 0 ? .up : .down
        }
        guard let gesture = gesture(fingers: fingerCount, direction: direction) else { return nil }

        let velocity = duration > 0 ? maxDelta / CGFloat(duration) : 0
        let minVelocity = minVelocityFor(gesture)
        guard velocity >= minVelocity else { return nil }

        return Decision(gesture: gesture, velocity: velocity, minVelocity: minVelocity)
    }
}
