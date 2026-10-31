import AppKit
import Carbon

/// Click Hints: Homerow/Vimac-style keyboard clicking. A shortcut (Settings ›
/// Shortcuts › Click with Keyboard), the status menu and Text Actions ›
/// Click Hints › Try It call `showHints()`: AOM reads the front window
/// through Accessibility, puts a one- or two-letter label on every button,
/// link, field, tab and row, and typing a label clicks it.
///
/// Idle cost is zero: `start()` installs nothing, and every monitor, panel
/// and image exists only while hints are on screen.
@MainActor
enum ClickHintsModule {
    /// The raw value of the `CaptureShortcutAction` case the integrator adds
    /// (`case showClickHints`), so this module reads its binding before the
    /// case exists in this branch.
    static let shortcutActionID = "showClickHints"
    static let title = "Click with Keyboard"
    static let symbol = "cursorarrow.click.2"

    /// Called once at launch (never in previews or tests). Nothing to start:
    /// the hotkey belongs to `CaptureShortcuts`.
    static func start() {}

    /// A scan is running; a second press waits for it.
    private(set) static var isScanning = false
    /// Hints are on screen.
    static var isShowing: Bool { ClickHintsSession.isActive }

    /// Shows hints over the front window, or takes them down if they are up
    /// (the shortcut toggles).
    static func showHints() {
        if let session = ClickHintsSession.active {
            session.finish()
            return
        }
        guard !isScanning else { return }
        // Tests and isolated previews never read or click the real screen.
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else {
            GestureHUD.shared.show(title: "No App in Front", detail: "Click hints work on the front app's window.")
            return
        }
        let settings = ClickHintsSettings()
        if let block = ClickHintsGate.check(gateContext(for: app, settings: settings)) {
            if let hud = block.hud { GestureHUD.shared.show(title: hud.title, detail: hud.detail) }
            return
        }
        let bundleID = app.bundleIdentifier
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let mouse = NSEvent.mouseLocation
        let request = ClickHintsScanner.Request(
            pid: app.processIdentifier,
            includesMenuBar: settings.includesMenuBar,
            includesDock: settings.includesDock,
            enhancedAccessibility: bundleID.map { ClickHintsGate.contains(settings.enhancedApps, $0) } ?? false,
            screens: ClickHintsDisplay.current().map(\.frame),
            pointer: CGPoint(x: mouse.x, y: primaryTop - mouse.y))
        let dockPID = settings.includesDock
            ? NSRunningApplication.runningApplications(withBundleIdentifier: ClickHintsScanner.dockBundleID).first?.processIdentifier
            : nil
        let alphabet = settings.alphabet, size = settings.size, startsInSearch = settings.startsInSearch
        isScanning = true
        DispatchQueue.global(qos: .userInteractive).async {
            let result = ClickHintsScanner.scan(request, dockPID: dockPID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isScanning = false
                    present(result, app: app, alphabet: alphabet, size: size, startsInSearch: startsInSearch)
                }
            }
        }
    }

    private static func present(_ result: ClickHintsScanner.Result, app: NSRunningApplication,
                                alphabet: ClickHintsAlphabet, size: ClickHintsSize, startsInSearch: Bool) {
        // The front app or the rules changed while reading: show nothing.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              ClickHintsGate.check(gateContext(for: app, settings: ClickHintsSettings())) == nil else {
            finishRestore(result.restore)
            return
        }
        guard !result.targets.isEmpty else {
            finishRestore(result.restore)
            let name = app.localizedName ?? "This app"
            switch result.failure {
            case .notResponding:
                GestureHUD.shared.show(title: "App Not Responding", detail: "\(name) didn't answer Accessibility in time. Try again in a moment.")
            case .noWindow:
                GestureHUD.shared.show(title: "No Window", detail: "\(name) has no window in front. Click hints work on the front window.")
            case nil:
                GestureHUD.shared.show(title: "No Clickable Items",
                                       detail: "\(name) shows nothing clickable to Accessibility here. For Chrome or an Electron app, turn on Enhanced Accessibility for it in Text Actions › Click Hints.")
            }
            return
        }
        let session = ClickHintsSession(targets: result.targets, pid: app.processIdentifier, windowFrame: result.windowFrame,
                                        alphabet: alphabet, size: size, startsInSearch: startsInSearch,
                                        restore: result.restore)
        session.present()
    }

    /// The live values the rules look at.
    static func gateContext(for app: NSRunningApplication, settings: ClickHintsSettings) -> ClickHintsGate.Context {
        let suppression = TriggerSuppression.shared
        return ClickHintsGate.Context(
            screenLocked: ScreenLock.isLocked,
            secureInput: IsSecureEventInputEnabled(),
            masterSwitchOn: AutomationGate.isOn,
            globallyPaused: suppression.isPaused,
            appPaused: suppression.isPaused(forApp: app.bundleIdentifier),
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            excludedApps: settings.excludedApps,
            accessibilityTrusted: AXIsProcessTrusted())
    }

    /// Puts back what enhanced accessibility changed, off the main thread.
    nonisolated static func finishRestore(_ restore: (() -> Void)?) {
        guard let restore else { return }
        DispatchQueue.global(qos: .utility).async { restore() }
    }

    // MARK: Status menu and shortcut

    static var shortcutAction: CaptureShortcutAction? { CaptureShortcutAction(rawValue: shortcutActionID) }

    /// The binding from Settings › Shortcuts, when the case exists and is set.
    static var currentShortcut: KeyboardShortcut? {
        shortcutAction.flatMap { CaptureShortcuts.shared.shortcut(for: $0) }
    }

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] {
        let item = QuickAccessMenuAction.item(title, symbol: symbol) {
            MainActor.assumeIsolated { showHints() }
        }
        if let shortcut = currentShortcut { applyShortcut(shortcut, to: item) }
        item.toolTip = "Show letters on the front window's buttons and links, then type one to click it"
        return [item]
    }

    /// Shows the binding as the item's key equivalent (letters, digits and
    /// Space; other keys are left off rather than shown wrong).
    static func applyShortcut(_ shortcut: KeyboardShortcut, to item: NSMenuItem) {
        guard let key = menuKeyEquivalent(for: shortcut.keyCode) else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = shortcut.modifiers.intersection([.command, .option, .control, .shift])
    }

    nonisolated static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        if keyCode == ClickHintsKeyboard.space { return " " }
        let name = keyCodeToString(keyCode)
        return name.count == 1 ? name.lowercased() : nil
    }
}
