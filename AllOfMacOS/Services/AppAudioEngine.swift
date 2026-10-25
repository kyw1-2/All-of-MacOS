import AppKit
import CoreAudio
import AudioToolbox
import Darwin

/// SoundSource-lite per-app audio control on macOS 14.2+ Core Audio Process
/// Taps. For each app the user adjusts: a process tap is created with
/// `.mutedWhenTapped` mute behavior (the app's own output is silenced while the
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
    var error: String? = nil
    var peakLevel: Float = 0
    var id: Int32 { pid }

    static func == (lhs: AppAudioState, rhs: AppAudioState) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.name == rhs.name &&
        lhs.bundleID == rhs.bundleID &&
        lhs.gain == rhs.gain &&
        lhs.muted == rhs.muted &&
        lhs.tapped == rhs.tapped &&
        lhs.outputDeviceUID == rhs.outputDeviceUID &&
        lhs.magicBoost == rhs.magicBoost && lhs.error == rhs.error && lhs.peakLevel == rhs.peakLevel
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
        var processIDs: [AudioObjectID] = []
        var outputUID = ""
        var sampleRate: Double = 48000
        init(pid: pid_t, bundleID: String, tapID: AudioObjectID, aggregateID: AudioObjectID,
             procID: AudioDeviceIOProcID?, box: Unmanaged<MixerBox>, gain: Float, muted: Bool) {
            self.pid = pid; self.bundleID = bundleID; self.tapID = tapID
            self.aggregateID = aggregateID; self.procID = procID; self.box = box
            self.gain = gain; self.muted = muted
        }
    }

    private var sessions: [pid_t: Session] = [:]

    var isSupported: Bool { true } // the type itself is 14.2-gated

    private var timer: Timer?
    private var syncing = false
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var errors: [pid_t: String] = [:]
    private var retryAfter: [pid_t: TimeInterval] = [:]
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {
        // Process objects can exist before playback starts; the process-list
        // notification alone does not tell us when those streams become usable.
        for selector in [kAudioHardwarePropertyProcessObjectList,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioOutputService.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.syncActiveProcesses()
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, block) == noErr {
                listeners.append((address, block))
            }
        }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.syncActiveProcesses() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func syncActiveProcesses() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        updatePlaybackListeners()
        let apps = runningAudioApps()
        let livePIDs = Set(apps.map(\.pid))
        for pid in Array(sessions.keys) where !livePIDs.contains(pid) { stop(pid: pid) }
        errors = errors.filter { livePIDs.contains($0.key) }
        retryAfter = retryAfter.filter { livePIDs.contains($0.key) }
        for app in apps where app.pid > 0 && app.pid != ProcessInfo.processInfo.processIdentifier {
            guard needsProcessing(app.bundleID) else {
                stop(pid: app.pid); errors.removeValue(forKey: app.pid); continue
            }
            let processIDs = Self.processObjectIDs(for: app.pid).sorted()
            let playing = processIDs.contains { Self.property($0, selector: kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1 }
            guard playing else { stop(pid: app.pid); continue }
            if let session = sessions[app.pid],
               session.bundleID != app.bundleID || session.processIDs != processIDs ||
               session.outputUID != Self.targetOutputUID(for: app.bundleID) ||
               session.sampleRate != Self.outputSampleRate(uid: session.outputUID) {
                stop(pid: app.pid)
            }
            if let session = sessions[app.pid] {
                session.box.takeUnretainedValue().deviceGain = AudioOutputService.softwareGain(uid: session.outputUID)
            }
            guard sessions[app.pid] == nil, !processIDs.isEmpty,
                  ProcessInfo.processInfo.systemUptime >= (retryAfter[app.pid] ?? 0) else { continue }
            _ = attach(pid: app.pid, gain: Self.storedGain(bundleID: app.bundleID), muted: app.muted)
        }
        NotificationCenter.default.post(name: NSNotification.Name("AOMAudioAppsChanged"), object: nil)
    }

    private func updatePlaybackListeners() {
        var listAddress = AudioOutputService.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr else { return }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !objects.isEmpty {
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects) == noErr else { return }
        }
        let live = Set(objects)
        var playingAddress = AudioOutputService.address(kAudioProcessPropertyIsRunningOutput)
        for id in Array(processListeners.keys) where !live.contains(id) {
            if let block = processListeners.removeValue(forKey: id) {
                AudioObjectRemovePropertyListenerBlock(id, &playingAddress, DispatchQueue.main, block)
            }
        }
        for id in live where processListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.syncActiveProcesses() }
            if AudioObjectAddPropertyListenerBlock(id, &playingAddress, DispatchQueue.main, block) == noErr {
                processListeners[id] = block
            }
        }
    }

    func level(pid: pid_t) -> Float { sessions[pid]?.box.takeUnretainedValue().peakLevel ?? 0 }

    private func needsProcessing(_ bundleID: String) -> Bool {
        let d = UserDefaults.standard
        return Self.storedGain(bundleID: bundleID) != 1 || d.bool(forKey: "AOMAudioMute_\(bundleID)") ||
            d.string(forKey: "AOMAudioRoute_\(bundleID)") != nil ||
            d.bool(forKey: "AOMAudioMagicBoost_\(bundleID)") ||
            Self.appEQ(bundleID: bundleID).isEnabled || Self.masterEQ().isEnabled ||
            Self.targetOutputUID(for: bundleID).map { AudioOutputService.softwareGain(uid: $0) != 1 } == true
    }

    private func attach(pid: pid_t, gain: Float, muted: Bool) -> Bool {
        errors.removeValue(forKey: pid)
        guard let session = createSession(pid: pid, gain: gain, muted: muted) else {
            if errors[pid] == nil { errors[pid] = "Audio processing could not start. Check Screen & System Audio Recording permission." }
            retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 5
            return false
        }
        sessions[pid] = session
        retryAfter.removeValue(forKey: pid)
        return true
    }

    static func appEQ(bundleID: String, sampleRate: Double = 48000) -> AudioEQ {
        let d = UserDefaults.standard
        let gains = d.bool(forKey: "AOMAudioAppEQEnabled_\(bundleID)")
            ? (d.array(forKey: "AOMAudioAppEQGains_\(bundleID)") as? [Double] ?? []).map(Float.init)
            : AudioEQ.presetFlat
        return AudioEQ(gains: gains, sampleRate: sampleRate)
    }

    static func masterEQ(sampleRate: Double = 48000) -> AudioEQ {
        let d = UserDefaults.standard
        guard d.bool(forKey: "AOMAudioEQEnabled") else { return AudioEQ(sampleRate: sampleRate) }
        let preset = d.string(forKey: "AOMAudioEQPreset") ?? "Flat"
        let gains = AudioEQ.presets[preset] ?? (d.array(forKey: "AOMAudioEQGains") as? [Double] ?? []).map(Float.init)
        return AudioEQ(gains: gains, sampleRate: sampleRate)
    }

    func updateEffects() {
        for session in sessions.values {
            session.box.takeUnretainedValue().setEffects(
                app: Self.appEQ(bundleID: session.bundleID, sampleRate: session.sampleRate),
                master: Self.masterEQ(sampleRate: session.sampleRate))
        }
        syncActiveProcesses()
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

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsiblePID? = {
        // Optional system SPI. Its absence falls back to ancestry and bundle
        // identity; never guess that every WebKit helper belongs to Safari.
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    private static func mainApp(for pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app
        }
        if let responsible = responsiblePID?(pid), responsible > 1, responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
            return app
        }
        var current = pid
        for _ in 0..<12 {
            guard let ppid = parentPID(of: current), ppid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: ppid), app.activationPolicy == .regular {
                return app
            }
            current = ppid
        }
        return nil
    }

    private static func owner(of object: AudioObjectID, pid: pid_t) -> NSRunningApplication? {
        if let app = mainApp(for: pid) { return app }
        let bundleID = AudioOutputService.string(object, kAudioProcessPropertyBundleID)
        let processURL = NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL.path
        let matches = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !id.isEmpty else { return false }
            if bundleID == id || bundleID.hasPrefix(id + ".") { return true }
            if let path = app.bundleURL?.standardizedFileURL.path, let processURL {
                return processURL.hasPrefix(path + "/")
            }
            return false
        }
        return matches.count == 1 ? matches[0] : nil
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
            } else if let main = owner(of: obj, pid: p), main.processIdentifier == targetPID {
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

                    let app = Self.owner(of: object, pid: rawPid) ?? NSRunningApplication(processIdentifier: rawPid)
                    let pid = app?.processIdentifier ?? rawPid
                    guard pid != ProcessInfo.processInfo.processIdentifier, !seenPIDs.contains(pid) else { continue }
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
                        magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)"),
                        error: errors[pid], peakLevel: level(pid: pid)
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
            guard pid != ProcessInfo.processInfo.processIdentifier, !seenPIDs.contains(pid) else { continue }
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
                magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)"),
                        error: errors[pid], peakLevel: level(pid: pid)
            ))
        }

        // Manually added apps remain configurable while closed.
        for (index, bundleID) in customApps.sorted().enumerated() where !results.contains(where: { $0.bundleID == bundleID }) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? url?.deletingPathExtension().lastPathComponent ?? bundleID
            results.append(AppState(pid: -pid_t(index + 1), name: name, bundleID: bundleID,
                                    icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                                    gain: Self.storedGain(bundleID: bundleID),
                                    muted: UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)"), tapped: false,
                                    outputDeviceUID: UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"),
                                    magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")))
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
        for app in runningAudioApps() where app.bundleID == bundleID && app.pid > 0 {
            stop(pid: app.pid)
            retryAfter.removeValue(forKey: app.pid)
        }
        syncActiveProcesses()
    }

    func setMagicBoost(_ enabled: Bool, bundleID: String) {
        UserDefaults.standard.set(enabled, forKey: "AOMAudioMagicBoost_\(bundleID)")
        for session in sessions.values where session.bundleID == bundleID {
            session.box.takeUnretainedValue().magicBoost = enabled
        }
        syncActiveProcesses()
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

        let uid = AudioOutputService.string(defOutID, kAudioDevicePropertyDeviceUID)
        return uid.isEmpty ? nil : uid
    }

    static func targetOutputUID(for bundleID: String) -> String? {
        if let stored = UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"),
           AudioOutputService.devices().contains(where: { $0.uid == stored }) { return stored }
        // Keep the preference so reconnecting headphones restores the route.
        return defaultOutputDeviceUID()
    }

    private static func outputSampleRate(uid: String) -> Double {
        guard let device = AudioOutputService.devices().first(where: { $0.uid == uid }),
              let rate = property(device.id, selector: kAudioDevicePropertyNominalSampleRate, as: Double.self),
              rate.isFinite, rate > 0 else { return 48000 }
        return rate
    }

    private static func outputChannels(aggregateID: AudioObjectID, uid: String) -> (Int, Int)? {
        var address = AudioOutputService.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &streams) == noErr else { return nil }
        var channels = 0
        for stream in streams {
            guard let format = property(stream, selector: kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return nil }
            channels += Int(format.mChannelsPerFrame)
        }
        guard channels > 0 else { return nil }
        var stereo: [UInt32] = [1, UInt32(min(2, channels))]
        if let device = AudioOutputService.devices().first(where: { $0.uid == uid }) {
            var property = AudioOutputService.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput)
            var bytes = UInt32(2 * MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device.id, &property, 0, nil, &bytes, &stereo)
        }
        guard stereo.allSatisfy({ $0 > 0 && Int($0) <= channels }) else { return (0, min(1, channels - 1)) }
        return (Int(stereo[0]) - 1, Int(stereo[1]) - 1)
    }

    // MARK: - Gain / mute / lifecycle

    /// Starts (or retunes) the tap session for a pid.
    func setGain(_ gain: Float, muted: Bool = false, pid: pid_t) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return false }
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
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        // A silent app can have its settings queued. A real Core Audio error
        // must remain visible instead of falsely reporting an active tap.
        guard Self.processObjectIDs(for: pid).contains(where: {
            Self.property($0, selector: kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1
        }) else {
            errors.removeValue(forKey: pid)
            return true
        }
        return attach(pid: pid, gain: clamped, muted: muted)
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
        Mixer.clamp(Float(UserDefaults.standard.object(forKey: "AOMAudioGain_\(bundleID)") as? Double ?? 1))
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
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            errors[pid] = "Cannot capture this app’s audio (\(tapStatus)). Check Screen & System Audio Recording permission."
            return nil
        }

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
            kAudioAggregateDeviceTapAutoStartKey as String: false,
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

        // The aggregate also contains the output hardware's input streams.
        // Read only the appended tap buffers, never a microphone input.
        guard let format = Self.property(tapID, selector: kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            errors[pid] = "This audio stream format cannot be processed."
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let sampleRate = Self.outputSampleRate(uid: outUID)
        var rate = sampleRate
        var rateAddress = AudioOutputService.address(kAudioDevicePropertyNominalSampleRate)
        _ = AudioObjectSetPropertyData(aggregateID, &rateAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
        let tapBuffers = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1
        var configAddress = AudioOutputService.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var configSize: UInt32 = 0
        var inputOffset: Int?
        if AudioObjectGetPropertyDataSize(aggregateID, &configAddress, 0, nil, &configSize) == noErr,
           configSize >= MemoryLayout<AudioBufferList>.size {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            if AudioObjectGetPropertyData(aggregateID, &configAddress, 0, nil, &configSize, storage) == noErr {
                let count = Int(storage.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
                if count >= tapBuffers { inputOffset = count - tapBuffers }
            }
        }
        guard let inputOffset, let outputChannels = Self.outputChannels(aggregateID: aggregateID, uid: outUID) else {
            errors[pid] = "The device did not expose a supported app audio input/output format."
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let magicBoost = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
        let mixer = MixerBox(gain: gain, muted: muted, magicBoost: magicBoost,
                             eq: Self.appEQ(bundleID: bundleID, sampleRate: sampleRate))
        mixer.setEffects(app: Self.appEQ(bundleID: bundleID, sampleRate: sampleRate), master: Self.masterEQ(sampleRate: sampleRate))
        mixer.inputBufferOffset = inputOffset
        mixer.leftOutputChannel = outputChannels.0
        mixer.rightOutputChannel = outputChannels.1
        mixer.deviceGain = AudioOutputService.softwareGain(uid: outUID)
        let box = Unmanaged.passRetained(mixer)
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Mixer.mix(input: input, output: output, box: box.takeUnretainedValue())
        }
        guard status == noErr, let procID else {
            errors[pid] = "Cannot start audio processing (\(status)). Check Screen & System Audio Recording permission."
            box.release()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            errors[pid] = "Audio output could not start (\(startStatus))."
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            box.release()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let session = Session(pid: pid, bundleID: bundleID, tapID: tapID, aggregateID: aggregateID,
                              procID: procID, box: box, gain: gain, muted: muted)
        session.processIDs = processObjIDs.sorted()
        session.outputUID = outUID
        session.sampleRate = sampleRate
        return session
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

/// Control writes are short and synchronized. The audio callback never waits
/// for the UI; it retains the previous render configuration on contention.
final class MixerBox {
    private let lock = NSLock()
    private var desiredGain: Float
    private var desiredMuted: Bool
    private var desiredBoost: Bool
    private var desiredDeviceGain: Float = 1
    private var peak: Float = 0
    var peakLevel: Float {
        lock.lock(); defer { lock.unlock() }; return peak
    }
    fileprivate func publishPeak(_ value: Float) {
        guard lock.try() else { return }
        peak = value
        lock.unlock()
    }
    private var desiredAppEQ: AudioEQProcessor
    private var desiredMasterEQ: AudioEQProcessor
    fileprivate var renderGain: Float
    fileprivate var renderMuted: Bool
    fileprivate var renderBoost: Bool
    fileprivate var renderDeviceGain: Float = 1
    fileprivate var appEQ: AudioEQProcessor
    fileprivate var masterEQ: AudioEQProcessor
    var inputBufferOffset = 0 // immutable once the IOProc starts
    var leftOutputChannel = 0
    var rightOutputChannel = 1

    var deviceGain: Float {
        get { lock.lock(); defer { lock.unlock() }; return desiredDeviceGain }
        set { lock.lock(); desiredDeviceGain = newValue; lock.unlock() }
    }
    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return desiredGain }
        set { lock.lock(); desiredGain = Mixer.clamp(newValue); lock.unlock() }
    }
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return desiredMuted }
        set { lock.lock(); desiredMuted = newValue; lock.unlock() }
    }
    var magicBoost: Bool {
        get { lock.lock(); defer { lock.unlock() }; return desiredBoost }
        set { lock.lock(); desiredBoost = newValue; lock.unlock() }
    }
    init(gain: Float, muted: Bool, magicBoost: Bool = false, eq: AudioEQ = AudioEQ()) {
        desiredGain = Mixer.clamp(gain); renderGain = Mixer.clamp(gain)
        desiredMuted = muted; renderMuted = muted
        desiredBoost = magicBoost; renderBoost = magicBoost
        let app = AudioEQProcessor(eq), master = AudioEQProcessor(AudioEQ(sampleRate: eq.sampleRate))
        desiredAppEQ = app; appEQ = app
        desiredMasterEQ = master; masterEQ = master
    }
    func setEffects(app: AudioEQ, master: AudioEQ) {
        lock.lock(); defer { lock.unlock() }
        if desiredAppEQ.eq != app { desiredAppEQ = AudioEQProcessor(app) }
        if desiredMasterEQ.eq != master { desiredMasterEQ = AudioEQProcessor(master) }
    }
    fileprivate func beginRender() {
        guard lock.try() else { return }
        renderGain = desiredGain; renderMuted = desiredMuted; renderBoost = desiredBoost
        renderDeviceGain = desiredDeviceGain
        appEQ = desiredAppEQ; masterEQ = desiredMasterEQ
        lock.unlock()
    }
}

/// Routes by channel count, not buffer count: mono, interleaved stereo and
/// planar stereo all share the same gain/mute/EQ path. Extra outputs are silent.
nonisolated enum Mixer {
    static func clamp(_ gain: Float) -> Float { gain.isFinite ? min(max(gain, 0), 2) : 1 }

    static func mix(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, box: MixerBox) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var peak: Float = 0
        defer { box.publishPeak(peak) }
        guard box.inputBufferOffset < inputs.count else { return }
        box.beginRender()
        guard !box.renderMuted else { return }
        let first = inputs[box.inputBufferOffset]
        let planar = first.mNumberChannels == 1 && inputs.count > box.inputBufferOffset + 1
        let channels = planar ? 2 : Int(first.mNumberChannels)
        guard channels > 0, let left = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let second = planar ? inputs[box.inputBufferOffset + 1] : first
        let right = planar ? second.mData?.assumingMemoryBound(to: Float.self) : left
        var frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        if planar { frames = min(frames, Int(second.mDataByteSize) / MemoryLayout<Float>.size) }
        let outputChannels = outputs.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard outputChannels > 0 else { return }
        for frame in 0..<frames {
            var l = left[planar ? frame : frame * channels]
            var r = planar ? (right?[frame] ?? 0) : left[frame * channels + min(1, channels - 1)]
            l = box.masterEQ.process(box.appEQ.process(l, channel: 0), channel: 0)
            r = box.masterEQ.process(box.appEQ.process(r, channel: 1), channel: 1)
            if box.renderBoost {
                l = tanh(l * 1.8)
                r = tanh(r * 1.8)
            }
            l *= box.renderGain * box.renderDeviceGain; r *= box.renderGain * box.renderDeviceGain
            // A bounded output prevents overdrive/EQ from wrapping or emitting NaNs.
            l = l.isFinite ? max(-1, min(1, l)) : 0
            r = r.isFinite ? max(-1, min(1, r)) : 0
            peak = max(peak, max(abs(l), abs(r)))
            var channel = 0
            for buffer in outputs {
                let count = Int(buffer.mNumberChannels)
                if count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                   frame < Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count) {
                    for offset in 0..<count {
                        let index = channel + offset
                        data[frame * count + offset] = outputChannels == 1 ? (l + r) * 0.5 : (index == box.leftOutputChannel ? l : (index == box.rightOutputChannel ? r : 0))
                    }
                }
                channel += count
            }
        }
    }
}
