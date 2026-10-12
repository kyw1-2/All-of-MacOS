import Foundation
import CoreGraphics

/// Local cursor metadata saved alongside an AOM-owned screen recording.
/// Screen coordinates are normalized into the video frame; raw app/window titles
/// or keyboard events are never collected.
struct AOMCursorPoint: Codable, Equatable {
    var time: Double
    var x: Double
    var y: Double
}

struct AOMCursorTrack: Codable {
    var points: [AOMCursorPoint]

    static func sidecarURL(for movie: URL) -> URL {
        movie.appendingPathExtension("aom-cursor.json")
    }

    static func read(for movie: URL) -> AOMCursorTrack? {
        let url = sidecarURL(for: movie)
        guard url.isFileURL,
              let data = try? Data(contentsOf: url),
              data.count <= 8_000_000,
              let track = try? JSONDecoder().decode(AOMCursorTrack.self, from: data),
              track.points.count <= 60_000,
              track.points.allSatisfy({ $0.time.isFinite && $0.time >= 0 &&
                  $0.x.isFinite && $0.y.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) }),
              zip(track.points, track.points.dropFirst()).allSatisfy({ $0.time <= $1.time })
              else { return nil }
        return track
    }

    func write(for movie: URL) throws {
        guard points.count <= 60_000 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let valid = points.filter {
            $0.time.isFinite && $0.time >= 0 &&
            $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y)
        }
        let data = try JSONEncoder().encode(AOMCursorTrack(points: valid))
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
            let a = points[i], b = points[max(0, i - 1)], c = points[max(0, i - 2)]
            return CGPoint(x: 0.6 * a.x + 0.3 * b.x + 0.1 * c.x,
                           y: 0.6 * a.y + 0.3 * b.y + 0.1 * c.y)
        }
        if seconds <= points[0].time { return filtered(0) }
        if seconds >= points[count - 1].time { return filtered(count - 1) }
        var lo = 1, hi = count - 1
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if points[mid].time < seconds { lo = mid + 1 }
            else { hi = mid }
        }
        let before = points[lo - 1], after = points[lo]
        let span = after.time - before.time
        guard span > 0, span.isFinite else { return filtered(lo) }
        let t = CGFloat(min(1, max(0, (seconds - before.time) / span)))
        let from = filtered(lo - 1), to = filtered(lo)
        return CGPoint(x: from.x + (to.x - from.x) * t,
                       y: from.y + (to.y - from.y) * t)
    }
}
