import Foundation

/// Capture-thread-owned timestamps. Host callback jitter does not imply missing
/// PCM: only valid sample timestamps on consecutive nonempty packets do.
struct AudioCaptureTimeline {
    enum Change: Equatable {
        case continuous
        case gap(Int)
        case reset
    }
    private var expected: Double?

    mutating func reset() { expected = nil }

    mutating func observe(sampleTime: Double, frames: Int, sampleRate: Double) -> Change {
        guard frames > 0 else { return .continuous }
        guard sampleTime.isFinite, sampleTime >= 0,
              sampleRate.isFinite, (8000...384000).contains(sampleRate) else {
            expected = nil
            return .continuous
        }
        let previous = expected
        expected = sampleTime + Double(frames)
        guard let previous else { return .continuous }
        let delta = sampleTime - previous
        if abs(delta) <= 0.5 { return .continuous }
        // A large forward jump or a restarted sample clock invalidates queued
        // audio. Bounded short holes keep the source timeline intact.
        guard delta > 0, delta <= sampleRate * AudioDropoutSoftener.maximumHoleSeconds else { return .reset }
        return .gap(Int(delta.rounded()))
    }
}
