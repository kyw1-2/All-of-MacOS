import Foundation


/// Local cursor metadata saved alongside an AOM-owned screen recording.
/// Screen coordinates are normalized into the video frame; raw app/window titles
/// or ordinary typed text are never collected.
struct AOMCursorPoint: Codable, Equatable {
    var time: Double
    var x: Double
    var y: Double
    /// Missing in legacy sidecars means visible.
    var visible: Bool? = nil
}

struct AOMCursorTrack: Codable {
    var points: [AOMCursorPoint]
    // Optional fields preserve compatibility with pre-Studio sidecars.
    var clicks: [AOMClickEvent]? = nil
    var keystrokes: [AOMKeystrokeEvent]? = nil

    static func sidecarURL(for movie: URL) -> URL {
        movie.appendingPathExtension("aom-cursor.json")
    }

    var isValid: Bool {
        zip(clicks ?? [], (clicks ?? []).dropFirst()).allSatisfy { $0.0.time <= $0.1.time } &&
        zip(keystrokes ?? [], (keystrokes ?? []).dropFirst()).allSatisfy { $0.0.time <= $0.1.time } &&
        (clicks ?? []).count <= 60_000 && (clicks ?? []).allSatisfy { $0.isValid } &&
        (keystrokes ?? []).count <= 60_000 && (keystrokes ?? []).allSatisfy { $0.isValid } &&
        points.count <= 60_000 && points.allSatisfy {
            $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y)
        } && zip(points, points.dropFirst()).allSatisfy { $0.0.time <= $0.1.time }
    }

    static func read(for movie: URL) -> AOMCursorTrack? {
        let url = sidecarURL(for: movie)
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Bound the read itself, rather than allocating an arbitrary-sized file
        // and checking its size afterwards.
        guard let data = try? handle.read(upToCount: 8_000_001), data.count <= 8_000_000,
              let track = try? JSONDecoder().decode(AOMCursorTrack.self, from: data),
              track.isValid else { return nil }
        return track
    }

    func write(for movie: URL) throws {
        guard movie.isFileURL, isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 8_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: Self.sidecarURL(for: movie), options: .atomic)
    }

    /// Smooth three local samples before interpolating a pair. Constraining to
    /// valid input prevents a corrupt sidecar from producing extreme transforms.
    func smoothedPosition(at seconds: Double) -> CGPoint? {
        guard seconds.isFinite, !points.isEmpty else { return nil }
        // The recorder always appends in timestamp order, so binary search is
        // O(log n) per encoded video frame rather than resorting all samples.
        let count = points.count
        guard count <= 60_000,
              points[0].time.isFinite, points[0].time >= 0 else { return nil }
        func filtered(_ i: Int) -> CGPoint {
            let a = points[i]
            let prior = points[max(0, i - 1)]
            let b = prior.visible == false ? a : prior
            let older = points[max(0, i - 2)]
            let c = prior.visible == false || older.visible == false ? b : older
            return CGPoint(x: 0.6 * a.x + 0.3 * b.x + 0.1 * c.x,
                           y: 0.6 * a.y + 0.3 * b.y + 0.1 * c.y)
        }
        if seconds < points[0].time { return nil }
        if seconds >= points[count - 1].time {
            guard points[count - 1].visible != false,
                  seconds - points[count - 1].time <= 0.25 else { return nil }
            return filtered(count - 1)
        }
        var lo = 1, hi = count - 1
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if points[mid].time < seconds { lo = mid + 1 }
            else { hi = mid }
        }
        let before = points[lo - 1], after = points[lo]
        if seconds == after.time {
            return after.visible == false ? nil : filtered(lo)
        }
        guard before.visible != false else { return nil }
        if after.visible == false { return filtered(lo - 1) }
        let span = after.time - before.time
        guard span > 0, span.isFinite else { return filtered(lo) }
        let t = CGFloat(min(1, max(0, (seconds - before.time) / span)))
        let from = filtered(lo - 1), to = filtered(lo)
        return CGPoint(x: from.x + (to.x - from.x) * t,
                       y: from.y + (to.y - from.y) * t)
    }
}

struct AOMClickEvent: Codable, Equatable {
    var time: Double
    var x: Double
    var y: Double
    var button: Int = 0
    var isValid: Bool { time.isFinite && time >= 0 && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) && (0...2).contains(button) }
}

struct AOMKeystrokeEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var label: String
    var duration: Double = 1.4
    var isValid: Bool { time.isFinite && time >= 0 && duration.isFinite && (0.1...10).contains(duration) && !label.isEmpty && label.count <= 80 }
}
