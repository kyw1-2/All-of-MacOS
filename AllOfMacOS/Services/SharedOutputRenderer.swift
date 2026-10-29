import AppKit
import AVFoundation

/// A stable graph per hardware output. App membership changes only the render
/// bus, never AVAudioEngine's connections while media is playing.
@MainActor
final class SharedOutputRenderer {
    static let shared = SharedOutputRenderer()
    nonisolated static let sampleRate: Double = 48000

    final class SourceToken {
        let id: UUID
        fileprivate let uid: String
        let isAirPlay: Bool
        let deviceID: AudioDeviceID
        fileprivate init(id: UUID, uid: String, deviceID: AudioDeviceID, isAirPlay: Bool = false) {
            self.id = id; self.uid = uid; self.deviceID = deviceID; self.isAirPlay = isAirPlay
        }
    }

    private final class DeviceGraph {
        let engine: AVAudioEngine
        let bus: AppAudioRenderBus
        let node: AVAudioSourceNode
        let deviceID: AudioDeviceID
        var observer: NSObjectProtocol?
        var failure: String?
        /// 3.3.3 (A03): this output's ring and counters in the event log;
        /// they go when the graph does (every removal path drops it).
        var eventSource: AudioEventLog.Source?
        init(engine: AVAudioEngine, bus: AppAudioRenderBus, node: AVAudioSourceNode, deviceID: AudioDeviceID) {
            self.engine = engine; self.bus = bus; self.node = node; self.deviceID = deviceID
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let eventSource {
                AudioEventLog.shared.unregister(eventSource)
                AudioEventLog.shared.record(.outputStopped, source: eventSource.name)
            }
        }
    }
    /// Output Magic Boost is a switch, as in SoundSource; 0 = off, 1 = on.
    private var masterBoostLevel: Int = UserDefaults.standard.bool(forKey: "AOMAudioMasterBoostEnabled") ? 1 : 0

    func setMasterBoostLevel(_ level: Int) {
        masterBoostLevel = level > 0 ? 1 : 0
        for graph in graphs.values { graph.bus.setBoostLevel(masterBoostLevel) }
        for output in airPlayOutputs.values { output.bus.setBoostLevel(masterBoostLevel) }
    }

    /// 3.3.3 (S06): the output Magic Boost preset (index into `AudioBoostPreset.all`).
    private var masterBoostPreset = AudioBoostPreset.index(of: AudioBoostPreset.storedID(bundleID: nil))

    func setMasterBoostPreset(_ index: Int) {
        masterBoostPreset = index
        for graph in graphs.values { graph.bus.setBoostPreset(index) }
        for output in airPlayOutputs.values { output.bus.setBoostPreset(index) }
    }

    /// 3.3.3 (S03): the Audio Unit effect on every output's master chain
    /// (nil: none), one instance per output, made here (main, never a
    /// render thread) and swapped in lock-free with a 10 ms crossfade.
    private(set) var masterEffect: AudioUnitEffectHost.Choice? =
        UserDefaults.standard.string(forKey: AudioUnitEffectHost.choiceKey).flatMap { AudioUnitEffectHost.Choice(key: $0) }

    private func makeMasterEffect() -> AudioUnitEffectHost? {
        guard let masterEffect else { return nil }
        return AudioUnitEffectHost(choice: masterEffect, sampleRate: Self.sampleRate,
                                   state: UserDefaults.standard.data(forKey: AudioUnitEffectHost.stateKey))
    }

    private var allBuses: [AppAudioRenderBus] { graphs.values.map(\.bus) + airPlayOutputs.values.map(\.bus) }

    /// Chooses the output effect (its saved state is kept only for the same
    /// component). False if the component could not be made; nothing changes then.
    @discardableResult
    func setMasterEffect(_ choice: AudioUnitEffectHost.Choice?) -> Bool {
        let defaults = UserDefaults.standard
        if let choice {
            guard AudioUnitEffectHost(choice: choice, sampleRate: Self.sampleRate) != nil else { return false }
            if choice.key != masterEffect?.key { defaults.removeObject(forKey: AudioUnitEffectHost.stateKey) }
            defaults.set(choice.key, forKey: AudioUnitEffectHost.choiceKey)
        } else {
            defaults.removeObject(forKey: AudioUnitEffectHost.choiceKey)
            defaults.removeObject(forKey: AudioUnitEffectHost.stateKey)
        }
        masterEffect = choice
        for bus in allBuses { bus.setEffect(makeMasterEffect()) }
        AudioEventLog.shared.record(.effectChanged, source: "system",
                                    detail: "output effect: \(choice.map { "\($0.name) (\($0.key))" } ?? "none")")
        return true
    }

    /// The instance an editor shows: on the default output if it has one.
    func masterEffectForEditing() -> AudioUnitEffectHost? {
        let uid = AudioOutputService.currentDeviceID().map { AudioOutputService.string($0, kAudioDevicePropertyDeviceUID) }
        if let uid, let bus = graphs[uid]?.bus ?? airPlayOutputs[uid]?.bus, let effect = bus.effect { return effect }
        return allBuses.lazy.compactMap(\.effect).first
    }

    /// After editing `edited`: its state is saved and the other outputs get
    /// fresh instances with it (each swapped in with the crossfade).
    func saveMasterEffectState(from edited: AudioUnitEffectHost) {
        guard let state = edited.state else { return }
        UserDefaults.standard.set(state, forKey: AudioUnitEffectHost.stateKey)
        for bus in allBuses where bus.effect !== edited { bus.setEffect(makeMasterEffect()) }
    }

    private var graphs: [String: DeviceGraph] = [:]
    private var airPlayOutputs: [String: AirPlayOutputRenderer] = [:]
    var activeDeviceUIDs: [String] { Array(Set(graphs.keys).union(airPlayOutputs.keys)) }

    /// Start asynchronously before creating a muting process tap. A real HAL
    /// render callback must arrive before this returns ready.
    func prepareAirPlay(device: AudioOutputDevice) -> AirPlayOutputRenderer.State {
        if let old = airPlayOutputs[device.uid], old.deviceID != device.id {
            // The old device object is gone: a fade has nothing left to play to.
            guard old.bus.hasNoLiveSources else { return .failed("AirPlay device reconnected. Reconnect audio processing.") }
            old.stop(); airPlayOutputs.removeValue(forKey: device.uid)
        }
        if airPlayOutputs[device.uid] == nil {
            let output = AirPlayOutputRenderer(deviceID: device.id, uid: device.uid) {
                if #available(macOS 14.2, *) { AppAudioEngine.shared.requestSync() }
            }
            output.bus.setBoostLevel(masterBoostLevel)
            output.bus.setBoostPreset(masterBoostPreset)
            output.bus.setEffect(makeMasterEffect())
            airPlayOutputs[device.uid] = output
        }
        return airPlayOutputs[device.uid]!.state
    }

    func airPlayFailure(_ token: SourceToken) -> String? {
        guard token.isAirPlay else { return nil }
        guard let output = airPlayOutputs[token.uid] else {
            return "AirPlay disconnected. Native playback restored."
        }
        if case .failed(let message) = output.state { return message }
        return nil
    }

    /// Outputs no app wants any more stop once their last source has faded
    /// out (`isEmpty` waits for the fades; 3.3.2 review).
    func releaseUnusedAirPlayOutputs(keeping uids: Set<String>) {
        for (uid, output) in Array(airPlayOutputs) where !uids.contains(uid) && output.bus.isEmpty {
            output.stop(); airPlayOutputs.removeValue(forKey: uid)
            airPlayMissingSince[uid] = nil
        }
    }

    func resetAirPlayFailures(uid requestedUID: String? = nil) {
        // A failed output renders nothing, so its fades cannot finish.
        for (uid, output) in Array(airPlayOutputs)
            where (requestedUID == nil || requestedUID == uid) && output.bus.hasNoLiveSources {
            if case .failed = output.state {
                output.stop(); airPlayOutputs.removeValue(forKey: uid)
                airPlayMissingSince[uid] = nil
            }
        }
    }

    func addSource(uid: String, device: AudioOutputDevice,
                   render: @escaping AppAudioRenderBus.Render) -> SourceToken? {
        if AudioOutputRestore.transportType(of: device.id) == kAudioDeviceTransportTypeAirPlay {
            guard case .ready = prepareAirPlay(device: device), let output = airPlayOutputs[uid] else { return nil }
            let id = UUID()
            output.bus.add(id: id, render: render)
            return SourceToken(id: id, uid: uid, deviceID: device.id, isAirPlay: true)
        }
        if let existing = graphs[uid], existing.deviceID != device.id {
            // A reconnected device may reuse its UID with a different object ID.
            // The caller first moves/removes its old sources; never overwrite
            // them. The old object is gone, so fading ones do not count.
            guard existing.bus.hasNoLiveSources else { return nil }
            existing.engine.stop()
            graphs.removeValue(forKey: uid)
        }
        if graphs[uid] == nil {
            guard let graph = makeGraph(uid: uid, device: device) else { return nil }
            graphs[uid] = graph
        }
        guard let graph = graphs[uid], graph.failure == nil, graph.engine.isRunning else { return nil }
        let id = UUID()
        graph.bus.add(id: id, render: render)
        return SourceToken(id: id, uid: uid, deviceID: device.id)
    }

    private func makeGraph(uid: String, device: AudioOutputDevice) -> DeviceGraph? {
        let engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else { return nil }
        var deviceID = device.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
              output.outputFormat(forBus: 0).channelCount > 0,
              output.outputFormat(forBus: 0).sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else { return nil }
        let bus = AppAudioRenderBus()
        bus.setBoostLevel(masterBoostLevel)
        bus.setBoostPreset(masterBoostPreset)
        bus.setEffect(makeMasterEffect())
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            bus.render(frames: Int(frames), output: buffers)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch { engine.stop(); return nil }
        let graph = DeviceGraph(engine: engine, bus: bus, node: node, deviceID: device.id)
        graph.eventSource = AudioEventLog.shared.register(name: "output:\(uid)", rings: [bus.events]) { [weak bus] in
            ["output.limiterEngagements": bus?.limiterEngagements.load() ?? 0]
        }
        AudioEventLog.shared.record(.outputStarted, source: "output:\(uid)", detail: "\(device.name), local output")
        graph.observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak graph] _ in
            // Defer out of AVAudioEngine's notification stack.
            DispatchQueue.main.async { [weak self, weak graph] in
                guard let self, let graph, self.graphs[uid] === graph else { return }
                self.recover(graph, uid: uid)
            }
        }
        return graph
    }

    private func recover(_ graph: DeviceGraph, uid: String) {
        guard !graph.engine.isRunning else { return }
        guard AudioOutputService.devices().contains(where: { $0.uid == uid && $0.id == graph.deviceID }) else {
            graph.failure = "Audio output disconnected"
            return
        }
        graph.failure = nil
        do { try graph.engine.start() }
        catch { graph.failure = "Audio output could not restart: \(error.localizedDescription)" }
    }

    func isReady(_ token: SourceToken) -> Bool {
        if token.isAirPlay {
            guard let output = airPlayOutputs[token.uid], output.deviceID == token.deviceID, case .ready = output.state else { return false }
            return true
        }
        guard let graph = graphs[token.uid], graph.deviceID == token.deviceID else { return false }
        return graph.failure == nil && graph.engine.isRunning
    }

    /// Restarts a stopped engine in place: overload or a transient format
    /// change stops the HAL cycle, and starting again keeps the tap, the
    /// aggregate and every source node attached — no player sees device loss.
    @discardableResult
    func ensureRunning(token: SourceToken) -> Bool {
        // AirPlay failures release muting taps; only explicit recovery can
        // reopen the remote session. Never start a reconnect loop here.
        guard !token.isAirPlay, let graph = graphs[token.uid], graph.deviceID == token.deviceID else { return false }
        guard !graph.engine.isRunning else { return graph.failure == nil }
        graph.failure = nil
        do { try graph.engine.start() } catch {
            graph.failure = "Audio output restart failed: \(error.localizedDescription)"
        }
        return graph.failure == nil && graph.engine.isRunning
    }

    func removeSource(_ token: SourceToken) {
        if token.isAirPlay {
            airPlayOutputs[token.uid]?.bus.remove(id: token.id)
            return
        }
        guard let graph = graphs[token.uid] else { return }
        graph.bus.remove(id: token.id)
        // Keep an idle graph running for subsequent app playback. Explicit
        // shutdown and physical device removal release the hardware.
    }

    /// When each AirPlay output's device was first missing from the device
    /// list (crackle audit 3.3.2, follow-up). One list read without the
    /// HomePod (its output streams can read empty for a moment while a route
    /// settles) used to stop the output and, through `airPlayFailure`, every
    /// HomePod tap at once: native audio cut back in mid-waveform and a
    /// reconnect followed seconds later. Now it goes once the device says it
    /// is dead, or after it has been missing for `airPlayMissingGrace`.
    private var airPlayMissingSince: [String: TimeInterval] = [:]
    nonisolated static let airPlayMissingGrace: TimeInterval = 1.5

    /// Pure: whether an AirPlay output whose device is missing from the list
    /// goes now. `deviceAlive` is kAudioDevicePropertyDeviceIsAlive of its
    /// device object (nil: the read failed, the object is gone).
    nonisolated static func releasesMissingAirPlay(missingFor: TimeInterval, deviceAlive: Bool?) -> Bool {
        guard deviceAlive == true else { return true }
        return missingFor >= airPlayMissingGrace
    }

    private static func deviceIsAlive(_ device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr else { return nil }
        return alive != 0
    }

    func rebindIfNeeded(devices: [AudioOutputDevice], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for (uid, output) in Array(airPlayOutputs) {
            if devices.contains(where: { $0.uid == uid && $0.id == output.deviceID }) {
                airPlayMissingSince[uid] = nil
                continue
            }
            let since = airPlayMissingSince[uid] ?? now
            airPlayMissingSince[uid] = since
            guard Self.releasesMissingAirPlay(missingFor: now - since,
                                              deviceAlive: Self.deviceIsAlive(output.deviceID)) else { continue }
            airPlayMissingSince[uid] = nil
            output.stop()
            airPlayOutputs.removeValue(forKey: uid)
        }
        for (uid, graph) in Array(graphs) {
            let present = devices.contains { $0.uid == uid && $0.id == graph.deviceID }
            if !present { graph.failure = "Audio output disconnected" }
            // A failed or stopped graph renders nothing, so fades do not count.
            if !present || (graph.bus.hasNoLiveSources && (graph.failure != nil || !graph.engine.isRunning)) {
                // Retire a vanished object even while tokens still reference it.
                // A reconnect can preserve the UID while replacing the numeric ID.
                graph.bus.removeAll()
                graph.engine.stop()
                graphs.removeValue(forKey: uid)
            }
        }
    }

    var airPlayStatistics: [String: [String: Any]] { airPlayOutputs.mapValues { $0.statistics } }

    func shutdown() {
        for output in airPlayOutputs.values { output.stop() }
        airPlayOutputs.removeAll()
        for graph in graphs.values { graph.engine.stop(); graph.bus.removeAll() }
        graphs.removeAll()
    }
}

/// Preallocated stereo summing bus. Control operations wait for an in-flight
/// render to finish; the realtime callback never allocates or edits an
/// AVAudioEngine graph. Removing a source fades it out over 5 ms and a sweep
/// on main releases its closure later; `removeAll` is the teardown barrier.
/// After summing, the output's Magic Boost and a transparent lookahead
/// limiter process the mix, so boosted or summed apps never hard clip.
final class AppAudioRenderBus {
    typealias Render = (Int, UnsafeMutablePointer<AudioBufferList>) -> Void
    static let ceiling: Float = 0.977 // -0.2 dBFS
    /// Network receivers (AirPlay) decode a lossy stream whose overshoot
    /// clips a mix at −0.2 dB sample peak: −1 dB true peak (4× oversampled
    /// detection), the usual headroom for lossy delivery.
    static let networkCeiling: Float = 0.891 // -1 dBFS
    /// The network bus releases over 150 ms instead of 25 ms (HomePod crackle
    /// audit, follow-up): at −1 dBTP the limiter works on most loud masters,
    /// and a 25 ms release rose and fell with every bass cycle.
    static let networkRelease: Double = 0.15
    private let lock = AudioUnfairLock()
    /// 3.3.2: a removed source fades out over 5 ms before it goes; cutting an
    /// app off mid-waveform (a session stopping, an output moving) clicked.
    /// The render thread only writes this box (never the array, which could
    /// copy); a control-thread sweep drops faded sources so their closures,
    /// and the transports those hold, are released off the render thread.
    private final class SourceFade {
        /// Frames already faded; -1 while the source is live.
        var faded = -1
        /// When `remove` started the fade (control thread).
        var removedAt: TimeInterval = 0
        var finished: Bool { faded >= AppAudioRenderBus.removalFadeFrames }
    }
    static let removalFadeFrames = 240
    private var sources: [(id: UUID, render: Render, fade: SourceFade)] = []
    private let capacity = 32768
    private let chunk = 512
    private let scratch: UnsafeMutablePointer<Float>
    private let sum: UnsafeMutablePointer<Float>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let limiter: AudioLookaheadLimiter
    private let boost = AudioMagicBoost(sampleRate: SharedOutputRenderer.sampleRate)
    private let boostLevel = AudioAtomicCounter()
    /// 3.3.3 (A03): the render thread's ring (limiter engagement; on an
    /// AirPlay bus also the mix clock's late wake-ups) and the engagements so far.
    let events = AudioEventRing(capacity: 32)
    let limiterEngagements = AudioAtomicCounter()
    /// Below this gain (−0.1 dB) the limiter counts as engaged; it counts as
    /// released after `limiterReleaseHoldSeconds` without any reduction, so a
    /// loud passage is one engagement, not one per peak.
    static let limiterEngageGain: Float = 0.98855
    static let limiterReleaseHoldSeconds = 2.0
    // Render thread only.
    private var limiterEngaged = false
    private var limiterQuietFrames = 0
    private var limiterEpisodeFrames = 0
    private var limiterEpisodeDeepest: Float = 1

    /// Centi-dB of gain reduction (render thread; no allocation).
    private static func centiDecibels(_ gain: Float) -> UInt64 {
        guard gain > 0, gain < 1 else { return gain >= 1 ? 0 : 99_999 }
        return UInt64((-20 * log10(Double(gain)) * 100).rounded())
    }

    // MARK: 3.3.3 (S03): a hosted Audio Unit on this output's master chain

    /// The effect the control thread published (a +1 retained
    /// `AudioUnitEffectHost` as pointer bits; 0: none). It runs after the
    /// apps are summed and before Magic Boost and the limiter, which still
    /// guard the output. A change crossfades over 10 ms from the previous
    /// effect (or dry); a replaced host is released by the control thread
    /// once the render thread has stopped using it, never on the render thread.
    private let effectSlot = AudioAtomicCounter()
    /// What the render thread uses: written before it starts and after it
    /// stops using a host (previous first when a crossfade starts).
    private let effectInUse = AudioAtomicCounter()
    private let effectPreviousInUse = AudioAtomicCounter()
    // Render thread only.
    private var effectBits: UInt64 = 0
    private var previousEffectBits: UInt64 = 0
    private var effectFadeRemaining = 0
    static let effectFadeFrames = 480
    private let effectOldLeft: UnsafeMutablePointer<Float>
    private let effectOldRight: UnsafeMutablePointer<Float>
    /// Control threads only: hosts replaced but perhaps still in use.
    private let retiredLock = NSLock()
    private var retiredEffects: [UInt64] = []

    /// Control thread: hosts `effect` on this output (nil: none).
    func setEffect(_ effect: AudioUnitEffectHost?) {
        let bits = effect.map { UInt64(UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())) } ?? 0
        var old = effectSlot.load()
        while !effectSlot.compareExchange(expected: old, desired: bits) { old = effectSlot.load() }
        if old != 0 {
            retiredLock.lock(); retiredEffects.append(old); retiredLock.unlock()
        }
        releaseRetiredEffects()
    }

    /// The hosted effect now published (control thread).
    var effect: AudioUnitEffectHost? {
        let bits = effectSlot.load()
        guard bits != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(bits)) else { return nil }
        return Unmanaged<AudioUnitEffectHost>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// Releases replaced hosts the render thread no longer uses; checks
    /// again later while one is still in use (an idle output keeps it until
    /// it renders again or goes away).
    func releaseRetiredEffects(attempt: Int = 0) {
        retiredLock.lock()
        let current = effectInUse.load(), previous = effectPreviousInUse.load(), published = effectSlot.load()
        let free = retiredEffects.filter { $0 != current && $0 != previous && $0 != published }
        retiredEffects.removeAll { free.contains($0) }
        let waiting = !retiredEffects.isEmpty
        retiredLock.unlock()
        for bits in free {
            if let pointer = UnsafeRawPointer(bitPattern: UInt(bits)) {
                Unmanaged<AudioUnitEffectHost>.fromOpaque(pointer).release()
            }
        }
        if waiting && attempt < 40 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.releaseRetiredEffects(attempt: attempt + 1)
            }
        }
    }

    /// Render thread, once per buffer: takes up a newly published effect.
    @inline(__always)
    private func adoptEffect() {
        let published = effectSlot.load()
        guard published != effectBits else { return }
        // The outgoing host is marked in use before the incoming one, so a
        // control thread that sees the new one also sees the old one held.
        effectPreviousInUse.store(effectBits)
        previousEffectBits = effectBits
        effectBits = published
        effectInUse.store(published)
        effectFadeRemaining = Self.effectFadeFrames
    }

    @inline(__always)
    private static func runEffect(_ bits: UInt64, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                  frames: Int) {
        guard bits != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(bits)) else { return }
        Unmanaged<AudioUnitEffectHost>.fromOpaque(pointer)._withUnsafeGuaranteedRef {
            _ = $0.process(left: left, right: right, frames: frames)
        }
    }

    /// Render thread: the hosted effect over one chunk, in place.
    private func processEffect(frames: Int) {
        guard effectBits != 0 || previousEffectBits != 0 || effectFadeRemaining > 0 else { return }
        guard effectFadeRemaining > 0 else {
            Self.runEffect(effectBits, left: left, right: right, frames: frames)
            return
        }
        // Crossfade: the previous effect (or dry) out, the new one (or dry) in.
        memcpy(effectOldLeft, left, frames * 4); memcpy(effectOldRight, right, frames * 4)
        Self.runEffect(previousEffectBits, left: effectOldLeft, right: effectOldRight, frames: frames)
        Self.runEffect(effectBits, left: left, right: right, frames: frames)
        let length = Float(Self.effectFadeFrames)
        for index in 0..<frames {
            let done = Self.effectFadeFrames - effectFadeRemaining + index + 1
            let x = min(1, Float(done) / length)
            let gain = x * x * (3 - 2 * x)
            left[index] = effectOldLeft[index] + (left[index] - effectOldLeft[index]) * gain
            right[index] = effectOldRight[index] + (right[index] - effectOldRight[index]) * gain
        }
        effectFadeRemaining = max(0, effectFadeRemaining - frames)
        if effectFadeRemaining == 0 {
            previousEffectBits = 0
            effectPreviousInUse.store(0)
        }
    }

    /// Render thread: one chunk's limiter activity into episodes.
    private func noteLimiter(frames: Int) {
        let deepest = limiter.takeDeepestReduction()
        if deepest < Self.limiterEngageGain {
            if !limiterEngaged {
                limiterEngaged = true
                limiterEpisodeFrames = 0
                limiterEpisodeDeepest = deepest
                limiterEngagements.add()
                events.push(.limiterEngaged, value: Self.centiDecibels(deepest))
            }
            limiterEpisodeDeepest = min(limiterEpisodeDeepest, deepest)
            limiterQuietFrames = 0
        } else if limiterEngaged {
            limiterQuietFrames += frames
            if Double(limiterQuietFrames) >= Self.limiterReleaseHoldSeconds * SharedOutputRenderer.sampleRate {
                limiterEngaged = false
                events.push(.limiterReleased, value: Self.centiDecibels(limiterEpisodeDeepest),
                            extra: UInt64(Double(limiterEpisodeFrames) * 1000 / SharedOutputRenderer.sampleRate))
            }
        }
        if limiterEngaged { limiterEpisodeFrames += frames }
    }
    /// Output Magic Boost switch; any level above zero is on.
    func setBoostLevel(_ level: Int) {
        boostLevel.store(level > 0 ? 1 : 0)
    }
    /// 3.3.3 (S06): the output's Magic Boost preset, with its limiter
    /// release. A network bus never releases faster than it was built to
    /// (150 ms: a faster release modulates bass on AirPlay).
    func setBoostPreset(_ index: Int) {
        let preset = AudioBoostPreset.all[min(max(0, index), AudioBoostPreset.all.count - 1)]
        boost.setPreset(index: index)
        let seconds = Self.limiterRelease(base: baseRelease, preset: preset)
        let coefficient = AudioLookaheadLimiter.releaseCoefficient(sampleRate: SharedOutputRenderer.sampleRate, seconds: seconds)
        limiterReleaseBits.store(UInt64(coefficient.bitPattern))
    }
    /// The limiter release a preset gives a bus built with `base` (never faster).
    static func limiterRelease(base: Double, preset: AudioBoostPreset) -> Double {
        max(base, preset.limiterRelease ?? base)
    }
    var boostPresetIndex: Int { boost.presetIndex }
    private let baseRelease: Double
    /// The limiter release coefficient wanted (Float bits; 0: unchanged) and,
    /// render thread only, the one in use.
    private let limiterReleaseBits = AudioAtomicCounter()
    private var appliedReleaseBits: UInt64 = 0
    var limiterCeiling: Float { limiter.ceiling }
    init(ceiling: Float = AppAudioRenderBus.ceiling, truePeak: Bool = false, releaseSeconds: Double = 0.025) {
        baseRelease = releaseSeconds.isFinite ? min(2, max(0.005, releaseSeconds)) : 0.025
        limiter = AudioLookaheadLimiter(sampleRate: SharedOutputRenderer.sampleRate, ceiling: ceiling, truePeak: truePeak,
                                        releaseSeconds: releaseSeconds)
        scratch = .allocate(capacity: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)
        sum = .allocate(capacity: capacity * 2)
        sum.initialize(repeating: 0, count: capacity * 2)
        left = .allocate(capacity: chunk); left.initialize(repeating: 0, count: chunk)
        right = .allocate(capacity: chunk); right.initialize(repeating: 0, count: chunk)
        effectOldLeft = .allocate(capacity: chunk); effectOldLeft.initialize(repeating: 0, count: chunk)
        effectOldRight = .allocate(capacity: chunk); effectOldRight.initialize(repeating: 0, count: chunk)
    }
    deinit {
        scratch.deallocate(); sum.deallocate(); left.deallocate(); right.deallocate()
        effectOldLeft.deallocate(); effectOldRight.deallocate()
        // Nothing renders any more: the published host and every replaced
        // one are released here (each holds exactly one retain).
        for bits in retiredEffects + [effectSlot.load()] where bits != 0 {
            if let pointer = UnsafeRawPointer(bitPattern: UInt(bits)) {
                Unmanaged<AudioUnitEffectHost>.fromOpaque(pointer).release()
            }
        }
    }
    /// No source that can still be heard: none live, and every removed one
    /// has finished its 5 ms fade (or was removed more than 0.5 s ago from an
    /// output that stopped rendering). 3.3.2 review: fading sources counted
    /// as gone, so releasing an unused AirPlay output could stop it inside a
    /// fade, a click at the end of the last app's audio.
    var isEmpty: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        return sources.allSatisfy { Self.isGone($0.fade, now: now) }
    }
    /// No live source; fading ones may still be heard. For an output whose
    /// device is gone or failed, where a fade has nothing left to play to.
    var hasNoLiveSources: Bool { lock.lock(); defer { lock.unlock() }; return sources.allSatisfy { $0.fade.faded >= 0 } }
    private static func isGone(_ fade: SourceFade, now: TimeInterval) -> Bool {
        fade.finished || (fade.faded >= 0 && now - fade.removedAt > 0.5)
    }
    /// Bumped under the lock whenever `sources` changes, so `add` can build
    /// the longer list outside the lock and swap it in.
    private var generation = 0
    /// 3.3.2 review: the AirPlay mix thread waits for this lock, so the new
    /// entry (its `SourceFade`) and the grown list are made before taking it;
    /// under the lock the two lists are only swapped, and the old one is
    /// released after it. A list changed in between (a sweep) is rebuilt.
    func add(id: UUID, render: @escaping Render) {
        let entry = (id: id, render: render, fade: SourceFade())
        while true {
            lock.lock()
            let snapshot = sources
            let seen = generation
            lock.unlock()
            var grown = snapshot
            grown.reserveCapacity(snapshot.count + 1)
            grown.append(entry)
            lock.lock()
            guard seen == generation else { lock.unlock(); continue }
            swap(&sources, &grown)
            generation &+= 1
            lock.unlock()
            return
        }
    }
    /// The source stops contributing after a 5 ms fade; its closure is
    /// released by a sweep shortly after (it keeps what it captured alive).
    func remove(id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        for source in sources where source.id == id && source.fade.faded < 0 {
            source.fade.removedAt = now
            source.fade.faded = 0
        }
        lock.unlock()
        for delay in [0.1, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sweep() }
        }
    }
    /// Teardown: every source goes at once (the output itself is stopping).
    func removeAll() {
        lock.lock()
        let released = sources
        sources.removeAll()
        generation &+= 1
        lock.unlock()
        _ = released
    }
    /// Drops finished fades, and fades an idle output never rendered (after
    /// 0.5 s); the closures are released after the lock.
    private func sweep() {
        let now = ProcessInfo.processInfo.systemUptime
        func done(_ fade: SourceFade) -> Bool { Self.isGone(fade, now: now) }
        // The AirPlay mix thread waits for this lock (allowWaiting), so no
        // heap allocation happens while it is held: the list of finished
        // sources is reserved before, and the removal works in place. The
        // closures are still released after the lock, from `finished`.
        lock.lock()
        let count = sources.count
        lock.unlock()
        var finished: [(id: UUID, render: Render, fade: SourceFade)] = []
        finished.reserveCapacity(count)
        lock.lock()
        for source in sources where done(source.fade) && finished.count < finished.capacity {
            finished.append(source)
        }
        if !finished.isEmpty {
            sources.removeAll { source in done(source.fade) && finished.contains { $0.fade === source.fade } }
            generation &+= 1
        }
        lock.unlock()
        _ = finished
    }

    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>, allowWaiting: Bool = false) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, frames <= capacity else { return }
        if allowWaiting { lock.lock() } else if !lock.tryLock() { return }
        defer { lock.unlock() }
        memset(sum, 0, frames * 2 * MemoryLayout<Float>.size)
        let fadeLength = Self.removalFadeFrames
        for source in sources {
            let fade = source.fade
            if fade.finished { continue }
            memset(scratch, 0, frames * 2 * MemoryLayout<Float>.size)
            var temporary = AudioBufferList(mNumberBuffers: 1, mBuffers:
                AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: scratch))
            withUnsafeMutablePointer(to: &temporary) { source.render(frames, $0) }
            if fade.faded >= 0 {
                for frame in 0..<frames {
                    let done = fade.faded + frame + 1
                    let x = Float(min(done, fadeLength)) / Float(fadeLength)
                    let gain = 1 - x * x * (3 - 2 * x)
                    scratch[frame * 2] *= gain; scratch[frame * 2 + 1] *= gain
                }
                fade.faded = min(fadeLength, fade.faded + frames)
            }
            for index in 0..<(frames * 2) {
                sum[index] += scratch[index].isFinite ? scratch[index] : 0
            }
        }
        // Snapshot once per buffer; a settings change never takes the render lock.
        let boostEnabled = boostLevel.load() != 0
        let releaseBits = limiterReleaseBits.load()
        if releaseBits != 0 && releaseBits != appliedReleaseBits {
            appliedReleaseBits = releaseBits
            limiter.setReleaseCoefficient(Float(bitPattern: UInt32(truncatingIfNeeded: releaseBits)))
        }
        adoptEffect()
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            for index in 0..<count {
                left[index] = sum[(offset + index) * 2]; right[index] = sum[(offset + index) * 2 + 1]
            }
            processEffect(frames: count)
            boost.process(left: left, right: right, frames: count, enabled: boostEnabled)
            limiter.process(left: left, right: right, frames: count)
            noteLimiter(frames: count)
            for index in 0..<count {
                sum[(offset + index) * 2] = left[index]; sum[(offset + index) * 2 + 1] = right[index]
            }
            offset += count
        }
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channel = 0
        for buffer in buffers {
            let width = Int(buffer.mNumberChannels)
            guard width > 0 else { continue }
            defer { channel += width }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / (4 * width))
            for frame in 0..<count {
                for offset in 0..<width {
                    let index = channel + offset
                    data[frame * width + offset] = channels == 1 ? (sum[frame * 2] + sum[frame * 2 + 1]) * 0.5
                        : (index < 2 ? sum[frame * 2 + index] : 0)
                }
            }
        }
    }
}
