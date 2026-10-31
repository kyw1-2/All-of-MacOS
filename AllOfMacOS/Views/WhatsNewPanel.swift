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
        Item(symbol: "sidebar.left", title: "A Redesigned Main Window",
             detail: "A Productivity section in the sidebar with four new pages, list and detail layouts, toasts with Undo, and a Workspace you can customize: hide sections, choose its quick actions and see each tool's live status."),
        Item(symbol: "folder.badge.gearshape", title: "Folder Rules Tidy Your Folders",
             detail: "Hazel-style rules for Downloads, the Desktop or any folder: match by name, kind, date, size, download site or tags, then move, rename, tag, compress, extract, optimize images, install apps from disk images, or run an automation or a Shortcut. Every rule starts off and shows what it would do first; Undo puts things back.",
             module: .folderRules),
        Item(symbol: "character.cursor.ibeam", title: "Actions Over Selected Text",
             detail: "Select text in any app and a PopClip-style bar offers Copy, Search, Translate (Papago), Look Up, Calculate, Pin to Clipboard and transforms such as Change Case, Format JSON or Base64. It never takes the keyboard and stays out of password fields. Off until you turn it on.",
             module: .textActions),
        Item(symbol: "cursorarrow.click.2", title: "Click with the Keyboard",
             detail: "Press ⇧⌘Space and every button, link and field in the front window gets one or two letters, Homerow-style; type them to click. Change the shortcut in Settings › Shortcuts › Productivity; the options are in Text Actions › Click Hints.",
             module: .textActions, note: "New shortcut"),
        Item(symbol: "folder", title: "Open & Save Helper and Drop Shelf",
             detail: "A panel beside every Open and Save dialog with your Finder windows, recent and favorite folders (Default Folder X). Shake the pointer or press ⇧ while dragging files for a Drop Shelf that holds them across apps (Dropover, Yoink). The Files page also lists your newest downloads and screenshots.",
             module: .files),
        Item(symbol: "timer", title: "Focus Sessions",
             detail: "Focus and break timers with a menu bar countdown and a daily log, hiding distracting apps while you focus, quitting apps left idle (with a memory saver for 8 GB Macs), and optional eye and stand-up reminders.",
             module: .focus),
        Item(symbol: "ruler", title: "Measure Anything on Screen",
             detail: "Press ⇧⌘7 to measure distances, sizes and colors in any app, in points or pixels, PixelSnap-style. Also in the Capture menu and on the Capture page.",
             module: .capture, note: "New shortcut"),
        Item(symbol: "doc.on.clipboard", title: "Paste-Style Preview Again",
             detail: "The clipboard shelf and its preview look as they did before, and one click on an item's title renames it, as in Paste.",
             module: .clipboard),
        Item(symbol: "magnifyingglass", title: "More from ⌘K",
             detail: "The palette now calculates and converts units, opens quicklinks (\"g cats\" searches Google), searches the menus of the app you were using, your Safari and Chrome bookmarks and recent files, and has a window switcher with live thumbnails (AltTab). Hold ⌘ in any app to see its shortcuts (KeyClu), off until you turn it on in Settings › Shortcuts."),
        Item(symbol: "arrow.triangle.branch", title: "Link Rules",
             detail: "Choose which browser opens which link, for example uos.ac.kr in Safari, and remove tracking parameters such as utm_source and fbclid; Figma, Zoom and Notion links open in their apps, and ⌥-click picks a browser. Settings › General › Links; it works once you make All of MacOS your default browser there."),
        Item(symbol: "keyboard", title: "Input Source per App",
             detail: "Settings › General › Input sources switches the keyboard when an app comes to the front: Terminal in English, KakaoTalk in Korean, and other apps back to what they used last (Input Source Pro)."),
        Item(symbol: "wrench.and.screwdriver", title: "23 New System Tools",
             detail: "Homebrew (outdated packages, upgrades, clean up, services, search), VPN and Tailscale, ten PDF page tools, the Metal HUD, an opt-in weather card and Install Disk Image…; Uninstall App… lists what an app left in your Library before anything goes to the Trash.",
             module: .systemTools),
        Item(symbol: "mic.slash", title: "Microphone Mute and a Fuller Mixer",
             detail: "Mute the microphone in every app with one shortcut, push to talk with a held key, or mute when Zoom or FaceTime opens. The App Audio mixer lists apps the way SoundSource does, each with its level, volume, Magic Boost, output and effects.",
             module: .audio),
        Item(symbol: "hifispeaker", title: "Fewer HomePod Clicks",
             detail: "When an app's own audio drops out for a moment, AOM now fades around the gap instead of playing a click, keeps its audio buffers in memory so a busy Mac can't page them out, and stops re-requesting the HomePod's buffer size during a session.",
             module: .audio),
        Item(symbol: "checkmark.seal", title: "25 Fixes",
             detail: "Among them: abbreviations stay quiet while AOM is paused, modifier keys no longer stick after macOS pauses the keyboard tap, Mission Control keys work without the ✕ buttons, unchanged launches keep older backups, and Apple Events errors say where to allow access.")
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
                // The panel's identity, like the page headers: a squircle
                // with the release's glyph.
                AOMModuleBadge(symbol: "sparkles", hue: AOMColor.accent, size: AOMIcon.headerBadge)
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
