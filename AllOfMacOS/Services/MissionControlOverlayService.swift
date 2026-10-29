import AppKit
import ApplicationServices
import SwiftUI

/// Mission Control Plus parity: when Mission Control is open, poll its AX
/// tree for the window thumbnails and float a small ✕ button panel over each
/// — clicking one closes the thumbnail's window with its own close button, so
/// closing windows from Mission Control takes one click. Mission Control
/// ending tears the overlays down. Mechanism after Mission Control Plus 1.24
/// (ExposeController.performTimerBasedUpdate + CloseButtonWindow).
///
/// 3.3.3: the thumbnails come from `MissionControlWindows` (WindowManager's
/// tree on macOS 27, the Dock's before), and the window behind a thumbnail is
/// found by its app and title. Until 3.3.2 the window was looked up among the
/// windows of the process `AXUIElementGetPid` reported for the thumbnail,
/// which is the process that draws Mission Control, so the ✕ never found it.
/// A click also checks AOM's switch, its pause, the lock and the window app's
/// own pause, and never closes one of AOM's windows.
@MainActor
final class MissionControlOverlayService: ObservableObject {
    static let shared = MissionControlOverlayService()

    static let defaultsEnabledKey = "AOMMissionControlButtons"

    @Published private(set) var isMissionControlActive = false
    private var pollTimer: Timer?
    private var tiles: [(panel: NSPanel, thumbnail: MissionControlThumbnail)] = []
    private let probeQueue = DispatchQueue(label: "com.kyw.allofmacos.mission-control-probe", qos: .utility)
    private var probeInFlight = false
    private var generation = 0
    private struct Snapshot: @unchecked Sendable {
        let thumbnails: [MissionControlThumbnail]?
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsEnabledKey) as? Bool ?? true
    }

    /// Whether the poller runs, so `isMissionControlActive` is current.
    var isPolling: Bool { pollTimer != nil }

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
        guard isEnabled, AutomationGate.isOn, !ScreenLock.isLocked else {
            generation += 1
            if isMissionControlActive || !tiles.isEmpty { teardown() }
            return
        }
        guard !probeInFlight else { return }
        probeInFlight = true
        let requestGeneration = generation
        probeQueue.async { [weak self] in
            let snapshot = Snapshot(thumbnails: MissionControlWindows.liveThumbnails())
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probeInFlight = false
                guard self.pollTimer != nil, self.generation == requestGeneration,
                      self.isEnabled, AutomationGate.isOn, !ScreenLock.isLocked else { return }
                if let thumbnails = snapshot.thumbnails {
                    if !self.isMissionControlActive { self.isMissionControlActive = true }
                    self.rebuildTiles(thumbnails)
                } else if self.isMissionControlActive || !self.tiles.isEmpty {
                    self.teardown()
                }
            }
        }
    }

    // MARK: - Tiles

    private func rebuildTiles(_ thumbnails: [MissionControlThumbnail]) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        // Thumbnails too small for a button keep none (as in 3.3.2).
        let shown = thumbnails.filter { $0.frame.width > 120 && $0.frame.height > 90 }
        for (index, thumbnail) in shown.enumerated() {
            let frame = CGRect(x: thumbnail.frame.minX, y: top - thumbnail.frame.maxY,
                               width: thumbnail.frame.width, height: thumbnail.frame.height)
            if index < tiles.count {
                let old = tiles[index]
                if old.thumbnail.identifier == thumbnail.identifier, old.thumbnail.title == thumbnail.title {
                    if old.panel.frame != frame { old.panel.setFrame(frame, display: true) }
                    tiles[index].thumbnail = thumbnail
                    continue
                }
                // Another window can take the same place. Its ✕ must not keep
                // the previous window captured in a closure.
                old.panel.orderOut(nil)
                tiles[index] = (makeCloseButton(frame: frame, thumbnail: thumbnail), thumbnail)
            } else {
                tiles.append((makeCloseButton(frame: frame, thumbnail: thumbnail), thumbnail))
            }
        }
        while tiles.count > shown.count { tiles.removeLast().panel.orderOut(nil) }
    }

    private func makeCloseButton(frame: CGRect, thumbnail: MissionControlThumbnail) -> NSPanel {
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
                self?.closeTile(thumbnail)
            }))
        panel.orderFrontRegardless()
        return panel
    }

    /// The ✕: the one window the thumbnail stands for (its app and title,
    /// never a guess), closed with its own close button, so the app may ask
    /// to save.
    private func closeTile(_ thumbnail: MissionControlThumbnail) {
        guard AutomationGate.isOn, !TriggerSuppression.shared.isPaused, !ScreenLock.isLocked else { return }
        guard let target = MissionControlWindows.window(for: thumbnail) else {
            GestureLog.shared.logFromAnyThread("Mission Control: no single window matches \"\(thumbnail.title ?? "?")\"",
                                               level: .error)
            return
        }
        guard target.pid != ProcessInfo.processInfo.processIdentifier,
              !TriggerSuppression.shared.isPaused(forApp: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier)
        else { return }
        if !MissionControlWindows.close(target.element) {
            GestureLog.shared.logFromAnyThread("Mission Control: the window has no close button", level: .error)
        }
    }

    private func teardown() {
        if isMissionControlActive { isMissionControlActive = false }
        for tile in tiles { tile.panel.orderOut(nil) }
        tiles.removeAll()
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
