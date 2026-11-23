import Darwin
import Foundation
import MachO

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
/// Wiring costs a few megabytes (about 1.3 MB for the
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

    // MARK: Code (7.12)

    /// 7.12: AOM's own code and constant data, kept resident while a HomePod stream
    /// runs. On 2026-11-23 (8 GB, 7.6 GB swapped) every overload of a 6-minute
    /// burst was logged by the HAL in AOM's process only ("IOWorkLoop:
    /// skipping cycle due to overload", none in coreaudiod), each a wake-up
    /// 5–12 ms late while AOM's render took 30 µs. The buffers were already
    /// wired; the code the IO thread runs was not, and AOM pages in about
    /// two pages of its binary a second under that pressure. Wiring __TEXT
    /// and __DATA_CONST costs about 30 MB while a HomePod plays and nothing
    /// otherwise. `defaults write com.kyw.allofmacos AOMAudioWireCode -bool NO` turns it off.
    private static let codeLock = NSLock()
    nonisolated(unsafe) private static var codeUsers = 0
    nonisolated(unsafe) private static var codeRegions: [(UnsafeMutableRawPointer, Int)] = []
    private static let codeBytesCounter = AudioAtomicCounter()

    static var wiresCode: Bool {
        UserDefaults.standard.object(forKey: "AOMAudioWireCode") as? Bool ?? true
    }

    /// One more HomePod stream: the first one keeps the code resident.
    /// 7.12.1: macOS 27 refuses `mlock` on code pages (EPERM, measured);
    /// only __DATA_CONST can be wired. __TEXT is kept resident instead by
    /// reading one byte of each of its pages every second on a utility
    /// thread (about 1,700 reads), so a page the IO thread needs is never
    /// one the kernel has just taken back.
    static func retainCode() {
        guard wiresCode else { return }
        codeLock.lock(); defer { codeLock.unlock() }
        codeUsers += 1
        guard codeUsers == 1, codeRegions.isEmpty, toucher == nil else { return }
        for (pointer, bytes) in mainImageSegments(["__DATA_CONST"]) where mlock(pointer, bytes) == 0 {
            codeRegions.append((pointer, bytes))
            codeBytesCounter.add(UInt64(bytes))
        }
        guard let text = mainImageSegments(["__TEXT"]).first else { return }
        let page = Int(getpagesize())
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler {
            let base = UnsafeRawPointer(text.0)
            var sum: UInt8 = 0
            var offset = 0
            while offset < text.1 { sum &+= base.load(fromByteOffset: offset, as: UInt8.self); offset += page }
            touchSink.store(UInt64(sum))
        }
        timer.resume()
        toucher = timer
        codeBytesCounter.add(UInt64(text.1))
        touchedBytes = UInt64(text.1)
    }

    /// One HomePod stream fewer: the last one lets the code go.
    static func releaseCode() {
        codeLock.lock(); defer { codeLock.unlock() }
        guard codeUsers > 0 else { return }
        codeUsers -= 1
        guard codeUsers == 0 else { return }
        for (pointer, bytes) in codeRegions {
            munlock(pointer, bytes)
            codeBytesCounter.add(0 &- UInt64(bytes))
        }
        codeRegions = []
        toucher?.cancel()
        toucher = nil
        codeBytesCounter.add(0 &- touchedBytes)
        touchedBytes = 0
    }

    nonisolated(unsafe) private static var toucher: DispatchSourceTimer?
    nonisolated(unsafe) private static var touchedBytes: UInt64 = 0
    /// Keeps the touch loop's reads from being optimized away.
    private static let touchSink = AudioAtomicCounter()

    /// Code bytes wired right now (audio-health.json `wiredCodeBytes`).
    static var wiredCodeBytes: UInt64 { codeBytesCounter.load() }

    /// The main executable's segments, page aligned.
    private static func mainImageSegments(_ names: [String]) -> [(UnsafeMutableRawPointer, Int)] {
        let slide = _dyld_get_image_vmaddr_slide(0)
        let page = Int(getpagesize())
        return names.compactMap { name in
            guard let segment = getsegbyname(name) else { return nil }
            let start = Int(segment.pointee.vmaddr) + slide
            let size = Int(segment.pointee.vmsize)
            guard size > 0, size < 256 << 20 else { return nil }
            let aligned = start & ~(page - 1)
            guard let pointer = UnsafeMutableRawPointer(bitPattern: aligned) else { return nil }
            return (pointer, size + (start - aligned))
        }
    }

    /// Bytes wired by AOM's audio buffers right now (any thread).
    static var wiredBytes: UInt64 { wiredBytesCounter.load() }
    /// Buffers macOS refused to wire since launch (any thread).
    static var failures: UInt64 { failureCounter.load() }
}
