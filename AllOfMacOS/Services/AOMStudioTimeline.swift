import Foundation

/// Source-video seconds throughout the editor, preview and export. Trimming
/// changes the playback range, never the meaning of an existing edit.
struct AOMStudioZoomKeyframe: Equatable, Identifiable {
    let id: UUID
    var time: Double
    var magnification: Double
    var focusX: Double
    /// Normalized top-left coordinates, matching the captured cursor track.
    var focusY: Double

    init(id: UUID = UUID(), time: Double, magnification: Double,
         focusX: Double = 0.5, focusY: Double = 0.5) {
        self.id = id
        self.time = time
        self.magnification = magnification
        self.focusX = focusX
        self.focusY = focusY
    }
}

enum AOMStudioTimeline {
    struct Focus: Equatable {
        var magnification: Double
        var x: Double
        var y: Double
    }

    static func sampledFocus(at time: Double,
                             keyframes: [AOMStudioZoomKeyframe]) -> Focus {
        let origin = Focus(magnification: 1, x: 0.5, y: 0.5)
        guard time.isFinite else { return origin }
        // Last edit at a given time wins; duplicate timestamps never create a
        // zero-length interpolation interval or a nondeterministic jump.
        var unique: [Double: AOMStudioZoomKeyframe] = [:]
        for frame in keyframes where frame.time.isFinite && frame.time >= 0 &&
            frame.time < 86_400 && frame.magnification.isFinite &&
            frame.focusX.isFinite && frame.focusY.isFinite {
            unique[frame.time] = frame
        }
        var previousTime = 0.0
        var previous = origin
        for frame in unique.values.sorted(by: { $0.time < $1.time }) {
            let focus = Focus(magnification: min(4, max(1, frame.magnification)),
                              x: min(1, max(0, frame.focusX)),
                              y: min(1, max(0, frame.focusY)))
            if time <= frame.time {
                let span = frame.time - previousTime
                if span <= 0 { return focus }
                let position = min(1, max(0, (time - previousTime) / span))
                let smooth = position * position * (3 - 2 * position)
                return Focus(magnification: previous.magnification +
                    (focus.magnification - previous.magnification) * smooth,
                             x: previous.x + (focus.x - previous.x) * smooth,
                             y: previous.y + (focus.y - previous.y) * smooth)
            }
            previousTime = frame.time
            previous = focus
        }
        return previous
    }

    /// Clamp the viewport rather than exposing empty pixels near screen edges.
    static func viewportCenter(for focus: Focus) -> CGPoint {
        let margin = 0.5 / focus.magnification
        return CGPoint(x: min(1 - margin, max(margin, focus.x)),
                       y: min(1 - margin, max(margin, focus.y)))
    }

    /// Shared video/cursor projection, expressed in normalized top-left space.
    static func projectedPoint(_ point: CGPoint, focus: Focus, padding: Double) -> CGPoint {
        let center = viewportCenter(for: focus)
        let inset = min(0.2, max(0, padding))
        let factor = 1 - 2 * inset
        return CGPoint(x: inset + (0.5 + (point.x - center.x) * focus.magnification) * factor,
                       y: inset + (0.5 + (point.y - center.y) * focus.magnification) * factor)
    }

    /// Independent, editable zoom suggestions from sustained pointer dwell.
    /// No clicks, keystrokes, window names or proprietary scene model required.
    static func suggestedZooms(track: AOMCursorTrack, start: Double, end: Double,
                               magnification: Double = 1.8) -> [AOMStudioZoomKeyframe] {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              track.isValid, magnification.isFinite else { return [] }
        let zoom = min(3, max(1.2, magnification))
        var result: [AOMStudioZoomKeyframe] = []
        var cluster: [AOMCursorPoint] = []
        var availableAfter = start
        func finishCluster() {
            defer { cluster.removeAll(keepingCapacity: true) }
            guard let first = cluster.first, let last = cluster.last,
                  last.time - first.time >= 0.6, first.time >= availableAfter,
                  first.time + 0.4 < end, result.count < 160 else { return }
            let x = cluster.reduce(0) { $0 + $1.x } / Double(cluster.count)
            let y = cluster.reduce(0) { $0 + $1.y } / Double(cluster.count)
            let begin = max(start, first.time - 0.3)
            let hold = min(last.time, end - 0.3, first.time + 3)
            guard hold > first.time else { return }
            result += [
                AOMStudioZoomKeyframe(time: begin, magnification: 1, focusX: x, focusY: y),
                AOMStudioZoomKeyframe(time: first.time + 0.3, magnification: zoom, focusX: x, focusY: y),
                AOMStudioZoomKeyframe(time: max(first.time + 0.3, hold), magnification: zoom, focusX: x, focusY: y),
                AOMStudioZoomKeyframe(time: min(end, max(first.time + 0.3, hold) + 0.3),
                                     magnification: 1, focusX: x, focusY: y)
            ]
            availableAfter = min(end, hold + 0.8)
        }
        for point in track.points where point.time >= start && point.time <= end {
            guard point.visible != false else { finishCluster(); continue }
            if let first = cluster.first, let last = cluster.last,
               hypot(point.x - first.x, point.y - first.y) > 0.06 || point.time - last.time > 0.25 {
                finishCluster()
            }
            cluster.append(point)
        }
        finishCluster()
        return result
    }
}
