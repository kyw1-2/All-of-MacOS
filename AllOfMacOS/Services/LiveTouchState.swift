import Foundation

extension Notification.Name {
    static let gestureDidFire = Notification.Name("AOMGestureDidFire")
}

struct TouchPoint: Identifiable, Equatable {
    let id: Int
    var x: Float
    var y: Float
    var size: Float
    /// Normalized contact pressure (0...1). Offset 64 of the 96-byte record
    /// carries the force reading on the built-in trackpad; it stays 0 on
    /// hardware that does not report it, so 0 means "no pressure reading".
    var pressure: Float = 0
}

struct TrailPoint {
    var x: Float
    var y: Float
    var age: TimeInterval // seconds since creation
}

@MainActor
class LiveTouchState: ObservableObject {
    static let shared = LiveTouchState()
    @Published var touches: [TouchPoint] = []
    @Published var isPressed: Bool = false
    @Published var lastFiredTriggerID: UUID?

    /// Trail history per finger ID — each finger gets a list of recent positions
    @Published var trails: [Int: [TrailPoint]] = [:]
    private let maxTrailAge: TimeInterval = 0.6
    private let maxTrailPoints: Int = 40
    private var fadeTimer: Timer?

    // Visualization is deliberately separate from recognition: every hardware
    // frame reaches the recognizer, only the display is coalesced to 30 Hz.
    var visualizerCount = 0
    private var pendingFrame: (points: [TouchPoint], pressed: Bool)?
    private var displayWork: DispatchWorkItem?
    private var lastDisplayTime: TimeInterval = -.infinity

    func present(_ points: [TouchPoint], pressed: Bool, visible: Bool) {
        guard visible else {
            displayWork?.cancel(); displayWork = nil; pendingFrame = nil
            fadeTimer?.invalidate(); fadeTimer = nil
            if !touches.isEmpty { touches = [] }
            if !trails.isEmpty { trails = [:] }
            if isPressed { isPressed = false }
            lastDisplayTime = -.infinity
            return
        }
        pendingFrame = (points, pressed)
        let interval = 1.0 / 30.0
        let elapsed = ProcessInfo.processInfo.systemUptime - lastDisplayTime
        // Contact and button transitions are immediate; motion alone is sampled.
        if points.map(\.id) != touches.map(\.id) || pressed != isPressed || elapsed >= interval {
            displayWork?.cancel(); displayWork = nil
            flushDisplay()
        } else if displayWork == nil {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.displayWork = nil
                    self?.flushDisplay()
                }
            }
            displayWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval - elapsed), execute: item)
        }
    }

    private func flushDisplay() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        lastDisplayTime = ProcessInfo.processInfo.systemUptime
        if isPressed != frame.pressed { isPressed = frame.pressed }
        apply(frame.points)
    }

    nonisolated func update(_ points: [TouchPoint]) {
        if Thread.isMainThread { MainActor.assumeIsolated { apply(points) } }
        else { Task { @MainActor in self.apply(points) } }
    }

    private func apply(_ points: [TouchPoint]) {
        if touches != points { touches = points }
        if points.isEmpty && isPressed { isPressed = false }
        let now = ProcessInfo.processInfo.systemUptime
        var next = trails
        for (id, trail) in next {
            let filtered = trail.filter { now - $0.age < maxTrailAge }
            if filtered.isEmpty { next.removeValue(forKey: id) }
            else { next[id] = filtered }
        }
        for point in points {
            var trail = next[point.id] ?? []
            // A resting finger doesn't need 40 identical line segments.
            if trail.last.map({ hypot($0.x - point.x, $0.y - point.y) >= 0.001 }) ?? true {
                trail.append(TrailPoint(x: point.x, y: point.y, age: now))
            }
            if trail.count > maxTrailPoints { trail.removeFirst(trail.count - maxTrailPoints) }
            next[point.id] = trail
        }
        // One publication for the entire dictionary, not one per finger.
        if !next.isEmpty || !trails.isEmpty { trails = next }
        updateFadeTimer()
    }

    private func updateFadeTimer() {
        if !trails.isEmpty && touches.isEmpty {
            // Need continuous fade — start timer if not running
            if fadeTimer == nil {
                fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.tickFade()
                    }
                }
            }
        } else {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func tickFade() {
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        for (fingerID, trail) in trails {
            let filtered = trail.filter { now - $0.age < maxTrailAge }
            if filtered.count != trail.count {
                changed = true
                if filtered.isEmpty {
                    trails.removeValue(forKey: fingerID)
                } else {
                    trails[fingerID] = filtered
                }
            }
        }
        if trails.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        } else if changed {
            // Force publish change so Canvas redraws
            objectWillChange.send()
        }
    }

    nonisolated func setPressed(_ pressed: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { if isPressed != pressed { isPressed = pressed } }
        } else {
            Task { @MainActor in if self.isPressed != pressed { self.isPressed = pressed } }
        }
    }

    nonisolated func flashTrigger(_ id: UUID) {
        Task { @MainActor in
            self.lastFiredTriggerID = id
            try? await Task.sleep(nanoseconds: 600_000_000)
            if self.lastFiredTriggerID == id {
                self.lastFiredTriggerID = nil
            }
        }
    }
}
