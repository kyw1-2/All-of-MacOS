import AppKit
import SwiftUI

/// CleanShot's "What's New" after an update: shown once per new version, in a
/// non-activating floating panel so it never takes focus from the app in use.
/// A first install records the version silently (the tutorial covers that).
enum WhatsNew {
    static let lastSeenKey = "AOMLastSeenVersion"

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Highlights of the current version, bundled so the panel works offline.
    /// 3.3.2: the title-bar snap now follows Swish, and several of its
    /// gestures act on windows where 3.3.1 did nothing or centred them; each
    /// one says where it is turned off.
    static let items: [Item] = [
        Item(symbol: "hand.draw.fill", title: "Swish-style title-bar snap",
             detail: "Quick flicks snap at once, a window at the top moves down to the bottom half or a quarter, diagonals pick a quarter, and resting two fingers still for 2 s cancels. The grid is 2 × 2 (halves and quarters, no thirds) unless you pick 3 × 2 or 3 × 3 in Window Tiling › Trackpad Gestures › Grid."),
        Item(symbol: "arrow.down.to.line", title: "Swipe down now minimizes",
             detail: "A short swipe down on a window that is not snapped minimizes it (3.3.1 centred it). To keep centring, set Window Tiling › Trackpad Gestures › Swipe down on a free window to Center."),
        Item(symbol: "arrow.down.right.and.arrow.up.left", title: "Pinch to close or quit",
             detail: "Pinch in on a title bar to close the window, twice to quit the app (it may ask to save); pinch out for full screen. Turn off: Window Tiling › Trackpad Gestures › Pinch gestures."),
        Item(symbol: "rectangle.on.rectangle", title: "Hold, then swipe: Spaces and full screen",
             detail: "Rest two fingers on a title bar for half a second, then swipe sideways to move the window to the next Space, up for full screen, down to minimize. ⌥ swipes do the same for Spaces and close the window. Turn off: Window Tiling › Trackpad Gestures › Tap and hold gestures and Modifier gestures."),
        Item(symbol: "dock.rectangle", title: "Dock and menu-bar gestures",
             detail: "Two fingers on a Dock icon or the menu bar minimize, unminimize, hide and switch apps; the top-bar Space swipe now switches on lift, so resting 2 s cancels it. Turn off: Window Tiling › Trackpad Gestures › Dock gestures, Menu-bar gestures."),
        Item(symbol: "hifispeaker.fill", title: "Cleaner HomePod and AirPlay audio",
             detail: "A true-peak limiter with headroom for the receiver, smoother resampling and drift control, larger IO buffers and no restart on a repeated format notice remove the crackle sources AOM's diagnostics found."),
        Item(symbol: "slider.horizontal.below.rectangle", title: "Per-app balance",
             detail: "In Audio, open an app's effects to pan it left or right, beside Volume Overdrive.")
    ]

    /// Pure decision: show for an update, never for a first install or a re-launch.
    static func shouldShow(lastSeen: String?, current: String) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        return lastSeen != current
    }

    @MainActor
    static func presentIfUpdated(defaults: UserDefaults = .standard) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !current.isEmpty else { return }
        let lastSeen = defaults.string(forKey: lastSeenKey)
        defaults.set(current, forKey: lastSeenKey)
        guard shouldShow(lastSeen: lastSeen, current: current) else { return }
        WhatsNewPanelController.shared.show(version: current)
    }
}

@MainActor
final class WhatsNewPanelController {
    static let shared = WhatsNewPanelController()
    private var panel: NSPanel?

    func show(version: String) {
        let size = NSSize(width: 380, height: 470)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        panel.contentView = NSHostingView(rootView: WhatsNewView(version: version) { [weak self] in self?.close() })
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct WhatsNewView: View {
    let version: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.title2.weight(.semibold))
                    Text("All of MacOS \(version)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close What's New")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WhatsNew.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack {
                Button("Full Release Notes") {
                    if let url = URL(string: "https://github.com/kyw1-2/All-of-MacOS/releases") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Continue", action: close).keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 380, height: 470)
        .aomFloatingSurface(.panel, radius: 22)
    }
}
