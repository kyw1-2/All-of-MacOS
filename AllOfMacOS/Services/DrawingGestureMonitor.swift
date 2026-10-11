import AppKit

/// Direction-sensitive $1-style recognizer. No ML, network, or idle timers.
enum DrawingRecognizer {
    static let points = 48
    static func interpolate(_ source: [DrawingPoint], at fraction: Double) -> DrawingPoint {
        let distances = zip(source, source.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = distances.reduce(0, +)
        guard total > 0.00001 else { return source[0] }
        let length = fraction * total
        var accumulated = 0.0
        for (i, segment) in distances.enumerated() {
            if accumulated + segment >= length {
                let t = segment > 0 ? (length - accumulated) / segment : 0
                return DrawingPoint(x: source[i].x + (source[i+1].x - source[i].x) * t,
                                    y: source[i].y + (source[i+1].y - source[i].y) * t)
            }
            accumulated += segment
        }
        return source.last!
    }
    static func normalized(_ raw: [DrawingPoint]) -> [DrawingPoint]? {
        guard raw.count >= 8 && raw.count <= 1024,
              raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        let scale = max(width, height)
        guard scale > 0.00001 else { return nil }
        let normalized = raw.map { DrawingPoint(x: ($0.x - (xs.min() ?? 0))/scale,
                                                 y: ($0.y - (ys.min() ?? 0))/scale) }
        return (0..<points).map { interpolate(normalized, at: Double($0) / Double(points - 1)) }
    }
    /// 0 = identical, larger values = less similar. Stroke direction is preserved.
    static func distance(_ candidate: [DrawingPoint], _ template: [DrawingPoint]) -> Double? {
        guard let a = normalized(candidate), let b = normalized(template) else { return nil }
        return zip(a,b).reduce(0.0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) } / Double(points)
    }
    static func certainty(from distance: Double) -> Double {
        max(0, min(1, 1 - distance / 0.7))
    }
    static func score(_ input: [DrawingPoint], template: [DrawingPoint], directionIndependent: Bool) -> Double? {
        guard let forward = distance(input, template) else { return nil }
        guard directionIndependent, let reverse = distance(input, Array(template.reversed())) else { return forward }
        return min(forward, reverse)
    }
    static func bestMatch(_ input: [DrawingPoint], among triggers: [Trigger], threshold: Double = 0.21) -> Trigger? {
        let scores = triggers.compactMap { trigger -> (Trigger,Double)? in
            let distances = trigger.drawingSamples.compactMap {
                score(input, template: $0, directionIndependent: trigger.drawingIgnoreDirection)
            }
            guard let distance = distances.min(), distance <= threshold,
                  certainty(from: distance) >= trigger.drawingCertainty else { return nil }
            return (trigger, distance)
        }.sorted { $0.1 < $1.1 }
        guard let best = scores.first else { return nil }
        // Ambiguous templates should not accidentally execute a competing action.
        if scores.count > 1 && scores[1].1 - best.1 < 0.045 { return nil }
        return best.0
    }
}

/// Drawing mode: hold Control+Option and drag the trackpad pointer with one finger.
/// Observes gestures only when enabled drawing triggers exist. Does not swallow events.
final class DrawingGestureMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var triggers: [Trigger] = []
    private var groups: [ActivationGroup] = []
    private var path: [DrawingPoint] = []
    private var started: CGPoint?
    private var startedApp: String?
    private var drawing = false
    private let maxPoints = 256

    func registerTriggers(_ all: [Trigger], groups: [ActivationGroup]) {
        stop()
        triggers = all.filter { trigger in
            guard trigger.isEnabled, !trigger.drawingSamples.isEmpty else { return false }
            if case .drawingPattern = trigger.input { return true }
            return false
        }
        self.groups = groups
        guard !triggers.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.process(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.process(event)
        }
    }
    private func reset() {
        path.removeAll(keepingCapacity: true); started = nil; startedApp = nil; drawing = false
    }
    private func process(_ event: NSEvent) {
        let flags = event.modifierFlags
        let active = flags.contains(.control) && flags.contains(.option)
        switch event.type {
        case .leftMouseDown:
            reset()
            guard active, UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true else { return }
            started = NSEvent.mouseLocation
            startedApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            drawing = true
            let point = NSEvent.mouseLocation
            path.append(DrawingPoint(x: Double(point.x), y: Double(point.y)))
        case .leftMouseDragged:
            guard drawing else { return }
            guard active, startedApp == NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { reset(); return }
            guard path.count < maxPoints else { return }
            let point = NSEvent.mouseLocation
            path.append(DrawingPoint(x: Double(point.x), y: Double(point.y)))
        case .leftMouseUp:
            defer { reset() }
            guard drawing, active, let origin = started,
                  startedApp == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  path.count >= 8 else { return }
            let last = NSEvent.mouseLocation
            path.append(DrawingPoint(x: Double(last.x), y: Double(last.y)))
            let minX = path.map(\.x).min() ?? 0, maxX = path.map(\.x).max() ?? 0
            let minY = path.map(\.y).min() ?? 0, maxY = path.map(\.y).max() ?? 0
            guard hypot(maxX-minX,maxY-minY) >= 35, hypot(Double(last.x-origin.x), Double(last.y-origin.y)) >= 0 else { return }
            let front = startedApp
            let candidates = triggers.filter { DrawingRecognizer.bestMatch(path, among: [$0]) != nil }
            guard !candidates.isEmpty else { return }
            let scoped = TriggerResolver.resolve(candidates, payload: true, frontBundleID: front,
                payloadOf: { _ in true }, appBundleIDOf: { $0.appBundleID },
                groups: groups, activationGroupIDOf: { $0.activationGroupID })
            guard let winner = DrawingRecognizer.bestMatch(path, among: scoped) else { return }
            ActionExecutor.fire(triggerID: winner.id, fallbackActions: winner.actions)
            LiveTouchState.shared.flashTrigger(winner.id)
            NotificationCenter.default.post(name: .gestureDidFire, object: nil,
                userInfo: ["name": winner.displayName, "actions": winner.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → ")])
        default: break
        }
    }
    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil; reset()
    }
    deinit { stop() }
}
