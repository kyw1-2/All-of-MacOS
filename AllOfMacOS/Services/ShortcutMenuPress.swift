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
    static func character(for keyCode: UInt16) -> String? {
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

    /// Chooses the front app's menu command for this shortcut when a text
    /// field there has the focus. True when a command was chosen.
    static func pressIfTyping(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard AXIsProcessTrusted(), let modifiers = menuModifiers(flags), let character = character(for: keyCode),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focused = element(attribute(app, kAXFocusedUIElementAttribute)),
              let role = attribute(focused, kAXRoleAttribute) as? String, textRoles.contains(role),
              let bar = element(attribute(app, kAXMenuBarAttribute)) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        for barItem in (attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []).dropFirst() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            guard let menu = (attribute(barItem, kAXChildrenAttribute) as? [AXUIElement])?.first else { continue }
            for item in attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard matches(cmdChar: attribute(item, "AXMenuItemCmdChar") as? String,
                              cmdModifiers: (attribute(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                              character: character, modifiers: modifiers) else { continue }
                guard (attribute(item, kAXEnabledAttribute) as? Bool) != false else { return false }
                let ok = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                if ok {
                    let title = attribute(item, kAXTitleAttribute) as? String ?? "?"
                    GestureLog.shared.logFromAnyThread("Shortcut chose “\(title)” in \(front.localizedName ?? "the front app") (a text field had the focus)", level: .action)
                }
                return ok
            }
        }
        return false
    }
}
