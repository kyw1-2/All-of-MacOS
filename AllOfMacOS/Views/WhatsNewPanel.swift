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
        Item(symbol: "hand.draw.fill", title: "Swish-style trackpad snap, round two",
             detail: "Swipe on a title bar for halves, thirds and now quarters in either order; swipe down on a snapped window to put it back."),
        Item(symbol: "rectangle.and.arrow.up.right.and.arrow.down.left", title: "Windows that keep their size",
             detail: "Apps with a fixed or minimum size now stay flush with the edge you snapped them to, from gestures and the Window menu alike."),
        Item(symbol: "checklist", title: "Trackpad readiness",
             detail: "Window Tiling checks Accessibility, haptic feedback and the Mission Control shortcuts the gestures rely on, with a link to fix each."),
        Item(symbol: "figure.walk.motion", title: "Reduce Motion and Increase Contrast",
             detail: "Animations respect Reduce Motion; chips, badges and notices get stronger outlines with Increase Contrast."),
        Item(symbol: "magnifyingglass", title: "Search System Tools",
             detail: "Find a tool from the toolbar, with a clear way back when nothing matches."),
        Item(symbol: "menubar.rectangle", title: "Tidier menus and names",
             detail: "The engine is called Automation everywhere, ⌘N and ⌘F work on Automation and Workspace, and developer items hide behind ⌥.")
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
