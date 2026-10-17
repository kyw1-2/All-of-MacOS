import AppKit
import Foundation

/// Other apps that register the same global hotkey as an AOM built-in.
///
/// Hotkeys registered with the system (Paste, many clipboard managers) are
/// delivered to their owner before any event tap sees the key, so AOM never
/// receives it: the other app's window flashes instead and the shelf does
/// not open. This finds such conflicts so the user can resolve them.
enum ShortcutConflicts {
    struct Conflict: Equatable {
        let appName: String
        let bundleID: String
        let shortcut: KeyboardShortcut
    }

    /// Known apps whose activation shortcut lives in their preferences as
    /// `{"keyCode":…, "internalModifiers":…}` JSON (Paste 4–7).
    private static let knownApps: [(bundleID: String, key: String)] = [
        ("com.wiheads.paste", "activationShortcut"),
        ("com.wiheads.paste-setapp", "activationShortcut"),
    ]

    static func clipboardHistoryConflict(
        shortcut: KeyboardShortcut? = MainActor.assumeIsolated { ClipboardShortcuts.shared.shortcut(for: .history) },
        running: [NSRunningApplication] = NSWorkspace.shared.runningApplications,
        preference: (String, String) -> Data? = { key, app in
            CFPreferencesCopyAppValue(key as CFString, app as CFString) as? Data
        }
    ) -> Conflict? {
        guard let shortcut else { return nil }
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for app in knownApps {
            guard let process = running.first(where: { $0.bundleIdentifier == app.bundleID && !$0.isTerminated }),
                  let data = preference(app.key, app.bundleID),
                  let other = decode(data) else { continue }
            if other.keyCode == shortcut.keyCode,
               other.modifiers.intersection(mask) == shortcut.modifiers.intersection(mask) {
                return Conflict(appName: process.localizedName ?? "Paste", bundleID: app.bundleID, shortcut: shortcut)
            }
        }
        return nil
    }

    static func decode(_ data: Data) -> KeyboardShortcut? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyCode = object["keyCode"] as? Int else { return nil }
        let raw = (object["internalModifiers"] as? Int) ?? (object["modifiers"] as? Int) ?? 0
        return KeyboardShortcut(keyCode: UInt16(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(raw)))
    }

    /// The alternative AOM offers when the default is taken.
    static let alternativeHistoryShortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])

    /// Asks once per conflicting app (and again if the user changes either
    /// shortcut back into a clash).
    @MainActor
    static func resolveIfNeeded() {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview,
              let conflict = clipboardHistoryConflict() else { return }
        let key = "AOMShortcutConflictDismissed_\(conflict.bundleID)_\(conflict.shortcut.displayString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let alert = NSAlert()
        alert.messageText = "\(conflict.appName) is also using \(conflict.shortcut.displayString)"
        alert.informativeText = "macOS gives this shortcut to \(conflict.appName), so the All of MacOS clipboard shelf can't open with it and \(conflict.appName)'s window appears instead.\n\nChoose a different shortcut for All of MacOS, or quit \(conflict.appName)."
        alert.addButton(withTitle: "Use \(alternativeHistoryShortcut.displayString) for All of MacOS")
        alert.addButton(withTitle: "Quit \(conflict.appName)")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ClipboardShortcuts.shared.setShortcut(alternativeHistoryShortcut, for: .history)
            GestureHUD.shared.show(title: "Clipboard Shortcut", detail: "Open the shelf with \(alternativeHistoryShortcut.displayString)")
        case .alertSecondButtonReturn:
            NSRunningApplication.runningApplications(withBundleIdentifier: conflict.bundleID).forEach { $0.terminate() }
        default:
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
