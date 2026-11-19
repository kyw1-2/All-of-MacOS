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

    private var panel: AOMLauncherPanel?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hiding = false

    var isVisible: Bool { panel?.isVisible == true && !hiding }

    static var activatesApp: Bool { UserDefaults.standard.bool(forKey: "AOMLauncherActivatesApp") }

    func toggle() { isVisible ? dismiss(restoringFocus: true) : show() }

    func show() {
        guard !isVisible, let appState = AppDelegate.current?.appState ?? AppState.current else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            previousApp = front
        } else {
            previousApp = PaletteSession.previousApp()
        }
        let panel = self.panel ?? makePanel()
        let presented = Binding<Bool>(get: { [weak self] in self?.isVisible ?? false },
                                      set: { [weak self] open in if !open { self?.dismiss(restoringFocus: true) } })
        let root = QuickCommandPalette(isPresented: presented, host: .launcher)
            .environmentObject(appState)
            .accentColor(appState.accentColorChoice.color)
            .tint(appState.accentColorChoice.color)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
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
            context.duration = PresetManager.isUIPreview ? 0 : 0.12
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
        let target = restoringFocus ? previousApp : nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
                // Tears the palette down: its Spotlight queries and menu
                // reads stop, and the next open starts fresh.
                panel.contentView = nil
                self?.hiding = false
                if let target, !target.isTerminated { target.activate(options: []) }
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
        let x = visible.midX - size.width / 2
        let y = max(visible.minY, visible.maxY - size.height - max(64, visible.height * 0.16))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
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
