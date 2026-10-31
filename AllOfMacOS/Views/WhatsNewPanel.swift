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
    /// Items that alter defaults people already use say so with a note.
    static let items: [Item] = [
        Item(symbol: "arrow.turn.left.up", title: "L-Shaped Swipe Takes the Top Corner",
             detail: "On a title bar, swipe left then up without lifting your fingers to snap the window to the top-left quarter, or right then up for the top-right. It works as one smooth turn or with a short rest at the corner, from anywhere, including a maximized window. A swipe up on its own still maximizes.",
             module: .tiling),
        Item(symbol: "arrow.up.left.and.arrow.down.right", title: "Swipe Up Always Maximizes",
             detail: "A two-finger swipe up on a title bar now maximizes the window from wherever it is: a half, any quarter (bottom-right no longer goes to top-right), a third or a sixth, also as the next motion in the same touch. No title-bar gesture snaps to the top or bottom half any more, and a swipe down on a bottom quarter puts the window back.",
             module: .tiling, note: "New default"),
        Item(symbol: "rectangle.grid.2x2", title: "A redesigned Workspace",
             detail: "A status header, setup steps side by side, module tiles with live counts, quick-action tiles, and an overview of recent activity, today's actions with a 7-day chart, and this Mac's CPU, memory, disk and battery."),
        Item(symbol: "wrench.and.screwdriver", title: "104 System Tools",
             detail: "New Display & Sound (resolution, brightness, wallpaper, output and input devices, volume, startup sound), Battery & Energy (battery details, sleep timer, stay awake while an app runs), Apps & Processes (force quit, top CPU and memory, relaunch, login items), Disk & Storage (eject a disk, verify, Time Machine, snapshots), Network (Wi-Fi details, ping, DNS, public IP, listening ports) and System Info groups, plus Low Power Mode, Hide Menu Bar and Finder tools. Text & Developer tools are gone. This Mac gauges and Control Center–style toggles sit on top.",
             module: .systemTools),
        Item(symbol: "textformat.size", title: "Standard macOS text and controls",
             detail: "Every page and Settings use the system text sizes (13 pt body) and regular controls again, with the sidebar following your sidebar size in System Settings. Settings rows put their description under the title, Automation, Window Tiling and Audio rows have room again, Capture shows larger thumbnails, Insights charts the runs of each day, and the palette, What's New and tour are sized like Spotlight and Apple's own panels.")
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
        // Isolated previews can show the panel for review
        // (`--aom-preview-whats-new`) without reading or recording the
        // last-seen version; real launches never take this path.
        if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-whats-new") {
            WhatsNewPanelController.shared.show(version: current)
            return
        }
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
        let hosting = NSHostingView(rootView: WhatsNewView(version: version) { [weak self] in self?.close() })
        // As tall as the list, up to `maxHeight`; a longer list scrolls, a
        // short one leaves no empty glass under it.
        let fitting = hosting.fittingSize.height
        let height = fitting.isFinite && fitting > 0
            ? min(WhatsNewView.maxHeight, max(WhatsNewView.minHeight, ceil(fitting))) : WhatsNewView.maxHeight
        let size = NSSize(width: WhatsNewView.width, height: height)
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
        panel.contentView = hosting
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
    /// 3.3.6: 380 → 460 wide, 500 → 600 tall at most, for 13 pt text.
    static let width: CGFloat = 460
    /// The panel grows with its list up to this height, then the list scrolls.
    static let maxHeight: CGFloat = 600
    /// A floor for the measured height (the header, one row and the buttons).
    static let minHeight: CGFloat = 200

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

    private var list: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x5) {
            ForEach(sections, id: \.title) { section in
                // A card group, not `AOMSection`: the section's first-divider
                // cover is drawn past the card's corners and showed as a
                // white line on the panel's glass.
                AOMCardGroup(section.title) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        WhatsNewRow(item: item, showsDivider: index > 0)
                    }
                }
            }
            Text("Items marked New default change how something you already use behaves; each one says where to turn it off.")
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AOMSpace.x1)
        }
        .padding(.bottom, AOMSpace.x1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            HStack(alignment: .center, spacing: AOMSpace.x3) {
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text("What's New")
                        .font(AOMFont.heroSentence)
                        .foregroundStyle(AOMColor.text)
                    Text("All of MacOS \(version)")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x2)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AOMFont.title.weight(.regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close What's New")
            }
            // The whole list when it fits (the panel is then exactly as tall
            // as it), a scroll view once the panel reaches `maxHeight`.
            ViewThatFits(in: .vertical) {
                list
                // No scroller: with "Show scroll bars: Always" a legacy
                // scroller drew a black track on the panel's glass, and
                // `.hidden` still shows it under that setting; `.never` doesn't.
                ScrollView { list }
                    .scrollIndicators(.never)
            }
            HStack(spacing: AOMSpace.x2) {
                Button("Full Release Notes") {
                    if let url = URL(string: "https://github.com/kyw1-2/All-of-MacOS/releases") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: AOMSpace.x2)
                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
                    .aomPrimaryButton()
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: Self.width)
        .aomFloatingSurface(.panel, radius: AOMRadius.panel)
    }
}

/// One highlight as a section row: the module badge, the title with its
/// pill, and the detail in full (rows elsewhere keep to one line; these are
/// read once, so nothing is truncated).
private struct WhatsNewRow: View {
    let item: WhatsNew.Item
    var showsDivider = true
    /// The row's module squircle: the Workspace tile size (design-336 b.7).
    static let badge: CGFloat = AOMIcon.tileBadge

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x3) {
            AOMModuleBadge(symbol: item.symbol, hue: item.module?.hue ?? AOMColor.accent, size: Self.badge)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
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
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowInset + Self.badge + AOMSpace.x3) }
        }
        .accessibilityElement(children: .combine)
    }
}
