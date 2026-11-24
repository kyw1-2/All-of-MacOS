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
        Item(symbol: "ellipsis.circle", title: "Steadier Actions Panel",
             detail: "The Actions panel scrolls when it's long, keeps your selection by action rather than position, and closes when you change page, so Return can't run something that just disappeared.",
             note: "Fixed"),
        Item(symbol: "bolt", title: "Buttons Act on What You See Now",
             detail: "Run, Duplicate, Pin and Delete for an automation, and Copy or Pin for a clipboard item, look the item up when pressed — an edit made a moment ago is what runs, and a deleted item is left alone.",
             note: "Fixed"),
        Item(symbol: "menubar.rectangle", title: "Menu Bar Page Keeps Your Place",
             detail: "Resizing the window past the point where the pane list becomes a pop-up no longer resets the pane. The header tells apart hiding off, no Accessibility, still reading and nothing hidden.",
             note: "Fixed"),
        Item(symbol: "macwindow", title: "Actions and Search Moved to the Toolbar",
             detail: "The bar under every page is gone: Actions (⋯) and Search sit in the window's toolbar, even with the sidebar hidden. When you select something that has actions, a slim bar with them appears under the page.",
             note: "New"),
        Item(symbol: "rectangle.split.2x1", title: "Menu Bar Settings as a List",
             detail: "The Menu Bar page lists its eight panes down the side, like Bartender's settings, and becomes a pop-up in a narrow window; ↑ and ↓ move between them.",
             note: "New"),
        Item(symbol: "checkmark.circle", title: "One Status on Workspace",
             detail: "Workspace's header says what is true — ready, paused or missing a permission — with the one action that fixes it, instead of a second status card underneath. Cards in the main window are solid and flat.",
             note: "New"),
        Item(symbol: "sparkles.rectangle.stack", title: "A New Look for the Main Window",
             detail: "The sidebar shows each tool as a colour icon like System Settings, and you can pin up to six pages under Favorites (right-click a page). Page headers say how the tool is doing beside its icon, Workspace's tool rows carry the same icons, and counts sit in small capsules.",
             note: "New"),
        Item(symbol: "menubar.rectangle", title: "Simpler Menu Bar Panel",
             detail: "The Mute Mic tile is gone from the panel. A mute you start elsewhere still shows at the top with Unmute.",
             note: "New default"),
        Item(symbol: "plusminus.circle", title: "Big Comparisons Don't Freeze",
             detail: "Comparing two long clipboard texts happens in the background with “Comparing…”, and nothing of either copy stays in memory after you close the screen.",
             note: "Fixed"),
        Item(symbol: "tray.full", title: "Drop Shelf Undo and Drops",
             detail: "Undoing Delete Shelf points at the file in the Trash when its old place was taken by another file, and two drops arriving at once each keep their progress.",
             module: .files, note: "Fixed"),
        Item(symbol: "calendar.badge.clock", title: "Free Times Reads Less",
             detail: "Free Times now reads only when events start and end and whether they block time — no titles, places or notes. A saved search with an impossible time range no longer quits AOM.",
             note: "Fixed"),
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
    /// 380 → 460 wide, 500 → 600 tall at most, for 13 pt text.
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
                // The panel's identity, like the page headers: a squircle
                // with the release's glyph.
                AOMModuleBadge(symbol: "sparkles", size: AOMIcon.headerBadge)
                    .accessibilityHidden(true)
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
                    .keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle())
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
            AOMModuleBadge(symbol: item.symbol, size: Self.badge)
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
