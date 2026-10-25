import AppKit
import CoreAudio
import Foundation

/// The system default output device is machine-wide state: a change outlives
/// the process that made it. Routing every app's audio to an AirPlay room (or
/// to one of our own aggregate devices) and then quitting leaves macOS playing
/// through a route that never starts, so other apps' video freezes about a
/// second in and stays frozen with AOM gone. Record what we changed and put the
/// previous device back when the change is no longer wanted.
enum AudioOutputRestore {
    private static let previousKey = "aom.audio.previousOutputUID"
    private static let appliedKey = "aom.audio.appliedOutputUID"
    private static let stampKey = "aom.audio.outputChangedAt"
    private static let enabledKey = "aom.audio.restoreOutputOnExit"

    /// Preserving a user-selected HomePod (or any output) across app exit is
    /// the safe default. Restore only if the user explicitly opted into it.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    static var hasPendingChange: Bool {
        !(UserDefaults.standard.string(forKey: appliedKey) ?? "").isEmpty
    }

    static var pendingRestoreName: String? {
        guard let uid = UserDefaults.standard.string(forKey: previousKey), !uid.isEmpty,
              let id = deviceID(forUID: uid) else { return nil }
        return name(of: id)
    }

    /// Called after a successful output switch. `previousUID` is the device that
    /// was default before we touched it.
    static func record(previousUID: String?, appliedUID: String) {
        guard isEnabled, !appliedUID.isEmpty, appliedUID != (previousUID ?? "") else { return }
        let defaults = UserDefaults.standard
        defaults.set(previousUID ?? "", forKey: previousKey)
        defaults.set(appliedUID, forKey: appliedKey)
        defaults.set(Date(), forKey: stampKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: previousKey)
        defaults.removeObject(forKey: appliedKey)
        defaults.removeObject(forKey: stampKey)
    }

    /// Restores the pre-change device when — and only when — the current default
    /// is still the one we applied. A device the user picked themselves is never
    /// overridden.
    @discardableResult
    static func restoreIfNeeded(reason: String) -> Bool {
        guard isEnabled else { return false }
        guard let applied = UserDefaults.standard.string(forKey: appliedKey), !applied.isEmpty else { return false }
        guard let current = defaultOutputUID() else { return false }
        guard current == applied else { clear(); return false }
        let previous = UserDefaults.standard.string(forKey: previousKey) ?? ""
        guard !previous.isEmpty, let target = deviceID(forUID: previous) else {
            // Nothing to go back to: leave the device alone but stop tracking it.
            clear()
            return false
        }
        guard setDefaultOutput(target) else { return false }
        clear()
        GestureLog.shared.logFromAnyThread(
            "Restored system audio output after \(reason): \(name(of: target))",
            level: .action)
        return true
    }

    // MARK: - CoreAudio helpers

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = propertyAddress(selector)
        guard AudioObjectHasProperty(object, &address) else { return "" }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return "" }
        return value as String
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(of id: AudioDeviceID) -> String {
        stringProperty(id, kAudioObjectPropertyName)
    }

    static func uid(of id: AudioDeviceID) -> String {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    static func defaultOutputUID() -> String? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        let value = uid(of: id)
        return value.isEmpty ? nil : value
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { self.uid(of: $0) == uid }
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        return status == noErr
    }
}

// MARK: - Launch-time repair of a stuck AirPlay default

extension AudioOutputRestore {
    private static let lastLocalKey = "aom.audio.lastLocalOutputUID"
    private static let protectKey = "aom.audio.protectMediaPlayback"

    /// Optional legacy fallback. Never assume an AirPlay default is broken:
    /// users intentionally select HomePod as the system audio output.
    /// Automatic force-switching to built-in speakers is disabled by default.
    static var protectsMediaPlayback: Bool {
        UserDefaults.standard.object(forKey: protectKey) as? Bool ?? false
    }

    static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreams)
        address.mScope = kAudioDevicePropertyScopeOutput
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Remembers the device to come back to when a later AirPlay route has to be
    /// undone.
    static func rememberLocalDefault() {
        guard let uid = defaultOutputUID(), let id = deviceID(forUID: uid) else { return }
        guard transportType(of: id) != kAudioDeviceTransportTypeAirPlay else { return }
        UserDefaults.standard.set(uid, forKey: lastLocalKey)
    }

    private static func localFallback() -> AudioDeviceID? {
        let saved = UserDefaults.standard.string(forKey: lastLocalKey) ?? ""
        if !saved.isEmpty, let id = deviceID(forUID: saved),
           transportType(of: id) != kAudioDeviceTransportTypeAirPlay { return id }
        if let builtIn = deviceID(forUID: "BuiltInSpeakerDevice") { return builtIn }
        return deviceIDs().first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }
    }

    /// Starting the app-audio engine can make macOS re-open the last AirPlay route
    /// and take it as the system default a few seconds after launch. The captured
    /// apps then play into an AirPlay buffer, which stalls video about a second in
    /// and keeps stalling after AOM quits. Watch the first seconds of a launch and
    /// put the device we started on back.
    static func guardStartupOutputFlip() {
        // Deliberately not gated on the AirPlay-repair preference: this undoes a
        // change our own engine just caused, not a choice the user made.
        guard !hasPendingChange else { return }
        guard let baselineUID = defaultOutputUID(), let baselineID = deviceID(forUID: baselineUID),
              transportType(of: baselineID) != kAudioDeviceTransportTypeAirPlay else { return }
        let name = self.name(of: baselineID)
        for delay in [2.0, 5.0, 9.0, 14.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let currentUID = defaultOutputUID(), let currentID = deviceID(forUID: currentUID),
                      transportType(of: currentID) == kAudioDeviceTransportTypeAirPlay else { return }
                guard setDefaultOutput(baselineID) else { return }
                GestureLog.shared.logFromAnyThread(
                    "AOM's audio engine woke AirPlay and macOS moved the default output; returned audio to \(name)",
                    level: .action)
            }
        }
    }

    /// An AirPlay default that outlives the process is what keeps video frozen
    /// about a second in, even with AOM quit. Put a local device back once, at
    /// launch, before anything tries to play.
    @discardableResult
    static func repairAirPlayDefaultAtLaunch() -> Bool {
        guard protectsMediaPlayback, !hasPendingChange else { return false }
        guard let uid = defaultOutputUID(), let current = deviceID(forUID: uid),
              transportType(of: current) == kAudioDeviceTransportTypeAirPlay else {
            rememberLocalDefault()
            return false
        }
        guard let target = localFallback(), setDefaultOutput(target) else { return false }
        GestureLog.shared.logFromAnyThread(
            "Returned system audio to \(name(of: target)) — an AirPlay default stalls video playback",
            level: .action)
        return true
    }
}
