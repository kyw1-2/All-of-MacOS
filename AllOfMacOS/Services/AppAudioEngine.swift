import AppKit
import CoreAudio
import AudioToolbox

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
                    guard let pid = Self.property(object, selector: kAudioProcessPropertyPID, as: pid_t.self), pid > 0,
                          Self.property(object, selector: kAudioProcessPropertyIsRunning, as: UInt32.self) == 1 else { continue }
                    let app = NSRunningApplication(processIdentifier: pid)
                    let bundleID = app?.bundleIdentifier ?? "pid-\(pid)"
                    seenPIDs.insert(pid)
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
    }

    func setMagicBoost(_ enabled: Bool, bundleID: String) {
        UserDefaults.standard.set(enabled, forKey: "AOMAudioMagicBoost_\(bundleID)")
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

    // MARK: - Gain / mute / lifecycle

    /// Starts (or retunes) the tap session for a pid. Returns false when the
    /// OS gates us out (denied capture) — pre-14.2 callers never get here.
    func setGain(_ gain: Float, muted: Bool = false, pid: pid_t) -> Bool {
        let clamped = Mixer.clamp(gain)
        if var session = sessions[pid] {
            session.box.takeUnretainedValue().gain = clamped
            session.box.takeUnretainedValue().muted = muted
            session.gain = clamped
            session.muted = muted
            sessions[pid] = session
            persistGain(clamped, pid: pid)
            return true
        }
        guard let session = createSession(pid: pid, gain: clamped, muted: muted) else {
            authorizationDenied = true
            return false
        }
        sessions[pid] = session
        persistGain(clamped, pid: pid)
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

    private func persistGain(_ gain: Float, pid: pid_t) {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            UserDefaults.standard.set(Double(gain), forKey: "AOMAudioGain_\(bundleID)")
        }
    }

    static func storedGain(bundleID: String) -> Float {
        Float(UserDefaults.standard.object(forKey: "AOMAudioGain_\(bundleID)") as? Double ?? 1)
    }

    // MARK: - Core Audio plumbing

    private func createSession(pid: pid_t, gain: Float, muted: Bool) -> Session? {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        // 1. The process tap; `.whenRunning` silences the app's own output
        //    while the tap runs, so the mixed render is the only audible path.
        // The Swift-refined API: plain init + [AudioObjectID] processes.
        let description = CATapDescription()
        description.processes = [AudioObjectID(pid)]
        description.isMono = true
        // .mutedWhenTapped silences the app's own hardware output exactly
        // while another client reads the tap — our mixer is that client.
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }

        // 2. The tap's UID, then a private aggregate device wrapping it.
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uidSize: UInt32 = 0
        var tapUID: CFString?
        guard AudioObjectGetPropertyDataSize(tapID, &uidAddress, 0, nil, &uidSize) == noErr, uidSize > 0,
              AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, &tapUID) == noErr,
              let tapUIDString = tapUID as String?, !tapUIDString.isEmpty else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AOM App Audio \(pid)",
            kAudioAggregateDeviceUIDKey: "com.kyw.allofmacos.tap.\(pid)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: tapUIDString,
                kAudioSubDeviceDriftCompensationKey: 1
            ]],
            kAudioAggregateDeviceMainSubDeviceKey: tapUIDString
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID) == noErr,
              aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // 3. The IOProc: pull tapped audio from input scope, apply gain, write
        //    to output scope. Runs on the realtime thread — no allocation.
        let box = Unmanaged.passRetained(MixerBox(gain: gain, muted: muted))
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
    let eq: EQBox
    /// Preallocated EQ scratch — the audio thread must not allocate.
    var scratch = [Float](repeating: 0, count: 8192)
    init(gain: Float, muted: Bool, eq: AudioEQ = AudioEQ()) {
        self.gain = gain; self.muted = muted; self.eq = EQBox(eq)
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
        for (index, outBuffer) in outputList.enumerated() {
            guard index < inputList.count,
                  let inputPtr = inputList[index].mData?.assumingMemoryBound(to: Float32.self),
                  let outputPtr = outBuffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let frames = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size
            // Realtime path: gain in place, then the EQ's zero-allocation
            // variant through the box's scratch buffer.
            for frame in 0..<frames { outputPtr[frame] = inputPtr[frame] * gain }
            if box.eq.current.isEnabled {
                box.scratch.withUnsafeMutableBufferPointer { scratch in
                    guard let base = scratch.baseAddress, scratch.count >= frames else { return }
                    box.eq.current.process(into: outputPtr, input: outputPtr, frames: frames, scratch: base)
                }
            }
        }
    }
}
