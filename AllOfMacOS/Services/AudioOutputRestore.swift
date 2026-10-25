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

    /// On by default; a user who wants AOM's output choice to survive a quit can
    /// turn it off in the audio workspace.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
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
