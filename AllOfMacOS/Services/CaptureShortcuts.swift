import Foundation
import AppKit

/// CleanShot X-style Global Keyboard Shortcuts for Screen Capture.
///
/// Stores and evaluates global hotkeys for capture operations, matching CleanShot's
/// dedicated Shortcuts preferences tab.
enum CaptureShortcutAction: String, CaseIterable, Identifiable {
    case captureArea = "captureArea"
    case captureFullscreen = "captureFullscreen"
    case captureWindow = "captureWindow"
    case recordScreen = "recordScreen"
    case capturePreviousArea = "capturePreviousArea"
    case scrollingCapture = "scrollingCapture"
    case ocr = "ocr"
    case history = "history"
    case toggleDesktopIcons = "toggleDesktopIcons"
    case pinLast = "pinLast"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .recordScreen: return "Record Screen"
        case .capturePreviousArea: return "Capture Previous Area"
        case .scrollingCapture: return "Scrolling Capture"
        case .ocr: return "OCR / Recognize Text"
        case .history: return "Capture History"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        case .pinLast: return "Pin Last Capture"
        }
    }

    var categoryName: String {
        switch self {
        case .captureArea, .captureFullscreen, .captureWindow, .recordScreen, .capturePreviousArea, .scrollingCapture:
            return "Screen Capture"
        case .ocr, .history, .toggleDesktopIcons, .pinLast:
            return "Tools & Utilities"
        }
    }

    var iconName: String {
        switch self {
        case .captureArea: return "crop"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .recordScreen: return "record.circle"
        case .capturePreviousArea: return "clock.arrow.circlepath"
        case .scrollingCapture: return "arrow.up.and.down.text.horizontal"
        case .ocr: return "text.viewfinder"
        case .history: return "clock.arrow.2.circlepath"
        case .toggleDesktopIcons: return "eye.slash"
        case .pinLast: return "pin"
        }
    }

    var defaultShortcut: KeyboardShortcut? {
        // Standard macOS / CleanShot X keycodes:
        // 19 = '2', 20 = '3', 21 = '4', 23 = '5', 25 = '9', 15 = 'R', 1 = 'S', 4 = 'H', 2 = 'D', 35 = 'P'
        switch self {
        case .captureArea:
            return KeyboardShortcut(keyCode: 21, modifiers: [.command, .shift]) // ⇧⌘4
        case .captureFullscreen:
            return KeyboardShortcut(keyCode: 20, modifiers: [.command, .shift]) // ⇧⌘3
        case .captureWindow:
            return KeyboardShortcut(keyCode: 23, modifiers: [.command, .shift]) // ⇧⌘5
        case .recordScreen:
            return KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift, .option]) // ⌥⇧⌘R
        case .capturePreviousArea:
            return KeyboardShortcut(keyCode: 25, modifiers: [.command, .shift]) // ⇧⌘9
        case .scrollingCapture:
            return KeyboardShortcut(keyCode: 1, modifiers: [.command, .shift, .option]) // ⌥⇧⌘S
        case .ocr:
            return KeyboardShortcut(keyCode: 19, modifiers: [.command, .shift]) // ⇧⌘2
        case .history:
            return KeyboardShortcut(keyCode: 22, modifiers: [.command, .shift]) // ⇧⌘6
        case .toggleDesktopIcons:
            return KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift, .option]) // ⌥⇧⌘D
        case .pinLast:
            return KeyboardShortcut(keyCode: 35, modifiers: [.command, .shift, .option]) // ⌥⇧⌘P
        }
    }

    var userDefaultsKey: String {
        "AOMCaptureShortcut_\(rawValue)"
    }
}

@MainActor
final class CaptureShortcuts: ObservableObject {
    static let shared = CaptureShortcuts()

    @Published private var shortcuts: [CaptureShortcutAction: KeyboardShortcut] = [:]

    private let defaults: UserDefaults
    private let actionHandler: ((CaptureShortcutAction) -> Void)?
    private static let isolatedDefaults = UserDefaults(suiteName: "AOMCaptureShortcuts-Isolated-\(UUID().uuidString)")!

    init(defaults: UserDefaults? = nil, actionHandler: ((CaptureShortcutAction) -> Void)? = nil) {
        // Test and preview hosts must never reset the installed app's shortcuts.
        self.defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview)
            ? Self.isolatedDefaults : .standard)
        self.actionHandler = actionHandler
        loadShortcuts()
    }

    var hasActiveShortcuts: Bool {
        !shortcuts.isEmpty
    }

    func shortcut(for action: CaptureShortcutAction) -> KeyboardShortcut? {
        shortcuts[action]
    }

    func setShortcut(_ shortcut: KeyboardShortcut?, for action: CaptureShortcutAction) {
        if let shortcut {
            shortcuts[action] = shortcut
            defaults.removeObject(forKey: action.userDefaultsKey + ".disabled")
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: action.userDefaultsKey)
            }
        } else {
            shortcuts.removeValue(forKey: action)
            defaults.removeObject(forKey: action.userDefaultsKey)
            // Absence means "use the default"; clearing needs its own persisted state.
            defaults.set(true, forKey: action.userDefaultsKey + ".disabled")
        }
        NotificationCenter.default.post(name: .init("AOMCaptureShortcutsDidChange"), object: self)
    }

    func resetToDefaults() {
        for action in CaptureShortcutAction.allCases {
            setShortcut(action.defaultShortcut, for: action)
        }
    }

    private func loadShortcuts() {
        for action in CaptureShortcutAction.allCases {
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

    /// Stable declaration order resolves legacy duplicate assignments predictably.
    func matchingAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CaptureShortcutAction? {
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let cleanMods = modifiers.intersection(mask)
        return CaptureShortcutAction.allCases.first { action in
            guard let shortcut = shortcuts[action] else { return false }
            return shortcut.keyCode == keyCode && shortcut.modifiers.intersection(mask) == cleanMods
        }
    }

    /// Consume the event now, then present AppKit UI after the event tap returns.
    func handleKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let action = matchingAction(keyCode: keyCode, modifiers: modifiers) else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let actionHandler = self.actionHandler {
                actionHandler(action)
            } else if !PresetManager.isRunningTests && !PresetManager.isUIPreview {
                self.executeAction(action)
            }
        }
        return true
    }

    private func executeAction(_ action: CaptureShortcutAction) {
        switch action {
        case .captureArea:
            CaptureCoordinator.shared.captureArea()
        case .captureFullscreen:
            CaptureCoordinator.shared.captureFullscreen()
        case .captureWindow:
            CaptureCoordinator.shared.captureActiveWindow()
        case .recordScreen:
            ScreenRecordingService.shared.toggleRecording()
        case .capturePreviousArea:
            CaptureCoordinator.shared.capturePreviousArea()
        case .scrollingCapture:
            CaptureCoordinator.shared.captureScrolling()
        case .ocr:
            CaptureCoordinator.shared.captureText()
        case .history:
            MediaHistoryOverlayController.shared.toggle()
        case .toggleDesktopIcons:
            CaptureSettings.hidesDesktopIcons.toggle()
            GestureHUD.shared.show(
                title: "Desktop Icons",
                detail: CaptureSettings.hidesDesktopIcons ? "Hidden" : "Visible"
            )
        case .pinLast:
            CaptureActions.pinLastCapture()
        }
    }
}
