import AppKit
import SwiftUI

/// The CleanShot X status-menu block, as data, so its order is testable.
///
/// Top-level order follows CleanShot 4.8.8's MainMenu.nib: All-In-One …
/// Record Screen | Hide/Show Desktop Icons | Open…, Open from Clipboard,
/// Pin to the Screen… | Capture History…. AOM-only commands live in the
/// grouped submenus after that block so the CleanShot part stays familiar.
enum CaptureMenuCommand: String, CaseIterable {
    case allInOne, captureArea, capturePreviousArea, captureFullscreen, captureWindow,
         scrollingCapture, selfTimer, captureText, recordScreen
    case toggleDesktopIcons
    case open, openFromClipboard, pinToScreen
    case captureHistory

    static let layout: [CaptureMenuCommand?] = [
        .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow,
        .scrollingCapture, .selfTimer, .captureText, .recordScreen,
        nil,
        .toggleDesktopIcons,
        nil,
        .open, .openFromClipboard, .pinToScreen,
        nil,
        .captureHistory,
    ]

    func title(isRecording: Bool = false, desktopIconsVisible: Bool = true) -> String {
        switch self {
        case .allInOne: return "All-In-One"
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .scrollingCapture: return "Scrolling Capture"
        case .selfTimer: return "Self-Timer"
        case .captureText: return "Capture Text (OCR)"
        case .recordScreen: return isRecording ? "Stop Recording" : "Record Screen"
        case .toggleDesktopIcons: return desktopIconsVisible ? "Hide Desktop Icons" : "Show Desktop Icons"
        case .open: return "Open…"
        case .openFromClipboard: return "Open from Clipboard"
        case .pinToScreen: return "Pin to the Screen…"
        case .captureHistory: return "Capture History…"
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: return "square.dashed.inset.filled"
        case .captureArea: return "viewfinder"
        case .capturePreviousArea: return "arrow.counterclockwise.square"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .scrollingCapture: return "arrow.up.and.down.text.horizontal"
        case .selfTimer: return "timer"
        case .captureText: return "text.viewfinder"
        case .recordScreen: return "record.circle"
        case .toggleDesktopIcons: return "menubar.dock.rectangle"
        case .open: return "folder"
        case .openFromClipboard: return "doc.on.clipboard"
        case .pinToScreen: return "pin"
        case .captureHistory: return "clock.arrow.circlepath"
        }
    }

    /// The configurable global shortcut shown next to the item, if any. The
    /// label is only shown where the shortcut performs this exact command.
    var shortcutAction: CaptureShortcutAction? {
        switch self {
        case .allInOne: return .allInOne
        case .captureArea: return .captureArea
        case .capturePreviousArea: return .capturePreviousArea
        case .captureFullscreen: return .captureFullscreen
        case .scrollingCapture: return .scrollingCapture
        case .captureText: return .ocr
        case .recordScreen: return .recordScreen
        case .captureHistory: return .history
        // Capture Window here is interactive; the shortcut captures the
        // active window and is labelled on "Capture Active Window" instead.
        case .captureWindow, .selfTimer, .toggleDesktopIcons, .open, .openFromClipboard, .pinToScreen:
            return nil
        }
    }
}

/// Builds the Capture submenu for the menu-bar status item.
@MainActor
enum CaptureMenu {
    static func build() -> NSMenuItem? {
        let root = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        let menu = NSMenu(title: "Capture")
        menu.autoenablesItems = false

        let shortcuts = CaptureShortcuts.shared
        let recording = ScreenRecordingService.shared.isRecording
        let iconsVisible = CaptureCoordinator.shared.desktopIconsVisible

        for command in CaptureMenuCommand.layout {
            guard let command else { menu.addItem(.separator()); continue }
            let entry = action(command.title(isRecording: recording, desktopIconsVisible: iconsVisible),
                               command.symbol,
                               shortcut: command.shortcutAction.flatMap { shortcuts.shortcut(for: $0) }) {
                perform(command)
            }
            if command == .captureHistory { entry.isEnabled = !CaptureHistory.shared.entries.isEmpty }
            if command == .capturePreviousArea { entry.isEnabled = CaptureSettings.lastArea != nil }
            menu.addItem(entry)
            // Pause/Resume belongs with recording (AOM extra).
            if command == .recordScreen, recording {
                menu.addItem(action(ScreenRecordingService.shared.isPaused ? "Resume Recording" : "Pause Recording",
                                    "pause.circle",
                                    shortcut: shortcuts.shortcut(for: .pauseRecording)) {
                    ScreenRecordingService.shared.togglePause()
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(moreCaptureModes(shortcuts))
        menu.addItem(quickAccessMenu())
        menu.addItem(lastCaptureMenu(shortcuts))

        root.submenu = menu
        return root
    }

    /// The everyday capture commands for the top level of the status menu,
    /// in CleanShot's order (its menu leads with the capture modes). The full
    /// set stays one level down in `build()`.
    static func quickItems() -> [NSMenuItem] {
        let shortcuts = CaptureShortcuts.shared
        let recording = ScreenRecordingService.shared
        var items: [NSMenuItem] = []
        for command in [CaptureMenuCommand.captureArea, .captureWindow, .captureFullscreen, .captureText, .recordScreen] {
            items.append(action(command.title(isRecording: recording.isRecording,
                                              desktopIconsVisible: CaptureCoordinator.shared.desktopIconsVisible),
                                command.symbol,
                                shortcut: command.shortcutAction.flatMap { shortcuts.shortcut(for: $0) }) {
                perform(command)
            })
        }
        if recording.isRecording {
            items.append(action(recording.isPaused ? "Resume Recording" : "Pause Recording", "pause.circle",
                                shortcut: shortcuts.shortcut(for: .pauseRecording)) { recording.togglePause() })
        }
        return items
    }

    private static func perform(_ command: CaptureMenuCommand) {
        let coordinator = CaptureCoordinator.shared
        switch command {
        case .allInOne: coordinator.captureAllInOne()
        case .captureArea: coordinator.captureArea()
        case .capturePreviousArea: coordinator.capturePreviousArea()
        case .captureFullscreen: coordinator.captureFullscreen()
        case .captureWindow: coordinator.captureWindowInteractive()
        case .scrollingCapture: coordinator.captureScrolling()
        case .selfTimer: coordinator.captureWithSelfTimer()
        case .captureText: coordinator.captureText()
        case .recordScreen: ScreenRecordingService.shared.toggleRecording()
        case .toggleDesktopIcons: coordinator.toggleDesktopIcons()
        case .open: AnnotationEditorController.shared.chooseImageOrProject()
        case .openFromClipboard: AnnotationEditorController.shared.openFromClipboard()
        case .pinToScreen: PinnedScreenshotController.shared.chooseAndPin()
        case .captureHistory: MediaHistoryOverlayController.shared.present()
        }
    }

    // MARK: - AOM extras (grouped)

    private static func moreCaptureModes(_ shortcuts: CaptureShortcuts) -> NSMenuItem {
        let root = NSMenuItem(title: "More Capture Modes", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        let menu = NSMenu(title: root.title)
        let coordinator = CaptureCoordinator.shared
        menu.addItem(action("Capture Active Window", "macwindow.badge.plus",
                            shortcut: shortcuts.shortcut(for: .captureWindow)) { coordinator.captureActiveWindow() })
        menu.addItem(action("Capture Window from List…", "rectangle.grid.2x2") { coordinator.captureWindowFromPicker() })
        menu.addItem(action("Capture All Displays", "display.2") { coordinator.captureAllDisplays() })
        menu.addItem(.separator())
        menu.addItem(action("Scrolling Capture (Horizontal)", "arrow.left.and.right") {
            coordinator.captureScrollingHorizontal()
        })
        // Capture Text variants (TextSniper parity): the opposite of the
        // Keep Line Breaks setting, clipboard images, and QR / barcodes.
        let textShortcuts = TextCaptureShortcuts.shared
        let keepsBreaks = TextCaptureSettings.shared.keepsLineBreaks
        menu.addItem(action(keepsBreaks ? "Capture Text (Join Lines)" : "Capture Text (Keep Line Breaks)",
                            keepsBreaks ? "text.justify" : "text.alignleft",
                            shortcut: textShortcuts.shortcut(for: .captureTextToggledLineBreaks)) {
            coordinator.captureText(keepsLineBreaks: !keepsBreaks)
        })
        menu.addItem(action("Capture Text from Clipboard Image", "doc.on.clipboard",
                            shortcut: textShortcuts.shortcut(for: .captureTextFromClipboard)) {
            coordinator.captureTextFromClipboardImage()
        })
        menu.addItem(action("Read QR / Barcode", "qrcode.viewfinder",
                            shortcut: textShortcuts.shortcut(for: .readQRCode)) {
            coordinator.captureQRCode()
        })
        menu.addItem(.separator())
        menu.addItem(action("Record Fullscreen", "rectangle.dashed.badge.record") {
            ScreenRecordingService.shared.recordFullscreenUnderPointer()
        })
        root.submenu = menu
        return root
    }

    private static func quickAccessMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Quick Access Overlay", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        let menu = NSMenu(title: root.title)
        menu.autoenablesItems = false
        let coordinator = CaptureCoordinator.shared
        let hasVisible = coordinator.hasVisibleQuickAccess

        let restore = action("Restore Recently Closed", "arrow.uturn.backward.circle") {
            coordinator.restoreRecentlyClosedOverlay()
        }
        restore.isEnabled = coordinator.canRestoreQuickAccess
        menu.addItem(restore)
        let hide = action(coordinator.areQuickAccessHidden ? "Show Overlays" : "Temporarily Hide Overlays", "eye.slash") {
            coordinator.toggleQuickAccessVisibility()
        }
        hide.isEnabled = hasVisible
        menu.addItem(hide)
        let saveAll = action("Save All Overlays", "square.and.arrow.down.on.square") { coordinator.saveAllQuickAccess() }
        saveAll.isEnabled = hasVisible
        menu.addItem(saveAll)
        let closeAll = action("Close All Overlays…", "xmark.rectangle") { coordinator.confirmCloseAllQuickAccess() }
        closeAll.isEnabled = hasVisible
        menu.addItem(closeAll)
        menu.addItem(.separator())
        menu.addItem(action("Add File to Quick Access…", "square.and.arrow.down") { coordinator.chooseQuickAccessFiles() })
        menu.addItem(action("Drag Diagnostics…", "checkmark.shield") { QuickAccessDiagnosticsController.shared.present() })
        menu.addItem(.separator())
        let toggle = action("Show After Capture", nil) {
            CaptureSettings.overlayEnabled.toggle()
        }
        toggle.state = CaptureSettings.overlayEnabled ? .on : .off
        menu.addItem(toggle)
        root.submenu = menu
        return root
    }

    private static func lastCaptureMenu(_ shortcuts: CaptureShortcuts) -> NSMenuItem {
        let root = NSMenuItem(title: "Last Capture", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        let menu = NSMenu(title: root.title)
        menu.autoenablesItems = false
        let hasCapture = CaptureHistory.shared.mostRecent != nil
        let items: [NSMenuItem] = [
            action("Annotate", "pencil.tip.crop.circle") { AnnotationEditorController.shared.openMostRecent() },
            action("Pin", "pin", shortcut: shortcuts.shortcut(for: .pinLast)) { CaptureActions.pinLastCapture() },
            action("Copy", "doc.on.doc") { CaptureActions.copyLastCapture() },
            action("Save", "square.and.arrow.down") { CaptureActions.saveLastCapture() },
            action("Copy Text", "text.viewfinder") { CaptureActions.copyTextFromLastCapture() },
        ]
        for item in items {
            item.isEnabled = hasCapture
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Annotation Project…", "doc.badge.gearshape") {
            AnnotationEditorController.shared.chooseProject()
        })
        let unpin = action("Unpin All Captures", "pin.slash") { PinnedScreenshotController.shared.unpinAll() }
        unpin.isEnabled = PinnedScreenshotController.shared.count > 0
        menu.addItem(unpin)
        root.submenu = menu
        return root
    }

    // MARK: - Helpers

    private static func action(_ title: String, _ symbol: String?,
                               shortcut: KeyboardShortcut? = nil,
                               _ handler: @escaping () -> Void) -> NSMenuItem {
        let entry = QuickAccessMenuAction.item(title, symbol: symbol) {
            MainActor.assumeIsolated { handler() }
        }
        if let shortcut { applyShortcut(shortcut, to: entry) }
        return entry
    }

    private static func applyShortcut(_ shortcut: KeyboardShortcut, to item: NSMenuItem) {
        let key = keyCodeToString(shortcut.keyCode)
        if key.count == 1 {
            item.keyEquivalent = key.lowercased()
            item.keyEquivalentModifierMask = shortcut.modifiers.intersection([.command, .option, .control, .shift])
        }
    }
}
