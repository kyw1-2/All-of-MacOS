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
    private var tiles: [(panel: NSPanel, element: AXUIElement, pid: pid_t, windowTitle: String?)] = []
    private let probeQueue = DispatchQueue(label: "com.kyw.allofmacos.mission-control-probe", qos: .utility)
    private var probeInFlight = false
    private var generation = 0
    private struct TileSnapshot: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
        let pid: pid_t
        let title: String?
    }

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
        generation += 1
        teardown()
    }

    // MARK: - Poll

    private func poll() {
        guard isEnabled, !ScreenLock.isLocked else {
            generation += 1
            if isMissionControlActive || !tiles.isEmpty { teardown() }
            return
        }
        guard !probeInFlight else { return }
        probeInFlight = true
        let requestGeneration = generation
        probeQueue.async { [weak self] in
            let snapshot = Self.captureSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probeInFlight = false
                guard self.pollTimer != nil, self.generation == requestGeneration,
                      self.isEnabled, !ScreenLock.isLocked else { return }
                if let snapshot {
                    if !self.isMissionControlActive { self.isMissionControlActive = true }
                    self.rebuildTiles(snapshot)
                } else if self.isMissionControlActive || !self.tiles.isEmpty {
                    self.teardown()
                }
            }
        }
    }

    nonisolated private static func captureSnapshot() -> [TileSnapshot]? {
        guard let window = missionControlWindow() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.compactMap { element in
            guard let rect = frame(of: element), rect.width > 120, rect.height > 90 else { return nil }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return TileSnapshot(element: element, frame: rect, pid: pid, title: title as? String)
        }
    }

    /// The Dock owns Mission Control's fullscreen AX window.
    nonisolated private static func missionControlWindow() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let ref = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(ref, 0.1)
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

    private func rebuildTiles(_ snapshot: [TileSnapshot]) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for (index, tile) in snapshot.enumerated() {
            let frame = CGRect(x: tile.frame.minX, y: top - tile.frame.maxY,
                               width: tile.frame.width, height: tile.frame.height)
            if index < tiles.count {
                let old = tiles[index]
                if CFEqual(old.element, tile.element), old.pid == tile.pid, old.windowTitle == tile.title {
                    if old.panel.frame != frame { old.panel.setFrame(frame, display: true) }
                    continue
                }
                // A new window can occupy the same tile index. Its close action
                // must not keep the previous window captured in a closure.
                old.panel.orderOut(nil)
                if let panel = makeCloseButton(frame: frame, tile: tile.element, pid: tile.pid, title: tile.title) {
                    tiles[index] = (panel, tile.element, tile.pid, tile.title)
                }
            } else if let panel = makeCloseButton(frame: frame, tile: tile.element, pid: tile.pid, title: tile.title) {
                tiles.append((panel, tile.element, tile.pid, tile.title))
            }
        }
        while tiles.count > snapshot.count { tiles.removeLast().panel.orderOut(nil) }
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
            onHover: { [weak panel] hovering in
                // Dim the rest of the tile so the button reads as attached.
                panel?.backgroundColor = NSColor.black.withAlphaComponent(hovering ? 0.001 : 0)
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
        guard pid > 0, let title, !title.isEmpty else { return }
        var windows: CFTypeRef?
        let ref = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(ref, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return }
        let matches = list.filter { window in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
            return (t as? String) == title
        }
        // An unresolved/duplicate title is not permission to close the first
        // unrelated window belonging to this process.
        guard matches.count == 1, let match = matches.first else { return }
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
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
        if isMissionControlActive { isMissionControlActive = false }
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
