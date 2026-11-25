import AppKit
import Carbon.HIToolbox

/// 7.20: the mouse's side buttons (button 3 = Back, 4 = Forward) work in apps
/// that only understand Back/Forward from the keyboard.
///
/// macOS delivers a side-button press to the app under the pointer, which
/// ignores it unless it handles "other mouse" buttons itself (browsers and
/// JetBrains IDEs do; Finder, VS Code, Xcode, Slack and most others don't).
/// AOM looks up the window under the pointer once (`CGWindowListCopyWindowInfo`),
/// and for an app on the list below sends that app's own Back/Forward keys to
/// its process, swallowing the click. Apps that handle the buttons, apps not
/// on the list, the desktop and secure text input all get the click untouched,
/// so an unknown editor never receives ⌘[ (outdent) by accident.
enum MouseNavigationAssist {
    static let enabledKey = "AOMMouseNavigationAssist"

    static var isEnabled: Bool {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return false }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Keys: Equatable {
        let back: (key: UInt16, flags: CGEventFlags)
        let forward: (key: UInt16, flags: CGEventFlags)
        static func == (a: Keys, b: Keys) -> Bool {
            a.back.key == b.back.key && a.back.flags == b.back.flags
                && a.forward.key == b.forward.key && a.forward.flags == b.forward.flags
        }
    }

    enum Policy: Equatable {
        /// The app handles the side buttons itself: leave the click alone.
        case native
        /// Send these keys instead of the click.
        case keys(Keys)
        /// Not known: leave the click alone.
        case unknown
    }

    private static let bracket = Keys(back: (UInt16(kVK_ANSI_LeftBracket), .maskCommand),
                                      forward: (UInt16(kVK_ANSI_RightBracket), .maskCommand))
    private static let controlMinus = Keys(back: (UInt16(kVK_ANSI_Minus), .maskControl),
                                           forward: (UInt16(kVK_ANSI_Minus), [.maskControl, .maskShift]))
    private static let xcode = Keys(back: (UInt16(kVK_LeftArrow), [.maskControl, .maskCommand]),
                                    forward: (UInt16(kVK_RightArrow), [.maskControl, .maskCommand]))
    private static let commandOptionArrows = Keys(back: (UInt16(kVK_LeftArrow), [.maskCommand, .maskAlternate]),
                                                  forward: (UInt16(kVK_RightArrow), [.maskCommand, .maskAlternate]))

    private static let nativeApps: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.naver.Whale", "org.chromium.Chromium",
    ]

    private static let keyedApps: [String: Keys] = [
        // ⌘[ / ⌘] is Back / Forward in their menus.
        "com.apple.finder": bracket, "com.apple.systempreferences": bracket, "com.apple.AppStore": bracket,
        "com.apple.Music": bracket, "com.apple.Dictionary": bracket, "com.apple.helpviewer": bracket,
        "com.tinyspeck.slackmacgap": bracket, "notion.id": bracket, "com.apple.Notes": bracket,
        // Editors where ⌘[ outdents: their own navigation keys.
        "com.microsoft.VSCode": controlMinus, "com.microsoft.VSCodeInsiders": controlMinus,
        "com.vscodium": controlMinus, "com.todesktop.230313mzl4w4u92": controlMinus,
        "com.exafunction.windsurf": controlMinus, "com.sublimetext.4": controlMinus,
        "com.apple.dt.Xcode": xcode,
        "md.obsidian": commandOptionArrows,
    ]

    static func policy(for bundleID: String?) -> Policy {
        guard let bundleID, !bundleID.isEmpty else { return .unknown }
        if nativeApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .native }
        if let keys = keyedApps[bundleID] { return .keys(keys) }
        return .unknown
    }

    /// The process that owns the frontmost normal window under `point`
    /// (global, top-left origin), skipping AOM's own windows. Nil over the
    /// desktop, the Dock or the menu bar.
    static func ownerPID(at point: CGPoint) -> pid_t? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    /// Called on a side-button press (3 or 4) with no modifiers and no user
    /// trigger for that button. True when AOM sent the app's keys and the
    /// click (and its release) must be swallowed.
    static func handle(button: Int, at point: CGPoint) -> Bool {
        guard isEnabled, (3...4).contains(button), !IsSecureEventInputEnabled(),
              let pid = ownerPID(at: point),
              let app = NSRunningApplication(processIdentifier: pid),
              case .keys(let keys) = policy(for: app.bundleIdentifier) else { return false }
        let stroke = button == 3 ? keys.back : keys.forward
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        send(key: stroke.key, flags: stroke.flags, to: frontmost ? nil : pid)
        GestureLog.shared.logFromAnyThread("mouse \(button == 3 ? "back" : "forward") → \(app.bundleIdentifier ?? "?")"
                                           + (frontmost ? "" : " (under the pointer)"), level: .action)
        return true
    }

    /// Posts the keystroke to the session (front app) or straight to a
    /// background app's process, tagged so AOM's own taps ignore it.
    private static func send(key: UInt16, flags: CGEventFlags, to pid: pid_t?) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
            if let pid { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
        }
    }
}

extension UserDefaults {
    /// KVO for the Settings switch, so the mouse monitor re-registers at once.
    @objc dynamic var AOMMouseNavigationAssist: Bool {
        object(forKey: MouseNavigationAssist.enabledKey) as? Bool ?? true
    }
}
