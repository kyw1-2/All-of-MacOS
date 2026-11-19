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

    func stop() {
        unregister()
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
            guard read == noErr, id.signature == 0x414F_4D4C, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { manager.onTrigger?() } }
            return noErr
        }, 1, &spec, context, &handlerRef)
        if result != noErr {
            GestureLog.shared.logFromAnyThread("Launcher hot key handler not installed (\(result))", level: .error)
        }
    }
}
