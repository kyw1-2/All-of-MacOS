import Foundation
import Darwin
#if canImport(Synchronization)
import Synchronization
#endif

private protocol AudioAtomicStorage: AnyObject {
    func load() -> UInt64
    func store(_ value: UInt64)
    func add(_ value: UInt64) -> UInt64
    func exchange(expected: UInt64, desired: UInt64) -> Bool
}

#if canImport(Synchronization)
@available(macOS 15.0, *)
private final class ModernAudioAtomic: AudioAtomicStorage {
    private let value: Atomic<UInt64>
    init(_ initial: UInt64) { value = Atomic(initial) }
    func load() -> UInt64 { value.load(ordering: .acquiring) }
    func store(_ new: UInt64) { value.store(new, ordering: .releasing) }
    func add(_ amount: UInt64) -> UInt64 { value.wrappingAdd(amount, ordering: .acquiringAndReleasing).newValue }
    func exchange(expected: UInt64, desired: UInt64) -> Bool {
        value.compareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing).exchanged
    }
}
#endif

/// macOS 14 compatibility; all storage is allocated before any IO starts.
private final class LegacyAudioAtomic: AudioAtomicStorage {
    private let value: UnsafeMutablePointer<Int64>
    init(_ initial: UInt64) { value = .allocate(capacity: 1); value.initialize(to: Int64(bitPattern: initial)) }
    deinit { value.deinitialize(count: 1); value.deallocate() }
    func load() -> UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, value)) }
    func store(_ new: UInt64) {
        var old = load()
        while !exchange(expected: old, desired: new) { old = load() }
    }
    func add(_ amount: UInt64) -> UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(Int64(bitPattern: amount), value)) }
    func exchange(expected: UInt64, desired: UInt64) -> Bool {
        OSAtomicCompareAndSwap64Barrier(Int64(bitPattern: expected), Int64(bitPattern: desired), value)
    }
}

final class AudioAtomicCounter {
    private let storage: AudioAtomicStorage
    init(_ initial: UInt64 = 0) {
#if canImport(Synchronization)
        if #available(macOS 15.0, *) { storage = ModernAudioAtomic(initial); return }
#endif
        storage = LegacyAudioAtomic(initial)
    }
    func load() -> UInt64 { storage.load() }
    func store(_ value: UInt64) { storage.store(value) }
    @discardableResult func add(_ value: UInt64 = 1) -> UInt64 { storage.add(value) }
    func raise(to value: UInt64) {
        var old = load()
        while old < value {
            if storage.exchange(expected: old, desired: value) { return }
            old = load()
        }
    }
}

/// Single producer / single consumer stereo queue. Release/acquire cursors
/// publish complete samples and prevent the writer from overwriting a frame
/// still being read. No mutex, allocation or dispatch occurs in either path.
/// The caller serializes consumers during output handoff. Control threads may
/// request a clear but never modify consumer state or its read cursor.
final class StereoPCMQueue {
    let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let written = AudioAtomicCounter()
    private let read = AudioAtomicCounter()
    private let clearBoundary = AudioAtomicCounter()
    private let clearGeneration = AudioAtomicCounter()
    private let enqueued = AudioAtomicCounter()
    private let dropped = AudioAtomicCounter()
    private let underruns = AudioAtomicCounter()
    private let discarded = AudioAtomicCounter()
    private let clears = AudioAtomicCounter()
    private let rendered = AudioAtomicCounter()
    // Consumer-owned resampler state.
    private var generation: UInt64 = 0
    private var fraction: Double = 0
    private var primed = false
    private var fade: Float = 0
    private var correction: Double = 0

    init(capacity: Int) {
        precondition(capacity >= 4)
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { samples.deallocate() }

    var statistics: [String: UInt64] {
        let r = read.load(), w = written.load()
        return ["capturedFrames": enqueued.load(), "renderedFrames": rendered.load(),
                "queuedFrames": w >= r ? w - r : 0,
                "droppedFrames": dropped.load(), "underruns": underruns.load(),
                "discardedFrames": discarded.load(), "clears": clears.load()]
    }
    var queuedFrames: Int {
        let r = read.load(), w = written.load()
        return w >= r ? Int(min(UInt64(capacity), w - r)) : 0
    }

    /// Setup only, before producer and consumer start (silence prebuffer).
    func prime(frames: Int) {
        precondition(frames >= 0 && frames < capacity)
        written.store(UInt64(frames)); primed = true
    }

    func requestClear() {
        clearBoundary.raise(to: written.load())
        clearGeneration.add()
    }

    @discardableResult
    func write(frames: Int, sample: (Int) -> (Float, Float)) -> Int {
        guard frames > 0 else { return 0 }
        let w = written.load(), r = read.load()
        let occupied = w >= r ? min(UInt64(capacity), w - r) : UInt64(capacity)
        let accepted = min(frames, capacity - Int(occupied))
        for frame in 0..<accepted {
            let (l, r) = sample(frame)
            let index = Int((w + UInt64(frame)) % UInt64(capacity)) * 2
            samples[index] = l.isFinite ? l : 0
            samples[index + 1] = r.isFinite ? r : 0
        }
        written.store(w + UInt64(accepted))
        enqueued.add(UInt64(accepted))
        if accepted < frames { dropped.add(UInt64(frames - accepted)) }
        return accepted
    }

    /// Output is interleaved stereo at the caller's clock. Initial priming is
    /// not counted as an underrun; only loss after a running queue is counted.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int, ratio: Double,
                targetFrames: Int, driftLimit: Double = 0.002, smoothing: Double = 1,
                fadeFrames: Int = 240) -> Int {
        guard frames > 0, ratio.isFinite, ratio > 0 else { return 0 }
        memset(output, 0, frames * 8)
        var r = read.load()
        let currentGeneration = clearGeneration.load()
        let boundary = clearBoundary.load()
        let w = written.load()
        if generation != currentGeneration {
            let next = max(r, min(w, boundary))
            discarded.add(next - r); clears.add()
            r = next
            fraction = 0; primed = false; fade = 0; correction = 0
            generation = currentGeneration
        }
        let target = min(capacity - 2, max(2, targetFrames))
        var available = Int(w - r)
        if available > min(capacity - 1, max(target * 3, Int(ceil(Double(frames) * ratio)) * 2)) {
            let keep = min(available, max(target, Int(ceil(Double(frames) * ratio)) + 2))
            discarded.add(UInt64(available - keep))
            r = w - UInt64(keep); available = keep
            fraction = 0; primed = false; fade = 0; correction = 0
        }
        if !primed {
            guard available >= target else { read.store(r); return 0 }
            primed = true
        }
        let desired = max(-driftLimit, min(driftLimit, Double(available - target) / Double(target) * 0.001))
        correction += (desired - correction) * smoothing
        let step = ratio * (1 + correction)
        var filled = 0
        while filled < frames && available > max(1, Int(fraction + step)) {
            let index = Int(r % UInt64(capacity)) * 2
            let next = Int((r + 1) % UInt64(capacity)) * 2
            fade = fadeFrames > 0 ? min(1, fade + 1 / Float(fadeFrames)) : 1
            for channel in 0..<2 {
                let a = samples[index + channel], b = samples[next + channel]
                output[filled * 2 + channel] = (a + (b - a) * Float(fraction)) * fade
            }
            fraction += step
            let advance = Int(fraction)
            r += UInt64(advance); available -= advance; fraction -= Double(advance)
            filled += 1
        }
        read.store(r)
        rendered.add(UInt64(filled))
        if filled < frames {
            let ramp = min(fadeFrames, filled)
            if ramp > 0 {
                for offset in 0..<ramp {
                    let gain = Float(ramp - offset - 1) / Float(ramp)
                    output[(filled - ramp + offset) * 2] *= gain
                    output[(filled - ramp + offset) * 2 + 1] *= gain
                }
            }
            primed = false; fraction = 0; fade = 0
            underruns.add()
        }
        return filled
    }
}
