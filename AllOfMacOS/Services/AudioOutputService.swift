import AppKit
import CoreAudio
import AudioToolbox

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioOutputSelection {
    static func resolve(name: String, uid: String?, devices: [AudioOutputDevice]) -> AudioOutputDevice? {
        if let uid, !uid.isEmpty { return devices.first { $0.uid == uid } }
        let matches = devices.filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }
}

final class AudioOutputService {
    static let shared = AudioOutputService()
    private var busy = false
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = address(selector); var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func devices() -> [AudioOutputDevice] {
        var property = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return devices.compactMap { id in
            var output = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &output, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            return AudioOutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName))
        }
    }
    static func currentDeviceID() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: id))
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr ? id : nil
    }
    static func steppedVolume(_ current: Float32, percentagePoints: Double) -> Float32 {
        min(1, max(0, current + Float32(percentagePoints / 100)))
    }
    private static func volumeProperty(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var property = address(selector, scope: kAudioDevicePropertyScopeOutput)
            var writable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &property),
               AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue { return property }
        }
        return nil
    }
    /// Some CoreAudio devices expose a writable mute switch. When macOS reaches
    /// 0% it may flip this switch on; setting volume alone then reads back as 0.
    private static func muteProperty(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            property.mElement = element
            if AudioObjectHasProperty(device, &property) { return property }
        }
        return nil
    }
    static func shouldUnmuteOnIncrease(isMuted: Bool, percentagePoints: Double) -> Bool {
        isMuted && percentagePoints > 0
    }
    private static func clearMuteForVolumeIncrease(device: AudioDeviceID, delta: Double) -> Bool {
        guard delta > 0, var property = muteProperty(device) else { return true }
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: current))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &current) == noErr else { return false }
        guard shouldUnmuteOnIncrease(isMuted: current != 0, percentagePoints: delta) else { return true }
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue else { return false }
        var unmuted: UInt32 = 0
        guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: unmuted)), &unmuted) == noErr else { return false }
        // Confirm the mute bit is clear before changing the scalar. Some output
        // devices silently ignore volume writes while this bit is still set.
        current = 1
        size = UInt32(MemoryLayout.size(ofValue: current))
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &current) == noErr && current == 0
    }
    private static func currentMuteState(_ device: AudioDeviceID) -> Bool? {
        guard var property = muteProperty(device) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    static func currentVolume() -> Float32? {
        guard let device = currentDeviceID(), var property = volumeProperty(device) else { return nil }
        var value: Float32 = 0; var size: UInt32 = 4
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
        return value
    }
    private var changingVolume = false
    private var volumeRequests: [(Double, (Bool) -> Void)] = []
    func adjustVolume(percentagePoints: Double, completion: @escaping (Bool) -> Void) {
        guard percentagePoints.isFinite, abs(percentagePoints) <= 100 else { completion(false); return }
        volumeRequests.append((percentagePoints, completion))
        if !changingVolume { changingVolume = true; applyNextVolumeChange() }
    }
    private func applyNextVolumeChange() {
        guard let (delta, completion) = volumeRequests.first else { return }
        func done(_ success: Bool, _ message: String) {
            self.volumeRequests.removeFirst()
            self.finish(success, message, completion)
            if !self.volumeRequests.isEmpty { DispatchQueue.main.async { self.applyNextVolumeChange() } }
            else { self.changingVolume = false }
        }
        guard let device = Self.currentDeviceID(), var property = Self.volumeProperty(device) else {
            done(false, "Current output does not expose adjustable volume"); return
        }
        // 0% is also hardware-mute on many macOS outputs. Unmute first so the
        // subsequent scalar write is applied rather than silently ignored.
        guard Self.clearMuteForVolumeIncrease(device: device, delta: delta) else {
            done(false, "Output could not be unmuted for volume increase"); return
        }
        guard let current = Self.currentVolume() else {
            done(false, "Current output volume could not be read"); return
        }
        var desired = Self.steppedVolume(current, percentagePoints: delta)
        guard AudioObjectSetPropertyData(device, &property, 0, nil, 4, &desired) == noErr else {
            done(false, "Output refused volume change"); return
        }
        func verify(_ left: Int) {
            guard Self.currentDeviceID() == device else { done(false, "Output changed during volume adjustment"); return }
            if let actual = Self.currentVolume(), abs(actual - desired) < 0.001,
               !(delta > 0 && Self.currentMuteState(device) == true) {
                done(true, String(format: "Volume: %.2f%% → %.2f%%", current * 100, actual * 100))
            } else if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { verify(left - 1) } }
            else { done(false, "Output could not confirm requested volume"); }
        }
        verify(20)
    }

    private static func isAirPlayOutput() -> Bool {
        guard let id = currentDeviceID() else { return false }
        var property = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &type) == noErr && type == kAudioDeviceTransportTypeAirPlay
    }
    func select(name: String, uid: String?, completion: @escaping (Bool) -> Void) {
        guard !busy else { finish(false, "Another sound output change is still running", completion); return }
        guard !name.isEmpty || !(uid ?? "").isEmpty else { finish(false, "Choose an output device or enter an AirPlay room name", completion); return }
        busy = true
        let done: (Bool, String) -> Void = { success, message in
            self.busy = false; self.finish(success, message, completion)
        }
        let devices = Self.devices()
        if let device = AudioOutputSelection.resolve(name: name, uid: uid, devices: devices) {
            var property = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            var id = device.id
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                                   UInt32(MemoryLayout.size(ofValue: id)), &id)
            guard status == noErr else { done(false, "Output refused change (\(status)): \(device.name)"); return }
            func verify(_ left: Int) {
                if Self.currentDeviceID() == device.id { done(true, "Sound output: \(device.name)") }
                else if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verify(left - 1) } }
                else { done(false, "Output change was not confirmed: \(device.name)") }
            }
            verify(20)
        } else if let uid, !uid.isEmpty {
            done(false, "Saved output device is disconnected: \(name)")
        } else {
            // AirPlay rooms are not separate HAL devices: HAL exposes a generic
            // 'AirPlay' device after connection. Select the named route via AX.
            selectSettingsRoute(name: name, completion: done)
        }
    }
    private func finish(_ success: Bool, _ message: String, _ completion: (Bool) -> Void) {
        GestureLog.shared.logFromAnyThread(message, level: success ? .action : .error)
        completion(success)
    }

    private func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }
    private func text(_ node: AXUIElement, _ key: String) -> String { attribute(node, key) as? String ?? "" }
    private func children(_ node: AXUIElement) -> [AXUIElement] { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func descendants(_ root: AXUIElement, limit: Int = 1500) -> [AXUIElement] {
        var result = [root]; var cursor = 0
        while cursor < result.count && result.count < limit {
            let next = children(result[cursor]); cursor += 1
            result.append(contentsOf: next.prefix(limit - result.count))
        }
        return result
    }
    private func hasLabel(_ node: AXUIElement, _ label: String) -> Bool {
        [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
            text(node, $0).split(separator: "\n").contains { String($0) == label }
        }
    }
    private func selectedRow(_ row: AXUIElement) -> Bool { (attribute(row, kAXSelectedAttribute) as? Bool) == true }
    private func selectSettingsRoute(name: String, completion: @escaping (Bool, String) -> Void) {
        guard AXIsProcessTrusted() else { completion(false, "Accessibility permission is required for AirPlay selection"); return }
        let previous = NSWorkspace.shared.frontmostApplication
        let settingsBefore = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        let wasRunning = settingsBefore != nil
        var soundWindow: AXUIElement?
        var selected = false
        var stableChecks = 0
        let start = ProcessInfo.processInfo.systemUptime
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"), NSWorkspace.shared.open(url) else {
            completion(false, "Could not open Sound settings"); return
        }
        func finish(_ success: Bool, _ message: String) {
            if success {
                // Only close the Sound window opened by this operation. Never
                // quit a Settings app that was already running for the user.
                if let window = soundWindow, let close = self.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() {
                    _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
                }
                if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.terminate() }
                if previous?.bundleIdentifier != "com.apple.systempreferences" { previous?.activate(options: []) }
            }
            completion(success, message)
        }
        func poll() {
            guard ProcessInfo.processInfo.systemUptime - start < 12 else {
                finish(false, "Sound output not found or connection timed out: \(name)"); return
            }
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.5)
                let windows = self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
                for window in windows {
                    let nodes = self.descendants(window)
                    // Stable accessibility identifiers, not numbered groups or
                    // a fixed window title, avoid the old KM hierarchy dependency.
                    if let table = nodes.first(where: { self.hasLabel($0, "OutputSourceTable") }) {
                        soundWindow = window
                        let rows = self.children(table).filter { self.text($0, kAXRoleAttribute) == kAXRowRole }
                        let matches = rows.filter { row in self.descendants(row, limit: 100).contains { self.hasLabel($0, name) } }
                        if matches.count > 1 { finish(false, "Multiple output rows have the same name: \(name)"); return }
                        if let row = matches.first {
                            let airPlay = self.descendants(row, limit: 100).contains { self.hasLabel($0, "AirPlay") }
                            if self.selectedRow(row), (!airPlay || Self.isAirPlayOutput()) {
                                stableChecks += 1
                                if stableChecks >= 3 { finish(true, "Sound output: \(name) (confirmed in Sound settings)"); return }
                            } else {
                                stableChecks = 0
                                if !selected {
                                    let status = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                                    if status == .success { selected = true }
                                    else if AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success {
                                        selected = true
                                    } else { finish(false, "Sound settings refused selection: \(name)"); return }
                                }
                            }
                        }
                    } else if let tabGroup = nodes.first(where: { self.hasLabel($0, "InputOutputTab") }) {
                        let output = self.descendants(tabGroup, limit: 30).first { self.hasLabel($0, "Output") || self.hasLabel($0, "출력") }
                        if let output { _ = AXUIElementPerformAction(output, kAXPressAction as CFString) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
    }
}

// MARK: - Absolute volume and microphone mute (1.1.4)

extension AudioOutputService {
    /// Percentage points needed to move `current` (0…1) to `target` (0…100).
    /// nil when the target is not a usable percentage.
    static func volumeDelta(current: Float32, targetPercent: Double) -> Double? {
        guard targetPercent.isFinite, (0...100).contains(targetPercent), current.isFinite else { return nil }
        return targetPercent - Double(current) * 100
    }

    /// Sets the output volume to an exact percentage by stepping through
    /// `adjustVolume`, so unmute-on-increase and read-back verification apply.
    func setVolume(percent: Double, completion: @escaping (Bool) -> Void) {
        guard let current = Self.currentVolume(),
              let delta = Self.volumeDelta(current: current, targetPercent: percent) else { completion(false); return }
        if abs(delta) < 0.05 { completion(true); return }
        adjustVolume(percentagePoints: delta, completion: completion)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Mute switches on the default input device, one per channel that has one.
    private static func inputMuteProperties(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        [kAudioObjectPropertyElementMain, 1, 2].compactMap { element -> AudioObjectPropertyAddress? in
            var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
            property.mElement = element
            var writable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &property),
                  AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue else { return nil }
            return property
        }
    }

    /// Flips the default microphone's mute state. Returns the new muted state,
    /// or nil when the input exposes no writable mute switch (many USB mics).
    @discardableResult
    static func toggleInputMute() -> Bool? {
        guard let device = defaultInputDeviceID() else { return nil }
        var properties = inputMuteProperties(device)
        guard !properties.isEmpty else { return nil }
        var first: UInt32 = 0; var size = UInt32(MemoryLayout.size(ofValue: first))
        guard AudioObjectGetPropertyData(device, &properties[0], 0, nil, &size, &first) == noErr else { return nil }
        var next: UInt32 = first == 0 ? 1 : 0
        var ok = true
        for index in properties.indices {
            ok = AudioObjectSetPropertyData(device, &properties[index], 0, nil, UInt32(MemoryLayout.size(ofValue: next)), &next) == noErr && ok
        }
        return ok ? next != 0 : nil
    }
}
