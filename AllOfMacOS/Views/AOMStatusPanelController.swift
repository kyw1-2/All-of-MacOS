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

    var isShown: Bool { panel?.isVisible == true }

    /// Pure: under the status item, centred on it, kept inside the screen.
    static func frame(size: CGSize, under button: CGRect, visible: CGRect) -> CGRect {
        let x = min(max(visible.minX + 8, button.midX - size.width / 2), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, button.minY - 6 - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    func show<Content: View>(_ content: Content, under button: NSStatusBarButton) {
        close()
        guard let buttonWindow = button.window else { return }
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
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
        let size = hosting.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func close() {
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
