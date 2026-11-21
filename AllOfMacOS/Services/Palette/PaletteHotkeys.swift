import AppKit
import Carbon.HIToolbox

// AOM 7.2 (Oracle report 05 §3-C, Raycast's command-hotkey-input): any
// launcher command, app, quicklink, script or snippet can get a key of its
// own from ⌘K › Set Hotkey…. The keys are Carbon hot keys like the
// launcher's ⌥Space (no Accessibility needed, consumed system-wide). A key
// another AOM shortcut, an automation or another app holds is refused with
// its owner's name, never registered twice.

struct PaletteHotkey: Codable, Hashable, Identifiable {
    var itemID: String
    /// The row's title when it was set: shown in lists, and typed into the
    /// launcher to find rows that exist only while searching.
    var title: String
    var keyCode: UInt16
    /// NSEvent.ModifierFlags (⌘⌥⌃⇧ only).
    var modifiers: UInt

    var id: String { itemID }
    var shortcut: KeyboardShortcut { KeyboardShortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)) }
    var display: String { shortcut.displayString }

    var carbonModifiers: UInt32 { PaletteHotkeyRules.carbonModifiers(NSEvent.ModifierFlags(rawValue: modifiers)) }
}

enum PaletteHotkeyRules {
    /// F1–F20.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    /// Esc, Return, Tab, Space, Delete and the arrows are never a hot key on their own.
    static let reservedBare: Set<UInt16> = [53, 36, 76, 48, 49, 51, 117, 123, 124, 125, 126]

    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Pure: a combination that cannot break typing — ⌘, ⌥ or ⌃ with a key
    /// (⇧ alone would take a capital letter), or a bare F-key.
    static func problem(with shortcut: KeyboardShortcut) -> String? {
        let flags = shortcut.modifiers.intersection(mask)
        if [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(shortcut.keyCode) { return "Press a key together with ⌘, ⌥ or ⌃" }
        if flags.isDisjoint(with: [.command, .option, .control]) {
            if functionKeys.contains(shortcut.keyCode), flags.isEmpty { return nil }
            return reservedBare.contains(shortcut.keyCode) || flags.isEmpty || flags == .shift
                ? "Use ⌘, ⌥ or ⌃ with the key so typing stays as it is" : nil
        }
        // ⌘Q, ⌘W, ⌘Tab, ⌘Space and ⌘H belong to every app or to macOS.
        if flags == .command, [12, 13, 48, 49, 4].contains(shortcut.keyCode) { return "\(shortcut.displayString) belongs to macOS or every app" }
        return nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func same(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.intersection(mask) == rhs.modifiers.intersection(mask)
    }

    /// The launcher's own key as a KeyboardShortcut (nil when off).
    static func launcherShortcut(_ choice: AOMLauncherShortcut = .current) -> KeyboardShortcut? {
        switch choice {
        case .optionSpace: return KeyboardShortcut(keyCode: 49, modifiers: [.option])
        case .commandShiftSpace: return KeyboardShortcut(keyCode: 49, modifiers: [.command, .shift])
        case .optionCommandSpace: return KeyboardShortcut(keyCode: 49, modifiers: [.option, .command])
        case .off: return nil
        }
    }
}

@MainActor
final class PaletteHotkeyStore: ObservableObject {
    static let shared = PaletteHotkeyStore()
    static let key = "AOMPaletteHotkeys.v1"

    enum Failure: Error, Equatable, LocalizedError {
        case unusable(String)
        case taken(String)
        case refused(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unusable(let reason): return reason
            case .taken(let owner): return "Already used by \(owner)"
            case .refused(let status):
                return status == OSStatus(eventHotKeyExistsErr) ? "Another app already uses this key" : "macOS refused the key (\(status))"
            }
        }
    }

    @Published private(set) var bindings: [PaletteHotkey] = []

    private let defaults: UserDefaults?
    private var refs: [String: EventHotKeyRef] = [:]
    private var numbers: [UInt32: String] = [:]
    private var handlerRef: EventHandlerRef?
    private var onFire: ((PaletteHotkey) -> Void)?
    private var suspended = false
    private let signature: OSType = 0x414F_4D48 // 'AOMH'

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = (PresetManager.isRunningTests || PresetManager.isUIPreview) ? nil : .standard
        }
        if let data = self.defaults?.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PaletteHotkey].self, from: data) {
            bindings = saved
        }
    }

    func binding(for itemID: String) -> PaletteHotkey? { bindings.first { $0.itemID == itemID } }

    /// Installs the handler and registers every saved key (at launch).
    func start(onFire: @escaping (PaletteHotkey) -> Void) {
        self.onFire = onFire
        installHandler()
        registerAll()
    }

    /// 7.3 (Codex 7.2.3 report, recommended feature 4): every place a key
    /// combination is used — the launcher, launcher rows, AOM's own
    /// shortcuts, automations (with the apps they are limited to) and the
    /// macOS Mission Control and Spaces keys AOM reads.
    struct Usage: Equatable, Identifiable {
        enum Kind: Equatable { case launcher, launcherRow(itemID: String), aomShortcut, automation(UUID), macOS }
        var kind: Kind
        var title: String
        /// "Every app", "Only in Safari", "In the Coding group".
        var scope: String
        var isEnabled = true
        var id: String { "\(kind)|\(title)" }
    }

    func usages(of shortcut: KeyboardShortcut, triggers: [Trigger], groups: [ActivationGroup] = []) -> [Usage] {
        var found: [Usage] = []
        if let launcher = PaletteHotkeyRules.launcherShortcut(), PaletteHotkeyRules.same(launcher, shortcut) {
            found.append(Usage(kind: .launcher, title: "Opens the launcher", scope: "Every app"))
        }
        for binding in bindings where PaletteHotkeyRules.same(binding.shortcut, shortcut) {
            found.append(Usage(kind: .launcherRow(itemID: binding.itemID), title: "Launcher: \(binding.title)", scope: "Every app"))
        }
        if let action = CaptureShortcuts.shared.matchingAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
            found.append(Usage(kind: .aomShortcut, title: action.displayName, scope: "Every app · Settings › Shortcuts"))
        }
        for trigger in triggers {
            guard case .keyboardShortcut(let key) = trigger.input, PaletteHotkeyRules.same(key, shortcut) else { continue }
            let scope: String
            if let bundleID = trigger.appBundleID, !bundleID.isEmpty {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
                scope = "Only in \(name.replacingOccurrences(of: ".app", with: ""))"
            } else if let group = trigger.activationGroupID, let named = groups.first(where: { $0.id == group }) {
                scope = "In the “\(named.name)” app group"
            } else {
                scope = "Every app"
            }
            found.append(Usage(kind: .automation(trigger.id), title: "Automation: \(trigger.displayName)", scope: scope, isEnabled: trigger.isEnabled))
        }
        let table = SymbolicHotKeys.load()
        let names: [(Int, String)] = [(SymbolicHotKeys.missionControl, "Mission Control"), (SymbolicHotKeys.appWindows, "Application windows"),
                                      (SymbolicHotKeys.showDesktop, "Show Desktop"), (SymbolicHotKeys.spaceLeft, "Move left a space"),
                                      (SymbolicHotKeys.spaceRight, "Move right a space")] + (1...9).map { (SymbolicHotKeys.desktop($0), "Switch to Desktop \($0)") }
        for (id, name) in names {
            guard let key = SymbolicHotKeys.hotKey(id: id, in: table), key.isEnabled, key.keyCode == shortcut.keyCode else { continue }
            var flags: NSEvent.ModifierFlags = []
            if key.flags.contains(.maskCommand) { flags.insert(.command) }
            if key.flags.contains(.maskAlternate) { flags.insert(.option) }
            if key.flags.contains(.maskControl) { flags.insert(.control) }
            if key.flags.contains(.maskShift) { flags.insert(.shift) }
            if flags == shortcut.modifiers.intersection(PaletteHotkeyRules.mask) {
                found.append(Usage(kind: .macOS, title: "macOS: \(name)", scope: "Every app · System Settings › Keyboard › Shortcuts"))
            }
        }
        return found
    }

    /// Who holds `shortcut` inside AOM already, by name.
    func owner(of shortcut: KeyboardShortcut, excluding itemID: String? = nil, triggers: [Trigger] = []) -> String? {
        if let launcher = PaletteHotkeyRules.launcherShortcut(), PaletteHotkeyRules.same(launcher, shortcut) {
            return "the launcher (\(launcher.displayString))"
        }
        if let other = bindings.first(where: { $0.itemID != itemID && PaletteHotkeyRules.same($0.shortcut, shortcut) }) {
            return "“\(other.title)”"
        }
        if let action = CaptureShortcuts.shared.matchingAction(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
            return "\(action.displayName) (Settings › Shortcuts)"
        }
        for trigger in triggers where trigger.isEnabled {
            if case .keyboardShortcut(let key) = trigger.input, PaletteHotkeyRules.same(key, shortcut) {
                return "the automation “\(trigger.displayName)”"
            }
        }
        return nil
    }

    /// Sets (or replaces) a row's key. The key is registered before it is
    /// saved, so a refusal leaves the previous key working.
    @discardableResult
    func set(_ shortcut: KeyboardShortcut, for itemID: String, title: String, triggers: [Trigger] = []) throws -> PaletteHotkey {
        if let problem = PaletteHotkeyRules.problem(with: shortcut) { throw Failure.unusable(problem) }
        if let owner = owner(of: shortcut, excluding: itemID, triggers: triggers) { throw Failure.taken(owner) }
        let binding = PaletteHotkey(itemID: itemID, title: title, keyCode: shortcut.keyCode,
                                    modifiers: shortcut.modifiers.intersection(PaletteHotkeyRules.mask).rawValue)
        let previous = self.binding(for: itemID)
        unregister(itemID)
        if handlerRef != nil, !suspended {
            let status = register(binding)
            if status != noErr {
                if let previous { _ = register(previous) }
                throw Failure.refused(status)
            }
        }
        bindings.removeAll { $0.itemID == itemID }
        bindings.append(binding)
        save()
        return binding
    }

    func remove(_ itemID: String) {
        unregister(itemID)
        bindings.removeAll { $0.itemID == itemID }
        save()
    }

    /// While a new key is recorded, AOM's own keys must not fire.
    func suspend() {
        suspended = true
        for id in Array(refs.keys) { unregister(id) }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    private func registerAll() {
        guard handlerRef != nil, !suspended else { return }
        for binding in bindings where refs[binding.itemID] == nil {
            let status = register(binding)
            if status != noErr {
                GestureLog.shared.logFromAnyThread("Launcher hotkey \(binding.display) for \(binding.title) not registered (\(status))", level: .error)
            }
        }
    }

    private func register(_ binding: PaletteHotkey) -> OSStatus {
        let number = (numbers.keys.max() ?? 0) + 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, EventHotKeyID(signature: signature, id: number),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return status }
        refs[binding.itemID] = ref
        numbers[number] = binding.itemID
        return noErr
    }

    private func unregister(_ itemID: String) {
        if let ref = refs.removeValue(forKey: itemID) { UnregisterEventHotKey(ref) }
        numbers = numbers.filter { $0.value != itemID }
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    fileprivate func fire(number: UInt32) {
        guard let itemID = numbers[number], let binding = binding(for: itemID) else { return }
        onFire?(binding)
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
            // The launcher's own key ('AOML') is GlobalHotKeyManager's.
            guard read == noErr, id.signature == 0x414F_4D48 else { return OSStatus(eventNotHandledErr) }
            let store = Unmanaged<PaletteHotkeyStore>.fromOpaque(context).takeUnretainedValue()
            let number = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { store.fire(number: number) } }
            return noErr
        }, 1, &spec, context, &handlerRef)
        if result != noErr {
            GestureLog.shared.logFromAnyThread("Launcher hotkey handler not installed (\(result))", level: .error)
        }
    }
}

/// 7.3: the shortcut last pressed on Find a Shortcut.
@MainActor
final class PaletteHotkeyFinder: ObservableObject {
    static let shared = PaletteHotkeyFinder()
    @Published var shortcut: KeyboardShortcut?
}
