import AppKit
import SwiftUI

/// A borderless panel that takes clicks and keys without activating AOM.
private final class AOMStatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 6.8: the menu bar panel without activating AOM.
///
/// Through 6.7 a click on AOM's menu bar icon activated the app to show an
/// NSPopover, and activation brings AOM's main window in front of the app
/// you were using ("the main window pops up"). Bartender, iStat Menus and
/// Raycast's menu bar use a non-activating panel instead: it takes clicks
/// and keys while the app in front stays active, so nothing else of AOM moves.
@MainActor
final class AOMStatusPanelController: NSObject, NSWindowDelegate {
    static let shared = AOMStatusPanelController()

    private var panel: AOMStatusPanelWindow?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// The status item's frame on screen while the panel is open.
    private var anchor: CGRect = .null
    /// 7.11 (spec §4): a press on the icon itself can close the panel before
    /// its click arrives (the panel resigns key on mouse-down); that click
    /// must not open it again. Uptime until which a reopen is refused.
    private var reopenBlockedUntil: TimeInterval = 0

    var isShown: Bool { panel?.isVisible == true }

    /// Pure: under the status item, centred on it, kept inside the screen.
    static func frame(size: CGSize, under button: CGRect, visible: CGRect) -> CGRect {
        let x = min(max(visible.minX + 8, button.midX - size.width / 2), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, button.minY - 6 - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// 7.24.1 (agy §6.1-2): the app in front when the panel opened — where a
    /// copy from the panel is pasted, even though the panel holds the keys.
    private(set) var destination: NSRunningApplication?

    /// 7.24.1 (agy §6.1-1): the panel never covers more than this.
    static func maxHeight(visible: CGRect) -> CGFloat {
        guard visible.height > 0 else { return 560 }
        return min(560, (visible.height * 0.72).rounded())
    }

    func show<Content: View>(_ content: Content, under button: NSStatusBarButton) {
        close()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            destination = front
        }
        // 7.0: no launcher or shelf left open under the menu bar panel.
        AOMOverlayCoordinator.shared.present(.menuBarPanel, dismiss: { [weak self] in self?.close() }) { _ in }
        guard let buttonWindow = button.window else { return }
        let hosting = NSHostingView(rootView: content)
        var size = hosting.fittingSize
        let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // 7.24.1: the content scrolls inside (AOMMenuBarCraftPanel); the window never grows past the cap.
        size.height = min(size.height, Self.maxHeight(visible: visible))
        let panel = AOMStatusPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "AOM Menu Bar Panel"
        panel.delegate = self
        panel.contentView = hosting
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        self.anchor = anchor
        let screen = buttonWindow.screen ?? NSScreen.main
        panel.setFrame(Self.frame(size: size, under: anchor, visible: screen?.visibleFrame ?? anchor), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = QuickCommandPalette.reducesMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53, self?.panel?.isKeyWindow == true else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    /// Grows or shrinks with its content (a session row appearing).
    func fitToContent() {
        guard let panel, let hosting = panel.contentView else { return }
        var size = hosting.fittingSize
        size.height = min(size.height, Self.maxHeight(visible: (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero))
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// True once when the panel was just closed by a press on the icon: the
    /// click that follows is that same press, so it closes, not reopens.
    func consumeIconPressClose() -> Bool {
        defer { reopenBlockedUntil = 0 }
        return ProcessInfo.processInfo.systemUptime < reopenBlockedUntil
    }

    /// Pure: a close happening while a button is held over the icon.
    static func isIconPress(pointer: CGPoint, anchor: CGRect, buttonsDown: Int) -> Bool {
        buttonsDown != 0 && !anchor.isNull && anchor.insetBy(dx: -3, dy: -3).contains(pointer)
    }

    func close() {
        // Left button only: a right-click opens the command menu, never the panel
        // (review 7.11). A trackpad tap may already be up when the panel resigns,
        // so the left mouse-down being handled counts too (swarm audit 7.11).
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0 || NSApp.currentEvent?.type == .leftMouseDown
        if Self.isIconPress(pointer: NSEvent.mouseLocation, anchor: anchor, buttonsDown: leftDown ? 1 : 0) {
            reopenBlockedUntil = ProcessInfo.processInfo.systemUptime + 0.8
        }
        anchor = .null
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Another app took the keyboard: the panel goes, like a menu.
        guard (notification.object as? NSWindow) === panel else { return }
        close()
    }
}
