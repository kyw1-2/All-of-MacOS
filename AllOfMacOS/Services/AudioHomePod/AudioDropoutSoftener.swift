/// Shapes exact-zero holes in captured AirPlay audio before it enters the queue.
/// A short, fixed lookahead retains both the fade and the 32 frames needed to
/// recognize a hole. The falling edge is still writable even when the hole
/// begins at a callback boundary. Processing is independent of packet size.
///
/// Constructed before IO starts; process/reset run only on the capture thread.
/// No allocation or locks in either operation. The stereo delay is wired.
final class AudioDropoutSoftener {
    static let minimumRun = 32
    static let maximumHoleSeconds = 0.085
    static let fadeSeconds = 0.002
    static let audible: Float = 0.001
    // 384 kHz: 768 fade frames + 32 detection frames, plus the current frame.
    private static let capacity = 1024
    private let samples: UnsafeMutablePointer<Float>
    private let wired: Bool
    private var cursor = 0
    private var primed = 0
    private var run = 0
    private var runFollowsAudio = false
    private var lastAudible = false
    private var fadeInRemaining = 0
    private var rate = 0.0
    private var fade = 96
    private var maximumHole = 4080
    private(set) var delayFrames = 128
    private(set) var softened: UInt64 = 0

    init() {
        samples = .allocate(capacity: Self.capacity * 2)
        samples.initialize(repeating: 0, count: Self.capacity * 2)
        wired = AudioRealtimeMemory.wire(samples, count: Self.capacity * 2)
    }

    deinit {
        AudioRealtimeMemory.unwire(samples, count: Self.capacity * 2, wired: wired)
        samples.deallocate()
    }

    /// Pending audio is discarded after a capture gap or route/format change.
    /// The lifetime counter stays monotonic for diagnostics.
    func reset() {
        cursor = 0; primed = 0; run = 0
        runFollowsAudio = false; lastAudible = false; fadeInRemaining = 0
    }

    /// Writes exactly `frames` stereo frames, delayed by `delayFrames`.
    /// Initial output is silence; every subsequent input frame is retained,
    /// including callbacks larger than the transport's work buffer.
    func process(frames: Int, sampleRate: Double, output: UnsafeMutablePointer<Float>,
                 sample: (Int) -> (Float, Float)) {
        guard frames > 0 else { return }
        let validRate = sampleRate.isFinite && (8000...384000).contains(sampleRate) ? sampleRate : 48000
        if rate != validRate {
            reset()
            rate = validRate
            fade = max(1, Int(rate * Self.fadeSeconds))
            delayFrames = fade + Self.minimumRun
            maximumHole = max(Self.minimumRun, Int(rate * Self.maximumHoleSeconds))
        }
        for index in 0..<frames {
            let raw = sample(index)
            let left = raw.0.isFinite ? raw.0 : 0
            let right = raw.1.isFinite ? raw.1 : 0
            let audible = abs(left) > Self.audible || abs(right) > Self.audible
            var gain: Float = 1
            if left == 0 && right == 0 {
                if run == 0 { runFollowsAudio = lastAudible }
                // Saturate: an indefinitely idle app must never overflow.
                run = min(maximumHole + 1, run + 1)
                if run == Self.minimumRun && runFollowsAudio {
                    // All these frames are still in the delay, even if the
                    // detection crossed several callbacks. Never edit the queue.
                    for step in 0..<min(fade, max(0, primed - (Self.minimumRun - 1))) {
                        let slot = (cursor - (Self.minimumRun - 1) - 1 - step + Self.capacity) % Self.capacity
                        let x = Float(step + 1) / Float(fade + 1)
                        let scale = x * x * (3 - 2 * x)
                        samples[slot * 2] *= scale
                        samples[slot * 2 + 1] *= scale
                    }
                }
                // Single exact-zero crossings still advance a recovery fade.
                // Only a confirmed new hole cancels it.
                if run >= Self.minimumRun { fadeInRemaining = 0 }
                else if fadeInRemaining > 0 { fadeInRemaining -= 1 }
            } else {
                if run >= Self.minimumRun && run <= maximumHole && runFollowsAudio && audible {
                    softened += 1
                    fadeInRemaining = fade
                }
                run = 0
                if fadeInRemaining > 0 {
                    let x = Float(fade - fadeInRemaining + 1) / Float(fade)
                    gain = x * x * (3 - 2 * x)
                    fadeInRemaining -= 1
                }
            }
            samples[cursor * 2] = left * gain
            samples[cursor * 2 + 1] = right * gain
            let read = (cursor - delayFrames + Self.capacity) % Self.capacity
            output[index * 2] = primed >= delayFrames ? samples[read * 2] : 0
            output[index * 2 + 1] = primed >= delayFrames ? samples[read * 2 + 1] : 0
            cursor = (cursor + 1) % Self.capacity
            primed = min(delayFrames, primed + 1)
            lastAudible = audible
        }
    }
}
