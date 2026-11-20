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

    /// 9 rows of 44 pt, the 52 pt search field and the 36 pt action bar.
    static let size = CGSize(width: 720, height: 490)

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

    private func show(initialRoute: PaletteRoute?) {
        guard !isVisible, let appState = AppDelegate.current?.appState ?? AppState.current else { return }
        presentation &+= 1
        hiding = false
        // Raycast's "auto-switch input source": type commands in English.
        PaletteInputSource.switchToEnglish()
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            previousApp = front
        } else {
            previousApp = PaletteSession.previousApp()
        }
        let panel = self.panel ?? makePanel()
        panelSize = Self.size(fitting: Self.screenUnderPointer()?.visibleFrame ?? CGRect(origin: .zero, size: Self.size))
        let presented = Binding<Bool>(get: { [weak self] in self?.isVisible ?? false },
                                      set: { [weak self] open in if !open { self?.dismiss(restoringFocus: true) } })
        let root = QuickCommandPalette(isPresented: presented, host: .launcher, initialRoute: initialRoute)
            .environmentObject(appState)
            .accentColor(appState.accentColorChoice.color)
            .tint(appState.accentColorChoice.color)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hosting
        place(panel)
        panel.alphaValue = 0
        // A non-activating panel takes the keyboard (and the input method)
        // while the app in front stays active, as Raycast's and Alfred's do,
        // so AOM's own window never jumps forward behind the launcher.
        // `defaults write com.kyw.allofmacos AOMLauncherActivatesApp -bool true`
        // activates AOM as well, should typing ever not reach the panel.
        if Self.activatesApp || PresetManager.isUIPreview { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
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
                // Tears the palette down: its Spotlight queries and menu
                // reads stop, and the next open starts fresh.
                panel.contentView = nil
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

    func windowDidResignKey(_ notification: Notification) {
        // A sheet of the palette (Quicklinks, Link Rules) takes key on purpose.
        guard isVisible, panel?.attachedSheet == nil, !PresetManager.isUIPreview else { return }
        dismiss(restoringFocus: false)
    }
}
