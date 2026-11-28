import AppKit
import ApplicationServices
import Carbon.HIToolbox

// AOM 7.11 (user report: "the Back gesture does nothing while the cursor is
// in a text field"). A Send Keyboard Shortcut action posts the keys to the
// front app, and a focused text field — or a web editor — gets them first and
// can keep ⌘[ for itself. When a text field has the focus and the front app
// has a menu command with that very shortcut (History › Back), AOM chooses
// that command through Accessibility instead, as a click on the menu would;
// otherwise the keys are posted as before.

enum ShortcutMenuPress {
    /// Roles that take typing.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Pure: AXMenuItemCmdModifiers for a ⌘ shortcut (bit 0 ⇧, 1 ⌥, 2 ⌃, 3 "no ⌘").
    static func menuModifiers(_ flags: NSEvent.ModifierFlags) -> Int? {
        guard flags.contains(.command) else { return nil }
        var value = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.option) { value |= 2 }
        if flags.contains(.control) { value |= 4 }
        return value
    }

    /// Pure: a menu item's shortcut matches when its character (any case) and
    /// modifiers are the same.
    static func matches(cmdChar: String?, cmdModifiers: Int?, character: String, modifiers: Int) -> Bool {
        guard let cmdChar, !cmdChar.isEmpty else { return false }
        return cmdChar.lowercased() == character.lowercased() && (cmdModifiers ?? 0) == modifiers
    }

    /// The key's character on an ASCII layout ("[" for kVK_ANSI_LeftBracket),
    /// whatever input source (Korean) is selected.
    ///
    /// 7.23 (crash 2026-11-28 10:20, 7.22.0): Text Input Sources must be read
    /// on the main queue. Back/Forward sent from the side buttons or a gesture
    /// ran this on the navigation-menu queue, and macOS 27's TSM asserted
    /// (`dispatch_assert_queue` → SIGTRAP) when the input source had changed
    /// since its last read — after 한/영 switching AOM quit on the next Back.
    static func character(for keyCode: UInt16) -> String? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { character(for: keyCode) }
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AOMMenuShelfProbe.attribute(element, name as CFString)
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    /// Web editors expose editable state independently of their AX role.
    static func isTypingRole(_ role: String?, editable: Bool, hasSelectionRange: Bool) -> Bool {
        if editable { return true }
        guard let role else { return false }
        if textRoles.contains(role) { return true }
        return ["AXWebArea", "AXGroup", "AXUnknown", "AXLayoutArea"].contains(role) && hasSelectionRange
    }

    /// For navigation shortcuts, prefer a menu command when the editor has
    /// focus. Do not broaden the behavior to every application or shortcut.
    static func isNavigationShortcut(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        [33, 30].contains(keyCode) && menuModifiers(flags) == 0 && !flags.contains(.function)
    }

    /// Chooses a menu command in the front app when a text field has focus.
    /// Bounded depth, work and AX timeout; no menu expansion or UI mutation.
    static func pressIfTyping(keyCode: UInt16, flags: NSEvent.ModifierFlags, expectedPID: pid_t? = nil) -> Bool {
        guard AXIsProcessTrusted(), let modifiers = menuModifiers(flags), let character = character(for: keyCode),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              expectedPID == nil || expectedPID == front.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        guard let focused = element(attribute(app, kAXFocusedUIElementAttribute)) else { return false }
        AXUIElementSetMessagingTimeout(focused, 0.08)
        let role = attribute(focused, kAXRoleAttribute) as? String
        let native = role.map { textRoles.contains($0) } ?? false
        if !native {
            guard isNavigationShortcut(keyCode, flags) else { return false }
            let editable = (attribute(focused, "AXEditable") as? Bool) == true
            let hasRange = attribute(focused, kAXSelectedTextRangeAttribute) != nil
            guard isTypingRole(role, editable: editable, hasSelectionRange: hasRange) else { return false }
        }
        // 7.24.1 (7.19 P0-3): the menu item found for this app and shortcut
        // within the last 10 s is pressed directly — still enabled and the app
        // still in front — instead of walking the menu bar again (up to 0.35 s).
        let cacheKey = MenuItemCache.Key(pid: front.processIdentifier, character: character.lowercased(), modifiers: modifiers)
        if let cached = MenuItemCache.shared.item(for: cacheKey, now: ProcessInfo.processInfo.systemUptime) {
            AXUIElementSetMessagingTimeout(cached, 0.08)
            if (attribute(cached, kAXEnabledAttribute) as? Bool) == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier,
               AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success {
                return true
            }
            MenuItemCache.shared.forget(cacheKey)
        }
        guard let bar = element(attribute(app, kAXMenuBarAttribute)) else { return false }
        AXUIElementSetMessagingTimeout(bar, 0.08)
        var remaining = 120
        func walk(_ node: AXUIElement, depth: Int) -> Bool {
            guard depth <= 4, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.08)
            if matches(cmdChar: attribute(node, "AXMenuItemCmdChar") as? String,
                       cmdModifiers: (attribute(node, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                       character: character, modifiers: modifiers),
               (attribute(node, kAXEnabledAttribute) as? Bool) == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier {
                let pressed = AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
                if pressed { MenuItemCache.shared.store(node, for: cacheKey, now: ProcessInfo.processInfo.systemUptime) }
                return pressed
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if walk(child, depth: depth + 1) { return true }
                if remaining <= 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
            }
            return false
        }
        for item in (attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []).dropFirst() {
            if walk(item, depth: 0) { return true }
            if remaining <= 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        return false
    }
}

/// 7.24.1: the menu items `pressIfTyping` found, per app and shortcut, for
/// 10 s. Thread-safe: presses come from the navigation queue and the main thread.
final class MenuItemCache: @unchecked Sendable {
    static let shared = MenuItemCache()
    static let lifetime: TimeInterval = 10

    struct Key: Hashable { let pid: pid_t; let character: String; let modifiers: Int }

    private let lock = NSLock()
    private var entries: [Key: (element: AXUIElement, storedAt: TimeInterval)] = [:]

    func item(for key: Key, now: TimeInterval) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard now - entry.storedAt < Self.lifetime else { entries[key] = nil; return nil }
        return entry.element
    }

    func store(_ element: AXUIElement, for key: Key, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if entries.count > 64 { entries = entries.filter { now - $0.value.storedAt < Self.lifetime } }
        entries[key] = (element, now)
    }

    func forget(_ key: Key) { lock.lock(); entries[key] = nil; lock.unlock() }
}
