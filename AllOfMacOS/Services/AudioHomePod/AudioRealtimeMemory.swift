import Darwin

/// 3.4.0 (HomePod crackle): the buffers AOM's realtime audio threads touch are
/// wired, so macOS never compresses or swaps them out.
///
/// Evidence, 31 Oct 2026 (installed 3.3.8, 8 GB MacBook Air while several
/// builds ran): 5.5 GB of 7 GB swap in use, 68 MB free, AOM resident at only
/// 38 MB after 12 h (the rest compressed), and CoreAudio's own overload
/// reports for the HomePod naming `PageFaultsOnIOThread` among the causes. A
/// page fault that has to decompress or read from swap inside a HAL callback
/// takes milliseconds; at the HomePod's fixed 128-frame cycle (2.7 ms, no
/// safety offset) the HAL then skips the cycle and the receiver plays a hole,
/// heard as a click. Wired pages stay resident, so the callbacks never wait
/// for memory.
///
/// Wiring is best effort and costs a few megabytes (about 1.3 MB for the
/// AirPlay bridge, 0.75 MB per tapped app, 0.26 MB for the shared resampling
/// kernel). A refusal (the wired-memory limit) leaves the buffer as it was and
/// is counted in audio-health.json (`wireFailures`).
enum AudioRealtimeMemory {
    private static let wiredBytesCounter = AudioAtomicCounter()
    private static let failureCounter = AudioAtomicCounter()

    /// Wires `bytes` at `pointer`. Pass the result to `unwire` before the
    /// memory is freed.
    @discardableResult
    static func wire(_ pointer: UnsafeMutableRawPointer, bytes: Int) -> Bool {
        guard bytes > 0 else { return false }
        guard mlock(pointer, bytes) == 0 else {
            failureCounter.add()
            return false
        }
        wiredBytesCounter.add(UInt64(bytes))
        return true
    }

    /// Wires a buffer of `count` floats.
    @discardableResult
    static func wire(_ pointer: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        wire(UnsafeMutableRawPointer(pointer), bytes: count * MemoryLayout<Float>.stride)
    }

    /// Releases what `wire` wired (nothing when it was not wired).
    static func unwire(_ pointer: UnsafeMutableRawPointer, bytes: Int, wired: Bool) {
        guard wired, bytes > 0 else { return }
        munlock(pointer, bytes)
        wiredBytesCounter.add(0 &- UInt64(bytes))
    }

    static func unwire(_ pointer: UnsafeMutablePointer<Float>, count: Int, wired: Bool) {
        unwire(UnsafeMutableRawPointer(pointer), bytes: count * MemoryLayout<Float>.stride, wired: wired)
    }

    /// Bytes wired by AOM's audio buffers right now (any thread).
    static var wiredBytes: UInt64 { wiredBytesCounter.load() }
    /// Buffers macOS refused to wire since launch (any thread).
    static var failures: UInt64 { failureCounter.load() }
}
