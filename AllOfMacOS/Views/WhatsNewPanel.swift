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
        /// The page the item belongs to: the panel groups by it and the badge
        /// takes its hue. nil: the whole app.
        var module: AOMModule? = nil
        /// A pill beside the title, for an item that changes how something
        /// people already use behaves ("New default").
        var note: String? = nil
        var id: String { title }
    }

    /// Highlights of the current version, bundled so the panel works offline.
    /// 3.3.3: several gestures change their default behaviour (multi-motion,
    /// tab pinches, ⇧/⌃ swipes, the Dock pinch waiting for a second pinch,
    /// pinboard search); each of those items says where it is turned off.
    static let items: [Item] = [
        Item(symbol: "sparkles", title: "A calmer, consistent look",
             detail: "Workspace opens with one status line and what needs your attention, and every page uses the same sections, rows and ⓘ help. Window Tiling is split into Title-bar snap, Gestures, Grid & layout, Keyboard, Dock & menu bar and Advanced. Pause AOM is in the new Controls menu."),
        Item(symbol: "hand.draw.fill", title: "Keep gesturing without lifting",
             detail: "Rest briefly on a title-bar swipe or pinch, then move again for the next gesture in the same touch. A tooltip by the pointer names where the window goes, and Esc cancels. Turn it off: Window Tiling › Multi-motion pause › Off.",
             module: .tiling, note: "New default"),
        Item(symbol: "square.on.square", title: "Tab gestures",
             detail: "Pinch in on a tab to close it. Tap and hold a Finder, Preview or Safari tab, then lift, to move it to its own window. Tabs in Chrome, Arc, Xcode and VS Code can be closed; in Firefox a pinch on the tab strip still closes the window. Turn off: Window Tiling › Tab gestures.",
             module: .tiling, note: "New default"),
        Item(symbol: "command", title: "Modifier roles and hotkeys",
             detail: "Choose the keys for the Super, General, Screen, Secondary and Tertiary roles; AOM refuses keys that clash. ⇧ swipes now use the 3 × 2 grid and ⌃ swipes the 3 × 3 grid. With the ⌃⌥ hotkeys on, add ⌘ for another display or ⇧ for the 3 × 2 grid, and press Esc to centre. Optional: macOS native tiling, and gestures anywhere on a window while you hold Super.",
             module: .tiling, note: "New default"),
        Item(symbol: "dock.rectangle", title: "Dock, menu bar and Mission Control",
             detail: "Pinch in twice on a Dock icon to minimize the app's windows, out twice to bring them back, so a single pinch now acts when you lift. A third finger cancels. Swiping up on the menu bar restores every minimized window on that display. New options: Mission Control gestures, tap the menu bar to scroll to the top. Turn off the double pinch: Window Tiling › Dock: pinch twice.",
             module: .tiling, note: "New default"),
        Item(symbol: "lock.shield", title: "Clipboard privacy and Paste-style pinboards",
             detail: "Suggestions never read password fields, secure keyboard entry or excluded apps, and AI tools over MCP no longer see secrets hidden in rich text, links, image text or long clips. Search highlights text inside images, and dragging over an image preview copies that part. Searching from a pinboard now covers every list (turn off: Clipboard › Search all lists from a pinboard). Link cards with page titles are optional and off.",
             module: .clipboard, note: "New default"),
        Item(symbol: "square.and.arrow.down", title: "BetterTouchTool presets",
             detail: "Import Preset reads .bttpreset files and copied BTT triggers: trackpad, keyboard, key sequences, mouse, named and system triggers, app groups and about 180 actions. A report lists what was imported, what was approximated and why, and what was skipped. Scripts and shell commands arrive turned off for review.",
             module: .automation),
        Item(symbol: "pianokeys", title: "MIDI, pressure and value bindings",
             detail: "MIDI triggers read Pitch Bend, Program Change and pressure messages too. A MIDI fader or knob, Force Touch pressure or scrolling with a modifier can set the volume, an app's volume or the display brightness directly. New: Force Touch stage triggers and sliders in floating menus.",
             module: .automation),
        Item(symbol: "photo.on.rectangle.angled", title: "Recording backgrounds and Annotate tools",
             detail: "Edit Recording places a video on a colour, gradient or picture, with click styles and colours, a cursor highlight and optional hidden desktop icons. Annotate adds text styles, an eraser (X) and image layers you can move, resize and rotate. Arrows now point the way you drag.",
             module: .capture),
        Item(symbol: "hifispeaker.fill", title: "Audio presets, headphone EQ and AirPlay",
             detail: "Magic Boost presets (Music, Speech, Movie, Night), an EQ curve per output that switches with it, including imported AutoEQ files, and an Audio Unit effect on every output. On a HomePod a skipped cycle now fades back in, and moving an app to another output no longer skips audio.",
             module: .audio)
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
        let size = NSSize(width: WhatsNewView.width, height: WhatsNewView.height)
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
        let margin = AOMSpace.x5
        panel.setFrame(NSRect(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The panel: a page-style header, one section card per module with a row
/// per item (module badge, title, optional pill, detail), and the actions.
/// Floating chrome outside, opaque cards inside, as on every AOM page.
private struct WhatsNewView: View {
    static let width: CGFloat = 420
    static let height: CGFloat = 560

    let version: String
    let close: () -> Void

    /// The items in their order, grouped by module (the app-wide ones first).
    private var sections: [(title: String, items: [WhatsNew.Item])] {
        var titles: [String] = []
        var grouped: [String: [WhatsNew.Item]] = [:]
        for item in WhatsNew.items {
            let title = item.module?.title ?? "Everywhere"
            if grouped[title] == nil { titles.append(title) }
            grouped[title, default: []].append(item)
        }
        return titles.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            HStack(alignment: .center, spacing: AOMSpace.x3) {
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("What's New")
                        .font(AOMFont.pageStatus)
                        .foregroundStyle(AOMColor.text)
                    Text("All of MacOS \(version)")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x2)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close What's New")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.x5) {
                    ForEach(sections, id: \.title) { section in
                        AOMSection(section.title) {
                            ForEach(section.items) { WhatsNewRow(item: $0) }
                        }
                    }
                    Text("Items marked New default change how something you already use behaves; each one says where to turn it off.")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, AOMSpace.x1)
                }
                .padding(.bottom, AOMSpace.x1)
            }
            .scrollIndicators(.automatic)
            HStack(spacing: AOMSpace.x2) {
                Button("Full Release Notes") {
                    if let url = URL(string: "https://github.com/kyw1-2/All-of-MacOS/releases") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: AOMSpace.x2)
                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
                    .aomPrimaryButton()
            }
            .controlSize(.regular)
        }
        .padding(AOMSpace.x5)
        .frame(width: Self.width, height: Self.height)
        .aomFloatingSurface(.panel, radius: AOMRadius.panel)
    }
}

/// One highlight as a section row: the module badge, the title with its
/// pill, and the detail in full (rows elsewhere keep to one line; these are
/// read once, so nothing is truncated).
private struct WhatsNewRow: View {
    let item: WhatsNew.Item

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x3) {
            AOMModuleBadge(symbol: item.symbol, hue: item.module?.hue ?? AOMColor.accent)
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                    Text(item.title)
                        .font(AOMFont.headline)
                        .foregroundStyle(AOMColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = item.note { AOMStatusPill(note, tone: .info) }
                }
                Text(item.detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x3)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowInset + AOMIcon.tileBadge + AOMSpace.x3) }
        .accessibilityElement(children: .combine)
    }
}
