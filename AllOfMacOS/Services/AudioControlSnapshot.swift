import AppKit
import CoreAudio
import Darwin

/// A running (or manually added, closed) app as the mixer lists it, as plain
/// values so the list can be built off the main thread. Icons are loaded on
/// main, once per bundle path, by the engine.
struct AudioAppIdentity: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String
    let bundlePath: String?
}

/// What one gather needs to know about the engine, captured on main so the
/// gather itself never touches engine state.
struct AudioControlGatherRequest: Sendable {
    var sequence: UInt64
    /// Post `AOMAudioAppsChanged` after the apply even when nothing changed.
    var announce = true
    /// Read process objects, playback, devices and session facts. Off while
    /// App Audio is disabled (unless the mixer asked for playback) or asleep.
    var sweep = true
    var appAudioEnabled = true
    var includeIdentities = false
    var identityGeneration: UInt64 = 0
    /// PIDs already in the identity list: a newly playing regular app outside
    /// it forces a rebuild in the same gather.
    var knownPIDs = Set<pid_t>()
    /// Live sessions: whether their app terminated, and their taps' formats.
    var sessionPIDs = Set<pid_t>()
    var tapIDs = Set<AudioObjectID>()
}

/// Everything the audio control apply step reads from CoreAudio and
/// LaunchServices, gathered in one pass on the control queue. A value: the
/// apply step on main only does bookkeeping against it.
struct AudioControlSnapshot: Sendable {
    var sequence: UInt64 = 0
    var announce = false
    /// False when the gather skipped the process sweep (see the request).
    var swept = false
    /// nil: the list read failed, which is not an empty list.
    var processObjects: [AudioObjectID]?
    var objectsByOwner: [pid_t: [AudioObjectID]] = [:]
    /// Process objects whose `kAudioProcessPropertyIsRunningOutput` is 1.
    var runningOutput = Set<AudioObjectID>()
    /// Process objects whose `kAudioProcessPropertyIsRunningInput` is 1.
    var runningInput = Set<AudioObjectID>()
    var playingOwners = Set<pid_t>()
    var defaultOutputID: AudioDeviceID?
    var defaultOutputUID: String?
    var defaultOutputTransport: UInt32?
    var devices: [AudioOutputDevice] = []
    var transport: [AudioDeviceID: UInt32] = [:]
    /// 6.5: AirPlay devices that answered "not alive" or a zero nominal rate
    /// (`AirPlayDeviceReadiness`), read here on the control queue so the apply
    /// step never asks the HAL on main while a HomePod reconnects.
    var unreadyAirPlay = Set<AudioDeviceID>()
    /// Configured software output gain per device UID (absent: unity).
    var softwareGains: [String: Float] = [:]
    /// Tap formats of the request's taps; a tap in `queriedTaps` but missing
    /// here failed its read (a transient during stream start).
    var tapFormats: [AudioObjectID: AudioStreamBasicDescription] = [:]
    var queriedTaps = Set<AudioObjectID>()
    /// Session PIDs whose application is gone.
    var terminatedPIDs = Set<pid_t>()
    /// The rebuilt identity list, or nil when the gather kept the current one.
    var apps: [AudioAppIdentity]?
    var identityGeneration: UInt64 = 0
    var takenAt: TimeInterval = -.infinity
    var gatherMS: Double = 0

    static let empty = AudioControlSnapshot()

    func isAirPlay(_ device: AudioOutputDevice) -> Bool {
        transport[device.id] == kAudioDeviceTransportTypeAirPlay
    }

    func device(uid: String) -> AudioOutputDevice? { devices.first { $0.uid == uid } }

    /// An AirPlay device a direct session may attach to now.
    func isReadyAirPlay(_ device: AudioOutputDevice) -> Bool { !unreadyAirPlay.contains(device.id) }

    func softwareGain(uid: String) -> Float { softwareGains[uid] ?? 1 }

    /// Owners with a process object that records (microphone or other input).
    var recordingOwners: Set<pid_t> {
        Set(objectsByOwner.compactMap { pid, objects in objects.contains(where: runningInput.contains) ? pid : nil })
    }

    /// `AppAudioEngine.targetOutputUID(for:)` against this snapshot: a stored
    /// route while its device is connected, otherwise the default output.
    func targetOutputUID(for bundleID: String, defaults: UserDefaults = .standard) -> String? {
        if let stored = defaults.string(forKey: "AOMAudioRoute_\(bundleID)"),
           devices.contains(where: { $0.uid == stored }) { return stored }
        return defaultOutputUID
    }

    /// Does every blocking read. Callable from any queue: it uses only the
    /// request and thread-safe statics (the owner cache is locked).
    @available(macOS 14.2, *)
    static func gather(_ request: AudioControlGatherRequest) -> AudioControlSnapshot {
        let interval = AOMPerformance.begin("Audio.sync")
        defer { AOMPerformance.end("Audio.sync", interval) }
        let start = mach_absolute_time()
        var snapshot = AudioControlSnapshot(sequence: request.sequence, announce: request.announce,
                                            identityGeneration: request.identityGeneration,
                                            takenAt: ProcessInfo.processInfo.systemUptime)
        snapshot.defaultOutputID = AudioOutputService.currentDeviceID()
        snapshot.defaultOutputTransport = AppAudioEngine.outputTransport(snapshot.defaultOutputID)
        if let id = snapshot.defaultOutputID {
            let uid = AudioOutputService.string(id, kAudioDevicePropertyDeviceUID)
            snapshot.defaultOutputUID = uid.isEmpty ? nil : uid
        }
        var includeIdentities = request.includeIdentities
        if request.sweep {
            snapshot.swept = true
            let objects = AppAudioEngine.readProcessObjectList()
            snapshot.processObjects = objects
            snapshot.objectsByOwner = AppAudioEngine.processObjectsByOwner(objects: objects ?? [])
            for object in snapshot.objectsByOwner.values.joined() {
                if AppAudioEngine.property(object, selector: kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1 {
                    snapshot.runningOutput.insert(object)
                }
                if AppAudioEngine.property(object, selector: kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1 {
                    snapshot.runningInput.insert(object)
                }
            }
            let running = snapshot.runningOutput
            snapshot.playingOwners = AudioPlaybackActivity.playingOwners(snapshot.objectsByOwner) { running.contains($0) }
            snapshot.devices = AudioOutputService.devices()
            for device in snapshot.devices {
                if let type = AppAudioEngine.outputTransport(device.id) {
                    snapshot.transport[device.id] = type
                    if type == kAudioDeviceTransportTypeAirPlay, !AirPlayDeviceReadiness.isReady(deviceID: device.id) {
                        snapshot.unreadyAirPlay.insert(device.id)
                    }
                }
                let gain = AudioOutputService.softwareGain(uid: device.uid, in: snapshot.devices,
                                                           appAudioEnabled: request.appAudioEnabled)
                if gain != 1 { snapshot.softwareGains[device.uid] = gain }
            }
            for tap in request.tapIDs {
                snapshot.queriedTaps.insert(tap)
                if let format = AppAudioEngine.property(tap, selector: kAudioTapPropertyFormat,
                                                        as: AudioStreamBasicDescription.self) {
                    snapshot.tapFormats[tap] = format
                }
            }
            // Playback or process-object disappearance is not termination.
            for pid in request.sessionPIDs where NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
                snapshot.terminatedPIDs.insert(pid)
            }
            // Some apps become regular only after their launch notification.
            // A newly playing owner must not wait for the identity TTL to
            // appear; its helpers may have been resolved while it was not
            // yet regular, so the next sweep re-resolves them.
            if !includeIdentities, snapshot.playingOwners.subtracting(request.knownPIDs).contains(where: {
                NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
            }) {
                includeIdentities = true
                AppAudioEngine.resetOwnerResolution()
            }
        }
        if includeIdentities { snapshot.apps = appIdentities() }
        snapshot.gatherMS = AudioHostTime.milliseconds(from: start, to: mach_absolute_time())
        return snapshot
    }

    /// Regular apps and known media players, then manually added apps that
    /// are not running (negative PIDs), sorted by name.
    static func appIdentities(defaults: UserDefaults = .standard) -> [AudioAppIdentity] {
        let knownMedia: Set<String> = [
            "com.apple.Music", "com.spotify.client", "com.apple.Safari",
            "com.google.Chrome", "org.mozilla.firefox", "org.videolan.vlc",
            "com.apple.QuickTimePlayerX", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord", "us.zoom.xos", "com.apple.FaceTime",
            "com.apple.Podcasts", "com.apple.TV"
        ]
        let customApps = Set(defaults.stringArray(forKey: "AOMAudioUserApps") ?? [])
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var results: [AudioAppIdentity] = []
        var seenPIDs = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != ownPID, !seenPIDs.contains(pid) else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            let isMedia = knownMedia.contains(bundleID) || customApps.contains(bundleID)
            guard isMedia || (app.activationPolicy == .regular && bundleID != ownBundleID) else { continue }
            seenPIDs.insert(pid)
            results.append(AudioAppIdentity(pid: pid, name: app.localizedName ?? bundleID, bundleID: bundleID,
                                            bundlePath: app.bundleURL?.path))
        }
        // Manually added apps remain configurable while closed.
        for (index, bundleID) in customApps.sorted().enumerated() where !results.contains(where: { $0.bundleID == bundleID }) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? url?.deletingPathExtension().lastPathComponent ?? bundleID
            results.append(AudioAppIdentity(pid: -pid_t(index + 1), name: name, bundleID: bundleID, bundlePath: url?.path))
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Main-thread bookkeeping for background gathers: at most one in flight, a
/// request meanwhile runs exactly one more afterwards, and a snapshot older
/// than one already applied (an inline sync overtook it) is dropped.
struct AudioControlSyncGate: Equatable {
    private(set) var inFlight = false
    private(set) var dirty = false
    private(set) var issued: UInt64 = 0
    private(set) var applied: UInt64 = 0

    /// The new background gather's sequence, or nil while one is running.
    mutating func beginBackground() -> UInt64? {
        guard !inFlight else { dirty = true; return nil }
        inFlight = true
        issued += 1
        return issued
    }

    /// An inline gather neither waits for nor blocks a background one.
    mutating func beginInline() -> UInt64 {
        issued += 1
        return issued
    }

    /// The background gather returned. True when another one should run.
    mutating func finishBackground() -> Bool {
        inFlight = false
        defer { dirty = false }
        return dirty
    }

    /// Whether a finished gather is newer than the last applied one.
    mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > applied else { return false }
        applied = sequence
        return true
    }
}

/// Opt-in diagnostics: how long gathers take and the worst main-thread apply.
struct AudioControlTimingStats: Equatable {
    private(set) var gatherCount = 0
    private(set) var gatherTotalMS: Double = 0
    private(set) var applyMaxMS: Double = 0

    var gatherMeanMS: Double { gatherCount == 0 ? 0 : gatherTotalMS / Double(gatherCount) }

    mutating func recordGather(ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        gatherCount += 1
        gatherTotalMS += ms
    }

    mutating func recordApply(ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        applyMaxMS = max(applyMaxMS, ms)
    }

    mutating func reset() { self = Self() }

    /// Diagnostics JSON values, in milliseconds to 0.001 ms.
    var json: [String: Double] {
        ["controlGatherMeanMS": (gatherMeanMS * 1000).rounded() / 1000,
         "controlApplyMaxMS": (applyMaxMS * 1000).rounded() / 1000]
    }
}

enum AudioHostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start, timebase.denom != 0 else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}
