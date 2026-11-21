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

    /// What was on when Airplane Mode went on, so turning it off restores
    /// only those.
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

    static var airplaneOn: Bool { saved != nil && !wifiOn && !bluetoothOn }

    /// Pure: which radios to turn on when Airplane Mode goes off. With no
    /// record (turned off by hand, or a fresh install) both come back.
    static func restore(from saved: Saved?) -> Saved { saved ?? Saved(wifi: true, bluetooth: true) }

    /// Nil when every radio changed, else what didn't.
    static func setAirplaneMode(_ on: Bool) -> String? {
        var problems: [String] = []
        if on {
            if saved == nil || wifiOn || bluetoothOn { saved = Saved(wifi: wifiOn, bluetooth: bluetoothOn) }
            if let problem = setWiFi(false) { problems.append(problem) }
            if !setBluetooth(false) { problems.append("Bluetooth power isn't available") }
        } else {
            let back = restore(from: saved)
            if back.wifi, let problem = setWiFi(true) { problems.append(problem) }
            if back.bluetooth, !setBluetooth(true) { problems.append("Bluetooth power isn't available") }
            saved = nil
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
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
        // Each press changes the tree, so it is read again after every one.
        for _ in 0..<60 {
            guard let (element, action) = firstClosable(in: root, depth: 0) else { break }
            guard AXUIElementPerformAction(element, action as CFString) == .success else { break }
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
