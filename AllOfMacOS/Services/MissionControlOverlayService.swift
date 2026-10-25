import AppKit
import ApplicationServices
import SwiftUI

/// Mission Control Plus parity: when Mission Control is open, poll the Dock's
/// AX tree for the window tiles and float a small ✕ button panel over each —
/// clicking one AX-raises the tile's source window and closes it (⌘W path),
/// so quitting an app from Mission Control takes one click. Escape or MC
/// ending tears the overlays down. Mechanism verified against Mission Control
/// Plus 1.24 (ExposeController.performTimerBasedUpdate + CloseButtonWindow).
@MainActor
final class MissionControlOverlayService: ObservableObject {
    static let shared = MissionControlOverlayService()

    static let defaultsEnabledKey = "AOMMissionControlButtons"

    @Published private(set) var isMissionControlActive = false
    private var pollTimer: Timer?
    private var tiles: [(panel: NSPanel, pid: pid_t, windowTitle: String?)] = []
    private var lastPid: pid_t = 0

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true
    }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        teardown()
    }

    // MARK: - Poll

    private func poll() {
        guard isEnabled, !ScreenLock.isLocked else {
            if isMissionControlActive { teardown() }
            return
        }
        let mcWindow = Self.missionControlWindow()
        if let mcWindow {
            if !isMissionControlActive { isMissionControlActive = true }
            rebuildTiles(for: mcWindow)
        } else if isMissionControlActive || !tiles.isEmpty {
            teardown()
            isMissionControlActive = false
        }
    }

    /// The Dock owns Mission Control's fullscreen AX window.
    nonisolated private static func missionControlWindow() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let ref = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            // Mission Control's surface is a fullscreen (non-utility) window.
            if (subrole as? String) == "AXFullscreen" { return window }
        }
        return nil
    }

    // MARK: - Tiles

    private func rebuildTiles(for mcWindow: AXUIElement) {
        guard let mcFrame = Self.frame(of: mcWindow) else { teardown(); return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mcWindow, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { teardown(); return }
        var tileFrames: [(AXUIElement, CGRect)] = []
        for child in children {
            guard let frame = Self.frame(of: child), frame.width > 120, frame.height > 90 else { continue }
            tileFrames.append((child, frame))
        }
        guard !tileFrames.isEmpty else { teardown(); return }
        // Reuse panels whose target frame barely moved; create the rest.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var usedPanels = Set<Int>()
        for (index, (ax, frame)) in tileFrames.enumerated() {
            let appFrame = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
            var pid: pid_t = 0
            AXUIElementGetPid(ax, &pid)
            if index < tiles.count {
                tiles[index].panel.setFrame(appFrame, display: true)
                usedPanels.insert(index)
            } else {
                if let panel = makeCloseButton(frame: appFrame, tile: ax, pid: pid, title: title(of: ax)) {
                    tiles.append((panel, pid, title(of: ax)))
                    usedPanels.insert(tiles.count - 1)
                }
            }
        }
        // Drop panels for tiles that disappeared (MC page changed).
        for index in tiles.indices.reversed() where !usedPanels.contains(index) && index >= tileFrames.count {
            tiles[index].panel.orderOut(nil)
            tiles.remove(at: index)
        }
    }

    private func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    private func makeCloseButton(frame: CGRect, tile: AXUIElement, pid: pid_t, title: String?) -> NSPanel? {
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: MissionControlTileOverlay(
            onHover: { hovering in
                // Dim the rest of the tile so the button reads as attached.
                panel.backgroundColor = NSColor.black.withAlphaComponent(hovering ? 0.001 : 0)
            },
            onClose: { [weak self] in
                self?.closeTile(tile: tile, pid: pid, title: title)
            }))
        panel.orderFrontRegardless()
        return panel
    }

    /// Closing from Mission Control: raise the source window first (so the
    /// close lands on the right target) then press its AX close button.
    private func closeTile(tile: AXUIElement, pid: pid_t, title: String?) {
        AXUIElementPerformAction(tile, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
        var windows: CFTypeRef?
        let ref = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(ref, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return }
        let match = list.first { window in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
            return (t as? String) == title && title != nil
        } ?? list.first
        guard let match else { return }
        var buttons: CFTypeRef?
        guard AXUIElementCopyAttributeValue(match, kAXChildrenAttribute as CFString, &buttons) == .success,
              let children = buttons as? [AXUIElement] else { return }
        for child in children {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == kAXCloseButtonSubrole as String {
                AXUIElementPerformAction(child, kAXPressAction as CFString)
                return
            }
        }
    }

    private func teardown() {
        for tile in tiles { tile.panel.orderOut(nil) }
        tiles.removeAll()
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              let p, CFGetTypeID(p) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        _ = AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let s, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        _ = AXValueGetValue(s as! AXValue, .cgSize, &size)
        // AX top-left based; keep in AX space for tile matching, flip at the UI edge.
        return CGRect(origin: origin, size: size)
    }
}

/// The ✕ button rendered inside a tile-sized click-through panel; only the
/// button itself intercepts clicks, the rest passes through to Mission Control.
private struct MissionControlTileOverlay: View {
    let onHover: (Bool) -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).allowsHitTesting(false)
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .shadow(radius: 3)
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: 26)
                .offset(x: 10, y: 10)
                .opacity(hovering ? 1 : 0)
                .onHover { hovering in
                    onHover(hovering)
                    self.hovering = hovering
                }
                .accessibilityLabel("Close window")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
