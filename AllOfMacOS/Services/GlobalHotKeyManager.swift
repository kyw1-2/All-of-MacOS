import AppKit
import Carbon.HIToolbox

/// The shortcut that opens ⌘K from any app (6.5, Raycast's launcher key).
/// ⌥Space by default; the others avoid macOS's own Space shortcuts
/// (⌃Space and ⌃⌥Space switch input sources, ⌘Space is Spotlight).
enum AOMLauncherShortcut: String, CaseIterable, Identifiable {
    case optionSpace, commandShiftSpace, optionCommandSpace, off

    static let defaultsKey = "AOMLauncherShortcut"

    var id: String { rawValue }

    static var current: AOMLauncherShortcut {
        get { AOMLauncherShortcut(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .optionSpace }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Carbon modifier mask, or nil when off.
    var carbonModifiers: UInt32? {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .optionCommandSpace: return UInt32(optionKey | cmdKey)
        case .off: return nil
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    var displayString: String {
        switch self {
        case .optionSpace: return "⌥Space"
        case .commandShiftSpace: return "⇧⌘Space"
        case .optionCommandSpace: return "⌥⌘Space"
        case .off: return "Off"
        }
    }

    /// Keycap parts for `AOMKeycap` rows.
    var keycaps: [String] {
        switch self {
        case .optionSpace: return ["⌥", "Space"]
        case .commandShiftSpace: return ["⇧", "⌘", "Space"]
        case .optionCommandSpace: return ["⌥", "⌘", "Space"]
        case .off: return []
        }
    }
}

/// A system-wide hot key through Carbon's `RegisterEventHotKey`: it needs no
/// Accessibility or Input Monitoring permission, works while AOM is in the
/// background or another app is full screen, and the key press is consumed,
/// so ⌥Space never types a non-breaking space into the front app.
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    /// What the last registration did, for Settings.
    enum Status: Equatable { case off, active, failed(OSStatus) }
    private(set) var status: Status = .off

    private let signature: OSType = 0x414F_4D4C // 'AOML'
    private let hotKeyNumber: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private init() {}

    func start(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        installHandler()
        apply(AOMLauncherShortcut.current)
    }

    /// Registers `shortcut` (or nothing for `.off`) and remembers it.
    @discardableResult
    func apply(_ shortcut: AOMLauncherShortcut) -> Status {
        AOMLauncherShortcut.current = shortcut
        unregister()
        guard let modifiers = shortcut.carbonModifiers else { status = .off; return status }
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, modifiers, EventHotKeyID(signature: signature, id: hotKeyNumber),
                                         GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref {
            hotKeyRef = ref
            status = .active
        } else {
            status = .failed(result)
            GestureLog.shared.logFromAnyThread("Launcher shortcut \(shortcut.displayString) not registered (\(result))", level: .error)
        }
        return status
    }

    // MARK: 7.23 Quick Entry (a second Carbon hot key, id 2)

    private var quickEntryRef: EventHotKeyRef?
    private var onQuickEntry: (() -> Void)?
    private(set) var quickEntryStatus: Status = .off

    func startQuickEntry(onTrigger: @escaping () -> Void) {
        onQuickEntry = onTrigger
        installHandler()
        applyQuickEntry(QuickEntryShortcut.current)
    }

    @discardableResult
    func applyQuickEntry(_ shortcut: QuickEntryShortcut) -> Status {
        QuickEntryShortcut.current = shortcut
        if let quickEntryRef { UnregisterEventHotKey(quickEntryRef); self.quickEntryRef = nil }
        guard let modifiers = shortcut.carbonModifiers else { quickEntryStatus = .off; return quickEntryStatus }
        if AOMLauncherShortcut.current != .off, AOMLauncherShortcut.current.carbonModifiers == modifiers,
           AOMLauncherShortcut.current.keyCode == shortcut.keyCode {
            quickEntryStatus = .failed(OSStatus(eventHotKeyExistsErr))
            return quickEntryStatus
        }
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, modifiers, EventHotKeyID(signature: signature, id: 2),
                                         GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref {
            quickEntryRef = ref
            quickEntryStatus = .active
        } else {
            quickEntryStatus = .failed(result)
            GestureLog.shared.logFromAnyThread("Quick Entry shortcut \(shortcut.displayString) not registered (\(result))", level: .error)
        }
        return quickEntryStatus
    }

    func stop() {
        unregister()
        if let quickEntryRef { UnregisterEventHotKey(quickEntryRef); self.quickEntryRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
        status = .off
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == 0x414F_4D4C, id.id == 1 || id.id == 2 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(context).takeUnretainedValue()
            let number = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { number == 2 ? manager.onQuickEntry?() : manager.onTrigger?() }
            }
            return noErr
        }, 1, &spec, context, &handlerRef)
        if result != noErr {
            GestureLog.shared.logFromAnyThread("Launcher hot key handler not installed (\(result))", level: .error)
        }
    }
}

extension AOMLauncherShortcut {
    /// 6.7 (report L5): the launcher's key is shown (empty launcher, menu bar
    /// panel) only while the registration really holds; a key another app
    /// took is not advertised as the way in.
    @MainActor static var isRegistered: Bool {
        current != .off && GlobalHotKeyManager.shared.status == .active
    }
}

/// 7.23: the Quick Entry key. ⌃⌥Space (the report's pick) is not offered:
/// macOS uses it to switch input sources, which Korean typing depends on.
enum QuickEntryShortcut: String, CaseIterable, Identifiable {
    case controlOptionN, optionShiftSpace, controlOptionJ, off

    static let defaultsKey = "AOMQuickEntryShortcut"
    var id: String { rawValue }

    static var current: QuickEntryShortcut {
        get { QuickEntryShortcut(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .controlOptionN }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .controlOptionN, .controlOptionJ: return UInt32(controlKey | optionKey)
        case .optionShiftSpace: return UInt32(optionKey | shiftKey)
        case .off: return nil
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlOptionN: return UInt32(kVK_ANSI_N)
        case .controlOptionJ: return UInt32(kVK_ANSI_J)
        case .optionShiftSpace, .off: return UInt32(kVK_Space)
        }
    }

    var displayString: String {
        switch self {
        case .controlOptionN: return "⌃⌥N"
        case .optionShiftSpace: return "⌥⇧Space"
        case .controlOptionJ: return "⌃⌥J"
        case .off: return "Off"
        }
    }
}

/// 7.23 (DeepSeek design reference §2.1, Things' three shortcut messages):
/// a shortcut that can't be used says what, why and what to do, in that order.
struct ShortcutClashMessage: Equatable {
    let title: String
    let why: String
    let fix: String

    static func make(_ shortcut: String, status: GlobalHotKeyManager.Status, launcher: String? = nil) -> ShortcutClashMessage? {
        guard case .failed(let code) = status else { return nil }
        let why: String
        if let launcher, code == OSStatus(eventHotKeyExistsErr) {
            why = "AOM's \(launcher) already uses it."
        } else if code == OSStatus(eventHotKeyExistsErr) {
            why = "Another app already registered it (Raycast, Alfred and ChatGPT often do)."
        } else {
            why = "macOS refused it (error \(code))."
        }
        return ShortcutClashMessage(title: "\(shortcut) can't be used", why: why, fix: "Pick another shortcut, or change it in the other app")
    }
}
