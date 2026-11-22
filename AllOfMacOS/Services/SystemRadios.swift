import AppKit
import ApplicationServices
import CoreWLAN

/// 7.4: Bluetooth power and Airplane Mode (Wi-Fi and Bluetooth together).
/// Bluetooth's controller power is IOBluetooth's preference call, the one
/// blueutil uses; it is looked up at run time so a macOS without it only
/// makes the action fail.
enum AOMRadios {
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    private static let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private static let getPower: GetPower? = framework.flatMap { dlsym($0, "IOBluetoothPreferenceGetControllerPowerState") }
        .map { unsafeBitCast($0, to: GetPower.self) }
    private static let setPower: SetPower? = framework.flatMap { dlsym($0, "IOBluetoothPreferenceSetControllerPowerState") }
        .map { unsafeBitCast($0, to: SetPower.self) }

    static var bluetoothOn: Bool { (getPower?() ?? 0) != 0 }
    static var wifiOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }

    @discardableResult
    static func setBluetooth(_ on: Bool) -> Bool {
        guard let setPower else { return false }
        setPower(on ? 1 : 0)
        return true
    }

    static func setWiFi(_ on: Bool) -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return "no Wi-Fi interface" }
        do { try interface.setPower(on); return nil } catch { return "Wi-Fi: \(error.localizedDescription)" }
    }

    // MARK: Airplane Mode

    /// What was on when Airplane Mode went on and hasn't come back yet, so
    /// turning it off restores only those. A radio leaves the record only
    /// once it reads on again (7.5, Codex D02: a failed restore used to
    /// erase the record, and the retry then turned on a radio that had
    /// been off). Stored as `AOMAirplaneMode.v1`, the 7.4 format.
    struct Saved: Codable, Equatable {
        var wifi: Bool
        var bluetooth: Bool
    }

    static let savedKey = "AOMAirplaneMode.v1"

    static var saved: Saved? {
        get { UserDefaults.standard.data(forKey: savedKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: savedKey) }
            else { UserDefaults.standard.removeObject(forKey: savedKey) }
        }
    }

    /// The radios and the record, swapped for stand-ins in tests.
    struct Radios {
        var wifiOn: () -> Bool
        var bluetoothOn: () -> Bool
        var setWiFi: (Bool) -> String?
        var setBluetooth: (Bool) -> Bool
        var load: () -> Saved?
        var store: (Saved?) -> Void
        /// Waits between read-backs (a radio can take a moment to report its new state).
        var pause: (TimeInterval) -> Void

        static let live = Radios(wifiOn: { AOMRadios.wifiOn }, bluetoothOn: { AOMRadios.bluetoothOn },
                                 setWiFi: { AOMRadios.setWiFi($0) }, setBluetooth: { AOMRadios.setBluetooth($0) },
                                 load: { AOMRadios.saved }, store: { AOMRadios.saved = $0 },
                                 pause: { Thread.sleep(forTimeInterval: $0) })
    }

    /// How a change went, the same for the HUD, the log and the action's result.
    struct AirplaneOutcome: Equatable {
        var on: Bool
        /// "Wi-Fi", "Bluetooth": radios that didn't reach the state asked for.
        var pending: [String] = []
        var problems: [String] = []

        var succeeded: Bool { pending.isEmpty }
        var title: String {
            if succeeded { return on ? "Airplane Mode On" : "Airplane Mode Off" }
            return "\(pending.joined(separator: " and ")) Still \(on ? "On" : "Off")"
        }
        var detail: String? {
            guard !succeeded else { return nil }
            let again = on ? "Turn Airplane Mode on again to retry." : "Turn Airplane Mode off again to retry; only what was on comes back."
            return (problems.isEmpty ? "" : problems.joined(separator: "; ") + ". ") + again
        }
    }

    static var airplaneOn: Bool { isAirplaneOn(saved: saved, wifiOn: wifiOn, bluetoothOn: bluetoothOn) }

    /// Pure: Airplane Mode holds while a radio it turned off is still off
    /// (or, when both were already off, while both still are).
    static func isAirplaneOn(saved: Saved?, wifiOn: Bool, bluetoothOn: Bool) -> Bool {
        guard let saved else { return false }
        if !saved.wifi && !saved.bluetooth { return !wifiOn && !bluetoothOn }
        return (saved.wifi && !wifiOn) || (saved.bluetooth && !bluetoothOn)
    }

    /// Pure: which radios to turn on when Airplane Mode goes off. With no
    /// record (turned off by hand, or a fresh install) both come back.
    static func restore(from saved: Saved?) -> Saved { saved ?? Saved(wifi: true, bluetooth: true) }

    /// The longest a radio gets to report its new state.
    static let settleSeconds: TimeInterval = 3

    /// Runs off the main thread (the read-back waits up to `settleSeconds`).
    static func setAirplaneMode(_ on: Bool, radios: Radios = .live) -> AirplaneOutcome {
        var outcome = AirplaneOutcome(on: on)
        func settle(_ reads: () -> Bool, _ wanted: Bool) -> Bool {
            var waited: TimeInterval = 0
            while reads() != wanted, waited < settleSeconds { radios.pause(0.1); waited += 0.1 }
            return reads() == wanted
        }
        if on {
            let before = radios.load()
            let wifi = radios.wifiOn(), bluetooth = radios.bluetoothOn()
            // A radio still waiting to come back from the last time counts as on.
            let record = Saved(wifi: wifi || (before?.wifi ?? false), bluetooth: bluetooth || (before?.bluetooth ?? false))
            if before == nil || wifi || bluetooth { radios.store(record) }
            // Only radios that are on are switched (Gemini 7.5 review: a radio
            // that was already off doesn't count as turned off, and isn't asked).
            var turnedOff = 0
            if wifi {
                if let problem = radios.setWiFi(false) { outcome.problems.append(problem) }
                if settle(radios.wifiOn, false) { turnedOff += 1 } else { outcome.pending.append("Wi-Fi") }
            }
            if bluetooth {
                if !radios.setBluetooth(false) { outcome.problems.append("Bluetooth power isn't available") }
                if settle(radios.bluetoothOn, false) { turnedOff += 1 } else { outcome.pending.append("Bluetooth") }
            }
            // Nothing turned off: Airplane Mode didn't start, so nothing to restore.
            if turnedOff == 0, wifi || bluetooth { radios.store(before) }
        } else {
            var left = restore(from: radios.load())
            if left.wifi {
                if let problem = radios.setWiFi(true) { outcome.problems.append(problem) }
                if settle(radios.wifiOn, true) { left.wifi = false } else { outcome.pending.append("Wi-Fi") }
            }
            if left.bluetooth {
                if !radios.setBluetooth(true) { outcome.problems.append("Bluetooth power isn't available") }
                if settle(radios.bluetoothOn, true) { left.bluetooth = false } else { outcome.pending.append("Bluetooth") }
            }
            radios.store(left.wifi || left.bluetooth ? left : nil)
        }
        return outcome
    }

    private static let airplaneQueue = DispatchQueue(label: "aom.radios.airplane", qos: .userInitiated)

    /// One change at a time, off main; `done` on main. `on` nil toggles,
    /// decided on the queue so two quick presses don't both turn it on.
    static func setAirplaneModeInBackground(_ on: Bool?, done: @escaping @MainActor (AirplaneOutcome) -> Void) {
        airplaneQueue.async {
            let outcome = setAirplaneMode(on ?? !airplaneOn)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }
}

/// 7.4 (Raycast "Dismiss Notifications"): presses Close (or Clear All on a
/// stack) on every notification Notification Center shows, through
/// Accessibility. The buttons are custom actions named in the system
/// language, so both English and Korean names are matched.
enum NotificationDismisser {
    static let closeNames: Set<String> = ["close", "clear all", "clear", "닫기", "모두 지우기", "지우기"]

    /// Pure: "Name:Close\nTarget:0x0\nSelector:(null)" → "close"; a plain
    /// action name is returned lowercased.
    static func actionTitle(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("Name:") { name = String(name.dropFirst(5)) }
        if let end = name.firstIndex(of: "\n") { name = String(name[..<end]) }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Pure: the action to press among an element's actions, Clear All first.
    static func closeAction(in names: [String]) -> String? {
        let titled = names.map { ($0, actionTitle($0)) }
        if let all = titled.first(where: { $0.1 == "clear all" || $0.1 == "모두 지우기" }) { return all.0 }
        return titled.first { closeNames.contains($0.1) }?.0
    }

    /// Off the main thread: a run can take seconds with many notifications.
    static func dismissAllInBackground(_ completion: @escaping @MainActor (Result<Int, AOMAIError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = dismissAll()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    static func dismissAll() -> Result<Int, AOMAIError> {
        guard AXIsProcessTrusted() else {
            return .failure(AOMAIError(message: "Dismiss All Notifications needs Accessibility for AOM."))
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return .success(0)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        var closed = 0
        var last: AXUIElement?
        // Each press changes the tree, so it is read again after every one.
        // A notification that is still there after its press (a long close
        // animation, or one that won't close) gets one more wait, then the
        // run stops instead of pressing it again and again.
        for _ in 0..<60 {
            guard let (element, action) = firstClosable(in: root, depth: 0) else { break }
            if let last, CFEqual(last, element) {
                usleep(400_000)
                guard let again = firstClosable(in: root, depth: 0), !CFEqual(again.0, element) else { break }
                continue
            }
            guard AXUIElementPerformAction(element, action as CFString) == .success else { break }
            last = element
            closed += 1
            usleep(120_000)
        }
        return .success(closed)
    }

    private static func firstClosable(in element: AXUIElement, depth: Int) -> (AXUIElement, String)? {
        guard depth < 14 else { return nil }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String], let action = closeAction(in: list) {
            return (element, action)
        }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = firstClosable(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
