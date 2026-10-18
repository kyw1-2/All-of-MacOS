import AppKit
import IOKit
import IOKit.hid

/// Pure tables and planners for synthetic keyboard/mouse actions. Nothing here
/// touches the system, so the tests exercise it directly.
enum KeyCodes {
    static let pageUp: UInt16 = 116, pageDown: UInt16 = 121, home: UInt16 = 115, end: UInt16 = 119
    static let contextMenu: UInt16 = 110
    static let arrows: [String: UInt16] = ["left": 123, "right": 124, "down": 125, "up": 126]
    /// macOS only defines virtual key codes up to F20; F21–F24 have none.
    private static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                 105, 107, 113, 106, 64, 79, 80, 90]
    static func functionKey(_ number: Int) -> UInt16? {
        functionKeys.indices.contains(number - 1) ? functionKeys[number - 1] : nil
    }
}

/// Modifier keys as `flagsChanged` events: their key code and the flag they set.
enum ModifierKeys {
    struct Info: Equatable { let keyCode: UInt16; let flag: CGEventFlags }
    static let table: [String: Info] = [
        "command": Info(keyCode: 55, flag: .maskCommand), "rightCommand": Info(keyCode: 54, flag: .maskCommand),
        "shift": Info(keyCode: 56, flag: .maskShift), "rightShift": Info(keyCode: 60, flag: .maskShift),
        "option": Info(keyCode: 58, flag: .maskAlternate), "rightOption": Info(keyCode: 61, flag: .maskAlternate),
        "control": Info(keyCode: 59, flag: .maskControl), "rightControl": Info(keyCode: 62, flag: .maskControl),
        "fn": Info(keyCode: 63, flag: .maskSecondaryFn)]
    /// Flags to carry after `name` is pressed or released while `held` are down.
    static func flags(held: Set<String>) -> CGEventFlags {
        held.compactMap { table[$0]?.flag }.reduce(into: CGEventFlags()) { $0.insert($1) }
    }
}

/// Splits a scroll into events. A duration spreads the amount over ~60 Hz steps
/// so the remainder is never lost to integer division.
enum ScrollPlan {
    struct Step: Equatable { let vertical: Int32; let horizontal: Int32; let delayMs: Int }
    static let maxSteps = 600
    static func steps(direction: String, amount: Int, durationMs: Int) -> [Step]? {
        guard ActionParameterValidation.directions.contains(direction), amount > 0, durationMs >= 0 else { return nil }
        let count = durationMs == 0 ? 1 : min(maxSteps, max(1, durationMs / 16))
        let base = amount / count, remainder = amount % count
        let interval = count > 1 ? durationMs / count : 0
        return (0..<count).compactMap { index in
            let part = Int32(base + (index < remainder ? 1 : 0))
            guard part > 0 else { return nil }
            switch direction {
            case "up": return Step(vertical: part, horizontal: 0, delayMs: index == 0 ? 0 : interval)
            case "down": return Step(vertical: -part, horizontal: 0, delayMs: index == 0 ? 0 : interval)
            case "left": return Step(vertical: 0, horizontal: -part, delayMs: index == 0 ? 0 : interval)
            default: return Step(vertical: 0, horizontal: part, delayMs: index == 0 ? 0 : interval)
            }
        }
    }
}

/// Mouse buttons for Custom Click: 0 left, 1 right, 2 middle, higher = extra buttons.
enum ClickPlan {
    struct Spec: Equatable {
        let downType: CGEventType, upType: CGEventType, button: CGMouseButton, buttonNumber: Int64
    }
    static func spec(button: Int) -> Spec? {
        switch button {
        case 0: return Spec(downType: .leftMouseDown, upType: .leftMouseUp, button: .left, buttonNumber: 0)
        case 1: return Spec(downType: .rightMouseDown, upType: .rightMouseUp, button: .right, buttonNumber: 1)
        case 2...31: return Spec(downType: .otherMouseDown, upType: .otherMouseUp, button: .center, buttonNumber: Int64(button))
        default: return nil
        }
    }
    /// The fixed-modifier click actions, as (modifiers, click count).
    static func presetClick(_ type: ActionType) -> (flags: CGEventFlags, count: Int)? {
        switch type {
        case .ctrlLeftClick: return (.maskControl, 1)
        case .optionLeftClick: return (.maskAlternate, 1)
        case .shiftLeftClick: return (.maskShift, 1)
        case .cmdDoubleClick: return (.maskCommand, 2)
        default: return nil
        }
    }
    static func flags(from modifiers: UInt?) -> CGEventFlags {
        let ns = NSEvent.ModifierFlags(rawValue: modifiers ?? 0)
        var flags = CGEventFlags()
        if ns.contains(.command) { flags.insert(.maskCommand) }
        if ns.contains(.option) { flags.insert(.maskAlternate) }
        if ns.contains(.shift) { flags.insert(.maskShift) }
        if ns.contains(.control) { flags.insert(.maskControl) }
        if ns.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

/// Quotes a value for a single-quoted POSIX shell word.
enum ShellQuote {
    static func single(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A full copy of a pasteboard so Paste String can put the user's clipboard back.
struct PasteboardSnapshot: Equatable {
    var items: [[String: Data]]
    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type.rawValue] = data } }
            return entry
        })
    }
    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        return pasteboard.writeObjects(restored)
    }
}

/// The macOS shortcuts the Spaces / Mission Control actions rely on. Read-only:
/// `com.apple.symbolichotkeys` is only ever read, never written.
struct SymbolicHotKey: Equatable {
    let id: Int
    let keyCode: UInt16
    let flags: CGEventFlags
    let isEnabled: Bool
    /// False when the preference file has no entry and the macOS default applies.
    let isConfigured: Bool
}

enum SymbolicHotKeys {
    static let missionControl = 32, appWindows = 33, showDesktop = 36, spaceLeft = 79, spaceRight = 81
    static func desktop(_ number: Int) -> Int { 117 + number } // 118…126 = Desktop 1…9

    /// Defaults macOS applies when the user has never touched the shortcut.
    static func defaultKey(_ id: Int) -> SymbolicHotKey? {
        let control = CGEventFlags.maskControl.rawValue
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        func make(_ code: UInt16, _ flags: UInt64, _ enabled: Bool) -> SymbolicHotKey {
            SymbolicHotKey(id: id, keyCode: code, flags: CGEventFlags(rawValue: flags), isEnabled: enabled, isConfigured: false)
        }
        switch id {
        case missionControl: return make(126, control | fn, true)
        case appWindows: return make(125, control | fn, true)
        case showDesktop: return make(103, fn, true)
        case spaceLeft: return make(123, control | fn, true)
        case spaceRight: return make(124, control | fn, true)
        case 118...126:
            let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
            return make(digits[id - 118], control, false)
        default: return nil
        }
    }

    /// Resolves one shortcut from the `AppleSymbolicHotKeys` dictionary.
    static func hotKey(id: Int, in table: [String: Any]?) -> SymbolicHotKey? {
        guard let entry = table?[String(id)] as? [String: Any] else { return defaultKey(id) }
        let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let code = (parameters[1] as? NSNumber)?.intValue, (0...0xFFFF).contains(code),
              let flags = (parameters[2] as? NSNumber)?.uint64Value else {
            return defaultKey(id).map { SymbolicHotKey(id: id, keyCode: $0.keyCode, flags: $0.flags, isEnabled: enabled, isConfigured: true) }
        }
        return SymbolicHotKey(id: id, keyCode: UInt16(code), flags: CGEventFlags(rawValue: flags), isEnabled: enabled, isConfigured: true)
    }

    static func load() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    /// Shown once, the first time an action needs a shortcut that is switched off.
    static let hintShownKey = "AOMSpaceShortcutHintShown"
    static func hintText(for id: Int) -> String {
        "Turn this on in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, then try again."
        + (id >= 118 ? " (Switch to Desktop N)" : "")
    }
}

/// Posts events tagged so AOM's own monitors ignore them.
enum SyntheticInput {
    static let selfTag: Int64 = 0x475454

    @discardableResult
    static func post(_ event: CGEvent?, tap: CGEventTapLocation = .cgSessionEventTap) -> Bool {
        guard let event else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: selfTag)
        event.post(tap: tap)
        return true
    }

    @discardableResult
    static func key(_ code: UInt16, flags: CGEventFlags = [], tap: CGEventTapLocation = .cgSessionEventTap) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags; up.flags = flags
        post(down, tap: tap); post(up, tap: tap)
        return true
    }

    @discardableResult
    static func modifier(_ name: String, down: Bool, held: Set<String>) -> Bool {
        guard let info = ModifierKeys.table[name] else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: info.keyCode, keyDown: down) else { return false }
        event.type = .flagsChanged
        event.flags = ModifierKeys.flags(held: held)
        return post(event, tap: .cghidEventTap)
    }

    /// Toggles Caps Lock through the HID system. Posting a Caps Lock key event
    /// does not reliably latch the state on current macOS.
    @discardableResult
    static func toggleCapsLock() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return false }
        defer { IOServiceClose(connect) }
        var state = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else { return false }
        return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state) == KERN_SUCCESS
    }
}
