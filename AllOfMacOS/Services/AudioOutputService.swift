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
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("com.kyw.allofmacos.tap.") else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName))
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
    private static func outputMuteProperties(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var result: [AudioObjectPropertyAddress] = []
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var p = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            p.mElement = element
            var writable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &p, &writable) == noErr, writable.boolValue else { continue }
            if element == kAudioObjectPropertyElementMain { return [p] }
            result.append(p)
        }
        return result
    }

    static func shouldUnmuteOnIncrease(isMuted: Bool, percentagePoints: Double) -> Bool {
        isMuted && percentagePoints > 0
    }
    private static func clearMuteForVolumeIncrease(device: AudioDeviceID, delta: Double) -> Bool {
        guard delta > 0 else { return true }
        for var p in outputMuteProperties(device) {
            var value: UInt32 = 0, size: UInt32 = 4
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &value) == noErr else { return false }
            if value != 0 {
                value = 0
                guard AudioObjectSetPropertyData(device, &p, 0, nil, 4, &value) == noErr else { return false }
            }
        }
        return true
    }
    static func currentMuteState(_ device: AudioDeviceID) -> Bool? {
        let properties = outputMuteProperties(device)
        guard !properties.isEmpty else { return nil }
        var allMuted = true
        for var p in properties {
            var value: UInt32 = 0, size: UInt32 = 4
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &value) == noErr else { return nil }
            allMuted = allMuted && value != 0
        }
        return allMuted
    }
    static func canAdjustOutputVolume() -> Bool {
        guard let device = currentDeviceID() else { return false }
        if volumeProperty(device) != nil { return true }
        if #available(macOS 14.2, *) { return true }
        return false
    }
    static func canAdjustBalance() -> Bool {
        guard let device = currentDeviceID() else { return false }
        return [1, 2].allSatisfy { channel in
            var p = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
            p.mElement = AudioObjectPropertyElement(channel)
            var writable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &p, &writable) == noErr && writable.boolValue
        }
    }

    static func currentVolume() -> Float32? {
        guard let device = currentDeviceID() else { return nil }
        guard var property = volumeProperty(device) else {
            if #available(macOS 14.2, *) { return softwareGain(uid: string(device, kAudioDevicePropertyDeviceUID)) }
            return nil
        }
        var value: Float32 = 0; var size: UInt32 = 4
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
        return value
    }
    static func softwareGain(uid: String) -> Float {
        guard let device = devices().first(where: { $0.uid == uid }), volumeProperty(device.id) == nil else { return 1 }
        let value = UserDefaults.standard.object(forKey: "AOMAudioDeviceGain_\(uid)") as? Double ?? 1
        return value.isFinite ? Float(min(1, max(0, value))) : 1
    }

    private var changingVolume = false
    private struct VolumeRequest {
        let value: Double
        let absolute: Bool
        let device: AudioDeviceID?
        let completion: (Bool) -> Void
    }
    private var volumeRequests: [VolumeRequest] = []
    func adjustVolume(percentagePoints: Double, completion: @escaping (Bool) -> Void) {
        guard percentagePoints.isFinite, abs(percentagePoints) <= 100 else { completion(false); return }
        volumeRequests.append(VolumeRequest(value: percentagePoints, absolute: false,
                                            device: Self.currentDeviceID(), completion: completion))
        if !changingVolume { changingVolume = true; applyNextVolumeChange() }
    }
    private func applyNextVolumeChange() {
        guard let request = volumeRequests.first else { return }
        let completion = request.completion
        func done(_ success: Bool, _ message: String) {
            self.volumeRequests.removeFirst()
            self.finish(success, message, completion)
            if !self.volumeRequests.isEmpty { DispatchQueue.main.async { self.applyNextVolumeChange() } }
            else { self.changingVolume = false }
        }
        guard let device = Self.currentDeviceID() else { done(false, "No output device is connected"); return }
        guard device == request.device else { done(false, "Output changed during volume adjustment"); return }
        guard var property = Self.volumeProperty(device) else {
            if #available(macOS 14.2, *) {
                let uid = Self.string(device, kAudioDevicePropertyDeviceUID)
                let current = Double(Self.softwareGain(uid: uid)) * 100
                let target = min(100, max(0, request.absolute ? request.value : current + request.value))
                UserDefaults.standard.set(target / 100, forKey: "AOMAudioDeviceGain_\(uid)")
                AppAudioEngine.shared.syncActiveProcesses()
                done(true, "Software output volume: \(Int(target))%")
            } else { done(false, "Software output volume requires macOS 14.2 or newer") }
            return
        }
        guard device == request.device, let initial = Self.currentVolume() else {
            done(false, "Output changed during volume adjustment"); return
        }
        let delta = request.absolute ? request.value - Double(initial) * 100 : request.value
        // 0% is also hardware-mute on many macOS outputs. Unmute first so the
        // subsequent scalar write is applied rather than silently ignored.
        guard Self.clearMuteForVolumeIncrease(device: device, delta: request.absolute && request.value > 0 ? max(delta, 0.001) : delta) else {
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
        let previousUID = Self.currentDeviceID().flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
        let done: (Bool, String) -> Void = { success, message in
            if success, let applied = Self.currentDeviceID().flatMap({ Self.string($0, kAudioDevicePropertyDeviceUID) }) {
                AudioOutputRestore.record(previousUID: previousUID, appliedUID: applied)
            }
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
        guard percent.isFinite, (0...100).contains(percent) else { completion(false); return }
        volumeRequests.append(VolumeRequest(value: percent, absolute: true,
                                            device: Self.currentDeviceID(), completion: completion))
        if !changingVolume { changingVolume = true; applyNextVolumeChange() }
    }

    static func isOutputMuted() -> Bool {
        guard let device = currentDeviceID() else { return false }
        return currentMuteState(device) ?? ((currentVolume() ?? 1) == 0)
    }

    /// Mute is independent of the volume fader. Devices without a mute switch
    /// restore their last nonzero level, keyed by the physical device UID.
    func toggleOutputMute(completion: @escaping (Bool) -> Void) {
        guard let device = Self.currentDeviceID() else { completion(false); return }
        let muteProperties = Self.outputMuteProperties(device)
        if !muteProperties.isEmpty, let muted = Self.currentMuteState(device) {
            var value: UInt32 = muted ? 0 : 1
            var ok = true
            for var property in muteProperties {
                ok = AudioObjectSetPropertyData(device, &property, 0, nil, 4, &value) == noErr && ok
            }
            completion(ok)
            return
        }
        guard let volume = Self.currentVolume() else { completion(false); return }
        let key = "AOMAudioOutputUnmute_" + Self.string(device, kAudioDevicePropertyDeviceUID)
        if volume > 0 {
            UserDefaults.standard.set(Double(volume), forKey: key)
            setVolume(percent: 0, completion: completion)
        } else {
            let saved = UserDefaults.standard.object(forKey: key) as? Double ?? 0.5
            setVolume(percent: max(1, min(100, saved * 100)), completion: completion)
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    static func currentInputDeviceID() -> AudioDeviceID? {
        defaultInputDeviceID()
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
        if properties.isEmpty {
            guard let current = currentInputVolume() else { return nil }
            let key = "AOMAudioInputUnmute_" + string(device, kAudioDevicePropertyDeviceUID)
            if current > 0 {
                UserDefaults.standard.set(Double(current), forKey: key)
                return setInputVolume(percent: 0) ? true : nil
            }
            let saved = UserDefaults.standard.object(forKey: key) as? Double ?? 0.8
            return setInputVolume(percent: max(1, min(100, saved * 100))) ? false : nil
        }
        var first: UInt32 = 0; var size = UInt32(MemoryLayout.size(ofValue: first))
        guard AudioObjectGetPropertyData(device, &properties[0], 0, nil, &size, &first) == noErr else { return nil }
        var next: UInt32 = first == 0 ? 1 : 0
        var ok = true
        for index in properties.indices {
            ok = AudioObjectSetPropertyData(device, &properties[index], 0, nil, UInt32(MemoryLayout.size(ofValue: next)), &next) == noErr && ok
        }
        return ok ? next != 0 : nil
    }

    // MARK: - Input Device Discovery & Control

    static func inputDevices() -> [AudioOutputDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devs.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return devs.compactMap { id in
            var input = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("com.kyw.allofmacos.tap.") else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName))
        }
    }

    static func selectInput(uid: String) {
        guard let device = inputDevices().first(where: { $0.uid == uid }) else { return }
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                       UInt32(MemoryLayout.size(ofValue: id)), &id)
    }

    private static func inputVolumeProperties(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var result: [AudioObjectPropertyAddress] = []
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var p = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput)
            p.mElement = element
            var writable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &p, &writable) == noErr, writable.boolValue else { continue }
            if element == kAudioObjectPropertyElementMain { return [p] }
            result.append(p)
        }
        return result
    }
    static func canAdjustInputVolume() -> Bool {
        guard let device = defaultInputDeviceID() else { return false }
        return !inputVolumeProperties(device).isEmpty
    }
    static func canMuteInput() -> Bool {
        guard let device = defaultInputDeviceID() else { return false }
        return !inputMuteProperties(device).isEmpty || !inputVolumeProperties(device).isEmpty
    }
    static func currentInputVolume() -> Float32? {
        guard let device = defaultInputDeviceID() else { return nil }
        var total: Float = 0
        let properties = inputVolumeProperties(device)
        guard !properties.isEmpty else { return nil }
        for var p in properties {
            var value: Float32 = 0, size: UInt32 = 4
            guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
            total += value
        }
        return total / Float(properties.count)
    }
    @discardableResult
    static func setInputVolume(percent: Double) -> Bool {
        guard percent.isFinite, (0...100).contains(percent), let device = defaultInputDeviceID() else { return false }
        let properties = inputVolumeProperties(device)
        guard !properties.isEmpty else { return false }
        var value = Float32(percent / 100)
        var ok = true
        for var p in properties { ok = AudioObjectSetPropertyData(device, &p, 0, nil, 4, &value) == noErr && ok }
        return ok
    }

    static func isInputMuted() -> Bool {
        guard let device = defaultInputDeviceID() else { return false }
        let props = inputMuteProperties(device)
        guard var first = props.first else { return currentInputVolume() == 0 }
        var value: UInt32 = 0
        var size: UInt32 = 4
        guard AudioObjectGetPropertyData(device, &first, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    // MARK: - System Alert Sounds Volume

    static func currentSystemAlertVolume() -> Float32? {
        // The system alert scalar is NOT the volume of the system-output
        // hardware device, which is often the very same device as music.
        var error: NSDictionary?
        let value = NSAppleScript(source: "alert volume of (get volume settings)")?.executeAndReturnError(&error)
        guard error == nil, let value else { return nil }
        return Float32(value.int32Value) / 100
    }

    @discardableResult
    static func setSystemAlertVolume(percent: Double) -> Bool {
        guard percent.isFinite, (0...100).contains(percent) else { return false }
        var error: NSDictionary?
        NSAppleScript(source: "set volume alert volume \(Int(percent.rounded()))")?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Stereo Balance

    static func currentBalance() -> Float32 {
        guard let device = currentDeviceID() else { return 0 }
        var propLeft = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: 1)
        var propRight = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                   mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: 2)
        var left: Float32 = 1, right: Float32 = 1
        var size: UInt32 = 4
        _ = AudioObjectGetPropertyData(device, &propLeft, 0, nil, &size, &left)
        _ = AudioObjectGetPropertyData(device, &propRight, 0, nil, &size, &right)
        let peak = max(left, right)
        guard peak > 0.001 else { return 0 }
        return (right - left) / peak
    }

    static func setBalance(_ balance: Float32) {
        guard balance.isFinite, let device = currentDeviceID() else { return }
        var lp = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        lp.mElement = 1
        var rp = lp; rp.mElement = 2
        var oldLeft: Float32 = 0, oldRight: Float32 = 0, size: UInt32 = 4
        guard AudioObjectGetPropertyData(device, &lp, 0, nil, &size, &oldLeft) == noErr,
              AudioObjectGetPropertyData(device, &rp, 0, nil, &size, &oldRight) == noErr else { return }
        let master = max(oldLeft, oldRight)
        let clamped = max(-1, min(1, balance))
        var left = master * (clamped < 0 ? 1 : max(0, 1 - clamped))
        var right = master * (clamped > 0 ? 1 : max(0, 1 + clamped))
        var propLeft = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: 1)
        var propRight = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                   mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: 2)
        _ = AudioObjectSetPropertyData(device, &propLeft, 0, nil, 4, &left)
        _ = AudioObjectSetPropertyData(device, &propRight, 0, nil, 4, &right)
    }
}
