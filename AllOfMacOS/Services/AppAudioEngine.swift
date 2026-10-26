import AppKit
import Accelerate
import CoreAudio
import AudioToolbox
import AVFoundation
import Darwin

/// Per-app control through public Core Audio process taps. Capture lifetime is
/// independent of playback activity; output is mixed by a stable device graph.
/// This is an AOM implementation, not Rogue Amoeba's proprietary ARK backend.
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
    var processingStatus: String = "Ready"
    var id: Int32 { pid }

    static func == (lhs: AppAudioState, rhs: AppAudioState) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.name == rhs.name &&
        lhs.bundleID == rhs.bundleID &&
        lhs.gain == rhs.gain &&
        lhs.muted == rhs.muted &&
        lhs.tapped == rhs.tapped &&
        lhs.outputDeviceUID == rhs.outputDeviceUID &&
        lhs.magicBoost == rhs.magicBoost && lhs.error == rhs.error && lhs.peakLevel == rhs.peakLevel && lhs.processingStatus == rhs.processingStatus
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
        var tapDescription: CATapDescription?
        var outputUID = ""
        var sampleRate: Double = 48000
        var outputSampleRate: Double = 48000
        var sourceToken: SharedOutputRenderer.SourceToken?
        var transport: AppAudioTransport?
        let createdAt = ProcessInfo.processInfo.systemUptime
        var watchdog = AudioActivityWatchdog()

        init(pid: pid_t, bundleID: String, tapID: AudioObjectID, aggregateID: AudioObjectID,
             procID: AudioDeviceIOProcID?, box: Unmanaged<MixerBox>, gain: Float, muted: Bool) {
            self.pid = pid; self.bundleID = bundleID; self.tapID = tapID
            self.aggregateID = aggregateID; self.procID = procID; self.box = box
            self.gain = gain; self.muted = muted
        }
    }

    private var sessions: [pid_t: Session] = [:]

    var isSupported: Bool { true } // the type itself is 14.2-gated

    /// Master toggle for App Audio Engine. When disabled, all process taps and
    /// aggregate devices are destroyed, and no background audio capture will run.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "AOMSoundEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "AOMSoundEnabled")
            UserDefaults.standard.set(newValue, forKey: "AOMAudioEngineEnabled")
            if !newValue {
                stopAll()
            } else {
                scheduleSync()
            }
            NotificationCenter.default.post(name: NSNotification.Name("AOMAudioAppsChanged"), object: nil)
        }
    }

    static var airPlayProcessingEnabled: Bool {
        UserDefaults.standard.object(forKey: "AOMAudioAirPlayProcessingEnabled") as? Bool ?? true
    }

    func setAirPlayProcessingEnabled(_ enabled: Bool) {
        guard enabled != Self.airPlayProcessingEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: "AOMAudioAirPlayProcessingEnabled")
        stopAll()
        errors.removeAll(); retryAfter.removeAll(); failedProcessIDs.removeAll()
        airPlayCaptureFailures.removeAll()
        scheduleSync()
    }

    private(set) var airPlayBypassed = false
    var airPlayProcessingActive: Bool { sessions.values.contains { $0.sourceToken?.isAirPlay == true } }
    var airPlayPreparing: Bool { !pendingAirPlayPIDs.isEmpty }
    private var pendingAirPlayPIDs = Set<pid_t>()
    // A capture failure on a live remote sender must not retry merely because
    // creating / destroying the failed tap changed CoreAudio's process list.
    private var airPlayCaptureFailures: [String: String] = [:]
    private var bypassedPIDs = Set<pid_t>()
    private var appIdentitySnapshot: [AppState] = []
    private var appIdentitySnapshotAt: TimeInterval = -.infinity
    private var timer: Timer?
    private var lastSyncAt: TimeInterval = 0
    private var syncing = false
    private var syncScheduled = false
    private var failedProcessIDs: [pid_t: [AudioObjectID]] = [:]
    private var outputTopology: [String: AudioDeviceID] = [:]
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
                if selector == kAudioHardwarePropertyDevices || selector == kAudioHardwarePropertyDefaultOutputDevice {
                    AudioOutputService.invalidateDeviceCache()
                } else {
                    self?.appIdentitySnapshotAt = -.infinity
                }
                self?.scheduleSync()
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, block) == noErr {
                listeners.append((address, block))
            }
        }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            // While nothing is captured the timer is only a backstop: the CoreAudio
            // process and device listeners already wake us as soon as playback starts.
            // Sweeping the whole process table every second kept an idle MacBook Air
            // at 3-4% CPU, so idle sweeps run one tick in three.
            let now = ProcessInfo.processInfo.systemUptime
            guard !self.sessions.isEmpty || now - self.lastSyncAt >= 3 else { return }
            self.scheduleSync()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func requestSync() { scheduleSync() }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncActiveProcesses()
        }
    }

    /// Identifies routes requiring either native bypass or the dedicated
    /// buffered AirPlay sender. Never route these through AVAudioEngine.
    /// Detect transport type, not a user-facing room name or a device ID.
    static func shouldBypassAirPlayCapture(defaultTransport: UInt32?, routeTransport: UInt32?) -> Bool {
        defaultTransport == kAudioDeviceTransportTypeAirPlay ||
            routeTransport == kAudioDeviceTransportTypeAirPlay
    }

    private static func outputTransport(_ id: AudioDeviceID?) -> UInt32? {
        guard let id, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var property = AudioOutputService.address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: type))
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &type) == noErr ? type : nil
    }

    private static func isNativeAirPlayActive() -> Bool {
        shouldBypassAirPlayCapture(defaultTransport: outputTransport(AudioOutputService.currentDeviceID()),
                                    routeTransport: nil)
    }

    func syncActiveProcesses() {
        guard !syncing else { return }
        syncing = true
        lastSyncAt = ProcessInfo.processInfo.systemUptime
        defer {
            syncing = false
            if UserDefaults.standard.bool(forKey: "AOMAudioDiagnostics") {
                let capture = Dictionary(uniqueKeysWithValues: sessions.values.compactMap { session -> (String, [String: Any])? in
                    guard let transport = session.transport else { return nil }
                    var stats = transport.statistics
                    stats["bundleID"] = session.bundleID
                    stats["airPlay"] = session.sourceToken?.isAirPlay ?? false
                    return (String(session.pid), stats)
                })
                let outputs = MainActor.assumeIsolated { SharedOutputRenderer.shared.airPlayStatistics }
                AudioDiagnostics.write(captures: capture, outputs: outputs)
            }
            NotificationCenter.default.post(name: NSNotification.Name("AOMAudioAppsChanged"), object: nil)
        }
        airPlayBypassed = Self.isNativeAirPlayActive() && !Self.airPlayProcessingEnabled
        pendingAirPlayPIDs.removeAll(keepingCapacity: true)
        bypassedPIDs.removeAll(keepingCapacity: true)
        guard isEnabled else {
            if !sessions.isEmpty { stopAll() }
            return
        }
        // Native mode releases taps without changing the selected HomePod.
        // Processing mode uses a separate sender, never an AVAudioEngine graph.
        if airPlayBypassed {
            let hadSessions = !sessions.isEmpty ||
                MainActor.assumeIsolated { !SharedOutputRenderer.shared.activeDeviceUIDs.isEmpty }
            if hadSessions {
                stopAll()
            }
            return
        }
        updatePlaybackListeners()
        let apps = runningAudioApps()
        // Nothing playing and nothing captured: enumerating devices and rebinding
        // renderers for an empty session list is pure overhead.
        if apps.isEmpty && sessions.isEmpty { return }
        let devices = AudioOutputService.devices()
        defer {
            let requested = Set(apps.compactMap { Self.targetOutputUID(for: $0.bundleID) })
            MainActor.assumeIsolated { SharedOutputRenderer.shared.releaseUnusedAirPlayOutputs(keeping: requested) }
        }
        let topology = Dictionary(devices.map { ($0.uid, $0.id) }, uniquingKeysWith: { first, _ in first })
        if topology != outputTopology {
            outputTopology = topology
            retryAfter.removeAll()
            failedProcessIDs.removeAll()
            airPlayCaptureFailures.removeAll()
        }
        MainActor.assumeIsolated {
            let renderer = SharedOutputRenderer.shared
            renderer.rebindIfNeeded(devices: devices)
        }
        // A stopped remote receiver cannot retain muting taps. Check before
        // any transient tap-format / process queries that might return early.
        for session in Array(sessions.values) {
            if let token = session.sourceToken,
               let message = MainActor.assumeIsolated({ SharedOutputRenderer.shared.airPlayFailure(token) }) {
                failAirPlay(session, message: message)
                continue
            }
            if let transport = session.transport {
                // A live sender alone does not prove the tap can capture this
                // app (for example, offloaded playback). Restore direct audio
                // if an actively playing producer has no capture callbacks.
                let playing = session.processIDs.contains {
                    Self.property($0, selector: kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1
                }
                let activity = transport.activity
                if let failure = session.watchdog.failure(playing: playing, capturing: activity.recent,
                    rendering: activity.rendering, now: ProcessInfo.processInfo.systemUptime) {
                    let message = failure == .capture
                        ? "Audio capture stopped receiving app audio. Native playback restored; use Reconnect to retry."
                        : "Audio output stopped consuming app audio. Native playback restored; use Reconnect to retry."
                    if session.sourceToken?.isAirPlay == true { failAirPlay(session, message: message) }
                    else { fail(session, message: message) }
                }
            }
        }
        // Playback/process-object disappearance is not application termination.
        for pid in Array(sessions.keys) {
            if NSRunningApplication(processIdentifier: pid)?.isTerminated != false { stop(pid: pid) }
        }
        let livePIDs = Set(apps.map(\.pid)).union(sessions.keys)
        errors = errors.filter { livePIDs.contains($0.key) }
        retryAfter = retryAfter.filter { livePIDs.contains($0.key) }
        failedProcessIDs = failedProcessIDs.filter { livePIDs.contains($0.key) }
        let objectsByOwner = Self.processObjectsByOwner()
        for app in apps where app.pid > 0 && app.pid != ProcessInfo.processInfo.processIdentifier {
            if let session = sessions[app.pid], session.bundleID != app.bundleID { stop(pid: app.pid) }
            let ids = objectsByOwner[app.pid] ?? []
            if let uid = Self.targetOutputUID(for: app.bundleID),
               let device = devices.first(where: { $0.uid == uid }),
               Self.outputTransport(device.id) == kAudioDeviceTransportTypeAirPlay,
               !Self.airPlayProcessingEnabled {
                bypassedPIDs.insert(app.pid)
                stop(pid: app.pid)
                errors.removeValue(forKey: app.pid)
                continue
            }
            if Self.airPlayProcessingEnabled,
               let uid = Self.targetOutputUID(for: app.bundleID),
               let device = devices.first(where: { $0.uid == uid }),
               Self.outputTransport(device.id) == kAudioDeviceTransportTypeAirPlay,
               sessions[app.pid] != nil || !ids.isEmpty {
                let key = "\(uid)|\(app.bundleID)"
                if let message = airPlayCaptureFailures[key] {
                    errors[app.pid] = message
                    continue
                }
                switch MainActor.assumeIsolated({ SharedOutputRenderer.shared.prepareAirPlay(device: device) }) {
                case .preparing:
                    pendingAirPlayPIDs.insert(app.pid)
                    continue
                case .failed(let message):
                    if let session = sessions[app.pid] { failAirPlay(session, message: message) }
                    errors[app.pid] = message
                    continue
                case .ready:
                    break
                }
            }
            if let failed = failedProcessIDs[app.pid], failed != ids {
                retryAfter.removeValue(forKey: app.pid)
                failedProcessIDs.removeValue(forKey: app.pid)
            }
            if let session = sessions[app.pid] {
                // Unity gain, unmute and bypass are parameter changes, not
                // reasons to destroy the app's current audio device.
                let mixer = session.box.takeUnretainedValue()
                session.gain = Self.storedGain(bundleID: app.bundleID)
                session.muted = UserDefaults.standard.bool(forKey: "AOMAudioMute_\(app.bundleID)")
                mixer.gain = session.gain; mixer.muted = session.muted
                mixer.magicBoost = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(app.bundleID)")
                guard updateProcesses(session, ids: ids) else {
                    continue
                }
                guard let format = Self.property(session.tapID, selector: kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
                      Self.supports(format) else {
                    // Transient format query during stream startup or playback state change.
                    // Never destroy the session tap here — doing so pauses media players.
                    continue
                }
                session.transport?.updateSampleRate(format.mSampleRate)
                session.sampleRate = format.mSampleRate
                guard let uid = Self.targetOutputUID(for: app.bundleID),
                      let device = devices.first(where: { $0.uid == uid }) else {
                    continue
                }
                let ready = session.sourceToken.map { token in
                    MainActor.assumeIsolated { SharedOutputRenderer.shared.isReady(token) }
                } ?? false
                if session.sourceToken == nil || session.outputUID != uid || session.sourceToken?.deviceID != device.id {
                    guard moveOutput(session, device: device) else {
                        errors[app.pid] = "Could not move audio to \(device.name). Previous output retained; use Reconnect to retry."
                        // If the previous object vanished, retaining its mute
                        // would strand the producer in silence.
                        if !ready { fail(session, message: "Audio output disconnected. Native playback restored; use Reconnect to retry.") }
                        continue
                    }
                    errors.removeValue(forKey: app.pid)
                } else if !ready {
                    // Overload or a transient format change can stop the
                    // engine. Restart it in place — the tap, aggregate and
                    // transport survive, so no player sees device loss.
                    if let token = session.sourceToken {
                        let recovered = MainActor.assumeIsolated { SharedOutputRenderer.shared.ensureRunning(token: token) }
                        if !recovered {
                            fail(session, message: "Audio output could not restart. Native playback restored; use Reconnect to retry.")
                            continue
                        }
                    }
                }
                mixer.deviceGain = AudioOutputService.softwareGain(uid: uid)
                continue
            }
            guard needsProcessing(app.bundleID) else {
                errors.removeValue(forKey: app.pid)
                retryAfter.removeValue(forKey: app.pid)
                failedProcessIDs.removeValue(forKey: app.pid)
                continue
            }
            guard ProcessInfo.processInfo.systemUptime >= (retryAfter[app.pid] ?? 0) else { continue }
            // Master effects must not instantiate an aggregate for every
            // non-audio app. Process-list notifications attach new producers.
            guard !ids.isEmpty else { continue }
            if attach(pid: app.pid, gain: Self.storedGain(bundleID: app.bundleID), muted: app.muted) {
                GestureLog.shared.logFromAnyThread("Audio session attached: pid \(app.pid) (\(app.bundleID))", level: .noMatch)
            }
        }
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
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSync() }
            if AudioObjectAddPropertyListenerBlock(id, &playingAddress, DispatchQueue.main, block) == noErr {
                processListeners[id] = block
            }
        }
    }

    func level(pid: pid_t) -> Float { sessions[pid]?.box.takeUnretainedValue().peakLevel ?? 0 }

    func status(pid: pid_t) -> String {
        if !isEnabled { return "Audio processing off — settings saved" }
        if airPlayBypassed || bypassedPIDs.contains(pid) {
            return "AirPlay direct — volume, EQ and boost saved for local output"
        }
        if pendingAirPlayPIDs.contains(pid) { return "Preparing HomePod output — current playback continues" }
        if let error = errors[pid] { return error }
        guard let session = sessions[pid], let transport = session.transport else {
            if pid <= 0 { return "App closed — settings saved" }
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            return needsProcessing(bundleID) ? "Waiting for app audio" : "Native playback — no effects applied"
        }
        let activity = transport.activity
        if activity.captured == 0 || !activity.recent {
            return "Ready — waiting for app playback"
        }
        if !activity.rendering { return "Waiting for output device…" }
        if session.sourceToken?.isAirPlay == true {
            return session.muted ? "Muted · HomePod" : "Processing locally → HomePod / AirPlay"
        }
        return session.muted ? "Muted" : "Processing audio"
    }

    func retry(pid: pid_t) {
        // A remote sender is shared: recovery must release all its sources
        // before replacing it, rather than recovering only one app.
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let remoteRoute = Self.targetOutputUID(for: bundleID).flatMap { uid in
            AudioOutputService.devices().first(where: { $0.uid == uid })
        }.map { Self.outputTransport($0.id) == kAudioDeviceTransportTypeAirPlay } ?? false
        if sessions[pid]?.sourceToken?.isAirPlay == true || remoteRoute,
           let uid = sessions[pid]?.outputUID ?? Self.targetOutputUID(for: bundleID) {
            retryAirPlay(uid: uid, requestedPID: pid)
            return
        }
        stop(pid: pid)
        errors.removeValue(forKey: pid)
        retryAfter.removeValue(forKey: pid)
        failedProcessIDs.removeValue(forKey: pid)
        syncActiveProcesses()
    }

    private func retryAirPlay(uid: String, requestedPID: pid_t) {
        // Only apps sharing this receiver need their capture restarted.
        // A per-app Reconnect must not tear down unrelated local video players.
        var affected = Set(runningAudioApps().filter {
            Self.targetOutputUID(for: $0.bundleID) == uid
        }.map(\.pid))
        affected.formUnion(sessions.values.filter { $0.outputUID == uid }.map(\.pid))
        affected.insert(requestedPID)
        for pid in affected {
            stop(pid: pid)
            errors.removeValue(forKey: pid)
            retryAfter.removeValue(forKey: pid)
            failedProcessIDs.removeValue(forKey: pid)
        }
        airPlayCaptureFailures = airPlayCaptureFailures.filter { !$0.key.hasPrefix(uid + "|") }
        MainActor.assumeIsolated {
            SharedOutputRenderer.shared.resetAirPlayFailures(uid: uid)
        }
        syncActiveProcesses()
    }

    func retryAll() {
        // Explicit user recovery, performed in one reconciliation pass.
        for pid in Array(sessions.keys) { stop(pid: pid) }
        errors.removeAll(); retryAfter.removeAll(); failedProcessIDs.removeAll()
        airPlayCaptureFailures.removeAll()
        MainActor.assumeIsolated {
            SharedOutputRenderer.shared.resetAirPlayFailures()
            SharedOutputRenderer.shared.rebindIfNeeded(devices: AudioOutputService.devices())
        }
        syncActiveProcesses()
    }

    private func needsProcessing(_ bundleID: String) -> Bool {
        guard isEnabled else { return false }
        if Self.isNativeAirPlayActive() && !Self.airPlayProcessingEnabled { return false }
        if let uid = Self.targetOutputUID(for: bundleID),
           let destination = AudioOutputService.devices().first(where: { $0.uid == uid }),
           Self.outputTransport(destination.id) == kAudioDeviceTransportTypeAirPlay {
            // All apps on this route share the buffered clock, including unity
            // gain apps, so changing an effect never rebuilds the connection.
            return Self.airPlayProcessingEnabled
        }
        let d = UserDefaults.standard
        return Self.storedGain(bundleID: bundleID) != 1 || d.bool(forKey: "AOMAudioMute_\(bundleID)") ||
            d.string(forKey: "AOMAudioRoute_\(bundleID)") != nil ||
            d.bool(forKey: "AOMAudioMagicBoost_\(bundleID)") ||
            d.bool(forKey: "AOMAudioMasterBoostEnabled") ||
            Self.appEQ(bundleID: bundleID).isEnabled || Self.masterEQ().isEnabled ||
            Self.targetOutputUID(for: bundleID).map { AudioOutputService.softwareGain(uid: $0) != 1 } == true
    }

    private func attach(pid: pid_t, gain: Float, muted: Bool) -> Bool {
        guard isEnabled else { return false }
        errors.removeValue(forKey: pid)
        guard let session = createSession(pid: pid, gain: gain, muted: muted) else {
            if errors[pid] == nil { errors[pid] = "Audio processing could not start. Check Screen & System Audio Recording permission." }
            // A permission/format/start failure must not repeatedly create and
            // destroy devices underneath a video player. Retry on explicit
            // request or an actual process/output topology change.
            retryAfter[pid] = .infinity
            failedProcessIDs[pid] = Self.processObjectIDs(for: pid).sorted()
            if Self.airPlayProcessingEnabled, let uid = Self.targetOutputUID(for: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""),
               let device = AudioOutputService.devices().first(where: { $0.uid == uid }),
               Self.outputTransport(device.id) == kAudioDeviceTransportTypeAirPlay {
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                let message = (errors[pid] ?? "AirPlay capture failed.") + " Native playback restored; use Reconnect to retry."
                airPlayCaptureFailures["\(uid)|\(bundleID)"] = message
                errors[pid] = message
            }
            return false
        }
        sessions[pid] = session
        failedProcessIDs.removeValue(forKey: pid)
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
        let masterBoost = UserDefaults.standard.bool(forKey: "AOMAudioMasterBoostEnabled")
            ? min(3, max(1, UserDefaults.standard.object(forKey: "AOMAudioMasterBoostLevel") as? Int ?? 2))
            : 0
        for session in sessions.values {
            let appBoost = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(session.bundleID)")
                ? min(3, max(1, UserDefaults.standard.object(forKey: "AOMAudioBoostLevel_\(session.bundleID)") as? Int ?? 2))
                : 0
            session.box.takeUnretainedValue().setEffects(
                app: Self.appEQ(bundleID: session.bundleID, sampleRate: SharedOutputRenderer.sampleRate),
                master: Self.masterEQ(sampleRate: SharedOutputRenderer.sampleRate),
                appBoost: appBoost, masterBoost: masterBoost)
        }
        scheduleSync()
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

    /// Resolving an owner scans every running app, and the sweep used to do that
    /// once per process object. Short-lived memoisation keeps the answer stable
    /// within a sweep without changing behaviour when an app really does change.
    private nonisolated(unsafe) static var ownerResolutionCache: [pid_t: (app: NSRunningApplication?, at: TimeInterval)] = [:]

    private static func owner(of object: AudioObjectID, pid: pid_t) -> NSRunningApplication? {
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = ownerResolutionCache[pid], now - hit.at < 5 { return hit.app }
        let app = resolveOwner(of: object, pid: pid)
        if ownerResolutionCache.count > 512 { ownerResolutionCache.removeAll(keepingCapacity: true) }
        ownerResolutionCache[pid] = (app, now)
        return app
    }

    private static func resolveOwner(of object: AudioObjectID, pid: pid_t) -> NSRunningApplication? {
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
        processObjectsByOwner()[targetPID] ?? []
    }

    /// One pass over the process-object list with owner resolution memoised.
    /// Callers used to re-read the whole list, and re-scan every running app, once
    /// per pid, which is what made the once-a-second sweep expensive.
    static func processObjectsByOwner() -> [pid_t: [AudioObjectID]] {
        var map: [pid_t: [AudioObjectID]] = [:]
        var ownerCache: [pid_t: pid_t] = [:]
        for obj in processObjectList() {
            guard let rawPID = property(obj, selector: kAudioProcessPropertyPID, as: pid_t.self), rawPID > 0,
                  rawPID != ProcessInfo.processInfo.processIdentifier else { continue }
            let ownerPID: pid_t
            if let cached = ownerCache[rawPID] { ownerPID = cached }
            else {
                let resolved = owner(of: obj, pid: rawPID)?.processIdentifier ?? rawPID
                ownerCache[rawPID] = resolved
                ownerPID = resolved
            }
            map[ownerPID, default: []].append(obj)
        }
        return map.mapValues { $0.sorted() }
    }

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioOutputService.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    // MARK: - Running audio apps (process objects, 14.2+)

    func runningAudioApps() -> [AppState] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - appIdentitySnapshotAt < 3 {
            return currentStates(for: appIdentitySnapshot)
        }
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
                          rawPid != ProcessInfo.processInfo.processIdentifier,
                          Self.property(object, selector: kAudioProcessPropertyIsRunning, as: UInt32.self) == 1 else { continue }

                    let app = Self.owner(of: object, pid: rawPid) ?? NSRunningApplication(processIdentifier: rawPid)
                    guard let app, app.activationPolicy == .regular else { continue }
                    let pid = app.processIdentifier
                    guard pid != ProcessInfo.processInfo.processIdentifier, !seenPIDs.contains(pid) else { continue }
                    seenPIDs.insert(pid)

                    let bundleID = app.bundleIdentifier ?? "pid-\(pid)"
                    results.append(AppState(
                        pid: pid,
                        name: app.localizedName ?? "Process \(pid)",
                        bundleID: bundleID,
                        icon: app.icon,
                        gain: sessions[pid]?.gain ?? Self.storedGain(bundleID: bundleID),
                        muted: sessions[pid]?.muted ?? UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)"),
                        tapped: sessions[pid] != nil,
                        outputDeviceUID: UserDefaults.standard.string(forKey: "AOMAudioRoute_\(bundleID)"),
                        magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)"),
                        error: errors[pid], peakLevel: level(pid: pid), processingStatus: status(pid: pid)
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
                        error: errors[pid], peakLevel: level(pid: pid), processingStatus: status(pid: pid)
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
        appIdentitySnapshot = results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appIdentitySnapshotAt = now
        return currentStates(for: appIdentitySnapshot)
    }

    private func currentStates(for identities: [AppState]) -> [AppState] {
        identities.map { identity in
            var state = identity
            let d = UserDefaults.standard
            state.gain = Self.storedGain(bundleID: state.bundleID)
            state.muted = d.bool(forKey: "AOMAudioMute_\(state.bundleID)")
            state.tapped = sessions[state.pid] != nil
            state.outputDeviceUID = d.string(forKey: "AOMAudioRoute_\(state.bundleID)")
            state.magicBoost = d.bool(forKey: "AOMAudioMagicBoost_\(state.bundleID)")
            state.error = airPlayBypassed || !isEnabled ? nil : errors[state.pid]
            state.processingStatus = status(pid: state.pid)
            // Meters have their own observable model. Do not invalidate an
            // entire application list for a changing sample peak.
            state.peakLevel = 0
            return state
        }
    }

    func addCustomApp(bundleID: String) {
        appIdentitySnapshotAt = -.infinity
        var list = UserDefaults.standard.stringArray(forKey: "AOMAudioUserApps") ?? []
        if !list.contains(bundleID) {
            list.append(bundleID)
            UserDefaults.standard.set(list, forKey: "AOMAudioUserApps")
        }
    }

    func setRoute(uid: String?, bundleID: String) {
        UserDefaults.standard.set(uid, forKey: "AOMAudioRoute_\(bundleID)")
        for app in runningAudioApps() where app.bundleID == bundleID && app.pid > 0 {
            retryAfter.removeValue(forKey: app.pid)
            failedProcessIDs.removeValue(forKey: app.pid)
        }
        syncActiveProcesses()
    }

    func setMagicBoost(_ enabled: Bool, bundleID: String) {
        UserDefaults.standard.set(enabled, forKey: "AOMAudioMagicBoost_\(bundleID)")
        updateEffects()
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
        // Persist quiet-app settings and arm once process objects are available.
        // All attachment policy (including failed-start suppression) lives in sync.
        syncActiveProcesses()
        return errors[pid] == nil
    }

    func stop(pid: pid_t) {
        guard let session = sessions.removeValue(forKey: pid) else { return }
        // Audit checklist 1: make teardown→attach loops visible instead of
        // guessing. Frequent lines here mean the sync loop is still churning.
        GestureLog.shared.logFromAnyThread("Audio session stopped: pid \(pid) (\(session.bundleID))", level: .noMatch)
        Self.destroy(session)
    }

    /// All live sessions (for master-EQ fan-out).
    func sessionsAll() -> [Session] { Array(sessions.values) }

    func stopAll() {
        pendingAirPlayPIDs.removeAll()
        for pid in Array(sessions.keys) { stop(pid: pid) }
        MainActor.assumeIsolated { SharedOutputRenderer.shared.shutdown() }
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

    static func captureDescription(processIDs: [AudioObjectID], bundleID: String) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "AOM App Audio \(bundleID)"
        description.isPrivate = true
        // The session owns the mute for its complete lifetime. Conditional
        // mutedWhenTapped can reopen direct audio during read interruptions;
        // buffered processed audio can still be queued on the remote receiver.
        // Every setup failure destroys this tap; the watchdog releases a failed
        // live session, restoring native playback instead of retaining silence.
        description.muteBehavior = .muted
        if #available(macOS 26.0, *) {
            description.bundleIDs = bundleID.isEmpty ? [] : [bundleID]
            // Rebuild helper membership from verified ownership. Restoring by
            // a shared helper bundle ID (e.g. WebKit.GPU) can capture another
            // app and overlap the same producer across multiple taps.
            description.isProcessRestoreEnabled = false
        }
        return description
    }

    private func createSession(pid: pid_t, gain: Float, muted: Bool) -> Session? {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        // Never mute the original producer before the remote callback clock
        // has been observed. Setup itself is asynchronous and outputs silence.
        guard let uid = Self.targetOutputUID(for: bundleID),
              let destination = AudioOutputService.devices().first(where: { $0.uid == uid }) else { return nil }
        if Self.isNativeAirPlayActive() && !Self.airPlayProcessingEnabled { return nil }
        if Self.outputTransport(destination.id) == kAudioDeviceTransportTypeAirPlay {
            guard Self.airPlayProcessingEnabled,
                  case .ready = MainActor.assumeIsolated({ SharedOutputRenderer.shared.prepareAirPlay(device: destination) }) else { return nil }
        }

        // 1. Resolve all CoreAudio process object IDs for this app (main + audio service helpers)
        let processObjIDs = Self.processObjectIDs(for: pid)
        guard !processObjIDs.isEmpty else { return nil }
        let description = Self.captureDescription(processIDs: processObjIDs, bundleID: bundleID)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            errors[pid] = "Cannot capture this app’s audio (\(tapStatus)). Check Screen & System Audio Recording permission."
            return nil
        }

        // 3. The tap's UUID string
        let tapUID = description.uuid.uuidString

        // 4. Target hardware output device UID
        let outUID = uid

        // Capture-only aggregate: no microphone, hardware output streams,
        // or assumptions about the tap being the last buffer in a mixed device.
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AOM App Audio \(pid)",
            kAudioAggregateDeviceUIDKey: "com.kyw.allofmacos.tap.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                              kAudioSubTapDriftCompensationKey: true]]
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
            errors[pid] = "Audio capture device could not be created (\(aggregateStatus))."
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        if Self.outputTransport(destination.id) == kAudioDeviceTransportTypeAirPlay {
            var address = AudioOutputService.address(kAudioDevicePropertyBufferFrameSize)
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(aggregateID, &address, &writable) == noErr, writable.boolValue {
                var preferred: UInt32 = 1024
                if let range = Self.property(aggregateID, selector: kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self),
                   range.mMinimum.isFinite, range.mMaximum.isFinite,
                   range.mMinimum >= 1, range.mMaximum >= range.mMinimum, range.mMaximum <= 32768 {
                    preferred = UInt32(min(range.mMaximum, max(range.mMinimum, Double(preferred))))
                }
                _ = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, 4, &preferred)
            }
        }
        guard let format = Self.property(tapID, selector: kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              Self.supports(format),
              let device = AudioOutputService.devices().first(where: { $0.uid == outUID }) else {
            errors[pid] = "The app audio format or selected output is unavailable."
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let sampleRate = format.mSampleRate
        let mixer = MixerBox(gain: gain, muted: muted,
                             magicBoost: UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)"),
                             eq: Self.appEQ(bundleID: bundleID, sampleRate: SharedOutputRenderer.sampleRate))
        let appBoost = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
            ? min(3, max(1, UserDefaults.standard.object(forKey: "AOMAudioBoostLevel_\(bundleID)") as? Int ?? 2)) : 0
        let masterBoost = UserDefaults.standard.bool(forKey: "AOMAudioMasterBoostEnabled")
            ? min(3, max(1, UserDefaults.standard.object(forKey: "AOMAudioMasterBoostLevel") as? Int ?? 2)) : 0
        mixer.setEffects(app: Self.appEQ(bundleID: bundleID, sampleRate: SharedOutputRenderer.sampleRate),
                         master: Self.masterEQ(sampleRate: SharedOutputRenderer.sampleRate),
                         appBoost: appBoost, masterBoost: masterBoost)
        mixer.deviceGain = AudioOutputService.softwareGain(uid: outUID)
        let isAirPlay = Self.outputTransport(device.id) == kAudioDeviceTransportTypeAirPlay
        let transport = AppAudioTransport(sampleRate: sampleRate, bufferedForAirPlay: isAirPlay)
        // Add only a software render source; the hardware graph remains fixed.
        guard let source = MainActor.assumeIsolated({ SharedOutputRenderer.shared.addSource(
            uid: outUID, device: device,
            render: { transport.render(frames: $0, output: $1, mixer: mixer, allowWaiting: isAirPlay) }) }) else {
            errors[pid] = "Cannot play through \(device.name). Choose another output or reconnect it."
            AudioHardwareDestroyAggregateDevice(aggregateID); AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            transport.capture(input)
        }
        guard procStatus == noErr, let procID else {
            errors[pid] = "Audio capture could not start (\(procStatus)). Check Screen & System Audio Recording permission."
            MainActor.assumeIsolated { SharedOutputRenderer.shared.removeSource(source) }
            AudioHardwareDestroyAggregateDevice(aggregateID); AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            errors[pid] = "Audio capture was refused (\(startStatus)). Check Screen & System Audio Recording permission."
            MainActor.assumeIsolated { SharedOutputRenderer.shared.removeSource(source) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID); AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let box = Unmanaged.passRetained(mixer)
        let session = Session(pid: pid, bundleID: bundleID, tapID: tapID, aggregateID: aggregateID,
                              procID: procID, box: box, gain: gain, muted: muted)
        session.processIDs = processObjIDs.sorted()
        session.tapDescription = description
        session.outputUID = outUID
        session.sampleRate = sampleRate
        session.outputSampleRate = SharedOutputRenderer.sampleRate
        session.transport = transport
        session.sourceToken = source
        return session
    }

    private static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        format.mBitsPerChannel == 32 && (1...2).contains(format.mChannelsPerFrame) &&
        format.mSampleRate.isFinite && format.mSampleRate > 0
    }

    private func updateProcesses(_ session: Session, ids: [AudioObjectID]) -> Bool {
        guard ids != session.processIDs else { return true }
        // An empty snapshot during helper replacement is transient. Keep the
        // tap alive; the next process-list notification updates its membership.
        guard !ids.isEmpty, let description = session.tapDescription else { return true }
        let previous = session.processIDs
        description.processes = ids
        var value = Unmanaged.passUnretained(description).toOpaque()
        var address = AudioOutputService.address(kAudioTapPropertyDescription)
        let result = AudioObjectSetPropertyData(session.tapID, &address, 0, nil,
                                                UInt32(MemoryLayout.size(ofValue: value)), &value)
        guard result == noErr else {
            // Retargeting a freshly created tap fails transiently — CoreAudio
            // is still publishing the process objects the tap itself changed.
            // Destroying the session here paused every video exactly 1 s after
            // attach. Keep the tap (the main process still gets captured) and
            // retry membership on the next tick.
            description.processes = previous
            GestureLog.shared.logFromAnyThread("Tap membership update deferred (\(result)) — keeping the session", level: .noMatch)
            return true
        }
        session.processIDs = ids
        return true
    }

    private func moveOutput(_ session: Session, device: AudioOutputDevice) -> Bool {
        guard let transport = session.transport else { return false }
        let mixer = session.box.takeUnretainedValue()
        let isAirPlay = Self.outputTransport(device.id) == kAudioDeviceTransportTypeAirPlay
        // Bridge, don't break: the new source is added before the old one is
        // removed. A failed add must leave the session playing through its
        // existing output — losing the device is what pauses every player.
        guard let source = MainActor.assumeIsolated({ SharedOutputRenderer.shared.addSource(
            uid: device.uid, device: device,
            render: { transport.render(frames: $0, output: $1, mixer: mixer, allowWaiting: isAirPlay) }) }) else { return false }
        if let old = session.sourceToken {
            MainActor.assumeIsolated { SharedOutputRenderer.shared.removeSource(old) }
        }
        transport.setBufferedForAirPlay(source.isAirPlay)
        session.sourceToken = source
        session.outputUID = device.uid
        return true
    }

    private func failAirPlay(_ session: Session, message: String) {
        let key = "\(session.outputUID)|\(session.bundleID)"
        stop(pid: session.pid)
        errors[session.pid] = message
        airPlayCaptureFailures[key] = message
        retryAfter[session.pid] = .infinity
        failedProcessIDs[session.pid] = session.processIDs
        GestureLog.shared.logFromAnyThread(message, level: .error)
    }

    private func fail(_ session: Session, message: String) {
        // Last-resort restore after in-place recovery failed. Suppress repeated
        // tap creation until explicit recovery or a genuine topology change.
        stop(pid: session.pid)
        errors[session.pid] = message
        retryAfter[session.pid] = .infinity
        failedProcessIDs[session.pid] = Self.processObjectIDs(for: session.pid).sorted()
        GestureLog.shared.logFromAnyThread(message, level: .error)
    }

    static func destroy(_ session: Session) {
        // Stop both callbacks before releasing the transport, mixer or tap.
        if let procID = session.procID {
            AudioDeviceStop(session.aggregateID, procID)
            AudioDeviceDestroyIOProcID(session.aggregateID, procID)
            session.procID = nil
        }
        if let source = session.sourceToken {
            MainActor.assumeIsolated { SharedOutputRenderer.shared.removeSource(source) }
            session.sourceToken = nil
        }
        session.transport = nil
        session.box.release()
        AudioHardwareDestroyAggregateDevice(session.aggregateID)
        AudioHardwareDestroyProcessTap(session.tapID)
    }
}

/// Five-millisecond, sample-counted ramps stay continuous across callback sizes.
struct AudioGainRamp {
    private(set) var current: Float
    private var target: Float
    private var remaining = 0
    init(_ value: Float) { current = value; target = value }
    mutating func setTarget(_ value: Float) {
        guard value != target else { return }
        target = value
        remaining = 240
    }
    mutating func next() -> Float {
        if remaining > 0 {
            current += (target - current) / Float(remaining)
            remaining -= 1
        }
        return current
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
    func publishPeak(_ value: Float) {
        guard lock.try() else { return }
        peak = value
        lock.unlock()
    }
    private var desiredAppEQ: AudioEQProcessor
    private var desiredMasterEQ: AudioEQProcessor
    private var desiredEQHeadroom: Float
    fileprivate var renderEQHeadroom: Float
    fileprivate var gainRamp: AudioGainRamp
    private var hasRendered = false
    private var previousAppEQ: AudioEQProcessor?
    private var previousMasterEQ: AudioEQProcessor?
    private var previousEQHeadroom: Float = 1
    private var eqTransitionRemaining = 0
    fileprivate var renderGain: Float
    fileprivate var renderMuted: Bool
    fileprivate var renderBoost: Bool
    /// Adaptive-compression strength: 0 off, 1 low, 2 medium, 3 high. The
    /// effective strength is the stronger of the app and master settings.
    fileprivate var renderBoostLevel: Int = 0
    fileprivate let boostProcessor = AudioAdaptiveBoost(sampleRate: 48000)
    private var desiredAppBoost: Int = 0
    private var desiredMasterBoost: Int = 0
    fileprivate var renderDeviceGain: Float = 1
    fileprivate var appEQ: AudioEQProcessor
    fileprivate var masterEQ: AudioEQProcessor
    var inputBufferOffset = 0 // immutable once the IOProc starts
    var leftOutputChannel = 0
    var rightOutputChannel = 1

    var deviceGain: Float {
        get { lock.lock(); defer { lock.unlock() }; return desiredDeviceGain }
        set { lock.lock(); desiredDeviceGain = Mixer.clamp(newValue); lock.unlock() }
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
        gainRamp = AudioGainRamp(muted ? 0 : Mixer.clamp(gain))
        desiredMuted = muted; renderMuted = muted
        desiredBoost = magicBoost; renderBoost = magicBoost
        desiredAppBoost = magicBoost ? 2 : 0
        let app = AudioEQProcessor(eq), master = AudioEQProcessor(AudioEQ(sampleRate: eq.sampleRate))
        desiredAppEQ = app; appEQ = app
        desiredMasterEQ = master; masterEQ = master
        let headroom = AudioEQ.headroomGain(app: eq, master: master.eq)
        desiredEQHeadroom = headroom; renderEQHeadroom = headroom
    }
    func setEffects(app: AudioEQ, master: AudioEQ, appBoost: Int, masterBoost: Int) {
        // Coefficients and headroom are prepared on the control thread. The
        // audio callback uses its previous configuration on lock contention.
        lock.lock(); defer { lock.unlock() }
        if desiredAppEQ.eq != app || desiredMasterEQ.eq != master {
            desiredEQHeadroom = AudioEQ.headroomGain(app: app, master: master)
            // Both chains need independent histories during a crossfade, even
            // if only one EQ changed. Never process the same filter twice.
            desiredAppEQ = AudioEQProcessor(app)
            desiredMasterEQ = AudioEQProcessor(master)
        }
        desiredAppBoost = min(3, max(0, appBoost))
        desiredBoost = desiredAppBoost > 0
        desiredMasterBoost = min(3, max(0, masterBoost))
    }
    fileprivate func beginRender() {
        guard lock.try() else { return }
        renderGain = desiredGain; renderMuted = desiredMuted
        // Legacy single-bool boost upgrades to the level model; the master
        // boost covers apps whose own toggle is off.
        renderBoost = desiredBoost && desiredAppBoost == 0
        renderBoostLevel = max(desiredAppBoost, desiredMasterBoost)
        renderDeviceGain = desiredDeviceGain
        if !hasRendered || (eqTransitionRemaining == 0 && appEQ !== desiredAppEQ) {
            if hasRendered {
                previousAppEQ = appEQ; previousMasterEQ = masterEQ
                previousEQHeadroom = renderEQHeadroom
                eqTransitionRemaining = 480
            }
            renderEQHeadroom = desiredEQHeadroom
            appEQ = desiredAppEQ; masterEQ = desiredMasterEQ
        }
        let target = renderMuted ? 0 : renderGain * renderDeviceGain
        if !hasRendered { gainRamp = AudioGainRamp(target); hasRendered = true }
        else { gainRamp.setTarget(target) }
        lock.unlock()
    }

    fileprivate func filter(left: inout Float, right: inout Float) {
        let inputLeft = left, inputRight = right
        left = masterEQ.process(appEQ.process(inputLeft * renderEQHeadroom, channel: 0), channel: 0)
        right = masterEQ.process(appEQ.process(inputRight * renderEQHeadroom, channel: 1), channel: 1)
        if eqTransitionRemaining > 0, let previousAppEQ, let previousMasterEQ {
            let oldLeft = previousMasterEQ.process(previousAppEQ.process(inputLeft * previousEQHeadroom, channel: 0), channel: 0)
            let oldRight = previousMasterEQ.process(previousAppEQ.process(inputRight * previousEQHeadroom, channel: 1), channel: 1)
            let blend = Float(481 - eqTransitionRemaining) / 480
            left = oldLeft + (left - oldLeft) * blend
            right = oldRight + (right - oldRight) * blend
            eqTransitionRemaining -= 1
        }
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
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                vDSP_vclr(data, 1, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride))
            }
        }
        var peak: Float = 0
        defer { box.publishPeak(peak) }
        guard box.inputBufferOffset < inputs.count else { return }
        box.beginRender()
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
            box.filter(left: &l, right: &r)
            box.boostProcessor.process(left: &l, right: &r, level: box.renderBoostLevel)
            let gain = box.gainRamp.next()
            l *= gain; r *= gain
            // Preserve peaks until the linked limiter on the final summing bus.
            // Clipping here permanently distorts EQ/boost before apps are mixed.
            l = l.isFinite ? l : 0
            r = r.isFinite ? r : 0
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