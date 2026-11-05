import AppKit
import CoreAudio

@objc private protocol AOMDisplayOSD {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func show(_ image: Int64, display: UInt32, priority: UInt32, fade: UInt32,
              filled: UInt32, total: UInt32, locked: Bool)
}

@MainActor
final class DisplayMediaKeys: NSObject {
    static let shared = DisplayMediaKeys()
    private let preference = "aom.externalDisplayMediaKeys"
    var enabled: Bool { UserDefaults.standard.bool(forKey: preference) }
    private var displays: [DisplayTarget] = []
    private var output: CGDirectDisplayID?
    private var outputUID: String?
    private var volumeByDisplay: [String: Float] = [:]
    private var beforeMute: [String: Float] = [:]
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed = Set<Int>()
    private var osd: NSXPCConnection?

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(reconfigure),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconfigure),
            name: NSWorkspace.didWakeNotification, object: nil)
        for name in [PermissionWatchdog.accessibilityLost, PermissionWatchdog.accessibilityRecovered] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateTap), name: name, object: nil)
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateOutput() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
        reconfigure()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            self.listener = nil
        }
        removeTap()
        MonitorControls.shared.reset(displays: []) {}
        osd?.invalidate()
        osd = nil
    }

    @objc func setEnabled(_ sender: NSMenuItem) {
        guard let requested = sender.representedObject as? Bool else { return }
        UserDefaults.standard.set(requested, forKey: preference)
        updateTap()
    }

    @objc private func reconfigure() {
        let next = DisplayControlService.displays().filter { !$0.isBuiltIn }
        for old in displays where !next.contains(where: { $0.displayID == old.displayID && $0.id == old.id }) {
            DisplayControlService.discardSoftwareDim(old.displayID)
        }
        displays = next
        output = nil
        MonitorControls.shared.reset(displays: next.map(\.displayID)) { [weak self] in
            self?.updateOutput()
            self?.updateTap()
        }
        updateTap()
    }

    private func updateOutput() {
        let currentDevice = AudioOutputService.currentDeviceID()
        defer { MonitorControls.shared.bindOutput(device: currentDevice ?? 0, display: output) }
        let previous = outputUID
        output = nil
        outputUID = nil
        guard let device = currentDevice else { return }
        let uid = AudioOutputRestore.uid(of: device)
        outputUID = uid
        let transport = AudioOutputRestore.transportType(of: device)
        guard transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort,
              AudioOutputService.volumeProperty(device) == nil else { return }
        let name = AudioOutputRestore.name(of: device)
        let matches = displays.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame || uid.localizedCaseInsensitiveContains($0.id) }
        let target = matches.count == 1 ? matches[0] : (displays.count == 1 ? displays[0] : nil)
        guard let target, MonitorControls.shared.level(target.displayID, .volume) != nil else { return }
        output = target.displayID
        if enabled, let previous, previous != uid, let last = volumeByDisplay[target.id] {
            setVolume(target, last, feedback: false)
        }
    }

    private func removeTap() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        pressed.removeAll()
    }

    @objc private func updateTap() {
        guard enabled, !displays.isEmpty, AXIsProcessTrusted() else { removeTap(); return }
        guard tap == nil else { return }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            MainActor.assumeIsolated {
                let keys = DisplayMediaKeys.shared
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    keys.pressed.removeAll()
                    if let tap = keys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let key = NSEvent(cgEvent: event), key.type == .systemDefined,
                          key.subtype.rawValue == 8, keys.handle(key) { return nil }
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: nil) else { return }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let key = (event.data1 >> 16) & 0xffff
        let state = (event.data1 >> 8) & 0xff
        if state == 0x0b { return pressed.remove(key) != nil }
        guard state == 0x0a, [0, 1, 2, 3, 7].contains(key),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              AutomationGate.allows(.keyboard) else { return false }
        if key == 2 || key == 3 {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  displays.contains(where: { $0.displayID == number.uint32Value }),
                  !DisplayControlService.hasNativeBrightness(number.uint32Value),
                  adjustBrightness(number.uint32Value, up: key == 2) else { return false }
        } else {
            guard let display = displays.first(where: { $0.displayID == output }),
                  let level = MonitorControls.shared.level(display.displayID, .volume) else { return false }
            if key == 7 && event.data1 & 1 != 0 { return pressed.contains(key) }
            let target: Float
            if key == 7 {
                if level > 0 { beforeMute[display.id] = level }
                target = level > 0 ? 0 : (beforeMute[display.id] ?? 0.25)
            } else {
                target = min(1, max(0, level + (key == 0 ? 1 : -1) / Float(16)))
            }
            guard setVolume(display, target, feedback: true) else { return false }
        }
        pressed.insert(key)
        return true
    }

    func setOutputVolume(device: UInt32, level: Float, completion: @escaping (Bool) -> Void) {
        guard AudioOutputService.currentDeviceID() == device,
              let target = displays.first(where: { $0.displayID == output }),
              MonitorControls.shared.outputLevel(device: device) != nil,
              setVolume(target, level, feedback: false, completion: completion) else {
            completion(false)
            return
        }
    }

    @discardableResult
    func setVolume(_ display: DisplayTarget, _ level: Float, feedback: Bool,
                   completion: ((Bool) -> Void)? = nil) -> Bool {
        MonitorControls.shared.request(display.displayID, .volume, level) { [weak self] result in
            let ok = result == .applied
            defer { completion?(ok) }
            guard let self, result != .cancelled else { return }
            AudioEventLog.shared.record(.displayVolume, source: display.id, value: Int64((level * 100).rounded()),
                                        detail: ok ? "DDC" : "DDC write failed")
            guard ok else { return }
            self.volumeByDisplay[display.id] = level
            if feedback { self.show(level > 0 ? 3 : 4, display.displayID, level) }
        }
    }

    private func adjustBrightness(_ id: CGDirectDisplayID, up: Bool) -> Bool {
        let gain = DisplayControlService.softwareDim(id) ?? 1
        let operation = MonitorBrightnessStep.next(hardware: MonitorControls.shared.level(id, .brightness),
                                                  gain: gain, up: up)
        switch operation {
        case .gamma(let next):
            guard DisplayControlService.setSoftwareDim(id, next) else { return false }
            show(1, id, next)
            return true
        case .brightness(let level):
            return DisplayControlService.setBrightness(id, level) { [weak self] ok in
                if ok { self?.show(1, id, level) }
            }
        }
    }

    private func show(_ image: Int64, _ id: CGDirectDisplayID, _ level: Float) {
        if osd == nil {
            let connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: AOMDisplayOSD.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                DispatchQueue.main.async { if self?.osd === connection { self?.osd = nil } }
            }
            osd = connection
            connection.resume()
        }
        let proxy = osd?.remoteObjectProxyWithErrorHandler { [weak connection = osd] _ in connection?.invalidate() }
        (proxy as? AOMDisplayOSD)?.show(image, display: id, priority: 500, fade: 1000,
            filled: UInt32((level * 100).rounded()), total: 100, locked: false)
    }
}
