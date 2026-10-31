import Accelerate

/// 3.4.0 (HomePod crackle): shapes a dropout inside an app's own audio.
///
/// With the HomePod as the Mac's output, every app that plays runs its own IO
/// at the HomePod's fixed 128-frame cycle (2.7 ms, no safety offset). Under
/// load an app misses a cycle. CoreAudio reports it as `ClientTimeout` with one
/// silent IO cycle for that app; on 31 Oct 2026 Chrome's helper did this
/// about every 8 minutes while builds ran. AOM's tap then delivers the app's
/// audio with a hole of exact zeros in it, and the hole's two hard edges are a
/// click that AOM used to pass on to the HomePod.
///
/// The softener fades out the frames before a run of exact zeros that starts
/// right after audible audio. After a short run (`maximumHoleSeconds`) that
/// ends in audible audio it fades back in, so the hole becomes a dip of a few
/// milliseconds instead of a click. A longer run is a pause: its start is
/// still shaped (a soft stop), and what follows it is left alone. Audio
/// without such runs is untouched, and no gains are written for it.
///
/// Used on the capture (tap IOProc) thread only: no allocation, no locks.
struct AudioDropoutSoftener {
    /// Exact-zero frames that make a run (natural audio crosses zero in one or two).
    static let minimumRun = 32
    /// Zero runs up to this long are dropouts; longer ones are pauses.
    static let maximumHoleSeconds = 0.085
    static let fadeSeconds = 0.002
    /// Audible: above −60 dBFS. A decoder fading out ends below it.
    static let audible: Float = 0.001

    /// Holes faded back in so far.
    private(set) var softened: UInt64 = 0
    // Carried from block to block.
    private var run = 0
    private var runFollowsAudio = false
    private var lastAudible = false
    private var fadeInIndex = 0
    private var fadeInLength = 0

    /// A new stream (after a capture gap): nothing carries over.
    mutating func reset() {
        run = 0; runFollowsAudio = false; lastAudible = false
        fadeInIndex = 0; fadeInLength = 0
    }

    /// Writes one gain per frame into `gains` (room for `frames`) and returns
    /// true when any of them is not 1. False: `gains` was not touched and the
    /// block plays as it is.
    mutating func shape(frames: Int, sampleRate: Double, gains: UnsafeMutablePointer<Float>,
                        sample: (Int) -> (Float, Float)) -> Bool {
        guard frames > 0 else { return false }
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        let fade = max(1, Int(rate * Self.fadeSeconds))
        let maximumHole = max(Self.minimumRun, Int(rate * Self.maximumHoleSeconds))
        var shaped = false
        var one: Float = 1
        // A fade-in that began in the previous block.
        if fadeInIndex < fadeInLength {
            vDSP_vfill(&one, gains, 1, vDSP_Length(frames)); shaped = true
            continueFadeIn(from: 0, frames: frames, gains: gains)
        }
        var previousAudible = lastAudible
        for index in 0..<frames {
            let (left, right) = sample(index)
            if left == 0 && right == 0 {
                if run == 0 { runFollowsAudio = previousAudible }
                run += 1
                if run == Self.minimumRun && runFollowsAudio {
                    // The run counts: fade out what led into it, as far as
                    // this block holds it (earlier frames are already queued).
                    let start = index + 1 - run
                    if start > 0 {
                        if !shaped { vDSP_vfill(&one, gains, 1, vDSP_Length(frames)); shaped = true }
                        let length = min(fade, start)
                        for step in 0..<length {
                            let x = Float(length - step) / Float(length + 1)
                            gains[start - length + step] *= x * x * (3 - 2 * x)
                        }
                    }
                }
                previousAudible = false
                continue
            }
            let audible = abs(left) > Self.audible || abs(right) > Self.audible
            if run > 0 {
                if run >= Self.minimumRun && run <= maximumHole && runFollowsAudio && audible {
                    softened += 1
                    if !shaped { vDSP_vfill(&one, gains, 1, vDSP_Length(frames)); shaped = true }
                    fadeInIndex = 0
                    fadeInLength = fade
                    continueFadeIn(from: index, frames: frames, gains: gains)
                }
                run = 0
            }
            previousAudible = audible
        }
        lastAudible = previousAudible
        return shaped
    }

    /// Applies the fade-in from `start` until it ends or the block does.
    private mutating func continueFadeIn(from start: Int, frames: Int, gains: UnsafeMutablePointer<Float>) {
        var frame = start
        let length = Float(fadeInLength)
        while frame < frames && fadeInIndex < fadeInLength {
            fadeInIndex += 1
            let x = Float(fadeInIndex) / length
            gains[frame] *= x * x * (3 - 2 * x)
            frame += 1
        }
    }
}
