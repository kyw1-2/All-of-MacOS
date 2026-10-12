import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// AOM's own link namespace; never claims cleanshot:// or executes arbitrary URLs.
/// A URL is a request to show native UI or perform an already user-initiated capture.
/// Unsupported parameters fail closed rather than silently changing capture behavior.
enum AOMCaptureDeepLink: Equatable {
    case captureArea, captureFullscreen, captureWindow, previousArea
    case scrollingCapture, selfTimer, recordScreen
    case captureText(keepsLineBreaks: Bool)
    case openHistory, restoreRecentlyClosed, openSettings
    case pin, openAnnotate, openFromClipboard, addQuickAccessOverlay(URL)

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "aom",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let command = parts.host?.lowercased() else { return nil }
        let items = parts.queryItems ?? []
        // Duplicate query keys, unknown flags and unsupported remote files are
        // never interpreted as commands.
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        func exact(_ keys: Set<String> = []) -> Bool { Set(params.keys) == keys }
        switch command {
        case "capture-area" where exact(): return .captureArea
        case "capture-fullscreen" where exact(): return .captureFullscreen
        case "capture-window" where exact(): return .captureWindow
        case "capture-previous-area" where exact(): return .previousArea
        case "scrolling-capture" where exact(): return .scrollingCapture
        case "self-timer" where exact(): return .selfTimer
        case "record-screen" where exact(): return .recordScreen
        case "capture-text" where exact(): return .captureText(keepsLineBreaks: true)
        case "capture-text" where exact(["linebreaks"]):
            guard let value = params["linebreaks"], ["true", "false"].contains(value) else { return nil }
            return .captureText(keepsLineBreaks: value == "true")
        case "open-history" where exact(): return .openHistory
        case "restore-recently-closed" where exact(): return .restoreRecentlyClosed
        case "open-settings" where exact(): return .openSettings
        case "pin" where exact(): return .pin
        case "open-annotate" where exact(): return .openAnnotate
        case "open-from-clipboard" where exact(): return .openFromClipboard
        case "add-quick-access-overlay" where exact(["filepath"]):
            guard let path = params["filepath"], path.hasPrefix("/"), !path.contains("\0"),
                  ["png", "jpg", "jpeg", "heic", "tif", "tiff", "mp4"].contains(
                    URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
            return .addQuickAccessOverlay(URL(fileURLWithPath: path))
        default: return nil
        }
    }
}


class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var appState: AppState?
    private weak var mainWindow: NSWindow?
    private var menuBarObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if showIcon {
            setupMenuBarIcon()
        }
        observeMenuBarSetting()
        if PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-clipboard-preview") {
            Task { @MainActor in
                let store = ClipboardStore.shared
                await store.ready()
                let board = store.createBoard(name: "Important", color: "green")
                for text in ["A calm place for everything you copy.", "https://developer.apple.com/swift/", "#4A90D9", "Meeting notes\nDesign review at 10:30\nRefine the clipboard cards\nKeep existing shortcuts", "Hello, clipboard.\n안녕하세요, 클립보드."] {
                    if let entry = store.createTextItem(text) { store.pin(entryID: entry.id, boardID: board.id) }
                }
                // Keep some items unpinned in the isolated preview so the
                // Important tab is distinguishable from Clipboard History.
                _ = store.createTextItem("Recent clipboard entry — not pinned")
                _ = store.createTextItem("Draft text available only in Clipboard History")
                ClipboardPanelController.shared.show()
            }
        }

        if !PresetManager.isUIPreview {
            requestAccessibilityPermissions()
            GestureHUD.shared.start()
        }
        // Monitor start-up is owned by AppState (see AppState.init) — it runs
        // whether or not a window is ever shown, which is what an LSUIElement
        // menu-bar app needs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.minSize = NSSize(width: 1300, height: 650)
                mainWindow = window
                window.delegate = self
            }
        }
    }

    // Action names follow the public screenshot-workflow terminology; the
    // namespace remains AOM-only to avoid hijacking another app's URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !PresetManager.isUIPreview else { return }
        for link in urls.prefix(8) {
            guard let command = AOMCaptureDeepLink.parse(link) else { continue }
            Task { @MainActor [weak self] in
                self?.handleCaptureDeepLink(command)
            }
        }
    }

    @MainActor
    private func handleCaptureDeepLink(_ command: AOMCaptureDeepLink) {
        switch command {
        case .captureArea: CaptureCoordinator.shared.captureArea()
        case .captureFullscreen: CaptureCoordinator.shared.captureFullscreen()
        case .captureWindow: CaptureCoordinator.shared.captureWindowFromPicker()
        case .previousArea: CaptureCoordinator.shared.capturePreviousArea()
        case .scrollingCapture: CaptureCoordinator.shared.captureScrolling()
        case .selfTimer: CaptureCoordinator.shared.captureWithSelfTimer()
        case .recordScreen: ScreenRecordingService.shared.promptAndStartRecording()
        case .captureText(let keepsLineBreaks):
            CaptureCoordinator.shared.captureText(keepsLineBreaks: keepsLineBreaks)
        case .openHistory: CaptureHistoryWindowController.shared.present()
        case .restoreRecentlyClosed: CaptureCoordinator.shared.restoreRecentlyClosedOverlay()
        case .openSettings: openSettings()
        case .pin: CaptureActions.pinLastCapture()
        case .openAnnotate: AnnotationEditorController.shared.openMostRecent()
        case .openFromClipboard:
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                GestureHUD.shared.show(title: "No Image", detail: "Copy an image first.")
                return
            }
            let entry = CaptureHistoryEntry(image: cg, kind: .area, capturedAt: Date(), windowTitle: nil, fileURL: nil)
            AnnotationEditorController.shared.open(capture: entry, url: nil)
        case .addQuickAccessOverlay(let url):
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? Int.max) <= 200_000_000 else {
                GestureHUD.shared.show(title: "Import Rejected", detail: "Select a regular media file up to 200 MB.")
                return
            }
            CaptureCoordinator.shared.importQuickAccessFiles([url])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// A software dim lives in the display's gamma table, which outlives the
    /// process. Without this, quitting while dimmed would leave the screen dark
    /// until the user changed the resolution or logged out.
    func applicationWillTerminate(_ notification: Notification) {
        DisplayControlService.clearAllSoftwareDims()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc private func toggleSnapping() {
        MainActor.assumeIsolated { if let appState { appState.setSnappingEnabled(!appState.currentPreset.snappingEnabled) } }
    }

    // MARK: - Capture actions
    //
    // Each of these forwards to the coordinator, which owns the capture path
    // itself. They are separate selectors rather than one dispatching method
    // because `NSMenuItem` identifies its action by selector, not by an argument.

    @objc func quickAccessDiagnosticsAction() {
        MainActor.assumeIsolated { QuickAccessDiagnosticsController.shared.present() }
    }

    @objc func importQuickAccessFileAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.chooseQuickAccessFiles() }
    }

    @objc func restoreRecentQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.restoreRecentlyClosedOverlay() }
    }

    @objc func toggleQuickAccessVisibilityAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.toggleQuickAccessVisibility() }
    }

    @objc func saveAllQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.saveAllQuickAccess() }
    }

    @objc func closeAllQuickAccessAction() {
        MainActor.assumeIsolated { CaptureCoordinator.shared.closeAllQuickAccess() }
    }

    @objc func captureAreaAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureArea() } }
    @objc func captureFullscreenAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureFullscreen() } }
    @objc func captureWindowAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWindowFromPicker() } }
    @objc func captureActiveWindowAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureActiveWindow() } }
    @objc func recordScreenAction() { MainActor.assumeIsolated { ScreenRecordingService.shared.toggleRecording() } }
    @objc func recordFullscreenAction() { MainActor.assumeIsolated { ScreenRecordingService.shared.recordFullscreenUnderPointer() } }
    @objc func captureWindowUnderCursorAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWindowUnderCursor() } }
    @objc func capturePreviousAreaAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.capturePreviousArea() } }
    @objc func captureScrollingAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureScrolling() } }
    @objc func captureAllDisplaysAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureAllDisplays() } }
    @objc func captureTextWithBreaksAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureText(keepsLineBreaks: true) } }
    @objc func captureTextWithoutBreaksAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureText(keepsLineBreaks: false) } }
    @objc func captureSelfTimerAction() { MainActor.assumeIsolated { CaptureCoordinator.shared.captureWithSelfTimer() } }
    @objc func annotateLastAction() { MainActor.assumeIsolated { AnnotationEditorController.shared.openMostRecent() } }
    @objc func pinLastAction() { MainActor.assumeIsolated { CaptureActions.pinLastCapture() } }
    @objc func copyLastAction() { MainActor.assumeIsolated { CaptureActions.copyLastCapture() } }
    @objc func saveLastAction() { MainActor.assumeIsolated { CaptureActions.saveLastCapture() } }
    @objc func ocrLastAction() { MainActor.assumeIsolated { CaptureActions.copyTextFromLastCapture() } }
    @objc func captureHistoryAction() { MainActor.assumeIsolated { CaptureHistoryWindowController.shared.present() } }
    @objc func unpinAllAction() { MainActor.assumeIsolated { PinnedScreenshotController.shared.unpinAll() } }
    @objc func toggleCaptureOverlayAction() {
        MainActor.assumeIsolated {
            CaptureSettings.overlayEnabled.toggle()
            GestureHUD.shared.show(title: "Quick Access Overlay",
                                   detail: CaptureSettings.overlayEnabled ? "On" : "Off")
        }
    }

    @objc private func showCheatSheet() { GestureHUD.shared.toggleCheatSheet() }
    @objc private func toggleHUD() {
        let enabled = UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true
        UserDefaults.standard.set(!enabled, forKey: "AOMHUDEnabled")
    }
    @objc private func testHUD() {
        GestureHUD.shared.show(title: "Three Finger Swipe Up", detail: "Mission Control")
    }
    // MARK: - Menu Bar

    private func setupMenuBarIcon() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "hand.point.up.braille", accessibilityDescription: "All of MacOS")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func removeMenuBarIcon() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func observeMenuBarSetting() {
        menuBarObserver = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                if change.newValue == true {
                    self?.setupMenuBarIcon()
                } else {
                    self?.removeMenuBarIcon()
                }
            }
        }
    }

    @objc private func statusItemClicked() {
        let menu = NSMenu()

        // Version header
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "All of MacOS v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())

        // Toggle ON/OFF
        let enabled = MainActor.assumeIsolated { appState?.globalEnabled ?? true }
        let toggleItem = NSMenuItem(title: enabled ? "Disable Gestures" : "Enable Gestures", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.image = NSImage(systemSymbolName: enabled ? "hand.raised.fill" : "hand.raised.slash.fill", accessibilityDescription: nil)
        menu.addItem(toggleItem)
        let snapping = MainActor.assumeIsolated { appState?.currentPreset.snappingEnabled ?? false }
        let snapItem = NSMenuItem(title: "Drag to Snap", action: #selector(toggleSnapping), keyEquivalent: "")
        snapItem.state = snapping ? .on : .off; snapItem.target = self
        snapItem.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        menu.addItem(snapItem)

        menu.addItem(NSMenuItem.separator())

        // Captures are a separate concern from gesture bindings, so they get
        // their own submenu rather than competing for space in the top level.
        if let capture = MainActor.assumeIsolated({ CaptureMenu.build() }) {
            menu.addItem(capture)
            menu.addItem(NSMenuItem.separator())
        }

        let clipboard = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
        let clipboardMenu = NSMenu()
        for (title, selector) in [("Clipboard History", #selector(showClipboard)), ("Paste Stack", #selector(showClipboardStack)),
                                  ("Paste Next in Stack", #selector(pasteNextClipboard))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; clipboardMenu.addItem(item)
        }
        let paused = MainActor.assumeIsolated { ClipboardStore.shared.paused }
        let pauseClipboard = NSMenuItem(title: paused ? "Resume Clipboard Recording" : "Pause Clipboard Recording", action: #selector(toggleClipboardPause), keyEquivalent: "")
        pauseClipboard.target = self; clipboardMenu.addItem(pauseClipboard)
        clipboard.submenu = clipboardMenu; menu.addItem(clipboard); menu.addItem(.separator())

        // Displays are settings you adjust directly rather than gestures you
        // bind, so they live here permanently instead of in the action list.
        if let displays = MainActor.assumeIsolated({ DisplayMenu.build() }) {
            menu.addItem(displays)
            menu.addItem(NSMenuItem.separator())
        }

        // What is bound to the app in front of you, without opening a window.
        if let appState = MainActor.assumeIsolated({ self.appState }),
           let triggers = MainActor.assumeIsolated({ TriggerMenu.build(from: appState) }) {
            menu.addItem(triggers)
            menu.addItem(NSMenuItem.separator())
        }

        // Open main window
        let openItem = NSMenuItem(title: "Open Main Window", action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let cheatSheetItem = NSMenuItem(title: "Show Cheat Sheet", action: #selector(showCheatSheet), keyEquivalent: "")
        cheatSheetItem.target = self; menu.addItem(cheatSheetItem)
        let hudItem = NSMenuItem(title: "Gesture HUD", action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.state = (UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true) ? .on : .off
        hudItem.target = self; menu.addItem(hudItem)
        let testHudItem = NSMenuItem(title: "Test HUD Overlay", action: #selector(testHUD), keyEquivalent: "")
        testHudItem.target = self
        testHudItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(testHudItem)

        menu.addItem(NSMenuItem.separator())

        // Restart
        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartApp), keyEquivalent: "r")
        restartItem.target = self
        restartItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(restartItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit All of MacOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        // Show the menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear the menu after it closes so the next click triggers statusItemClicked again
        DispatchQueue.main.async {
            self.statusItem?.menu = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        MainActor.assumeIsolated {
            appState?.toggleGlobalEnabled()
        }
        updateStatusIcon()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Find and invoke the Settings menu item from the app menu
        if let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu {
            for item in appMenu.items {
                if item.title.contains("Settings") || item.title.contains("Preferences") {
                    _ = item.target?.perform(item.action, with: item)
                    return
                }
            }
        }
        // Fallback: try the known selector directly
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }


    // MARK: - Window management

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Find any suitable window
            for window in NSApp.windows where window.canBecomeMain {
                mainWindow = window
                window.delegate = self
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let enabled = MainActor.assumeIsolated { appState?.globalEnabled ?? true }
        let symbolName = enabled ? "hand.point.up.braille" : "hand.raised.slash"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "All of MacOS")
    }

    @objc private func showClipboard() { MainActor.assumeIsolated { ClipboardPanelController.shared.show() } }
    @objc private func showClipboardStack() { MainActor.assumeIsolated { ClipboardPanelController.shared.showStack() } }
    @objc private func pasteNextClipboard() { MainActor.assumeIsolated { ClipboardPanelController.shared.pasteNext() } }
    @objc private func toggleClipboardPause() { MainActor.assumeIsolated { ClipboardStore.shared.paused.toggle() } }

    // MARK: - Permissions

    // There is deliberately no automation (Apple Events) request here. Nothing
    // the app does needs it: keystrokes go out as CGEvents and the one action
    // that used to drive System Events now toggles Appearance in-process. The
    // old check sent an Apple Event on every launch just to probe the grant,
    // which made macOS raise the Automation consent prompt each time — and
    // because an ad-hoc signature gives the app a new identity on every build,
    // re-granting never stuck.

    private func requestAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSLog("[AOM] Accessibility NOT granted — prompt requested")
        } else {
            NSLog("[AOM] Accessibility already granted")
        }
    }
}

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        return object(forKey: "showMenuBarIcon") as? Bool ?? true
    }
}
