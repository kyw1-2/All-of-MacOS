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
              track.points.count <= 60_000 else { return nil }
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
        let input = points.filter {
            $0.time.isFinite && $0.time >= 0 &&
            $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y)
        }
        guard !input.isEmpty else { return nil }
        let sorted = input.sorted { $0.time < $1.time }
        func filtered(_ index: Int) -> CGPoint {
            let a = sorted[index]
            let b = sorted[max(0, index - 1)]
            let c = sorted[max(0, index - 2)]
            return CGPoint(x: 0.6 * a.x + 0.3 * b.x + 0.1 * c.x,
                           y: 0.6 * a.y + 0.3 * b.y + 0.1 * c.y)
        }
        guard seconds > sorted[0].time else { return filtered(0) }
        for i in 1..<sorted.count where seconds <= sorted[i].time {
            let from = filtered(i - 1), to = filtered(i)
            let span = sorted[i].time - sorted[i-1].time
            guard span > 0 else { return to }
            let t = CGFloat(min(1, max(0, (seconds - sorted[i-1].time) / span)))
            return CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t)
        }
        return filtered(sorted.count - 1)
    }
}
