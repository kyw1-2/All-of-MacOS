import Foundation
import AppKit
import CoreAudio
import CoreWLAN
import IOKit
import IOKit.ps
import IOKit.usb
import IOBluetooth
import Combine

// MARK: - Signals

/// A normalized system event. Live providers translate OS callbacks into these;
/// tests construct them directly, so no real sleep / USB / Bluetooth / Wi-Fi is
/// ever involved in verification.
enum SystemSignal: Equatable {
    case hid(vendorID: Int, productID: Int, usagePage: Int, usage: Int, value: Int)
    case midi(device: String, status: Int, channel: Int, number: Int, value: Int)
    /// Force Touch pressure as AppKit reports it: stage 0 (none), 1 (click)
    /// or 2 (deep press), and the pressure within that stage (0…1).
    case forceTouch(stage: Int, pressure: Double)
    case gamepad(device: String, control: String, pressed: Bool)
    case willSleep, didWake
    case appActivated(bundleID: String)
    case appDeactivated(bundleID: String)
    case screensaver(started: Bool)
    case spaceChanged
    /// Current charge 0...100 (a reading, not a transition).
    case battery(percent: Int)
    /// Current SSID; "" = connected but the name is unreadable (no Location
    /// permission); nil = not connected. A reading, not a transition.
    case wifi(ssid: String?)
    case usb(name: String, connected: Bool)
    case bluetooth(name: String, connected: Bool)
    case inputSourceChanged
    case audioOutputChanged
    case clipboardChanged
    case fileChanged(path: String)
    case variable(name: String, value: String)
    /// Pointer position in AppKit screen coordinates (origin bottom-left).
    case pointer(CGPoint)
}

/// The independent OS observers a set of triggers needs. A preset only pays for
/// the sources its triggers actually use.
enum SignalSource: Hashable {
    case midi, gamepad, forceTouch
    case hid(Set<GenericHIDFilter>)
    case sleepWake, appFocus, screensaver, space, battery, wifi, usb, bluetooth
    case inputSource, audioOutput, clipboard, variables, pointer
    case files(Set<String>)

    /// The sources required by a collection of trigger kinds.
    static func needs(for kinds: [SystemTriggerKind]) -> Set<SignalSource> {
        var out = Set<SignalSource>()
        var paths = Set<String>()
        var hidFilters = Set<GenericHIDFilter>()
        for kind in kinds {
            switch kind {
            case .hidInput(let vendor, let product, _, _, _, _):
                if (1...65535).contains(vendor), (1...65535).contains(product) { hidFilters.insert(GenericHIDFilter(vendorID: vendor, productID: product)) }
            case .midiMessage: out.insert(.midi)
            case .forceTouchStage: out.insert(.forceTouch)
            case .gamepadButton: out.insert(.gamepad)
            case .systemWillSleep, .systemDidWake: out.insert(.sleepWake)
            case .appActivated, .appDeactivated: out.insert(.appFocus)
            case .screensaverStarted, .screensaverStopped: out.insert(.screensaver)
            case .activeSpaceChanged: out.insert(.space)
            case .batteryBelow, .batteryAbove: out.insert(.battery)
            case .wifiConnected, .wifiDisconnected: out.insert(.wifi)
            case .usbConnected, .usbDisconnected: out.insert(.usb)
            case .bluetoothConnected, .bluetoothDisconnected: out.insert(.bluetooth)
            case .inputSourceChanged: out.insert(.inputSource)
            case .audioOutputChanged: out.insert(.audioOutput)
            case .clipboardChanged: out.insert(.clipboard)
            case .variableChanged: out.insert(.variables)
            case .screenCornerHover, .screenEdgeHover: out.insert(.pointer)
            case .fileDidChange(let path):
                if let normalized = TriggerSystemPaths.normalized(path) { paths.insert(normalized) }
            default: break
            }
        }
        if !paths.isEmpty { out.insert(.files(paths)) }
        if !hidFilters.isEmpty { out.insert(.hid(hidFilters)) }
        return out
    }
}

enum TriggerSystemPaths {
    /// Absolute, symlink-free path, or nil when the input is not an absolute path.
    static func normalized(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~"), !trimmed.contains("\0") else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Starts and stops OS observers. The monitor owns exactly one.
protocol SystemSignalProvider: AnyObject {
    func start(_ needs: Set<SignalSource>, emit: @escaping (SystemSignal) -> Void)
    func stop()
}

// MARK: - Pure matching

enum SystemSignalMatcher {
    /// Case-insensitive substring filter; an empty filter matches everything.
    static func nameMatches(_ filter: String, _ name: String) -> Bool {
        let wanted = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.hasPrefix("regex:") { return regexMatches(String(wanted.dropFirst(6)), name) }
        return wanted.isEmpty || name.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func networkMatches(_ filter: String, _ name: String) -> Bool {
        if filter.hasPrefix("regex:") { return regexMatches(String(filter.dropFirst(6)), name) }
        return filter.isEmpty || filter.caseInsensitiveCompare(name) == .orderedSame
    }
    private static func regexMatches(_ pattern: String, _ name: String) -> Bool {
        guard pattern.count <= 256, name.count <= 1024,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// MIDI matching for discrete triggers and value bindings alike. A
    /// negative number matches any note, controller or program; Channel
    /// Pressure and Pitch Bend have no number; Program Change has no value
    /// range. Value bindings pass `checkValue: false`, because their input
    /// range, not the trigger's value filter, decides what the value does.
    static func midiMatches(_ kind: SystemTriggerKind, device: String, status: Int, channel: Int,
                            number: Int, value: Int, checkValue: Bool = true) -> Bool {
        guard case .midiMessage(let filter, let wantedStatus, let wantedChannel, let wantedNumber, let low, let high) = kind,
              wantedStatus == status, wantedChannel == 0 || wantedChannel == channel,
              nameMatches(filter, device) else { return false }
        let type = MIDIMessageType(rawValue: status)
        if type?.hasNumber ?? true, wantedNumber >= 0, wantedNumber != number { return false }
        guard checkValue, type != .programChange else { return true }
        return (low...max(low, high)).contains(value)
    }

    /// Stateless match of a signal against a kind. Stateful kinds (battery
    /// thresholds, Wi-Fi transitions, variable changes, hover) are resolved by
    /// the monitor before it builds the signal it passes here.
    static func matches(_ kind: SystemTriggerKind, _ signal: SystemSignal) -> Bool {
        switch (kind, signal) {
        case (.hidInput(let vendor, let product, let page, let usage, let low, let high),
              .hid(let actualVendor, let actualProduct, let actualPage, let actualUsage, let value)):
            return vendor == actualVendor && product == actualProduct && page == actualPage && usage == actualUsage && (low...max(low, high)).contains(value)
        case (.midiMessage, .midi(let device, let status, let channel, let number, let value)):
            return midiMatches(kind, device: device, status: status, channel: channel, number: number, value: value)
        case (.gamepadButton(let filter, let control, let pressed), .gamepad(let device, let actualControl, let actualPressed)):
            return nameMatches(filter, device) && control == actualControl && pressed == actualPressed
        case (.systemWillSleep, .willSleep), (.systemDidWake, .didWake): return true
        case (.appActivated(let id), .appActivated(let actual)): return id.isEmpty || id == actual
        case (.appDeactivated(let id), .appDeactivated(let actual)): return id.isEmpty || id == actual
        case (.screensaverStarted, .screensaver(let started)): return started
        case (.screensaverStopped, .screensaver(let started)): return !started
        case (.activeSpaceChanged, .spaceChanged), (.inputSourceChanged, .inputSourceChanged),
             (.audioOutputChanged, .audioOutputChanged), (.clipboardChanged, .clipboardChanged): return true
        case (.usbConnected(let f), .usb(let n, true)), (.usbDisconnected(let f), .usb(let n, false)): return nameMatches(f, n)
        case (.bluetoothConnected(let f), .bluetooth(let n, true)),
             (.bluetoothDisconnected(let f), .bluetooth(let n, false)): return nameMatches(f, n)
        case (.fileDidChange(let path), .fileChanged(let changed)):
            return TriggerSystemPaths.normalized(path) == changed
        default: return false
        }
    }
}

/// Tracks stateful readings and reports only transitions, so a trigger fires
/// when something *changes* rather than on every reading.
struct SystemTransitionTracker {
    private var belowState: [UUID: Bool] = [:]
    private var aboveState: [UUID: Bool] = [:]
    private var lastSSID: String??
    private var variableValues: [String: String] = [:]

    mutating func reset() { self = SystemTransitionTracker() }

    /// Ids whose battery rule just became true. The first reading only records
    /// the baseline, so launching AOM at 15% does not fire "below 20%".
    mutating func batteryTransitions(percent: Int, entries: [(id: UUID, kind: SystemTriggerKind)]) -> [UUID] {
        var fired: [UUID] = []
        for entry in entries {
            switch entry.kind {
            case .batteryBelow(let limit):
                let now = percent < limit
                if let was = belowState[entry.id], !was, now { fired.append(entry.id) }
                belowState[entry.id] = now
            case .batteryAbove(let limit):
                let now = percent > limit
                if let was = aboveState[entry.id], !was, now { fired.append(entry.id) }
                aboveState[entry.id] = now
            default: break
            }
        }
        return fired
    }

    enum WiFiTransition: Equatable { case connected(ssid: String), disconnected(ssid: String) }

    /// Converts a Wi-Fi reading into connect/disconnect events. `ssid` "" means
    /// connected to an unreadable network; nil means not connected. The first
    /// reading is only a baseline. Switching networks reports a disconnect from
    /// the old one followed by a connect to the new one.
    mutating func wifiTransitions(_ ssid: String?) -> [WiFiTransition] {
        defer { lastSSID = .some(ssid) }
        guard let previous = lastSSID, previous != ssid else { return [] }
        var events: [WiFiTransition] = []
        if let old = previous { events.append(.disconnected(ssid: old)) }
        if let new = ssid { events.append(.connected(ssid: new)) }
        return events
    }

    /// Records a variable assignment; true only when the value actually changed.
    mutating func variableChanged(name: String, value: String, seed: String?) -> Bool {
        let previous = variableValues[name] ?? seed
        variableValues[name] = value
        return previous != value
    }
    mutating func seedVariable(_ name: String, value: String?) { if let value { variableValues[name] = value } }
}

// MARK: - Screen hover

/// Corner / edge hover with dwell time. Pure: it is given pointer positions,
/// screen frames and timestamps.
struct ScreenHoverRecognizer {
    enum Zone: Hashable {
        case corner(ScreenCorner, dwellMs: Int)
        case edge(ScreenEdge, dwellMs: Int, minDistance: Int)
    }
    /// Corner hot square, in px. Corners are generous because overshoot is the norm.
    static let cornerSize: CGFloat = 6

    private let zones: Set<Zone>
    private var since: [Zone: TimeInterval] = [:]
    private var fired = Set<Zone>()

    init(zones: Set<Zone>) { self.zones = zones }

    var nextDeadline: TimeInterval? {
        since.filter { !fired.contains($0.key) }.map { $0.value + Self.dwell($0.key) }.min()
    }
    static func dwell(_ zone: Zone) -> TimeInterval {
        switch zone {
        case .corner(_, let ms), .edge(_, let ms, _): return Double(max(0, ms)) / 1000
        }
    }

    /// Whether `point` is inside `zone` on any of `screens`.
    static func contains(_ zone: Zone, point: CGPoint, screens: [CGRect]) -> Bool {
        for frame in screens where frame.insetBy(dx: -1, dy: -1).contains(point) {
            let left = point.x - frame.minX, right = frame.maxX - point.x
            let bottom = point.y - frame.minY, top = frame.maxY - point.y
            let c = cornerSize
            let corners: [ScreenCorner: Bool] = [
                .topLeft: left <= c && top <= c, .topRight: right <= c && top <= c,
                .bottomLeft: left <= c && bottom <= c, .bottomRight: right <= c && bottom <= c]
            switch zone {
            case .corner(let corner, _):
                if corners[corner] == true { return true }
            case .edge(let edge, _, let distance):
                let d = CGFloat(min(max(distance, 0), 500))
                // Corners belong to corner triggers.
                if corners.values.contains(true) { continue }
                let near: Bool, probe: CGPoint
                switch edge {
                case .left: near = left <= d; probe = CGPoint(x: point.x - d - 2, y: point.y)
                case .right: near = right <= d; probe = CGPoint(x: point.x + d + 2, y: point.y)
                case .bottom: near = bottom <= d; probe = CGPoint(x: point.x, y: point.y - d - 2)
                case .top: near = top <= d; probe = CGPoint(x: point.x, y: point.y + d + 2)
                }
                // A border shared with another display is not the edge of the desktop.
                if near, !screens.contains(where: { $0 != frame && $0.contains(probe) }) { return true }
            }
        }
        return false
    }

    mutating func move(to point: CGPoint, screens: [CGRect], now: TimeInterval) {
        for zone in zones {
            if Self.contains(zone, point: point, screens: screens) {
                if since[zone] == nil { since[zone] = now }
            } else {
                since[zone] = nil; fired.remove(zone)
            }
        }
    }

    /// Zones whose dwell has elapsed; each fires once until the pointer leaves it.
    mutating func poll(now: TimeInterval) -> [Zone] {
        var out: [Zone] = []
        for (zone, start) in since where !fired.contains(zone) && now - start >= Self.dwell(zone) - 1e-6 {
            fired.insert(zone); out.append(zone)
        }
        return out
    }

    mutating func reset() { since.removeAll(); fired.removeAll() }
}

// MARK: - Live provider

/// Real OS observers. Each source is installed only when requested and removed
/// on `stop()`. Nothing here is exercised by tests (they inject a fake provider).
final class LiveSystemSignalProvider: SystemSignalProvider {
    private var emit: ((SystemSignal) -> Void)?
    private var hidMonitor: GenericHIDInputMonitor?
    private var midiMonitor: MIDIInputMonitor?
    private var forceTouchMonitor: ForceTouchPressureMonitor?
    private var gamepadMonitor: GamepadInputMonitor?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var defaultsToken: NSObjectProtocol?
    private var batterySource: CFRunLoopSource?
    private var wifiDelegate: WiFiDelegate?
    private final class USBContext {
        weak var provider: LiveSystemSignalProvider?
        let connected: Bool
        init(provider: LiveSystemSignalProvider, connected: Bool) { self.provider = provider; self.connected = connected }
    }
    private var usbContexts: [USBContext] = []
    private var usbPorts: [(IONotificationPortRef, [io_iterator_t])] = []
    private var bluetoothTokens: [IOBluetoothUserNotification] = []
    private var bluetoothDisconnectTokens: [String: IOBluetoothUserNotification] = [:]
    private var audioListener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var fileWatchers: [String: ResilientFileWatcher] = [:]
    private var clipboardSink: AnyCancellable?
    private var pointerMonitors: [Any] = []
    private var lastVariableSnapshot: [String: String] = [:]

    func start(_ needs: Set<SignalSource>, emit: @escaping (SystemSignal) -> Void) {
        stop()
        self.emit = emit
        for need in needs {
            switch need {
            case .hid(let filters):
                let monitor = GenericHIDInputMonitor(filters: filters) { [weak self] in self?.send($0) }; hidMonitor = monitor; monitor.start()
            case .midi:
                let monitor = MIDIInputMonitor { [weak self] in self?.send($0) }; midiMonitor = monitor; monitor.start()
            case .forceTouch:
                let monitor = ForceTouchPressureMonitor { [weak self] in self?.send($0) }; forceTouchMonitor = monitor; monitor.start()
            case .gamepad:
                let monitor = GamepadInputMonitor { [weak self] in self?.send($0) }; gamepadMonitor = monitor; monitor.start()
            case .sleepWake: observeSleepWake()
            case .appFocus: observeAppFocus()
            case .screensaver: observeScreensaver()
            case .space: observeSpace()
            case .battery: observeBattery()
            case .wifi: observeWiFi()
            case .usb: observeUSB()
            case .bluetooth: observeBluetooth()
            case .inputSource: observeInputSource()
            case .audioOutput: observeAudioOutput()
            case .clipboard: observeClipboard()
            case .variables: observeVariables()
            case .pointer: observePointer()
            case .files(let paths): paths.forEach(watch)
            }
        }
    }

    func stop() {
        hidMonitor?.stop(); hidMonitor = nil
        midiMonitor?.stop(); midiMonitor = nil
        forceTouchMonitor?.stop(); forceTouchMonitor = nil
        gamepadMonitor?.stop(); gamepadMonitor = nil
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspace.removeObserver); workspaceTokens.removeAll()
        distributedTokens.forEach(DistributedNotificationCenter.default().removeObserver); distributedTokens.removeAll()
        if let defaultsToken { NotificationCenter.default.removeObserver(defaultsToken); self.defaultsToken = nil }
        if let batterySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode); self.batterySource = nil }
        if let wifiDelegate { CWWiFiClient.shared().delegate = nil; try? CWWiFiClient.shared().stopMonitoringAllEvents(); _ = wifiDelegate; self.wifiDelegate = nil }
        for (port, iterators) in usbPorts { iterators.forEach { IOObjectRelease($0) }; IONotificationPortDestroy(port) }
        usbPorts.removeAll(); usbContexts.removeAll()
        bluetoothTokens.forEach { $0.unregister() }; bluetoothTokens.removeAll()
        bluetoothDisconnectTokens.values.forEach { $0.unregister() }; bluetoothDisconnectTokens.removeAll()
        if let (address, block) = audioListener {
            var a = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
            audioListener = nil
        }
        fileWatchers.values.forEach { $0.stop() }; fileWatchers.removeAll()
        clipboardSink = nil
        pointerMonitors.forEach(NSEvent.removeMonitor); pointerMonitors.removeAll()
        emit = nil
    }

    private func send(_ signal: SystemSignal) { emit?(signal) }

    // MARK: Workspace notifications

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.send(.willSleep) })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.send(.didWake) })
    }

    private func observeAppFocus() {
        let center = NSWorkspace.shared.notificationCenter
        func bundle(_ note: Notification) -> String? {
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        }
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let id = bundle(note) { self?.send(.appActivated(bundleID: id)) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let id = bundle(note) { self?.send(.appDeactivated(bundleID: id)) }
        })
    }

    private func observeSpace() {
        workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.send(.spaceChanged) })
    }

    private func observeScreensaver() {
        let center = DistributedNotificationCenter.default()
        distributedTokens.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in self?.send(.screensaver(started: true)) })
        distributedTokens.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in self?.send(.screensaver(started: false)) })
    }

    private func observeInputSource() {
        distributedTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main) { [weak self] _ in
                self?.send(.inputSourceChanged) })
    }

    // MARK: Battery

    static func batteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Swift.min(100, Swift.max(0, current * 100 / max))
        }
        return nil
    }

    private func observeBattery() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let provider = Unmanaged<LiveSystemSignalProvider>.fromOpaque(ctx).takeUnretainedValue()
            if let percent = LiveSystemSignalProvider.batteryPercent() { provider.send(.battery(percent: percent)) }
        }, context) else { return }
        let source = created.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batterySource = source
        if let percent = Self.batteryPercent() { send(.battery(percent: percent)) } // baseline
    }

    // MARK: Wi-Fi

    private final class WiFiDelegate: NSObject, CWEventDelegate {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
        func ssidDidChangeForWiFiInterface(withName interfaceName: String) { DispatchQueue.main.async(execute: onChange) }
        func linkDidChangeForWiFiInterface(withName interfaceName: String) { DispatchQueue.main.async(execute: onChange) }
    }

    private func observeWiFi() {
        let client = CWWiFiClient.shared()
        let report: () -> Void = { [weak self] in
            guard let interface = CWWiFiClient.shared().interface() else { self?.send(.wifi(ssid: nil)); return }
            // The SSID needs Location permission; without it a live link is
            // reported as connected-to-unknown ("") so "any network" works.
            if let ssid = interface.ssid() { self?.send(.wifi(ssid: ssid)) }
            else { self?.send(.wifi(ssid: interface.serviceActive() && interface.powerOn() ? "" : nil)) }
        }
        let delegate = WiFiDelegate(report)
        wifiDelegate = delegate
        client.delegate = delegate
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        report() // baseline
    }

    // MARK: USB (IOKit)

    private func observeUSB() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        var iterators: [io_iterator_t] = []
        for (notification, connected) in [(kIOFirstMatchNotification, true), (kIOTerminatedNotification, false)] {
            var iterator: io_iterator_t = 0
            let box = USBContext(provider: self, connected: connected)
            usbContexts.append(box)
            let matching = IOServiceMatching("IOUSBHostDevice")
            let status = IOServiceAddMatchingNotification(port, notification, matching, { ctx, iterator in
                guard let ctx else { return }
                let box = Unmanaged<USBContext>.fromOpaque(ctx).takeUnretainedValue()
                box.provider?.drain(iterator, connected: box.connected, emit: true)
            }, Unmanaged.passUnretained(box).toOpaque(), &iterator)
            guard status == KERN_SUCCESS else { continue }
            drain(iterator, connected: connected, emit: false) // arm; devices already attached are not "connects"
            iterators.append(iterator)
        }
        usbPorts.append((port, iterators))
    }

    private func drain(_ iterator: io_iterator_t, connected: Bool, emit shouldEmit: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard shouldEmit else { continue }
            var name = ""
            if let product = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { name = product }
            else {
                var buffer = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(service, &buffer)
                name = String(cString: buffer)
            }
            send(.usb(name: name, connected: connected))
        }
    }

    // MARK: Bluetooth (IOBluetooth)

    /// IOBluetooth aborts the process when the app has no Bluetooth usage
    /// description, so it is only touched when that key is present.
    static var bluetoothAvailable: Bool {
        !PresetManager.isRunningTests && !PresetManager.isUIPreview &&
            Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    private func observeBluetooth() {
        guard Self.bluetoothAvailable else {
            GestureLog.shared.logFromAnyThread("Bluetooth triggers need NSBluetoothAlwaysUsageDescription in Info.plist", level: .error)
            return
        }
        if let token = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothDeviceConnected(_:device:))) {
            bluetoothTokens.append(token)
        }
        // Devices connected before AOM started must also emit their disconnect.
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
            watchBluetoothDisconnect(device)
        }
    }

    private func watchBluetoothDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, bluetoothDisconnectTokens[address] == nil else { return }
        bluetoothDisconnectTokens[address] = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
    }

    @objc private func bluetoothDeviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? device.addressString ?? ""
        send(.bluetooth(name: name, connected: true))
        watchBluetoothDisconnect(device)
    }

    @objc private func bluetoothDeviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString { bluetoothDisconnectTokens.removeValue(forKey: address)?.unregister() }
        send(.bluetooth(name: device.name ?? device.addressString ?? "", connected: false))
    }

    // MARK: Audio output (CoreAudio)

    private func observeAudioOutput() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.send(.audioOutputChanged) }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            audioListener = (address, block)
        }
    }

    // MARK: Clipboard (via ClipboardStore, not a second pasteboard poll)

    private func observeClipboard() {
        var newest = Date.distantPast
        clipboardSink = MainActor.assumeIsolated {
            let store = ClipboardStore.shared
            newest = store.entries.first?.lastCopiedAt ?? .distantPast
            return store.$entries.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] entries in
                // Deleting or pinning never advances the newest copy time; a capture does.
                guard let latest = entries.first?.lastCopiedAt, latest > newest else { return }
                newest = latest
                self?.send(.clipboardChanged)
            }
        }
    }

    // MARK: Variables (UserDefaults diff, so every WorkflowVariables writer is seen)

    private func observeVariables() {
        lastVariableSnapshot = Self.variableSnapshot()
        defaultsToken = NotificationCenter.default.addObserver(forName: WorkflowVariables.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let now = Self.variableSnapshot()
            for (name, value) in now where self.lastVariableSnapshot[name] != value { self.send(.variable(name: name, value: value)) }
            self.lastVariableSnapshot = now
        }
    }
    static func variableSnapshot() -> [String: String] {
        WorkflowVariables.snapshot()
    }

    // MARK: Files

    private func watch(_ path: String) {
        guard fileWatchers[path] == nil else { return }
        let watcher = ResilientFileWatcher(path: path) { [weak self] in self?.send(.fileChanged(path: path)) }
        fileWatchers[path] = watcher; watcher.start()
    }

    // MARK: Pointer

    private func observePointer() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.send(.pointer(NSEvent.mouseLocation))
        } { pointerMonitors.append(monitor) }
    }
}
