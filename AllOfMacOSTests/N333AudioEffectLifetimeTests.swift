import XCTest
import AudioToolbox
import CoreAudio
@testable import AllOfMacOS

/// N333-02 (3.3.3 re-audit): the render thread must never adopt an Audio
/// Unit host that a control thread has already released. The audit's probe
/// (au-lifetime-interleaving-probe.swift) let a control thread replace the
/// effect and reclaim right after the render thread read the slot, before
/// it marked the host in use. `AppAudioRenderBus.effectAdoptionHook` forces
/// that interleaving here, and the one right after the render thread
/// published its hazard. A host's lifetime is watched through a weak
/// reference (nil after deinit); pointer bits are only compared, never
/// dereferenced. Apple's AULowpass/AUHighpass hosted as in Audio333Tests,
/// synthetic render calls only: no audio device, output or volume.
final class N333AudioEffectLifetimeTests: XCTestCase {
    private let lowpass = AudioUnitEffectHost.Choice(subtype: kAudioUnitSubType_LowPassFilter,
                                                     manufacturer: kAudioUnitManufacturer_Apple, name: "AULowpass")
    private let highpass = AudioUnitEffectHost.Choice(subtype: kAudioUnitSubType_HighPassFilter,
                                                      manufacturer: kAudioUnitManufacturer_Apple, name: "AUHighpass")

    /// A host the test no longer owns: its bits, recorded while it was
    /// alive, and a weak reference that is nil once it deinitialised.
    private final class Watched {
        let bits: UInt64
        weak var host: AudioUnitEffectHost?
        init(_ host: AudioUnitEffectHost) {
            bits = AppAudioRenderBus.effectBitPattern(of: host)
            self.host = host
        }
        var alive: Bool { host != nil }
    }

    private func makeHost(_ choice: AudioUnitEffectHost.Choice) throws -> AudioUnitEffectHost {
        guard let host = AudioUnitEffectHost(choice: choice) else { throw XCTSkip("\(choice.name) is not installed") }
        return host
    }

    /// A bus with one 1 kHz tone source (as Audio333Tests' `toneBus`).
    private static func toneBus() -> AppAudioRenderBus {
        let bus = AppAudioRenderBus()
        var sample = 0
        bus.add(id: UUID()) { frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                let value = 0.3 * Float(sin(2 * Double.pi * 1000 * Double(sample) / 48000))
                data[frame * 2] = value; data[frame * 2 + 1] = value
                sample += 1
            }
        }
        return bus
    }

    /// Synthetic render calls of 128 frames (the HomePod's IO size); four
    /// of them cover the 480-frame effect crossfade.
    private static func render(_ bus: AppAudioRenderBus, buffers: Int = 1, frames: Int = 128) {
        var output = [Float](repeating: 0, count: frames * 2)
        for _ in 0..<buffers {
            output.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                withUnsafeMutablePointer(to: &list) { bus.render(frames: frames, output: $0, allowWaiting: true) }
            }
        }
    }

    /// Whatever the render thread holds is one of `watched`, and alive.
    private func assertHoldsOnlyLiveHosts(_ bus: AppAudioRenderBus, _ watched: [Watched],
                                          file: StaticString = #filePath, line: UInt = #line) {
        let state = bus.effectRenderState
        for bits in [state.current, state.previous] where bits != 0 {
            guard let host = watched.first(where: { $0.bits == bits }) else {
                XCTFail("the render thread holds bits no test host had", file: file, line: line)
                continue
            }
            XCTAssertTrue(host.alive, "the render thread holds a released host", file: file, line: line)
        }
    }

    /// Takes the effect out; once nothing renders a host any more the next
    /// reclamation gives back its retains, so every host has gone.
    private func tearDownEffect(_ bus: AppAudioRenderBus, _ watched: [Watched],
                                file: StaticString = #filePath, line: UInt = #line) {
        bus.effectAdoptionHook = nil
        bus.setEffect(nil)
        Self.render(bus, buffers: 5)
        XCTAssertEqual(bus.effectRenderState.current, 0, file: file, line: line)
        XCTAssertEqual(bus.effectRenderState.previous, 0, file: file, line: line)
        bus.releaseRetiredEffects()
        for host in watched { XCTAssertFalse(host.alive, "a host was not released", file: file, line: line) }
    }

    /// The audit's interleaving: right after the render thread read the
    /// slot, a control thread takes the effect out and reclaims. No hazard
    /// named the host yet, so it goes, and the render thread must not adopt
    /// its bits.
    func testAHostReleasedRightAfterTheRenderThreadReadItIsNeverAdopted() throws {
        let bus = Self.toneBus()
        var a: AudioUnitEffectHost? = try makeHost(lowpass)
        let watchedA = Watched(a!)
        bus.setEffect(a)
        a = nil
        XCTAssertTrue(watchedA.alive, "the bus holds the only reference")
        var swapped = false, aliveAfterSwap = true
        bus.effectAdoptionHook = { [unowned bus] point, bits in
            guard point == .loaded, bits == watchedA.bits, !swapped else { return }
            swapped = true
            bus.setEffect(nil)
            aliveAfterSwap = watchedA.alive
        }
        Self.render(bus)
        bus.effectAdoptionHook = nil
        XCTAssertTrue(swapped, "the swap ran between the load and the hazard")
        XCTAssertFalse(aliveAfterSwap, "the window was hit: reclamation released the host the render thread had just read")
        XCTAssertEqual(bus.effectRenderState.current, 0, "the render thread did not adopt the released host")
        XCTAssertEqual(bus.effectRenderState.previous, 0)
        XCTAssertEqual(bus.effectHazards.candidate, 0, "and withdrew its hazard")
        Self.render(bus, buffers: 4)
        XCTAssertEqual(bus.effectRenderState.current, 0)
        tearDownEffect(bus, [watchedA])
    }

    /// The same window, but the control thread puts a new host in: the
    /// hazard for the released one fails its re-check, and the new host is
    /// adopted only after its own hazard held.
    func testAReplacementRightAfterTheLoadIsAdoptedOnlyOnceItsHazardHolds() throws {
        let bus = Self.toneBus()
        var a: AudioUnitEffectHost? = try makeHost(lowpass)
        var b: AudioUnitEffectHost? = try makeHost(highpass)
        let watchedA = Watched(a!), watchedB = Watched(b!)
        bus.setEffect(a)
        a = nil
        var hazards: [UInt64] = []
        bus.effectAdoptionHook = { [unowned bus] point, bits in
            if point == .hazardPublished { hazards.append(bits) }
            guard point == .loaded, bits == watchedA.bits, let replacement = b else { return }
            b = nil
            bus.setEffect(replacement)
        }
        Self.render(bus)
        bus.effectAdoptionHook = nil
        XCTAssertNil(b, "the swap ran between the load and the hazard")
        XCTAssertFalse(watchedA.alive, "the window was hit: A was released before it was marked in use")
        XCTAssertEqual(hazards, [watchedA.bits, watchedB.bits], "A's hazard failed the re-check; B's held")
        XCTAssertEqual(bus.effectRenderState.current, watchedB.bits, "the render thread adopted B, never A")
        XCTAssertTrue(watchedB.alive)
        XCTAssertEqual(bus.effectHazards.current, watchedB.bits)
        XCTAssertEqual(bus.effectHazards.candidate, 0)
        assertHoldsOnlyLiveHosts(bus, [watchedA, watchedB])
        tearDownEffect(bus, [watchedA, watchedB])
    }

    /// A control thread that retires and reclaims a host while the render
    /// thread's hazard names it keeps the host; it goes at the next
    /// reclamation after the hazard was withdrawn. For the effect taken out
    /// and for one replaced by a new host.
    func testAHostWithAPublishedHazardSurvivesReclamationUntilTheHazardGoes() throws {
        for replacedByANewHost in [false, true] {
            let bus = Self.toneBus()
            var a: AudioUnitEffectHost? = try makeHost(lowpass)
            var b: AudioUnitEffectHost?
            if replacedByANewHost { b = try makeHost(highpass) }
            let watchedA = Watched(a!)
            let watchedB = b.map { Watched($0) }
            let watched = [watchedA] + (watchedB.map { [$0] } ?? [])
            bus.setEffect(a)
            a = nil
            var aliveWhileNamed: Bool?
            bus.effectAdoptionHook = { [unowned bus] point, bits in
                guard point == .hazardPublished, bits == watchedA.bits, aliveWhileNamed == nil else { return }
                let replacement = b
                b = nil
                bus.setEffect(replacement)
                aliveWhileNamed = watchedA.alive
            }
            Self.render(bus)
            bus.effectAdoptionHook = nil
            let context = replacedByANewHost ? "replaced" : "taken out"
            XCTAssertEqual(aliveWhileNamed, true, "\(context): a published hazard keeps the host through reclamation")
            XCTAssertEqual(bus.effectRenderState.current, watchedB?.bits ?? 0,
                           "\(context): the re-check saw the swap, so A was not adopted")
            XCTAssertEqual(bus.effectHazards.candidate, 0, "\(context): the hazard was withdrawn")
            bus.releaseRetiredEffects()
            XCTAssertFalse(watchedA.alive, "\(context): the next reclamation released it")
            if let watchedB { XCTAssertTrue(watchedB.alive, "\(context): the adopted replacement is alive") }
            assertHoldsOnlyLiveHosts(bus, watched)
            tearDownEffect(bus, watched)
        }
    }

    /// The audit's second case: an effect is in use and a new one is
    /// published; right after the render thread read the new one, a control
    /// thread replaces it again and reclaims. The new host (not yet named)
    /// goes and is never adopted; the host in use stays through the swap and
    /// its crossfade, and goes at the reclamation after its hazard.
    func testWhileAnEffectIsInUseANewOneReleasedRightAfterItsLoadIsNeverAdopted() throws {
        let bus = Self.toneBus()
        var a: AudioUnitEffectHost? = try makeHost(lowpass)
        var b: AudioUnitEffectHost? = try makeHost(highpass)
        var c: AudioUnitEffectHost? = try makeHost(lowpass)
        let watchedA = Watched(a!), watchedB = Watched(b!), watchedC = Watched(c!)
        let watched = [watchedA, watchedB, watchedC]
        bus.setEffect(a)
        a = nil
        Self.render(bus, buffers: 5)
        XCTAssertEqual(bus.effectRenderState.current, watchedA.bits)
        XCTAssertEqual(bus.effectRenderState.previous, 0, "the fade-in from dry is over")
        bus.setEffect(b)
        b = nil
        XCTAssertTrue(watchedA.alive, "in use: retired, not released")
        var aliveAtSwap: (inUse: Bool, loaded: Bool)?
        bus.effectAdoptionHook = { [unowned bus] point, bits in
            guard point == .loaded, bits == watchedB.bits, let replacement = c else { return }
            c = nil
            bus.setEffect(replacement)
            aliveAtSwap = (inUse: watchedA.alive, loaded: watchedB.alive)
        }
        Self.render(bus)
        bus.effectAdoptionHook = nil
        XCTAssertEqual(aliveAtSwap?.inUse, true, "the host in use survives the reclamation")
        XCTAssertEqual(aliveAtSwap?.loaded, false, "the window was hit: B was released before it was marked in use")
        let state = bus.effectRenderState
        XCTAssertEqual(state.current, watchedC.bits, "the render thread adopted C, never B")
        XCTAssertEqual(state.previous, watchedA.bits, "and crossfades from A")
        XCTAssertGreaterThan(state.fadeRemaining, 0)
        assertHoldsOnlyLiveHosts(bus, watched)
        bus.releaseRetiredEffects()
        XCTAssertTrue(watchedA.alive, "the previous hazard keeps A while the crossfade runs it")
        Self.render(bus, buffers: 4)
        XCTAssertEqual(bus.effectRenderState.previous, 0, "the crossfade is over")
        XCTAssertEqual(bus.effectHazards.previous, 0)
        bus.releaseRetiredEffects()
        XCTAssertFalse(watchedA.alive, "released at the reclamation after its hazard went")
        XCTAssertTrue(watchedC.alive)
        assertHoldsOnlyLiveHosts(bus, watched)
        tearDownEffect(bus, watched)
    }

    /// A control thread replacing the effect between every hazard and its
    /// re-check cannot hold the render thread: the cycle ends after
    /// `effectAdoptionAttempts` checks with the effect it had, and once the
    /// churn stops the next cycle adopts what is published.
    func testReplacementAtEveryCheckEndsTheRenderCycleWithinTheAttemptBound() throws {
        let bus = Self.toneBus()
        var a: AudioUnitEffectHost? = try makeHost(lowpass)
        var b: AudioUnitEffectHost? = try makeHost(highpass)
        var c: AudioUnitEffectHost? = try makeHost(lowpass)
        let watchedA = Watched(a!)
        let watched = [watchedA, Watched(b!), Watched(c!)]
        bus.setEffect(a)
        Self.render(bus, buffers: 5)
        XCTAssertEqual(bus.effectRenderState.current, watchedA.bits)
        bus.setEffect(b)
        let checks = AudioAtomicCounter()
        bus.effectAdoptionHook = { [unowned bus, b, c] point, _ in
            guard point == .hazardPublished else { return }
            // Another swap lands between this hazard and its re-check.
            bus.setEffect(checks.add() % 2 == 1 ? c : b)
        }
        let finished = DispatchSemaphore(value: 0)
        Thread {
            N333AudioEffectLifetimeTests.render(bus)
            finished.signal()
        }.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "the render cycle ends instead of waiting")
        bus.effectAdoptionHook = nil
        XCTAssertEqual(checks.load(), UInt64(AppAudioRenderBus.effectAdoptionAttempts), "a bounded number of checks")
        XCTAssertEqual(bus.effectRenderState.current, watchedA.bits, "the cycle kept the effect it had")
        XCTAssertEqual(bus.effectHazards.current, watchedA.bits)
        XCTAssertEqual(bus.effectHazards.candidate, 0, "and withdrew its hazard")
        let published = try XCTUnwrap(bus.effect.map { AppAudioRenderBus.effectBitPattern(of: $0) }, "an effect is published")
        Self.render(bus)
        XCTAssertEqual(bus.effectRenderState.current, published, "the next cycle adopts what is published")
        a = nil; b = nil; c = nil
        assertHoldsOnlyLiveHosts(bus, watched)
        tearDownEffect(bus, watched)
    }

    /// Free-running: one thread renders while this one replaces the effect
    /// with a new host each time and drops its own reference, so a replaced
    /// host goes as soon as reclamation allows. The hook widens the windows
    /// after the load and after the hazard. Whenever the render thread looks,
    /// what it holds is alive, and every host has gone at the end. (The
    /// sanitizer target: run it under the Address and Thread Sanitizers.)
    func testSwapsRacingTheRenderThreadNeverLeaveItHoldingAReleasedHost() throws {
        let bus = Self.toneBus()
        var pool: [AudioUnitEffectHost] = []
        for index in 0..<24 {
            let host = try makeHost(index % 2 == 0 ? lowpass : highpass)
            pool.append(host)
        }
        // Made while all are alive, so their bits differ; read-only from here on.
        let watched = pool.map { Watched($0) }
        let violations = AudioAtomicCounter(), checks = AudioAtomicCounter(), renders = AudioAtomicCounter()
        let running = AudioAtomicCounter(1)
        bus.effectAdoptionHook = { [unowned bus] point, bits in
            let state = bus.effectRenderState
            for held in [state.current, state.previous] where held != 0 {
                if watched.first(where: { $0.bits == held })?.alive != true { violations.add() }
            }
            guard bits != 0, bits != state.current else { return }
            if point == .hazardPublished { checks.add() }
            usleep(150)
        }
        let done = DispatchSemaphore(value: 0)
        Thread {
            var output = [Float](repeating: 0, count: 256)
            while running.load() == 1 {
                output.withUnsafeMutableBufferPointer { pointer in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                    withUnsafeMutablePointer(to: &list) { bus.render(frames: 128, output: $0, allowWaiting: true) }
                }
                renders.add()
            }
            done.signal()
        }.start()
        let started = Date()
        while renders.load() == 0 && Date().timeIntervalSince(started) < 2 { usleep(100) }
        while !pool.isEmpty {
            bus.setEffect(pool.removeLast()) // the bus now holds the only reference
            usleep(600)
        }
        bus.setEffect(nil)
        usleep(20_000)
        running.store(0)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        bus.effectAdoptionHook = nil
        XCTAssertEqual(violations.load(), 0, "the render thread never held a released host")
        XCTAssertGreaterThan(renders.load(), 50)
        XCTAssertGreaterThan(checks.load(), 0, "new hosts went through the hazard check")
        tearDownEffect(bus, watched)
    }
}
