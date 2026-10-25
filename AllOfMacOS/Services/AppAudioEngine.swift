import AppKit
import CoreAudio
import AudioToolbox
import Darwin

/// SoundSource-lite per-app audio control on macOS 14.2+ Core Audio Process
/// Taps. For each app the user adjusts: a process tap is created with
/// `.whenRunning` mute behavior (the app's own output is silenced while the
/// tap runs), the tapped stream is mixed with the app's gain into the default
/// output device through an IOProc owned by this engine.
///
/// Everything here is macOS 14.2+; callers gate with `isSupported`. The mixer
/// math and persisted state are pure and unit-tested in isolation. Requires
/// the system audio-recording approval (macOS 14.4+ prompt), which SoundSource
/// needs identically.
/// Un-gated so panels and actions can reference it before the availability
/// check; the engine itself stays 14.2+.
struct AppAudioState: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    var bundleID: String = ""
    var icon: NSImage? = nil
    var gain: Float // 0...2, 1 = unity
    var muted: Bool
    var tapped: Bool
    var outputDeviceUID: String? = nil
    var magicBoost: Bool = false
    var id: Int32 { pid }

    static func == (lhs: AppAudioState, rhs: AppAudioState) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.name == rhs.name &&
        lhs.bundleID == rhs.bundleID &&
        lhs.gain == rhs.gain &&
        lhs.muted == rhs.muted &&
        lhs.tapped == rhs.tapped &&
        lhs.outputDeviceUID == rhs.outputDeviceUID &&
        lhs.magicBoost == rhs.magicBoost
    }
}

@available(macOS 14.2, *)
final class AppAudioEngine {
    static let shared = AppAudioEngine()

    typealias AppState = AppAudioState

    final class Session {
        let pid: pid_t
        let bundleID: String
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        var procID: AudioDeviceIOProcID?
        var box: Unmanaged<MixerBox>
        var gain: Float
        var muted: Bool
        init(pid: pid_t, bundleID: String, tapID: AudioObjectID, aggregateID: AudioObjectID,
             procID: AudioDeviceIOProcID?, box: Unmanaged<MixerBox>, gain: Float, muted: Bool) {
            self.pid = pid; self.bundleID = bundleID; self.tapID = tapID
            self.aggregateID = aggregateID; self.procID = procID; self.box = box
            self.gain = gain; self.muted = muted
        }
    }

    @Published private(set) var authorizationDenied = false
    private var sessions: [pid_t: Session] = [:]

    var isSupported: Bool { true } // the type itself is 14.2-gated

    private init() {
        setupProcessListener()
    }

    private func setupProcessListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.syncActiveProcesses()
        }
    }

    func syncActiveProcesses() {
        for app in runningAudioApps() {
            let bundleID = app.bundleID
            guard !bundleID.isEmpty else { continue }
            let hasCustomGain = UserDefaults.standard.object(forKey: "AOMAudioGain_\(bundleID)") != nil
            let isMuted = UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)")
            if hasCustomGain || isMuted {
                let gain = Self.storedGain(bundleID: bundleID)
                _ = setGain(gain, muted: isMuted, pid: app.pid)
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name("AOMAudioAppsChanged"), object: nil)
    }

    // MARK: - Process Hierarchy & Helpers

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if size == MemoryLayout<proc_bsdinfo>.size {
            return pid_t(info.pbi_ppid)
        }
        return nil
    }

    private static func mainApp(for pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app
        }
        var current = pid
        for _ in 0..<5 {
            guard let ppid = parentPID(of: current), ppid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: ppid), app.activationPolicy == .regular {
                return app
            }
            current = ppid
        }
        return nil
    }

    static func processObjectIDs(for targetPID: pid_t) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }

        var result: [AudioObjectID] = []
        for obj in objects {
            guard let p = property(obj, selector: kAudioProcessPropertyPID, as: pid_t.self), p > 0 else { continue }
            if p == targetPID {
                result.append(obj)
            } else if let main = mainApp(for: p), main.processIdentifier == targetPID {
                result.append(obj)
            }
        }
        return result
    }

    // MARK: - Running audio apps (process objects, 14.2+)

    func runningAudioApps() -> [AppState] {
        var results: [AppState] = []
        var seenPIDs = Set<pid_t>()

        // 1. Process tap objects from CoreAudio
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
           size > 0 {
            let count = Int(size) / MemoryLayout<AudioObjectID>.stride
            var objects = [AudioObjectID](repeating: 0, count: count)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr {
                for object in objects {
                    guard let rawPid = Self.property(object, selector: kAudioProcessPropertyPID, as: pid_t.self), rawPid > 0,
                          Self.property(object, selector: kAudioProcessPropertyIsRunning, as: UInt32.self) == 1 else { continue }

                    let app = Self.mainApp(for: rawPid) ?? NSRunningApplication(processIdentifier: rawPid)
                    let pid = app?.processIdentifier ?? rawPid
                    guard !seenPIDs.contains(pid) else { continue }
                    seenPIDs.insert(pid)

                    let bundleID = app?.bundleIdentifier ?? "pid-\(pid)"
                    results.append(AppState(
                        pid: pid,
                        name: app?.localizedName ?? "Process \(pid)",
                        bundleID: bundleID,
                        icon: app?.icon,
                        gain: sessions[pid]?.gain ?? Self.storedGain(bundleID: bundleID),
                        muted: sessions[pid]?.muted ?? UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)"),
                        tapped: sessions[pid] != nil,
                        outputDeviceUID: UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"),
                        magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
                    ))
                }
            }
        }

        // 2. Discover running media & regular user apps (SoundSource parity)
        let knownMedia = Set([
            "com.apple.Music", "com.spotify.client", "com.apple.Safari",
            "com.google.Chrome", "org.mozilla.firefox", "org.videolan.vlc",
            "com.apple.QuickTimePlayerX", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord", "us.zoom.xos", "com.apple.FaceTime",
            "com.apple.Podcasts", "com.apple.TV"
        ])
        let customApps = Set(UserDefaults.standard.stringArray(forKey: "AOMAudioUserApps") ?? [])

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard !seenPIDs.contains(pid) else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            let isMedia = knownMedia.contains(bundleID) || customApps.contains(bundleID)
            let isRegular = app.activationPolicy == .regular
            guard isMedia || (isRegular && bundleID != Bundle.main.bundleIdentifier) else { continue }

            seenPIDs.insert(pid)
            results.append(AppState(
                pid: pid,
                name: app.localizedName ?? bundleID,
                bundleID: bundleID,
                icon: app.icon,
                gain: sessions[pid]?.gain ?? Self.storedGain(bundleID: bundleID),
                muted: sessions[pid]?.muted ?? UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)"),
                tapped: sessions[pid] != nil,
                outputDeviceUID: UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"),
                magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
            ))
        }

        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addCustomApp(bundleID: String) {
        var list = UserDefaults.standard.stringArray(forKey: "AOMAudioUserApps") ?? []
        if !list.contains(bundleID) {
            list.append(bundleID)
            UserDefaults.standard.set(list, forKey: "AOMAudioUserApps")
        }
    }

    func setRoute(uid: String?, bundleID: String) {
        UserDefaults.standard.set(uid, forKey: "AOMAudioRoute_\(bundleID)")
        for (pid, session) in sessions where session.bundleID == bundleID {
            let gain = session.gain
            let muted = session.muted
            stop(pid: pid)
            _ = setGain(gain, muted: muted, pid: pid)
        }
    }

    func setMagicBoost(_ enabled: Bool, bundleID: String) {
        UserDefaults.standard.set(enabled, forKey: "AOMAudioMagicBoost_\(bundleID)")
        for (_, session) in sessions where session.bundleID == bundleID {
            session.box.takeUnretainedValue().magicBoost = enabled
        }
    }

    nonisolated private static func property<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                                as type: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func defaultOutputDeviceUID() -> String? {
        var defOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var defOutID = AudioObjectID(0)
        var defOutSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defOutAddr, 0, nil, &defOutSize, &defOutID) == noErr else { return nil }

        var devUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outUID: CFString = "" as CFString
        var outUIDSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(defOutID, &devUIDAddr, 0, nil, &outUIDSize, &outUID) == noErr else { return nil }
        let uid = outUID as String
        return uid.isEmpty ? nil : uid
    }

    static func targetOutputUID(for bundleID: String) -> String? {
        if let stored = UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"), !stored.isEmpty {
            return stored
        }
        return defaultOutputDeviceUID()
    }

    // MARK: - Gain / mute / lifecycle

    /// Starts (or retunes) the tap session for a pid.
    func setGain(_ gain: Float, muted: Bool = false, pid: pid_t) -> Bool {
        let clamped = Mixer.clamp(gain)
        persistState(gain: clamped, muted: muted, pid: pid)
        if let session = sessions[pid] {
            session.box.takeUnretainedValue().gain = clamped
            session.box.takeUnretainedValue().muted = muted
            session.gain = clamped
            session.muted = muted
            sessions[pid] = session
            return true
        }
        if let session = createSession(pid: pid, gain: clamped, muted: muted) {
            sessions[pid] = session
            authorizationDenied = false
            return true
        }
        // When process hasn't opened an audio stream yet, gain is persisted
        // and attached automatically as soon as the audio stream starts.
        return true
    }

    func stop(pid: pid_t) {
        guard let session = sessions.removeValue(forKey: pid) else { return }
        Self.destroy(session)
    }

    /// All live sessions (for master-EQ fan-out).
    func sessionsAll() -> [Session] { Array(sessions.values) }

    func stopAll() {
        for pid in Array(sessions.keys) { stop(pid: pid) }
    }

    func session(pid: pid_t) -> Session? { sessions[pid] }

    private func persistState(gain: Float, muted: Bool, pid: pid_t) {
        let app = Self.mainApp(for: pid) ?? NSRunningApplication(processIdentifier: pid)
        if let bundleID = app?.bundleIdentifier, !bundleID.isEmpty {
            UserDefaults.standard.set(Double(gain), forKey: "AOMAudioGain_\(bundleID)")
            UserDefaults.standard.set(muted, forKey: "AOMAudioMute_\(bundleID)")
        }
    }

    static func storedGain(bundleID: String) -> Float {
        Float(UserDefaults.standard.object(forKey: "AOMAudioGain_\(bundleID)") as? Double ?? 1)
    }

    // MARK: - Core Audio plumbing

    private func createSession(pid: pid_t, gain: Float, muted: Bool) -> Session? {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""

        // 1. Resolve all CoreAudio process object IDs for this app (main + audio service helpers)
        let processObjIDs = Self.processObjectIDs(for: pid)
        guard !processObjIDs.isEmpty else {
            return nil
        }

        // 2. The stereo process tap; .mutedWhenTapped silences the app's original
        //    unattenuated output while our aggregate device renders the scaled audio.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }

        // 3. The tap's UUID string
        let tapUID = description.uuid.uuidString

        // 4. Target hardware output device UID
        guard let outUID = Self.targetOutputUID(for: bundleID) ?? Self.defaultOutputDeviceUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // 5. Aggregate device wrapping BOTH Tap (via TapListKey) and Physical Output (via SubDeviceListKey)
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AOM App Audio \(pid)",
            kAudioAggregateDeviceUIDKey as String: "com.kyw.allofmacos.tap.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ],
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: outUID,
                    kAudioSubDeviceDriftCompensationKey as String: true
                ]
            ],
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID) == noErr,
              aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // 6. Realtime IOProc
        let magicBoost = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
        let box = Unmanaged.passRetained(MixerBox(gain: gain, muted: muted, magicBoost: magicBoost))
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil,
            { _, input, _, output, _ in
                Mixer.mix(input: input, output: output, box: box.takeUnretainedValue())
            })
        guard status == noErr, procID != nil else {
            box.release()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        AudioDeviceStart(aggregateID, procID!)
        return Session(pid: pid, bundleID: bundleID, tapID: tapID, aggregateID: aggregateID,
                       procID: procID, box: box, gain: gain, muted: muted)
    }

    static func destroy(_ session: Session) {
        if let procID = session.procID {
            AudioDeviceStop(session.aggregateID, procID)
            AudioDeviceDestroyIOProcID(session.aggregateID, procID)
        }
        session.box.release()
        AudioHardwareDestroyAggregateDevice(session.aggregateID)
        AudioHardwareDestroyProcessTap(session.tapID)
    }
}

/// The gain/mute/EQ state an IOProc reads. Updated from the main thread by
/// the engine; the audio thread reads plain value properties per cycle.
final class MixerBox {
    var gain: Float
    var muted: Bool
    var magicBoost: Bool
    let eq: EQBox
    /// Preallocated EQ scratch — the audio thread must not allocate.
    var scratch = [Float](repeating: 0, count: 8192)
    init(gain: Float, muted: Bool, magicBoost: Bool = false, eq: AudioEQ = AudioEQ()) {
        self.gain = gain; self.muted = muted; self.magicBoost = magicBoost; self.eq = EQBox(eq)
    }
}

/// Realtime-safe mixing: scale tapped input into the output, no allocation.
nonisolated enum Mixer {
    static func clamp(_ gain: Float) -> Float { min(max(gain, 0), 2) }

    static func mix(input: UnsafePointer<AudioBufferList>,
                    output: UnsafeMutablePointer<AudioBufferList>,
                    box: MixerBox) {
        let gain = box.muted ? Float(0) : box.gain
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard inputList.count > 0, outputList.count > 0 else { return }

        let useMagicBoost = box.magicBoost

        if inputList.count == outputList.count {
            for (index, outBuffer) in outputList.enumerated() {
                guard let inPtr = inputList[index].mData?.assumingMemoryBound(to: Float32.self),
                      let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
                    if let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float32.self) {
                        let total = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size
                        for f in 0..<total { outPtr[f] = 0 }
                    }
                    continue
                }
                let inSamples = Int(inputList[index].mDataByteSize) / MemoryLayout<Float32>.size
                let outSamples = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size
                let frames = min(inSamples, outSamples)
                for f in 0..<frames {
                    var s = inPtr[f] * gain
                    if useMagicBoost {
                        s = s > 0 ? (s / (1.0 + s * 0.4)) * 1.3 : (s / (1.0 - s * 0.4)) * 1.3
                    }
                    outPtr[f] = s
                }
                if outSamples > frames {
                    for f in frames..<outSamples { outPtr[f] = 0 }
                }
                if box.eq.current.isEnabled {
                    box.scratch.withUnsafeMutableBufferPointer { scratch in
                        guard let base = scratch.baseAddress, scratch.count >= frames else { return }
                        box.eq.current.process(into: outPtr, input: outPtr, frames: frames, scratch: base)
                    }
                }
            }
        } else if inputList.count == 1 && outputList.count >= 2 {
            // Stereo interleaved input to non-interleaved stereo output
            guard let inPtr = inputList[0].mData?.assumingMemoryBound(to: Float32.self),
                  let out0 = outputList[0].mData?.assumingMemoryBound(to: Float32.self),
                  let out1 = outputList[1].mData?.assumingMemoryBound(to: Float32.self) else { return }
            let inFrames = (Int(inputList[0].mDataByteSize) / MemoryLayout<Float32>.size) / 2
            let out0Frames = Int(outputList[0].mDataByteSize) / MemoryLayout<Float32>.size
            let out1Frames = Int(outputList[1].mDataByteSize) / MemoryLayout<Float32>.size
            let frames = min(inFrames, min(out0Frames, out1Frames))
            for f in 0..<frames {
                var s0 = inPtr[f * 2] * gain
                var s1 = inPtr[f * 2 + 1] * gain
                if useMagicBoost {
                    s0 = s0 > 0 ? (s0 / (1.0 + s0 * 0.4)) * 1.3 : (s0 / (1.0 - s0 * 0.4)) * 1.3
                    s1 = s1 > 0 ? (s1 / (1.0 + s1 * 0.4)) * 1.3 : (s1 / (1.0 - s1 * 0.4)) * 1.3
                }
                out0[f] = s0
                out1[f] = s1
            }
            if out0Frames > frames { for f in frames..<out0Frames { out0[f] = 0 } }
            if out1Frames > frames { for f in frames..<out1Frames { out1[f] = 0 } }
        } else if inputList.count >= 2 && outputList.count == 1 {
            // Non-interleaved stereo input to interleaved stereo output
            guard let in0 = inputList[0].mData?.assumingMemoryBound(to: Float32.self),
                  let in1 = inputList[1].mData?.assumingMemoryBound(to: Float32.self),
                  let outPtr = outputList[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
            let inFrames = min(Int(inputList[0].mDataByteSize), Int(inputList[1].mDataByteSize)) / MemoryLayout<Float32>.size
            let outFrames = (Int(outputList[0].mDataByteSize) / MemoryLayout<Float32>.size) / 2
            let frames = min(inFrames, outFrames)
            for f in 0..<frames {
                var s0 = in0[f] * gain
                var s1 = in1[f] * gain
                if useMagicBoost {
                    s0 = s0 > 0 ? (s0 / (1.0 + s0 * 0.4)) * 1.3 : (s0 / (1.0 - s0 * 0.4)) * 1.3
                    s1 = s1 > 0 ? (s1 / (1.0 + s1 * 0.4)) * 1.3 : (s1 / (1.0 - s1 * 0.4)) * 1.3
                }
                outPtr[f * 2] = s0
                outPtr[f * 2 + 1] = s1
            }
            let totalOut = outFrames * 2
            if totalOut > frames * 2 {
                for f in (frames * 2)..<totalOut { outPtr[f] = 0 }
            }
        }
    }
}
