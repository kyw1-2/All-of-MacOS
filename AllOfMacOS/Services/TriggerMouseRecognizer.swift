import Foundation
import CoreGraphics

/// Pure Normal Mouse recognizer (multi-click counting, long press, discrete
/// drag direction, scroll direction). It never reads a clock, an event tap, or
/// preferences: callers feed it events with explicit timestamps and read back
/// the triggers that completed, so it can be exercised with synthetic streams.
struct MouseGestureRecognizer {

    struct Config: Equatable {
        /// Max gap between presses that still count as the next click.
        var multiClickInterval: TimeInterval = 0.5
        /// Max travel (points) between presses of one multi-click.
        var multiClickDistance: Double = 6
        var longPressDuration: TimeInterval = 0.5
        /// Travel (points) before a held button counts as a drag.
        var dragThreshold: Double = 40
        /// Accumulated scroll delta (points) per scroll trigger firing.
        var scrollStep: Double = 30
        /// Minimum time between scroll firings, so momentum scrolling does not machine-gun.
        var scrollMinInterval: TimeInterval = 0.12
    }

    /// A completed trigger. `modifiers` are those held when the originating
    /// press (or scroll event) happened.
    struct Output: Equatable {
        let spec: MouseTriggerSpec
        let modifiers: UInt
    }

    private struct Press {
        var start: (x: Double, y: Double)
        var startTime: TimeInterval
        var modifiers: UInt
        var count: Int
        var longDeadline: TimeInterval?
        var longFired = false
        var dragFired = false
        var dragTracked: Bool
    }
    private struct LastClick { var time: TimeInterval; var x: Double; var y: Double; var count: Int }
    private struct PendingClick { var spec: MouseTriggerSpec; var modifiers: UInt; var deadline: TimeInterval }

    let config: Config
    private let wanted: Set<MouseTriggerSpec>
    private var presses: [Int: Press] = [:]
    private var lastClick: [Int: LastClick] = [:]
    private var pending: [Int: PendingClick] = [:]
    private var scrollStepper: ScrollStepper

    init(config: Config, wanted: Set<MouseTriggerSpec>) {
        self.config = config
        self.wanted = wanted
        self.scrollStepper = ScrollStepper(step: config.scrollStep, minInterval: config.scrollMinInterval)
    }

    // MARK: Derived registration facts

    private func clickCounts(_ button: Int) -> Set<Int> {
        Set(wanted.compactMap { $0.button == button ? $0.kind.clickCount : nil })
    }
    private func hasKind(_ button: Int, where test: (MouseTriggerKind) -> Bool) -> Bool {
        wanted.contains { $0.button == button && test($0.kind) }
    }
    /// Clicks must wait for release when the same button can also long-press or
    /// drag, otherwise the click would fire before we know it was one.
    private func clicksFireOnRelease(_ button: Int) -> Bool {
        hasKind(button) { $0 == .longPress || $0.isDrag }
    }

    /// The earliest time `poll` could produce output, so a caller can sleep exactly that long.
    var nextDeadline: TimeInterval? {
        var all: [TimeInterval] = pending.values.map(\.deadline)
        all += presses.values.compactMap { $0.longFired ? nil : $0.longDeadline }
        return all.min()
    }

    // MARK: Events

    mutating func buttonDown(_ button: Int, x: Double, y: Double, time: TimeInterval, modifiers: UInt) -> [Output] {
        var count = 1
        if let last = lastClick[button], time - last.time <= config.multiClickInterval,
           hypot(x - last.x, y - last.y) <= config.multiClickDistance {
            count = last.count + 1
        }
        // Past the highest configured multi-click the sequence restarts, so a
        // lone single-click trigger still fires on every rapid click.
        if count > (clickCounts(button).max() ?? 1) { count = 1 }
        lastClick[button] = LastClick(time: time, x: x, y: y, count: count)
        presses[button] = Press(
            start: (x, y), startTime: time, modifiers: modifiers, count: count,
            longDeadline: hasKind(button) { $0 == .longPress } ? time + config.longPressDuration : nil,
            dragTracked: hasKind(button) { $0.isDrag })
        // A new press supersedes a pending shorter click of the same button.
        if pending[button] != nil, clickCounts(button).contains(count) { pending[button] = nil }
        guard !clicksFireOnRelease(button) else { return [] }
        return resolveClick(button, count: count, time: time, modifiers: modifiers)
    }

    mutating func buttonUp(_ button: Int, time: TimeInterval) -> [Output] {
        guard let press = presses.removeValue(forKey: button) else { return [] }
        if press.longFired || press.dragFired {
            // A hold or drag never chains into a double click.
            lastClick[button] = nil
            return []
        }
        guard clicksFireOnRelease(button) else { return [] }
        return resolveClick(button, count: press.count, time: time, modifiers: press.modifiers)
    }

    mutating func moved(x: Double, y: Double, time: TimeInterval) -> [Output] {
        var out: [Output] = []
        for (button, press) in presses where press.dragTracked && !press.dragFired && !press.longFired {
            let dx = x - press.start.x, dy = y - press.start.y
            guard hypot(dx, dy) >= config.dragThreshold else { continue }
            var updated = press
            updated.dragFired = true
            presses[button] = updated
            // Screen coordinates grow downward; "up" is toward smaller y.
            let kind: MouseTriggerKind = abs(dx) >= abs(dy) ? (dx > 0 ? .dragRight : .dragLeft) : (dy > 0 ? .dragDown : .dragUp)
            lastClick[button] = nil
            let spec = MouseTriggerSpec(button: button, kind: kind)
            if wanted.contains(spec) { out.append(Output(spec: spec, modifiers: press.modifiers)) }
        }
        return out
    }

    /// `dx`/`dy` are scroll deltas as reported by the system (positive `dy` = up,
    /// positive `dx` = right). The dominant axis of each event decides direction.
    mutating func scroll(dx: Double, dy: Double, time: TimeInterval, modifiers: UInt) -> [Output] {
        let wantedKinds = Set(wanted.filter { $0.kind.isScroll }.map(\.kind))
        guard let kind = scrollStepper.feed(dx: dx, dy: dy, time: time, wanted: wantedKinds) else { return [] }
        return [Output(spec: MouseTriggerSpec(button: 0, kind: kind), modifiers: modifiers)]
    }

    /// Emits long presses and deferred clicks whose deadline has passed.
    mutating func poll(now: TimeInterval) -> [Output] {
        var out: [Output] = []
        for (button, press) in presses {
            guard !press.longFired, !press.dragFired, let deadline = press.longDeadline, now >= deadline else { continue }
            var updated = press
            updated.longFired = true
            presses[button] = updated
            lastClick[button] = nil
            out.append(Output(spec: MouseTriggerSpec(button: button, kind: .longPress), modifiers: press.modifiers))
        }
        for (button, click) in pending where now >= click.deadline {
            pending[button] = nil
            out.append(Output(spec: click.spec, modifiers: click.modifiers))
        }
        return out
    }

    mutating func reset() {
        presses.removeAll(); lastClick.removeAll(); pending.removeAll(); scrollStepper.reset()
    }

    // MARK: Click decision

    private mutating func resolveClick(_ button: Int, count: Int, time: TimeInterval, modifiers: UInt) -> [Output] {
        let counts = clickCounts(button)
        guard let kind = MouseTriggerKind.allCases.first(where: { $0.clickCount == count }) else { return [] }
        let spec = MouseTriggerSpec(button: button, kind: kind)
        guard counts.contains(count) else { return [] }
        if count >= (counts.max() ?? count) {
            pending[button] = nil
            return [Output(spec: spec, modifiers: modifiers)]
        }
        // A longer click is registered too: wait to see whether it arrives.
        pending[button] = PendingClick(spec: spec, modifiers: modifiers, deadline: time + config.multiClickInterval)
        return []
    }
}


/// Turns a stream of scroll deltas into discrete up/down/left/right steps:
/// accumulate along the dominant axis, fire once per `step`, and rate-limit so
/// momentum scrolling does not machine-gun. Shared by Normal Mouse scroll and
/// trackpad "Scroll Up/Down (modifier key needed)".
struct ScrollStepper {
    var step: Double
    var minInterval: TimeInterval
    private var accum: [MouseTriggerKind: Double] = [:]
    private var lastFire: TimeInterval = -.infinity

    init(step: Double = 30, minInterval: TimeInterval = 0.12) {
        self.step = step; self.minInterval = minInterval
    }

    mutating func reset() { accum.removeAll(); lastFire = -.infinity }

    /// Returns the scroll kind that just completed a step, if it is in `wanted`.
    mutating func feed(dx: Double, dy: Double, time: TimeInterval, wanted: Set<MouseTriggerKind>) -> MouseTriggerKind? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        let kind: MouseTriggerKind
        let amount: Double
        if abs(dy) >= abs(dx) { kind = dy > 0 ? .scrollUp : .scrollDown; amount = abs(dy) }
        else { kind = dx > 0 ? .scrollRight : .scrollLeft; amount = abs(dx) }
        let opposite: MouseTriggerKind = [.scrollUp: .scrollDown, .scrollDown: .scrollUp,
                                          .scrollLeft: .scrollRight, .scrollRight: .scrollLeft][kind]!
        accum[opposite] = 0 // reversing direction restarts accumulation
        guard wanted.contains(kind) else { return nil }
        accum[kind, default: 0] += amount
        guard accum[kind, default: 0] >= step, time - lastFire >= minInterval else { return nil }
        accum[kind] = 0
        lastFire = time
        return kind
    }
}
