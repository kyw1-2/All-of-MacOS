import AppKit
import SwiftUI

/// The borderless panel ⌘K lives in. It can become key (typing, IME) but
/// never main, so it does not take over AOM's window.
private final class AOMLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ⌘K as a launcher of its own (6.5, after Raycast): a floating glass panel
/// in the upper middle of the screen with the pointer, opened from any app by
/// the global shortcut (⌥Space by default), ⌘K in AOM, the menu bar panel or
/// `aom://open-launcher` — without bringing up AOM's main window.
///
/// The app that was in front stays the palette's target (menus, links,
/// window tiling). An action that works on it runs after the panel has gone
/// and that app is active again; actions that open AOM's own windows bring
/// AOM forward instead.
@MainActor
final class AOMLauncherController: NSObject, NSWindowDelegate {
    static let shared = AOMLauncherController()

    /// 7.0: 9 rows of 44 pt, the 56 pt search field and the 38 pt footer;
    /// wide enough for the list and its detail side by side (42 : 58).
    static let size = CGSize(width: 760, height: 500)

    /// 6.7 (report L4): never larger than the screen it opens on, with a
    /// 16 pt margin; the rows scroll.
    static func size(fitting visible: CGRect) -> CGSize {
        CGSize(width: min(size.width, max(360, visible.width - 32)).rounded(),
               height: min(size.height, max(280, visible.height - 32)).rounded())
    }

    /// The size of the panel on screen now.
    private(set) var panelSize = AOMLauncherController.size

    private var panel: AOMLauncherPanel?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hiding = false
    /// 6.8 (Codex review): bumped by every show, so a close animation that
    /// ends after a new open never hides or empties the new panel.
    private var presentation = 0

    /// 7.11 (Raycast's "Pop to Root Search after 90 seconds"): closed without
    /// running anything — focus moved away, a click outside, Esc, the hotkey —
    /// the launcher keeps its screen, search and selection, and opening it
    /// again within this time shows it as it was. Running a row starts fresh.
    static let keepSeconds: TimeInterval = 90
    /// Uptime until which the hidden palette may be shown again as it was.
    private var keptUntil: TimeInterval = 0
    private var teardown: DispatchWorkItem?
    /// A row ran: the next open starts at the root.
    private var startFresh = false

    /// Called when a row's action runs (it closes the launcher on its own way).
    func resetOnNextOpen() { startFresh = true }

    /// Pure: whether a hidden palette comes back as it was.
    static func reusesKept(now: TimeInterval, keptUntil: TimeInterval, hasContent: Bool, startFresh: Bool,
                           initialRoute: Bool, hotkey: Bool) -> Bool {
        hasContent && !startFresh && !initialRoute && !hotkey && now < keptUntil
    }

    /// Keeps the hidden palette for `keepSeconds`, then tears it down (its
    /// queries and timers stop, as a fresh close did through 7.10).
    private func keep(_ panel: AOMLauncherPanel, ticket: Int) {
        teardown?.cancel()
        guard !startFresh else { panel.contentView = nil; startFresh = false; keptUntil = 0; return }
        keptUntil = ProcessInfo.processInfo.systemUptime + Self.keepSeconds
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.presentation == ticket, !panel.isVisible else { return }
            panel.contentView = nil
            self.keptUntil = 0
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepSeconds, execute: work)
        NotificationCenter.default.post(name: .aomLauncherVisibility, object: nil, userInfo: ["visible": false])
    }

    /// The app that was in front when the launcher opened (paste targets, "except" lists).
    var frontApp: NSRunningApplication? { previousApp.flatMap { $0.isTerminated ? nil : $0 } }

    var isVisible: Bool { panel?.isVisible == true && !hiding }

    static var activatesApp: Bool { UserDefaults.standard.bool(forKey: "AOMLauncherActivatesApp") }

    func toggle() { isVisible ? dismiss(restoringFocus: true) : show() }

    /// 6.11: opens straight on a screen (System Tools' Kill Apps…).
    func show(route: PaletteRoute) {
        if isVisible { dismiss(restoringFocus: false) }
        show(initialRoute: route)
    }

    func show() { show(initialRoute: nil) }

    /// 7.2: a launcher hotkey (⌘K › Set Hotkey…). An app opens at once; any
    /// other row is found by a launcher that stays invisible unless the row
    /// opens a screen (or can't be found), so a command runs without a flash.
    func run(_ hotkey: PaletteHotkey) {
        // 7.10: Menu Bar › Hotkeys run without the launcher.
        if hotkey.itemID.hasPrefix(MenuBarHotkeys.prefix) { MenuBarHotkeys.fire(hotkey); return }
        if hotkey.itemID.hasPrefix("app.") {
            let url = URL(fileURLWithPath: String(hotkey.itemID.dropFirst("app.".count)))
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        if isVisible { hideImmediatelyForHandoff() }
        show(initialRoute: nil, runItem: hotkey)
    }

    /// Fades in a launcher opened invisibly for a hotkey.
    func reveal() {
        guard let panel, panel.isVisible, !hiding, panel.alphaValue < 1 else { return }
        PaletteInputSource.switchToEnglish()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = QuickCommandPalette.reducesMotion ? 0.05 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func show(initialRoute: PaletteRoute?, runItem: PaletteHotkey? = nil) {
        guard !isVisible, let appState = AppDelegate.current?.appState ?? AppState.current else { return }
        // 7.0: one floating surface at a time — the shelf, the menu bar
        // panel, the switcher or the drop shelf goes before the launcher comes.
        AOMOverlayCoordinator.shared.present(.launcher, dismiss: { [weak self] in self?.hideImmediatelyForHandoff() }) { _ in }
        presentation &+= 1
        hiding = false
        // Raycast's "auto-switch input source": type commands in English.
        // A hotkey's command that never shows the panel leaves it alone.
        if runItem == nil { PaletteInputSource.switchToEnglish() }
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            previousApp = front
        } else {
            previousApp = PaletteSession.previousApp()
        }
        let panel = self.panel ?? makePanel()
        panelSize = Self.size(fitting: Self.screenUnderPointer()?.visibleFrame ?? CGRect(origin: .zero, size: Self.size))
        teardown?.cancel()
        teardown = nil
        if Self.reusesKept(now: ProcessInfo.processInfo.systemUptime, keptUntil: keptUntil, hasContent: panel.contentView != nil,
                           startFresh: startFresh, initialRoute: initialRoute != nil, hotkey: runItem != nil) {
            // The screen as it was left (7.11).
            if PresetManager.isUIPreview { NSLog("AOM launcher: shown again as it was") }
            panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
            panel.appearance = AOMLauncherAppearance.shared.shown.appearance
            place(panel)
            panel.alphaValue = 0
            if Self.activatesApp || PresetManager.isUIPreview { NSApp.activate(ignoringOtherApps: true) }
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PresetManager.isUIPreview ? 0 : QuickCommandPalette.reducesMotion ? 0.05 : 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            watchClicksOutside()
            NotificationCenter.default.post(name: .aomLauncherVisibility, object: nil, userInfo: ["visible": true])
            return
        }
        startFresh = false
        keptUntil = 0
        let presented = Binding<Bool>(get: { [weak self] in self?.isVisible ?? false },
                                      set: { [weak self] open in if !open { self?.dismiss(restoringFocus: true) } })
        let root = AOMLauncherThemedRoot(appAccent: appState.accentColorChoice.color) {
            QuickCommandPalette(isPresented: presented, host: .launcher, initialRoute: initialRoute, runItem: runItem)
                .environmentObject(appState)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hosting
        panel.appearance = AOMLauncherAppearance.shared.shown.appearance
        place(panel)
        panel.alphaValue = 0
        // A non-activating panel takes the keyboard (and the input method)
        // while the app in front stays active, as Raycast's and Alfred's do,
        // so AOM's own window never jumps forward behind the launcher.
        // `defaults write com.kyw.allofmacos AOMLauncherActivatesApp -bool true`
        // activates AOM as well, should typing ever not reach the panel.
        if Self.activatesApp || PresetManager.isUIPreview { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        // A hotkey's command decides first whether the panel is seen at all.
        if runItem != nil { watchClicksOutside(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PresetManager.isUIPreview ? 0 : QuickCommandPalette.reducesMotion ? 0.05 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        watchClicksOutside()
    }

    /// Hides the panel; with `restoringFocus` the app that was in front is
    /// activated again before `then` runs, so window and menu actions reach it.
    func dismiss(restoringFocus: Bool, then: (() -> Void)? = nil) {
        guard let panel, panel.isVisible, !hiding else { then?(); return }
        hiding = true
        stopWatchingClicks()
        // 7.8: a theme only tried on in the Theme screen isn't kept.
        AOMLauncherAppearance.shared.preview(nil)
        // The input source comes back only on a plain cancel to the app you
        // were in; an action may open another app, which keeps English.
        let restoresInput = restoringFocus && then == nil
        if !restoresInput { PaletteInputSource.forget() }
        let ticket = presentation
        let target = restoringFocus ? previousApp : nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Reopened during the fade: the new panel stays.
                guard self?.presentation == ticket else { then?(); return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                // 7.11: a plain close keeps the palette for a while (Raycast);
                // after an action, or once the time is up, it is torn down
                // and its Spotlight queries and menu reads stop.
                if then == nil, let self { self.keep(panel, ticket: ticket) } else {
                    panel.contentView = nil
                    self?.startFresh = false
                    self?.keptUntil = 0
                }
                self?.hiding = false
                if let target, !target.isTerminated { target.activate(options: []) }
                if restoresInput {
                    // After the app has the keyboard again: switching while the
                    // panel still resigns can change only the menu bar's flag.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { PaletteInputSource.restore() }
                }
                if let then {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (target == nil ? 0 : 0.06), execute: then)
                }
            }
        })
    }

    /// 7.0: for AOMOverlayCoordinator. Hides the panel now, without the
    /// fade and without giving the previous app its focus back: another
    /// AOM surface is taking over, and a late fade-out completion activating
    /// the old app would steal that surface's keyboard.
    func hideImmediatelyForHandoff() {
        guard let panel, panel.isVisible else { return }
        // A fade already running ends on an old ticket and does nothing.
        presentation &+= 1
        hiding = false
        stopWatchingClicks()
        AOMLauncherAppearance.shared.preview(nil)
        PaletteInputSource.forget()
        panel.orderOut(nil)
        panel.alphaValue = 1
        // Another AOM surface took over: kept too, like a plain close (7.11).
        keep(panel, ticket: presentation)
    }

    /// 7.8: the theme's appearance on the panel, so the launcher ink and
    /// every system colour inside resolve light or dark for it (live while
    /// arrowing through the theme screen).
    func applyAppearance() {
        let look = AOMLauncherAppearance.shared
        panel?.appearance = look.shown.appearance
        panel?.invalidateShadow()
    }

    private func makePanel() -> AOMLauncherPanel {
        let panel = AOMLauncherPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                     styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.title = "All of MacOS Launcher"
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Upper middle of the screen with the pointer (Raycast's place).
    static func frame(on visible: CGRect) -> CGRect {
        let size = size(fitting: visible)
        let x = min(max(visible.minX, visible.midX - size.width / 2), visible.maxX - size.width)
        let y = max(visible.minY, visible.maxY - size.height - min(max(64, visible.height * 0.16),
                                                                    max(0, visible.height - size.height)))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func place(_ panel: NSPanel) {
        guard let visible = Self.screenUnderPointer()?.visibleFrame else { return }
        panel.setFrame(Self.frame(on: visible), display: true)
    }

    private func watchClicksOutside() {
        stopWatchingClicks()
        // Clicks in other apps; that app comes forward by itself.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    }

    private var showingToolAlert = false

    func withModalInteraction<T>(_ action: () -> T) -> T {
        guard isVisible, panel?.isKeyWindow == true else { return action() }
        showingToolAlert = true
        defer {
            showingToolAlert = false
            if isVisible { panel?.makeKey() }
        }
        return action()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A sheet of the palette (Quicklinks, Link Rules) takes key on purpose.
        guard isVisible, !showingToolAlert, panel?.attachedSheet == nil, !PresetManager.isUIPreview else { return }
        dismiss(restoringFocus: false)
    }
}

/// 7.8: the launcher's root — the theme's accent (or the app's) for tints,
/// re-read when the theme changes while the panel is open.
struct AOMLauncherThemedRoot<Content: View>: View {
    let appAccent: Color
    @ViewBuilder let content: () -> Content
    @ObservedObject private var look = AOMLauncherAppearance.shared

    var body: some View {
        let accent = look.shown.accentColor ?? appAccent
        content()
            .accentColor(accent)
            .tint(accent)
    }
}

extension Notification.Name {
    /// 7.11: the launcher was hidden (kept) or shown again as it was; userInfo["visible"].
    static let aomLauncherVisibility = Notification.Name("AOMLauncherVisibility")
}
