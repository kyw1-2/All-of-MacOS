import Foundation
import AppKit

/// Global shortcuts for the Capture Text commands that are not part of the
/// CleanShot shortcut table. "Capture Text" itself stays
/// `CaptureShortcutAction.ocr` (⇧⌘2, also TextSniper's default).
///
/// Kept as its own type so the CleanShot table and its exhaustive switches
/// are unchanged; `CaptureShortcuts.handleKeyEvent` consults this table after
/// its own.
enum TextCaptureShortcutAction: String, CaseIterable, Identifiable {
    /// Capture Text with the opposite of the Keep Line Breaks setting
    /// (TextSniper's "Capture With/Without Line Breaks").
    case captureTextToggledLineBreaks
    case captureTextFromClipboard
    case readQRCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captureTextToggledLineBreaks: return "Capture Text (Toggle Line Breaks)"
        case .captureTextFromClipboard: return "Capture Text from Clipboard Image"
        case .readQRCode: return "Read QR / Barcode"
        }
    }

    var iconName: String {
        switch self {
        case .captureTextToggledLineBreaks: return "text.justify"
        case .captureTextFromClipboard: return "doc.on.clipboard"
        case .readQRCode: return "qrcode.viewfinder"
        }
    }

    /// TextSniper ships these unassigned; only the line-break variant gets a
    /// default, one that no CleanShot/AOM default uses (⌥⇧⌘2).
    var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .captureTextToggledLineBreaks: return KeyboardShortcut(keyCode: 19, modifiers: [.command, .shift, .option])
        case .captureTextFromClipboard, .readQRCode: return nil
        }
    }

    var userDefaultsKey: String { "AOMTextCaptureShortcut_\(rawValue)" }
}

@MainActor
final class TextCaptureShortcuts: ObservableObject {
    static let shared = TextCaptureShortcuts()

    @Published private var shortcuts: [TextCaptureShortcutAction: KeyboardShortcut] = [:]
    private let defaults: UserDefaults
    private static let isolatedDefaults = UserDefaults(suiteName: "AOMTextCaptureShortcuts-Isolated-\(UUID().uuidString)")!

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview)
            ? Self.isolatedDefaults : .standard)
        load()
    }

    func shortcut(for action: TextCaptureShortcutAction) -> KeyboardShortcut? { shortcuts[action] }

    func setShortcut(_ shortcut: KeyboardShortcut?, for action: TextCaptureShortcutAction) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            shortcuts[action] = shortcut
            defaults.set(data, forKey: action.userDefaultsKey)
            defaults.removeObject(forKey: action.userDefaultsKey + ".disabled")
        } else {
            shortcuts.removeValue(forKey: action)
            defaults.removeObject(forKey: action.userDefaultsKey)
            defaults.set(true, forKey: action.userDefaultsKey + ".disabled")
        }
        NotificationCenter.default.post(name: .init("AOMCaptureShortcutsDidChange"), object: self)
    }

    func resetToDefaults() {
        for action in TextCaptureShortcutAction.allCases { setShortcut(action.defaultShortcut, for: action) }
    }

    private func load() {
        for action in TextCaptureShortcutAction.allCases {
            if defaults.bool(forKey: action.userDefaultsKey + ".disabled") {
                shortcuts[action] = nil
            } else if let data = defaults.data(forKey: action.userDefaultsKey),
                      let saved = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
                shortcuts[action] = saved
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    var hasActiveShortcuts: Bool { !shortcuts.isEmpty }

    func matchingAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TextCaptureShortcutAction? {
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let clean = modifiers.intersection(mask)
        return TextCaptureShortcutAction.allCases.first { action in
            guard let shortcut = shortcuts[action] else { return false }
            return shortcut.keyCode == keyCode && shortcut.modifiers.intersection(mask) == clean
        }
    }

    /// Consumes a matching key event and runs the command after the event tap returns.
    func handleKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let action = matchingAction(keyCode: keyCode, modifiers: modifiers) else { return false }
        DispatchQueue.main.async {
            guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
            MainActor.assumeIsolated { Self.perform(action) }
        }
        return true
    }

    static func perform(_ action: TextCaptureShortcutAction) {
        switch action {
        case .captureTextToggledLineBreaks:
            CaptureCoordinator.shared.captureText(keepsLineBreaks: !TextCaptureSettings.shared.keepsLineBreaks)
        case .captureTextFromClipboard:
            TextCaptureController.shared.captureFromClipboardImage()
        case .readQRCode:
            CaptureCoordinator.shared.captureQRCode()
        }
    }
}
