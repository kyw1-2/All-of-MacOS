import AppKit

/// Dedicated shortcuts stay outside the user's gesture preset, so adding the
/// clipboard workspace cannot replace a saved binding.
@MainActor
final class ClipboardShortcuts: ObservableObject {
    enum Command: String, CaseIterable, Identifiable {
        case history, stack, next, pause
        var id: String { rawValue }
        var title: String {
            switch self { case .history: return "Clipboard History"; case .stack: return "Paste Stack"; case .next: return "Paste Next in Stack"; case .pause: return "Pause / Resume Clipboard History" }
        }
        var initial: KeyboardShortcut? {
            self == .history ? KeyboardShortcut(keyCode: 9, modifiers: [.command, .shift]) : nil
        }
    }
    static let shared = ClipboardShortcuts()
    static let didChange = Notification.Name("AOMClipboardShortcutsDidChange")
    @Published private var bindings: [Command: KeyboardShortcut] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview)
            ? UserDefaults(suiteName: "AOMClipboardShortcuts-Isolated-\(ProcessInfo.processInfo.processIdentifier)")! : .standard)
        for command in Command.allCases {
            let key = "AOMClipboardShortcut_" + command.rawValue
            if self.defaults.bool(forKey: key + "Disabled") { continue }
            bindings[command] = self.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) } ?? command.initial
        }
    }
    var hasActiveShortcuts: Bool { !bindings.isEmpty }
    func shortcut(for command: Command) -> KeyboardShortcut? { bindings[command] }
    func setShortcut(_ shortcut: KeyboardShortcut?, for command: Command) {
        let key = "AOMClipboardShortcut_" + command.rawValue
        bindings[command] = shortcut
        defaults.set(shortcut == nil, forKey: key + "Disabled")
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func matchingCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        return Command.allCases.first { command in
            guard let shortcut = bindings[command] else { return false }
            return shortcut.keyCode == keyCode && shortcut.modifiers.intersection(mask) == modifiers.intersection(mask)
        }
    }
    func handleKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let command = matchingCommand(keyCode: keyCode, modifiers: modifiers) else { return false }
        DispatchQueue.main.async {
            guard !PresetManager.isRunningTests else { return }
            switch command {
            case .history: ClipboardPanelController.shared.toggle()
            case .stack: ClipboardPanelController.shared.showStack()
            case .next: ClipboardPanelController.shared.pasteNext()
            case .pause: ClipboardStore.shared.paused.toggle()
            }
        }
        return true
    }
}
