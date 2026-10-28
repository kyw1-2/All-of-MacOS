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

    /// Upper bound for a sidecar on disk. A full track (60,000 cursor points,
    /// clicks and keystrokes each) encodes to about 16 MB; the old 8 MB bound
    /// rejected long recordings with heavy typing and reported it as a full
    /// disk.
    static let maximumBytes = 24_000_000

    enum Failure: LocalizedError, Equatable {
        case invalid
        case tooLarge(bytes: Int)
        var errorDescription: String? {
            switch self {
            case .invalid: return "The input track has unordered or out-of-range samples."
            case .tooLarge(let bytes):
                return "The input track is \(bytes / 1_000_000) MB, above the \(AOMCursorTrack.maximumBytes / 1_000_000) MB limit."
            }
        }
    }

    static func read(for movie: URL) -> AOMCursorTrack? {
        let url = sidecarURL(for: movie)
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Bound the read itself, rather than allocating an arbitrary-sized file
        // and checking its size afterwards.
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let track = try? JSONDecoder().decode(AOMCursorTrack.self, from: data),
              track.isValid else { return nil }
        return track
    }

    func write(for movie: URL) throws {
        guard movie.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        guard isValid else { throw Failure.invalid }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge(bytes: data.count) }
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

/// Bounded cursor sampling that always covers the whole recording.
///
/// The recorder samples the pointer every 50 ms, and a track holds at most
/// 60,000 points — 50 minutes. Until 3.3.0 later samples were dropped
/// silently, so the last 15 minutes of a 65-minute recording had no pointer
/// at all (audit F06: `smoothedPosition(at: 3001)` was nil). Now, when the
/// buffer fills, the sampler keeps every other point and doubles its spacing:
/// 50 ms resolution up to 50 minutes, 100 ms up to 100 minutes, 200 ms up to
/// 200 minutes, and so on, always within the sidecar limits. Points on either
/// side of a visibility change are kept on the first thinning pass, so
/// hidden intervals keep their edges.
struct AOMCursorSampler {
    static let capacity = 60_000
    let capacity: Int
    /// The recorder's sampling interval (50 ms).
    let baseSpacing: Double
    private(set) var points: [AOMCursorPoint] = []
    /// The target spacing between kept samples; doubles with each thinning.
    private(set) var spacing: Double
    /// Samples come from a run-loop timer and arrive 48–55 ms apart, not at
    /// exactly 50 ms. Spacing is enforced with half a sampling interval of
    /// slack, so jitter never drops a sample before the first thinning and
    /// the average spacing after it stays at the target.
    private var minimumGap: Double { spacing - baseSpacing * 0.5 }

    init(spacing: Double = 0.05, capacity: Int = AOMCursorSampler.capacity) {
        baseSpacing = max(0.001, spacing)
        self.spacing = baseSpacing
        self.capacity = max(16, capacity)
        points.reserveCapacity(min(self.capacity, 4_096))
    }

    mutating func removeAll() {
        points.removeAll(keepingCapacity: true)
        spacing = baseSpacing
    }

    mutating func append(_ point: AOMCursorPoint) {
        guard point.time.isFinite, point.x.isFinite, point.y.isFinite else { return }
        if let last = points.last {
            guard point.time >= last.time else { return }
            let changed = (point.visible ?? true) != (last.visible ?? true)
            // Closer than the current spacing only visibility changes are kept.
            guard changed || point.time - last.time >= minimumGap else { return }
        }
        points.append(point)
        if points.count >= capacity { thin() }
    }

    private mutating func thin() {
        var preserveTransitions = true
        repeat {
            spacing *= 2
            points = Self.thinned(points, spacing: minimumGap, preserveTransitions: preserveTransitions)
            // A pointer that flickers in and out of the area on every sample
            // has nothing to drop but transitions; the next pass ignores them
            // so the track stays bounded whatever the input.
            preserveTransitions = false
        } while points.count > capacity * 3 / 4
    }

    /// Keeps the first and last point, visibility transitions (optionally)
    /// and every point at least `spacing` after the previous kept one.
    static func thinned(_ points: [AOMCursorPoint], spacing: Double, preserveTransitions: Bool) -> [AOMCursorPoint] {
        guard points.count > 2 else { return points }
        var kept: [AOMCursorPoint] = []
        kept.reserveCapacity(points.count / 2 + 16)
        var lastKept = -Double.infinity
        for index in points.indices {
            let point = points[index]
            let visible = point.visible ?? true
            let edge = index == points.startIndex || index == points.index(before: points.endIndex)
            let transition = preserveTransitions && (
                (index > points.startIndex && (points[index - 1].visible ?? true) != visible) ||
                (index + 1 < points.endIndex && (points[index + 1].visible ?? true) != visible))
            if edge || transition || point.time - lastKept >= spacing {
                kept.append(point)
                lastKept = point.time
            }
        }
        return kept
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
