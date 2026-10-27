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
    static let items: [Item] = [
        Item(symbol: "sparkles.rectangle.stack", title: "Liquid Glass design",
             detail: "One sidebar, System Settings–style settings with search, and glass only on floating controls."),
        Item(symbol: "hifispeaker.2.fill", title: "Clean HomePod and AirPlay audio",
             detail: "A lookahead limiter and a realtime mixer remove the crackle. Magic Boost now works like SoundSource."),
        Item(symbol: "speaker.wave.3.fill", title: "Volume Overdrive",
             detail: "Push a quiet app up to 400% without clipping, per app."),
        Item(symbol: "bolt.horizontal.circle", title: "33 new actions",
             detail: "Selected text, clipboard items, menu paths, text on screen, MIDI and OSC, input sources, Bluetooth and more."),
        Item(symbol: "command.square.fill", title: "Hyper key and key remapping",
             detail: "Caps Lock as ⌃⌥⇧⌘, any key remapped, and a reversed mouse wheel that leaves the trackpad natural."),
        Item(symbol: "record.circle", title: "Recording",
             detail: "Restart a take in one click, and turn on Do Not Disturb while recording.")
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
