import Foundation

/// Source-video seconds throughout the editor, preview and export. Trimming
/// changes the playback range, never the meaning of an existing edit.
struct AOMStudioZoomKeyframe: Codable, Equatable, Identifiable {
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
        // Find the two neighbors directly, without allocating a dictionary or
        // sorting on every video frame. Equal timestamps replace the previous
        // candidate, preserving the editor's last-edit-wins policy.
        var before: AOMStudioZoomKeyframe?
        var after: AOMStudioZoomKeyframe?
        for frame in keyframes where frame.time.isFinite && frame.time >= 0 &&
            frame.time < 86_400 && frame.magnification.isFinite &&
            frame.focusX.isFinite && frame.focusY.isFinite {
            if frame.time < time {
                if before == nil || frame.time >= before!.time { before = frame }
            } else if after == nil || frame.time <= after!.time { after = frame }
        }
        func focus(_ frame: AOMStudioZoomKeyframe) -> Focus {
            Focus(magnification: min(4, max(1, frame.magnification)),
                  x: min(1, max(0, frame.focusX)), y: min(1, max(0, frame.focusY)))
        }
        let previous = before.map(focus) ?? origin
        guard let after else { return previous }
        let next = focus(after)
        let previousTime = before?.time ?? 0
        let span = after.time - previousTime
        if span <= 0 { return next }
        let position = min(1, max(0, (time - previousTime) / span))
        let smooth = position * position * (3 - 2 * position)
        return Focus(magnification: previous.magnification + (next.magnification - previous.magnification) * smooth,
                     x: previous.x + (next.x - previous.x) * smooth,
                     y: previous.y + (next.y - previous.y) * smooth)
    }

    /// Validated event tracks are sorted and key badges last at most ten
    /// seconds. A newer short badge can expire before an older long one.
    static func activeKeystroke(at time: Double, events: [AOMKeystrokeEvent]) -> AOMKeystrokeEvent? {
        guard time.isFinite else { return nil }
        var lower = 0, upper = events.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].time <= time { lower = middle + 1 }
            else { upper = middle }
        }
        var index = lower
        while index > 0 {
            index -= 1
            let event = events[index]
            guard event.time > time - 10 else { break }
            if time < event.time + event.duration { return event }
        }
        return nil
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

    /// Event tracks are sorted once when captured/loaded. Bound per-frame work
    /// to the current ripple interval rather than scanning an entire recording.
    static func activeClicks(at time: Double, clicks: [AOMClickEvent]) -> ArraySlice<AOMClickEvent> {
        guard time.isFinite else { return [] }
        func boundary(_ threshold: Double, inclusive: Bool) -> Int {
            var lower = 0, upper = clicks.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if clicks[middle].time < threshold || (!inclusive && clicks[middle].time == threshold) { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        let begin = boundary(time - 0.65, inclusive: false)
        let end = boundary(time, inclusive: false)
        return clicks[begin..<max(begin, end)]
    }

    /// Independent, editable zoom suggestions from sustained pointer dwell.
    /// No clicks, keystrokes, window names or proprietary scene model required.
    static func suggestedZooms(track: AOMCursorTrack, start: Double, end: Double,
                               magnification: Double = 1.8) -> [AOMStudioZoomKeyframe] {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              track.isValid, magnification.isFinite else { return [] }
        let zoom = min(3, max(1.2, magnification))
        // Clicks carry explicit interaction context; group repeated actions at
        // the same target and leave room for the entrance/exit transitions.
        let clicks = (track.clicks ?? []).filter { $0.time >= start && $0.time <= end }.sorted { $0.time < $1.time }
        if !clicks.isEmpty {
            var groups: [[AOMClickEvent]] = []
            for click in clicks {
                if let last = groups.last?.last, click.time - last.time < 1.4,
                   hypot(click.x - last.x, click.y - last.y) < 0.12 {
                    groups[groups.count - 1].append(click)
                } else { groups.append([click]) }
            }
            var frames: [AOMStudioZoomKeyframe] = []
            var available = start
            for (index, group) in groups.prefix(40).enumerated() {
                guard let first = group.first, let last = group.last else { continue }
                let begin = max(available, first.time - 0.3)
                let limit = index + 1 < groups.count ? groups[index + 1][0].time - 0.3 : end
                let peak = min(end, max(begin, first.time + 0.12))
                let hold = min(end, limit, max(peak, last.time + 0.7))
                guard hold >= peak else { continue }
                let finish = min(end, limit, hold + 0.3)
                frames += [AOMStudioZoomKeyframe(time: begin, magnification: 1, focusX: first.x, focusY: first.y),
                           AOMStudioZoomKeyframe(time: peak, magnification: zoom, focusX: first.x, focusY: first.y),
                           AOMStudioZoomKeyframe(time: hold, magnification: zoom, focusX: last.x, focusY: last.y),
                           AOMStudioZoomKeyframe(time: finish, magnification: 1, focusX: last.x, focusY: last.y)]
                available = finish
            }
            return frames
        }
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

/// Ordered, non-destructive source ranges. Reordering never rewrites telemetry.
struct AOMStudioClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { end - start }
    func isValid(duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration + 0.05
    }
    static func sourceTime(at outputTime: Double, clips: [Self]) -> Double? {
        guard outputTime.isFinite, outputTime >= 0 else { return nil }
        var offset = 0.0
        for clip in clips {
            guard clip.start.isFinite, clip.end.isFinite, clip.duration > 0 else { return nil }
            if outputTime < offset + clip.duration { return clip.start + outputTime - offset }
            offset += clip.duration
        }
        if outputTime == offset { return clips.last?.end }
        return nil
    }
}
