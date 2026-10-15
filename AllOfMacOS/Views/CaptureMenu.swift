import AppKit
import SwiftUI

/// Builds the Capture submenu for the menu-bar status item.
///
/// A submenu rather than flat items because there are fifteen capture commands
/// and putting them all at the top level would push the gesture controls off the
/// menu. The order follows CleanShot X conventions and reflects user configured
/// global shortcuts.
@MainActor
enum CaptureMenu {
    static func build() -> NSMenuItem? {
        let root = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        let menu = NSMenu(title: "Capture")

        let shortcuts = CaptureShortcuts.shared

        menu.addItem(item(
            "Capture Area", "viewfinder",
            #selector(AppDelegate.captureAreaAction),
            shortcut: shortcuts.shortcut(for: .captureArea)
        ))
        menu.addItem(item(
            "Capture Fullscreen", "rectangle.inset.filled",
            #selector(AppDelegate.captureFullscreenAction),
            shortcut: shortcuts.shortcut(for: .captureFullscreen)
        ))
        menu.addItem(item(
            "Capture Window…", "macwindow",
            #selector(AppDelegate.captureWindowAction)
        ))
        menu.addItem(item(
            "Capture Active Window", "macwindow.badge.plus",
            #selector(AppDelegate.captureActiveWindowAction),
            shortcut: shortcuts.shortcut(for: .captureWindow)
        ))
        menu.addItem(item(
            "Record Screen…", "record.circle",
            #selector(AppDelegate.recordScreenAction),
            shortcut: shortcuts.shortcut(for: .recordScreen)
        ))
        menu.addItem(itemWithCaptureState(
            ScreenRecordingService.shared.isPaused ? "Resume Recording" : "Pause Recording", "pause.circle",
            #selector(AppDelegate.pauseRecordingAction),
            enabled: ScreenRecordingService.shared.isRecording,
            shortcut: shortcuts.shortcut(for: .pauseRecording)
        ))
        menu.addItem(item(
            "Record Fullscreen", "display",
            #selector(AppDelegate.recordFullscreenAction)
        ))

        menu.addItem(.separator())

        menu.addItem(item(
            "All-In-One Capture", "square.dashed.inset.filled",
            #selector(AppDelegate.captureAllInOneAction)
        ))

        menu.addItem(item(
            "Capture Previous Area", "arrow.counterclockwise.square",
            #selector(AppDelegate.capturePreviousAreaAction),
            shortcut: shortcuts.shortcut(for: .capturePreviousArea)
        ))
        menu.addItem(item(
            "Capture Scrolling Area", "scroll",
            #selector(AppDelegate.captureScrollingAction),
            shortcut: shortcuts.shortcut(for: .scrollingCapture)
        ))
        menu.addItem(item(
            "Capture Scrolling Horizontally", "arrow.left.and.right",
            #selector(AppDelegate.captureScrollingHorizontalAction)
        ))
        menu.addItem(item(
            "Capture All Displays", "display.2",
            #selector(AppDelegate.captureAllDisplaysAction)
        ))

        menu.addItem(.separator())

        let textItem = NSMenuItem(title: "Capture Text (OCR)", action: nil, keyEquivalent: "")
        textItem.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        if let ocrShortcut = shortcuts.shortcut(for: .ocr) {
            applyShortcut(ocrShortcut, to: textItem)
        }
        let textMenu = NSMenu(title: "Capture Text")
        textMenu.addItem(item("Keep Line Breaks", nil, #selector(AppDelegate.captureTextWithBreaksAction)))
        textMenu.addItem(item("Join Lines", nil, #selector(AppDelegate.captureTextWithoutBreaksAction)))
        textItem.submenu = textMenu
        menu.addItem(textItem)

        menu.addItem(item("Capture With Self-Timer", "timer", #selector(AppDelegate.captureSelfTimerAction)))

        menu.addItem(.separator())

        menu.addItem(item(
            "Quick Access Drag Diagnostics…", "checkmark.shield",
            #selector(AppDelegate.quickAccessDiagnosticsAction)
        ))
        menu.addItem(item(
            "Add File to Quick Access…", "square.and.arrow.down",
            #selector(AppDelegate.importQuickAccessFileAction)
        ))
        menu.addItem(itemWithCaptureState(
            "Restore Recently Closed Quick Access", "arrow.uturn.backward.circle",
            #selector(AppDelegate.restoreRecentQuickAccessAction),
            enabled: CaptureCoordinator.shared.canRestoreQuickAccess
        ))
        menu.addItem(itemWithCaptureState(
            CaptureCoordinator.shared.areQuickAccessHidden
                ? "Show Quick Access Overlays" : "Temporarily Hide Quick Access Overlays",
            "eye.slash",
            #selector(AppDelegate.toggleQuickAccessVisibilityAction),
            enabled: CaptureCoordinator.shared.hasVisibleQuickAccess
        ))
        menu.addItem(itemWithCaptureState(
            "Save All Quick Access Overlays", "square.and.arrow.down.on.square",
            #selector(AppDelegate.saveAllQuickAccessAction),
            enabled: CaptureCoordinator.shared.hasVisibleQuickAccess
        ))
        menu.addItem(itemWithCaptureState(
            "Close All Quick Access Overlays", "xmark.rectangle.portrait",
            #selector(AppDelegate.closeAllQuickAccessAction),
            enabled: CaptureCoordinator.shared.hasVisibleQuickAccess
        ))
        menu.addItem(.separator())

        // The most-recent-capture actions are disabled when there is nothing to
        // act on, rather than being hidden, so the menu keeps a stable shape.
        menu.addItem(item("Open Annotation Project…", "doc.badge.gearshape", #selector(AppDelegate.openAnnotationProjectAction)))
        let hasCapture = CaptureHistory.shared.mostRecent != nil
        menu.addItem(itemWithCaptureState(
            "Annotate Last Capture", "pencil.tip.crop.circle",
            #selector(AppDelegate.annotateLastAction),
            enabled: hasCapture
        ))
        menu.addItem(itemWithCaptureState(
            "Pin Last Capture", "pin",
            #selector(AppDelegate.pinLastAction),
            enabled: hasCapture,
            shortcut: shortcuts.shortcut(for: .pinLast)
        ))
        menu.addItem(itemWithCaptureState(
            "Copy Last Capture", "doc.on.doc",
            #selector(AppDelegate.copyLastAction),
            enabled: hasCapture
        ))
        menu.addItem(itemWithCaptureState(
            "Save Last Capture", "square.and.arrow.down",
            #selector(AppDelegate.saveLastAction),
            enabled: hasCapture
        ))
        menu.addItem(itemWithCaptureState(
            "Copy Text From Last Capture", "text.viewfinder",
            #selector(AppDelegate.ocrLastAction),
            enabled: hasCapture
        ))

        menu.addItem(.separator())

        let historyItem = item(
            "Capture History…", "clock.arrow.circlepath",
            #selector(AppDelegate.captureHistoryAction),
            shortcut: shortcuts.shortcut(for: .history)
        )
        historyItem.isEnabled = hasCapture
        menu.addItem(historyItem)

        let unpinItem = item("Unpin All Captures", "pin.slash", #selector(AppDelegate.unpinAllAction))
        unpinItem.isEnabled = PinnedScreenshotController.shared.count > 0
        menu.addItem(unpinItem)

        let overlayItem = item("Quick Access Overlay", "rectangle.on.rectangle", #selector(AppDelegate.toggleCaptureOverlayAction))
        overlayItem.state = CaptureSettings.overlayEnabled ? .on : .off
        menu.addItem(overlayItem)

        root.submenu = menu
        return root
    }

    private static func item(
        _ title: String,
        _ symbol: String?,
        _ selector: Selector,
        shortcut: KeyboardShortcut? = nil
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        if let symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let shortcut {
            applyShortcut(shortcut, to: entry)
        }
        return entry
    }

    private static func itemWithCaptureState(
        _ title: String,
        _ symbol: String?,
        _ selector: Selector,
        enabled: Bool,
        shortcut: KeyboardShortcut? = nil
    ) -> NSMenuItem {
        let entry = item(title, symbol, selector, shortcut: shortcut)
        entry.isEnabled = enabled
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
