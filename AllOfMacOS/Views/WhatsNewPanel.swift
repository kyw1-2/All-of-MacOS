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
    /// 3.3.5: the swipe-down and double-swipe changes alter defaults people
    /// already use; that item says so.
    static let items: [Item] = [
        Item(symbol: "wrench.and.screwdriver", title: "69 System Tools",
             detail: "Quick toggles with live state (Dark Mode, Keep Awake, Wi-Fi, mutes, Dock auto-hide, keyboard lock for cleaning), power and session commands, Finder, Dock and screenshot settings, maintenance, an app uninstaller and cleanup scans that only move items to the Trash, clipboard text and developer tools, a speed test and port lookup. A live status strip, favorites and recent tools sit on top.",
             module: .systemTools),
        Item(symbol: "arrow.up.and.down", title: "Swish double swipes",
             detail: "Swipe up or down, rest until the trackpad taps, and swipe the same way again for the top or bottom half. A swipe down no longer turns into the bottom half when it is long or quick, taking a swipe back to where it started cancels it, and unsnapped windows stay whole on a display.",
             module: .tiling, note: "New default"),
        Item(symbol: "rectangle.compress.vertical", title: "A compact main window",
             detail: "12 pt text, a smaller sidebar and toolbar title, a slim setup strip, two-line module tiles, one-line rows in Automation, Clipboard, Settings and Shortcuts, six capture thumbnails a row, and a denser palette, What's New and tour.")
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
    /// 3.3.5: 420 → 380 wide, 560 → 500 tall at most (smaller type fits more).
    static let width: CGFloat = 380
    /// The panel grows with its list up to this height, then the list scrolls.
    static let maxHeight: CGFloat = 500
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
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
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
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AOMSpace.x1)
        }
        .padding(.bottom, AOMSpace.x1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(alignment: .center, spacing: AOMSpace.x3) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("What's New")
                        .font(AOMFont.pageStatus)
                        .foregroundStyle(AOMColor.text)
                    Text("All of MacOS \(version)")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x2)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close What's New")
            }
            // The whole list when it fits (the panel is then exactly as tall
            // as it), a scroll view once the panel reaches `maxHeight`.
            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }
                    .scrollIndicators(.automatic)
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
            .controlSize(.small)
        }
        .padding(AOMSpace.x3)
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
    /// The row's module badge: one title line tall (3.3.5, was 24 pt).
    static let badge: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x2) {
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
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowInset + Self.badge + AOMSpace.x2) }
        }
        .accessibilityElement(children: .combine)
    }
}
