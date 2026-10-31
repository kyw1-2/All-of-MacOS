import AppKit
import SwiftUI

/// The command palette, after Raycast's root search and Action Panel: one
/// field that is focused on open, ↑↓ to move, ↩ for the primary action, ⌘↩
/// for the first secondary, ⌘K (or Actions) for every action of the row,
/// Esc to back out one level. With an empty query results are grouped by
/// kind; while searching they are one ranked list with the calculator and a
/// matched quicklink pinned on top and web and file searches as fallbacks
/// at the bottom. Shortcut hints are the user's real bindings.
///
/// 3.4 sources: the calculator (AOMCalculator), quicklinks ("g cats"), the
/// menus of the app that was in front before the palette opened, Chrome and
/// Safari bookmarks, Copy Link to Current Item, recent files and the latest
/// download and screenshot. They load when the palette opens and stop when
/// it closes.
struct QuickCommandPalette: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboardStore = ClipboardStore.shared
    @ObservedObject private var captureHistory = CaptureHistory.shared
    @ObservedObject private var quicklinks = PaletteQuicklinkStore.shared
    @StateObject private var session = PaletteSession()
    @StateObject private var recentFiles = PaletteRecentFiles()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var query = ""
    @State private var selectedID: String?
    @State private var showsActions = false
    @State private var actionIndex = 0
    @State private var editingQuicklinks = false
    @State private var editingLinkRouter = false
    @State private var hoveredID: String?
    @FocusState private var isFieldFocused: Bool

    struct PaletteAction {
        let title: String
        var symbol: String? = nil
        let run: () -> Void
    }

    /// Where a row goes while searching.
    enum Placement: Equatable {
        /// Ranked with the rest by how well its title matches.
        case ranked
        /// Always first: the calculator's answer, a matched quicklink.
        case pinned
        /// Always last: search the web or the disk for the text.
        case fallback
    }

    struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let section: Section
        var shortcut: String?
        let primary: PaletteAction
        /// ⌘↩ runs the first; all of them are in the Actions panel (⌘K).
        private(set) var secondaries: [PaletteAction]
        var placement: Placement = .ranked
        /// Short trailing text: a folder, a time, a profile.
        var accessory: String?
        /// An app or file icon instead of the symbol.
        var image: NSImage?
        /// Shown but unavailable (a disabled menu item).
        var isDimmed = false

        /// The palette stays a launcher, not a context menu.
        static let secondaryLimit = 3

        init(id: String, title: String, subtitle: String, icon: String, section: Section,
             shortcut: String? = nil, primary: PaletteAction, secondaries: [PaletteAction] = [],
             placement: Placement = .ranked, accessory: String? = nil, image: NSImage? = nil, isDimmed: Bool = false) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.section = section
            self.shortcut = shortcut
            self.primary = primary
            self.secondaries = Array(secondaries.prefix(Self.secondaryLimit))
            self.placement = placement
            self.accessory = accessory
            self.image = image
            self.isDimmed = isDimmed
        }

        /// The primary action first, then the secondaries.
        var actions: [PaletteAction] { [primary] + secondaries }
    }

    enum Section: String, CaseIterable {
        case calculator = "Calculator"
        case quicklinks = "Quicklinks"
        case commands = "Commands"
        case automations = "Automations"
        case clipboard = "Clipboard"
        case captures = "Recent captures"
        case recentFiles = "Recent files"
        case navigation = "Go to"
        // Listed only while searching, like Raycast's root search.
        case applications = "Applications"
        case menuItems = "Menu items"
        case bookmarks = "Bookmarks"
        case files = "Files"
        case fallback = "Search with"
    }

    /// Pure search and keyboard decisions, split from the view so they are
    /// testable without a window: with an empty (or blank) query the ranked
    /// rows are grouped by section in declaration order; otherwise pinned
    /// rows come first, then one ranked list — title prefix, then title,
    /// then subtitle, then section name, then a fuzzy title match — stable
    /// within a rank, then the fallbacks.
    enum PaletteSearch {
        enum EscapeOutcome: Equatable {
            /// The query has content: clear it and keep the palette open.
            case clearQuery
            /// The query is empty: dismiss the palette.
            case close
        }

        static func trimmedQuery(_ query: String) -> String {
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Esc backs out one level: clear the query first, then close.
        static func escapeOutcome(query: String) -> EscapeOutcome {
            trimmedQuery(query).isEmpty ? .close : .clearQuery
        }

        /// Lower rank sorts first; nil means the item does not match.
        static func rank(of item: PaletteItem, matching query: String) -> Int? {
            if item.title.lowercased().hasPrefix(query.lowercased()) { return 0 }
            if item.title.localizedCaseInsensitiveContains(query) { return 1 }
            if item.subtitle.localizedCaseInsensitiveContains(query) { return 2 }
            if item.section.rawValue.localizedCaseInsensitiveContains(query) { return 3 }
            if let score = PaletteFuzzy.score(query, item.title), score >= PaletteFuzzy.subsequenceFloor + 40 { return 4 }
            return nil
        }

        static func results(for items: [PaletteItem], query: String) -> [PaletteItem] {
            let trimmed = trimmedQuery(query)
            let ranked = items.filter { $0.placement == .ranked }
            guard !trimmed.isEmpty else {
                return Section.allCases.flatMap { section in ranked.filter { $0.section == section } }
            }
            let ordered = ranked.compactMap { item in rank(of: item, matching: trimmed).map { (item, $0) } }
                .enumerated()
                .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
                .map(\.element.0)
            return items.filter { $0.placement == .pinned } + ordered + items.filter { $0.placement == .fallback }
        }

        /// The action ⌘1…⌘3 or a click in the Actions panel runs, clamped.
        static func action(at index: Int, of item: PaletteItem) -> PaletteAction? {
            let actions = item.actions
            return actions.indices.contains(index) ? actions[index] : nil
        }
    }

    // MARK: Items

    private func close() { isPresented = false }

    private func captureKeys(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    private var keepAwakeTitle: String {
        KeepAwakeService.shared.isActive
            ? "Turn Off Keep Awake\(KeepAwakeService.shared.remainingDescription.map { " (\($0))" } ?? "")"
            : "Keep Awake"
    }

    private var trimmed: String { PaletteSearch.trimmedQuery(query) }
    private var isSearching: Bool { !trimmed.isEmpty }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        items += calculatorItems()
        items += quicklinkItems()
        items += commandItems()
        items += automationItems()
        items += clipboardItems()
        items += captureItems()
        items += recentFileItems()
        items += navigationItems()
        if isSearching {
            items += applicationItems()
            items += menuItems()
            items += bookmarkItems()
            items += fallbackItems()
        }
        return items
    }

    private func copyToClipboard(_ text: String, announce: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        GestureHUD.shared.show(title: "Copied", detail: announce)
    }

    private func calculatorItems() -> [PaletteItem] {
        guard isSearching, let result = AOMCalculator.evaluate(trimmed) else { return [] }
        let question = result.expression ?? trimmed
        let kind: String
        switch result.kind {
        case .number: kind = "Calculation"
        case .conversion: kind = "Conversion"
        case .base: kind = "Number base"
        }
        return [PaletteItem(
            id: "calculator", title: result.display, subtitle: question, icon: "equal.square", section: .calculator,
            primary: PaletteAction(title: "Copy Answer", symbol: "doc.on.doc") {
                close(); copyToClipboard(result.display, announce: result.display)
            },
            secondaries: [PaletteAction(title: "Copy Equation", symbol: "equal") {
                close(); copyToClipboard("\(question) = \(result.display)", announce: "\(question) = \(result.display)")
            }],
            placement: .pinned, accessory: kind)]
    }

    private func quicklinkItems() -> [PaletteItem] {
        guard isSearching else { return [] }
        let links = quicklinks.links
        if let match = PaletteQuicklinks.match(query, in: links) {
            let link = match.link
            guard !match.query.isEmpty, let url = PaletteQuicklinks.url(for: link, query: match.query) else {
                return [PaletteItem(id: "quicklink.\(link.id)", title: "Search \(link.name)…",
                                    subtitle: "Type what to search for after “\(link.keyword) ”", icon: "link",
                                    section: .quicklinks, primary: PaletteAction(title: "Type a Search") { isFieldFocused = true },
                                    placement: .pinned, accessory: link.keyword)]
            }
            return [PaletteItem(id: "quicklink.\(link.id)", title: "Search \(link.name) for “\(match.query)”",
                                subtitle: url.host ?? url.absoluteString, icon: "link", section: .quicklinks,
                                primary: PaletteAction(title: "Open", symbol: "arrow.up.forward.app") {
                                    close(); NSWorkspace.shared.open(url)
                                },
                                secondaries: [PaletteAction(title: "Copy URL", symbol: "doc.on.doc") {
                                    close(); copyToClipboard(url.absoluteString, announce: url.absoluteString)
                                }],
                                placement: .pinned, accessory: link.keyword)]
        }
        return PaletteQuicklinks.suggestions(trimmed, in: links).map { link in
            PaletteItem(id: "quicklink.\(link.id)", title: link.name,
                        subtitle: PaletteQuicklinks.hasPlaceholder(link) ? "Type “\(link.keyword) ” and a search" : "Quicklink",
                        icon: "link", section: .quicklinks,
                        primary: PaletteAction(title: PaletteQuicklinks.hasPlaceholder(link) ? "Use Quicklink" : "Open") {
                            if PaletteQuicklinks.hasPlaceholder(link) {
                                query = link.keyword + " "
                                isFieldFocused = true
                            } else if let url = PaletteQuicklinks.url(for: link, query: "") {
                                close(); NSWorkspace.shared.open(url)
                            }
                        },
                        accessory: link.keyword)
        }
    }

    private func commandItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func command(_ id: String, _ title: String, _ subtitle: String, _ icon: String, keys: String? = nil,
                     secondaries: [PaletteAction] = [], _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: id, title: title, subtitle: subtitle, icon: icon, section: .commands, shortcut: keys,
                                     primary: PaletteAction(title: "Run") { close(); run() }, secondaries: secondaries))
        }
        // Keycaps mirror the user's real bindings; unbound commands show none.
        // Capture Text resolves to the OCR binding, as in CaptureMenu.
        command("capture.area", "Capture Area", "Drag a region to capture", "viewfinder",
                keys: captureKeys(.captureArea)) { CaptureCoordinator.shared.captureArea() }
        command("capture.window", "Capture Window", "Pick a window to capture", "macwindow",
                keys: captureKeys(.captureWindow)) {
            CaptureCoordinator.shared.captureWindowInteractive()
        }
        command("capture.fullscreen", "Capture Full Screen", "The display under the pointer", "display",
                keys: captureKeys(.captureFullscreen)) {
            CaptureCoordinator.shared.captureFullscreen()
        }
        command("capture.text", "Capture Text", "Recognize text in a region and copy it", "text.viewfinder",
                keys: captureKeys(.ocr)) {
            CaptureCoordinator.shared.captureText()
        }
        command("capture.record", "Record Screen", "Start a screen recording", "record.circle",
                keys: captureKeys(.recordScreen)) {
            ScreenRecordingService.shared.promptAndStartRecording()
        }
        command("clipboard.shelf", "Open Clipboard Shelf", "Find and paste a copied item", "doc.on.clipboard",
                keys: ClipboardShortcuts.shared.shortcut(for: .history)?.displayString) {
            ClipboardPanelController.shared.show()
        }
        let source = session.target?.name
        let linkSubtitle = source.map { "From \($0): Markdown, rich text and the URL" } ?? "Markdown, rich text and the URL"
        command("links.copyCurrent", "Copy Link to Current Item", linkSubtitle, "link.badge.plus",
                secondaries: [
                    PaletteAction(title: "Copy as Markdown", symbol: "text.badge.checkmark") { close(); session.copyLink(style: .markdown) },
                    PaletteAction(title: "Copy URL", symbol: "link") { close(); session.copyLink(style: .plainURL) },
                ]) {
            session.copyLink(style: .rich)
        }
        if let app = source {
            command("menus.shortcuts", "Show Keyboard Shortcuts for \(app)", "Every menu shortcut in \(app), grouped by menu",
                    "command.square") {
                PaletteShortcutSheet.shared.showForPreviousApp()
            }
        }
        let holdOn = PaletteShortcutSheet.shared.isEnabled
        command("menus.holdCommand", holdOn ? "Turn Off Hold ⌘ for Shortcuts" : "Turn On Hold ⌘ for Shortcuts",
                "Hold ⌘ in any app to see its menu shortcuts", "command") {
            PaletteShortcutSheet.shared.setEnabled(!holdOn)
            GestureHUD.shared.show(title: holdOn ? "Hold ⌘ Off" : "Hold ⌘ On",
                                   detail: holdOn ? nil : "Hold ⌘ for \(PaletteShortcutSheet.shared.holdDescription) to see an app's shortcuts.")
        }
        command("window.left", "Tile Window Left Half", "Move the front window to the left half", "rectangle.lefthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowLeft))
        }
        command("window.right", "Tile Window Right Half", "Move the front window to the right half", "rectangle.righthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowRight))
        }
        command("window.maximize", "Maximize Window", "Fill the visible screen", "arrow.up.left.and.arrow.down.right") {
            ActionExecutor.executeAction(TriggerAction(actionType: .maximizeWindow))
        }
        command("window.switcher", "Window Switcher", "Every window with thumbnails, like AltTab", "rectangle.stack",
                keys: captureKeys(.windowSwitcher)) {
            WindowSwitcherController.shared.show()
        }
        command("window.pinFront", "Pin Front Window", "Keep the front window on top", "pin",
                keys: captureKeys(.togglePinFrontWindow)) {
            ActionExecutor.executeAction(TriggerAction(actionType: .togglePinFrontWindow))
        }
        command("window.unpinAll", "Unpin All Windows", "Remove every live window pin", "pin.slash") {
            ActionExecutor.executeAction(TriggerAction(actionType: .unpinAllWindows))
        }
        command("system.keepAwake", keepAwakeTitle, "Hold a prevent-idle-sleep power assertion", "flask",
                keys: captureKeys(.keepAwake)) {
            KeepAwakeService.shared.toggle(minutes: nil, keepDisplay: false)
        }
        command("audio.mixer", "App Audio Mixer", "Per-app volume and mute (macOS 14.2+)", "slider.horizontal.3") {
            AppAudioMixerService.shared.showPanel()
        }
        command("menus.edit", "Floating Menus & Widgets", "Create menus, clocks and variable widgets · 플로팅 메뉴",
                "rectangle.grid.2x2") {
            FloatingMenuController.shared.edit()
        }
        items.append(PaletteItem(id: "quicklinks.edit", title: "Edit Quicklinks…",
                                 subtitle: "Keywords that search a site: g Google, n Naver, gh GitHub …", icon: "link.circle",
                                 section: .commands, primary: PaletteAction(title: "Edit") { editingQuicklinks = true }))
        items.append(PaletteItem(id: "links.router", title: "Link Rules…",
                                 subtitle: "Open links in the right browser or app and remove tracking parameters",
                                 icon: "arrow.triangle.branch", section: .commands,
                                 primary: PaletteAction(title: "Edit") { editingLinkRouter = true }))
        // Every action is searchable, including capabilities which previously
        // existed only inside the automation picker. Opening creates a draft.
        if isSearching {
            for type in ActionType.allCases {
                items.append(PaletteItem(id: "action.\(type.rawValue)", title: type.rawValue,
                    subtitle: type.description + " · Configure Automation", icon: type.iconName, section: .commands,
                    primary: PaletteAction(title: "Configure Automation") { close(); appState.createDraft(for: type) }))
            }
        }
        return items
    }

    private func automationItems() -> [PaletteItem] {
        appState.currentPreset.triggers.map { trigger in
            var keys: String?
            if case .keyboardShortcut(let shortcut) = trigger.input { keys = shortcut.displayString }
            // Never offer a list-level run for Type Text (it could type a stored password).
            var secondaries: [PaletteAction] = []
            if trigger.isEnabled, !trigger.actions.isEmpty, !trigger.aomTypesText {
                secondaries = [PaletteAction(title: "Run Now", symbol: "play") {
                    close()
                    ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                                  triggerID: trigger.id)
                }]
            }
            return PaletteItem(id: "trigger.\(trigger.id.uuidString)", title: trigger.displayName,
                               subtitle: trigger.aomRowDetail, icon: trigger.input.category.iconName,
                               section: .automations, shortcut: keys,
                               primary: PaletteAction(title: "Open in Editor") {
                                   close()
                                   appState.selectedActivationGroupID = trigger.activationGroupID
                                   if trigger.activationGroupID == nil {
                                       appState.selectedAppTarget = (trigger.appBundleID ?? "").isEmpty ? .allApps
                                           : appState.currentPreset.appTargets.first { $0.bundleID == trigger.appBundleID } ?? .allApps
                                   }
                                   appState.selectedTrigger = trigger
                                   appState.selectedMainTab = .gestures
                               },
                               secondaries: secondaries)
        }
    }

    private func clipboardItems() -> [PaletteItem] {
        clipboardStore.entries.prefix(20).map { entry in
            PaletteItem(
                id: "clipboard.\(entry.id.uuidString)", title: entry.title,
                subtitle: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                icon: entry.kind.symbol, section: .clipboard,
                primary: PaletteAction(title: "Copy", symbol: "doc.on.doc") {
                    close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: false)
                },
                secondaries: entry.kind == .text || entry.kind == .link
                    ? [PaletteAction(title: "Copy as Plain Text", symbol: "textformat") {
                        close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: true)
                    }]
                    : [])
        }
    }

    private func captureItems() -> [PaletteItem] {
        captureHistory.entries.prefix(6).map { capture in
            PaletteItem(
                id: "capture.\(capture.id.uuidString)", title: capture.displayName,
                subtitle: "\(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height)) · \(AOMRelativeTime.string(capture.capturedAt))",
                icon: capture.kind == .videoRecording ? "film" : "photo", section: .captures,
                primary: PaletteAction(title: "Edit") { close(); CaptureItemActions.edit(capture) },
                secondaries: [PaletteAction(title: "Copy", symbol: "doc.on.doc") { close(); CaptureItemActions.copy(capture) }])
        }
    }

    private func fileActions(_ file: PaletteFile) -> [PaletteAction] {
        [PaletteAction(title: "Show in Finder", symbol: "folder") {
            close(); NSWorkspace.shared.activateFileViewerSelecting([file.url])
        },
         PaletteAction(title: "Copy Path", symbol: "doc.on.doc") {
             close(); copyToClipboard(file.url.path, announce: file.url.path)
         }]
    }

    private func fileItem(_ file: PaletteFile, id: String, title: String? = nil) -> PaletteItem {
        let folder = (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return PaletteItem(id: id, title: title ?? file.name,
                           subtitle: title == nil ? folder : file.name, icon: "doc", section: .recentFiles,
                           primary: PaletteAction(title: "Open", symbol: "arrow.up.forward.app") {
                               close(); NSWorkspace.shared.open(file.url)
                           },
                           secondaries: fileActions(file), accessory: AOMRelativeTime.string(file.date),
                           image: session.icon(forPath: file.url.path))
    }

    private func recentFileItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let download = recentFiles.latestDownload {
            items.append(fileItem(download, id: "files.latestDownload", title: "Latest Download"))
        }
        if let screenshot = recentFiles.latestScreenshot {
            items.append(fileItem(screenshot, id: "files.latestScreenshot", title: "Latest Screenshot"))
        }
        let recent = isSearching
            ? recentFiles.recent.filter { PaletteFuzzy.score(trimmed, $0.name) != nil }.prefix(6)
            : recentFiles.recent.prefix(5)
        items += recent.map { fileItem($0, id: "files.recent.\($0.url.path)") }
        return items
    }

    private func navigationItems() -> [PaletteItem] {
        var items = AOMMainTab.allCases.map { tab in
            PaletteItem(id: "go.\(tab.rawValue)", title: tab.title, subtitle: "Show \(tab.title)",
                        icon: tab.sidebarSymbol, section: .navigation,
                        shortcut: tab.shortcutKey.map { "⌘\($0.character)" },
                        primary: PaletteAction(title: "Open") { close(); appState.selectedMainTab = tab })
        }
        items.append(PaletteItem(id: "go.settings", title: "Settings", subtitle: "Open All of MacOS Settings",
                                 icon: "gearshape", section: .navigation, shortcut: "⌘,",
                                 primary: PaletteAction(title: "Open") { close(); openSettings() }))
        return items
    }

    // BTT / Raycast launcher: installed apps.
    private func applicationItems() -> [PaletteItem] {
        PaletteApplications.matching(trimmed).map { app in
            PaletteItem(id: "app.\(app.url.path)", title: app.name, subtitle: app.url.deletingLastPathComponent().path,
                        icon: "app", section: .applications,
                        primary: PaletteAction(title: "Open", symbol: "arrow.up.forward.app") {
                            close(); NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
                        },
                        secondaries: [PaletteAction(title: "Show in Finder", symbol: "folder") {
                            close(); NSWorkspace.shared.activateFileViewerSelecting([app.url])
                        }],
                        image: session.icon(forPath: app.url.path))
        }
    }

    private func menuItems() -> [PaletteItem] {
        guard let target = session.target else { return [] }
        switch session.menu {
        case .ready(let snapshot):
            let appIcon = target.bundleID.flatMap { session.icon(forBundleID: $0) }
            return PaletteMenuSearch.results(snapshot.items, query: trimmed, limit: 8).map { item in
                PaletteItem(id: "menu.\(item.id)", title: item.title, subtitle: item.path.joined(separator: " › "),
                            icon: "filemenu.and.selection", section: .menuItems, shortcut: item.shortcut,
                            primary: PaletteAction(title: "Choose in \(target.name)", symbol: "cursorarrow.click") {
                                close(); session.choose(item)
                            },
                            accessory: item.isEnabled ? (item.isChecked ? "On" : nil) : "Unavailable",
                            image: appIcon, isDimmed: !item.isEnabled)
            }
        case .failed(.notTrusted):
            return [PaletteItem(id: "menu.permission", title: "Allow Accessibility to Search \(target.name) Menus",
                                subtitle: "Menu search reads the menu bar through Accessibility", icon: "hand.raised",
                                section: .menuItems, primary: PaletteAction(title: "Open Settings") {
                                    close()
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }, placement: .fallback)]
        case .idle, .loading, .failed(.unreadable):
            return []
        }
    }

    private func bookmarkItems() -> [PaletteItem] {
        var items = PaletteBookmarkSearch.results(session.bookmarks, query: trimmed, limit: 8).map { bookmark in
            let place = [bookmark.url.host, bookmark.folderPath.isEmpty ? nil : bookmark.folderPath].compactMap { $0 }
                .joined(separator: " · ")
            return PaletteItem(id: "bookmark.\(bookmark.id)", title: bookmark.title, subtitle: place, icon: "bookmark",
                               section: .bookmarks,
                               primary: PaletteAction(title: "Open in \(bookmark.browser.name)", symbol: "arrow.up.forward.app") {
                                   close(); PaletteBookmarkOpener.open(bookmark)
                               },
                               secondaries: [
                                   PaletteAction(title: "Copy URL", symbol: "doc.on.doc") {
                                       close(); copyToClipboard(bookmark.url.absoluteString, announce: bookmark.url.absoluteString)
                                   },
                                   PaletteAction(title: "Copy as Markdown", symbol: "text.badge.checkmark") {
                                       close()
                                       let link = PaletteLink(title: bookmark.title, url: bookmark.url)
                                       PaletteLinkFormat.write([link], style: .markdown)
                                       GestureHUD.shared.show(title: "Copied", detail: PaletteLinkFormat.markdown(link))
                                   },
                               ],
                               accessory: bookmark.profileName, image: session.icon(forBundleID: bookmark.browser.bundleID))
        }
        if session.safariAccess == .needsFullDiskAccess, trimmed.count >= 2 {
            items.append(PaletteItem(id: "bookmark.safari.permission", title: "Allow Full Disk Access to Search Safari Bookmarks",
                                     subtitle: "Safari keeps bookmarks in a folder only Full Disk Access can read",
                                     icon: "lock.shield", section: .bookmarks,
                                     primary: PaletteAction(title: "Open Settings") {
                                         close(); NSWorkspace.shared.open(PaletteBookmarkOpener.fullDiskAccessURL)
                                     }, placement: .fallback))
        }
        return items
    }

    private func fallbackItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        if PaletteQuicklinks.match(query, in: quicklinks.links) == nil {
            for keyword in ["g", "n"] {
                guard let link = quicklinks.links.first(where: { $0.isEnabled && $0.keyword == keyword }),
                      let url = PaletteQuicklinks.url(for: link, query: trimmed) else { continue }
                items.append(PaletteItem(id: "fallback.\(keyword)", title: "Search \(link.name) for “\(trimmed)”",
                                         subtitle: url.host ?? "", icon: "magnifyingglass", section: .fallback,
                                         primary: PaletteAction(title: "Open", symbol: "arrow.up.forward.app") {
                                             close(); NSWorkspace.shared.open(url)
                                         }, placement: .fallback, accessory: link.keyword))
            }
        }
        let text = trimmed
        items.append(PaletteItem(id: "files.search", title: "Search Files for “\(text)”",
                                 subtitle: "Spotlight results in Finder", icon: "doc.text.magnifyingglass", section: .files,
                                 primary: PaletteAction(title: "Search") {
                                     close(); NSWorkspace.shared.showSearchResults(forQueryString: text)
                                 }, placement: .fallback))
        return items
    }

    /// Searching ranks one flat list; menus, bookmarks and files are capped
    /// by their own searches before they get here.
    private var results: [PaletteItem] { PaletteSearch.results(for: allItems, query: query) }

    private func sectionTitle(_ section: Section) -> String {
        switch section {
        case .menuItems: return session.target.map { "\($0.name) menus" } ?? section.rawValue
        case .fallback: return "Search with"
        default: return section.rawValue
        }
    }

    // MARK: Body

    var body: some View {
        let items = results
        let selected = items.first { $0.id == selectedID } ?? items.first
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                searchField(count: items.count)
                AOMDivider()
                if items.isEmpty {
                    emptyState
                } else {
                    resultList(items, selected: selected)
                }
                AOMDivider()
                actionBar(selected)
            }
            .frame(width: AOMSize.paletteWidth, height: AOMFeatureSize.paletteHeight)
            .overlay(alignment: .bottomTrailing) {
                if showsActions, let selected {
                    actionPanel(selected)
                        .padding(.trailing, AOMSpace.x3)
                        .padding(.bottom, AOMSize.rowStandard + AOMSpace.x1)
                        .transition(.opacity)
                }
            }
            // Glass chrome draws its own shadow; nothing is added on top (c.4).
            .aomFloatingSurface(.panel, radius: AOMRadius.panel, inWindow: true)
            .background(alignment: .topLeading) {
                // ⌘K inside the palette opens the Actions panel (Raycast).
                Button("Actions") { toggleActions(selected) }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .aomAnimation(.quick, value: showsActions)
        .onAppear(perform: appear)
        .onDisappear {
            session.end()
            recentFiles.stop()
        }
        .onExitCommand {
            // Esc goes back one level: the Actions panel, the query, then the palette.
            if showsActions { showsActions = false; return }
            switch PaletteSearch.escapeOutcome(query: query) {
            case .clearQuery: query = ""
            case .close: close()
            }
        }
        .onKeyPress(.upArrow) { moveSelection(-1, in: items, selected: selected); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1, in: items, selected: selected); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard let item = selected else { return .handled }
            if showsActions {
                let action = PaletteSearch.action(at: actionIndex, of: item)
                showsActions = false
                action?.run()
            } else if press.modifiers.contains(.command) {
                // ⌘↩ keeps running the first secondary, as before.
                item.secondaries.first?.run()
            } else {
                item.primary.run()
            }
            return .handled
        }
        .sheet(isPresented: $editingQuicklinks) {
            PaletteQuicklinksEditor(store: quicklinks)
        }
        .sheet(isPresented: $editingLinkRouter) {
            PaletteLinkRouterSheet()
        }
    }

    private func appear() {
        isFieldFocused = true
        session.begin()
        recentFiles.start()
        guard PresetManager.isUIPreview else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.lastIndex(of: "--aom-preview-palette-query"), arguments.indices.contains(index + 1) {
            query = arguments[index + 1]
        }
        let now = Date()
        recentFiles.showSamples([
            PaletteFile(url: URL(fileURLWithPath: "/Users/Shared/Report draft.pages"), name: "Report draft.pages",
                        date: now.addingTimeInterval(-1800)),
            PaletteFile(url: URL(fileURLWithPath: "/Users/Shared/Lecture 7.pdf"), name: "Lecture 7.pdf",
                        date: now.addingTimeInterval(-7200)),
        ], download: PaletteFile(url: URL(fileURLWithPath: "/Users/Shared/Downloads/Syllabus.pdf"), name: "Syllabus.pdf",
                                 date: now.addingTimeInterval(-600)),
           screenshot: PaletteFile(url: URL(fileURLWithPath: "/Users/Shared/Screenshot 2026-10-31.png"),
                                   name: "Screenshot 2026-10-31.png", date: now.addingTimeInterval(-300)))
        if arguments.contains("--aom-preview-palette-actions") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showsActions = true }
        }
        if arguments.contains("--aom-preview-quicklinks") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editingQuicklinks = true }
        }
        if arguments.contains("--aom-preview-link-rules") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editingLinkRouter = true }
        }
        if arguments.contains("--aom-preview-switcher") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                close()
                WindowSwitcherController.shared.showPreviewSample()
            }
        }
        if arguments.contains("--aom-preview-shortcut-sheet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                close()
                PaletteShortcutSheet.shared.showPreviewSample()
            }
        }
    }

    private func toggleActions(_ item: PaletteItem?) {
        guard item != nil else { return }
        actionIndex = 0
        showsActions.toggle()
    }

    private func moveSelection(_ offset: Int, in items: [PaletteItem], selected: PaletteItem?) {
        if showsActions, let selected {
            actionIndex = min(selected.actions.count - 1, max(0, actionIndex + offset))
            return
        }
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = items[min(items.count - 1, max(0, current + offset))].id
    }

    // MARK: Pieces

    private func searchField(count: Int) -> some View {
        // One alignment line for the whole palette: the search glyph,
        // section titles, row icons and the action bar start 16 pt in,
        // and the query lines up with the row titles.
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: "magnifyingglass")
                .font(AOMFont.body.weight(.medium))
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: PaletteMetrics.rowBadge)
                .accessibilityHidden(true)
            if let match = PaletteQuicklinks.match(query, in: quicklinks.links) {
                // The matched quicklink reads as a token before the search.
                Text(match.link.name)
                    .font(AOMFont.token.weight(.medium))
                    .foregroundStyle(AOMColor.accent)
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(minHeight: AOMSize.tokenHeight)
                    .background(AOMColor.accent.opacity(contrast == .increased ? 0.22 : 0.12), in: Capsule())
                    .accessibilityLabel("Quicklink \(match.link.name)")
            }
            TextField("Search commands, apps, menus, bookmarks, or calculate…", text: $query)
                .textFieldStyle(.plain)
                .font(AOMFont.pageStatus.weight(.regular))
                .focused($isFieldFocused)
                .onChange(of: query) { _, _ in
                    selectedID = nil
                    showsActions = false
                }
                .accessibilityLabel("Search")
            if isSearching {
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(AOMColor.textTertiary)
            }
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: AOMSize.rowDetail)
    }

    private var emptyState: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: "magnifyingglass")
                .font(AOMFont.title.weight(.regular)).imageScale(.large)
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.bottom, AOMSpace.x1)
                .accessibilityHidden(true)
            Text("No results for “\(query)”").font(AOMFont.headline).foregroundStyle(AOMColor.text)
            Text("Try an automation name, an app, a menu item or a sum such as 12 × 11.")
                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                .multilineTextAlignment(.center)
            // The empty state needs a mouse-reachable way out too.
            Button("Clear Search") {
                query = ""
                isFieldFocused = true
            }
            .buttonStyle(.borderless)
            .padding(.top, AOMSpace.x2)
        }
        .padding(AOMSpace.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultList(_ items: [PaletteItem], selected: PaletteItem?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if showsHeader(at: index, in: items) {
                            // Sentence case, no tracking (c.2).
                            Text(sectionTitle(item.section))
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textSecondary)
                                .padding(.horizontal, AOMSpace.x2)
                                .padding(.top, index == 0 ? AOMSpace.x1 : AOMSpace.x3)
                                .padding(.bottom, AOMSpace.x1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(item, selected: item.id == selected?.id)
                            .id(item.id)
                    }
                }
                .padding(AOMSpace.x2)
            }
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    /// Section titles while browsing; while searching only where the pinned
    /// rows and the fallbacks start, since the middle is one ranked list.
    private func showsHeader(at index: Int, in items: [PaletteItem]) -> Bool {
        let item = items[index]
        let previous = index > 0 ? items[index - 1] : nil
        if !isSearching { return previous?.section != item.section }
        if item.placement == .fallback { return previous?.placement != .fallback }
        return false
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            selectedID = item.id
            item.primary.run()
        } label: {
            Group {
                if item.section == .calculator {
                    calculatorRow(item, selected: selected)
                } else {
                    standardRow(item, selected: selected)
                }
            }
            .padding(.horizontal, AOMSpace.x2)
            .background(rowFill(item, selected: selected), in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .contextMenu {
            ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { action.run() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityHint(item.primary.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func rowFill(_ item: PaletteItem, selected: Bool) -> Color {
        if selected { return AOMColor.selection }
        return hoveredID == item.id ? AOMColor.rowHover : .clear
    }

    private func accessibilityLabel(_ item: PaletteItem) -> String {
        var parts = [item.title, item.subtitle]
        if let accessory = item.accessory { parts.append(accessory) }
        if let keys = item.shortcut { parts.append(keys) }
        if item.isDimmed { parts.append("unavailable") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private func badge(_ item: PaletteItem, selected: Bool) -> some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: PaletteMetrics.rowBadge, height: PaletteMetrics.rowBadge)
                .accessibilityHidden(true)
        } else {
            Image(systemName: item.icon)
                .font(AOMFont.callout.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? Color.white : AOMColor.textSecondary)
                .frame(width: PaletteMetrics.rowBadge, height: PaletteMetrics.rowBadge)
                .background(selected ? Color.white.opacity(0.18) : AOMColor.track,
                            in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func standardRow(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: AOMSpace.x2) {
            badge(item, selected: selected)
            Text(item.title)
                .font(AOMFont.body.weight(.medium))
                .foregroundStyle(selected ? Color.white : AOMColor.text)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.subtitle)
                .font(AOMFont.callout)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : AOMColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AOMSpace.x2)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(AOMFont.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : AOMColor.textTertiary)
                    .lineLimit(1)
            } else if isSearching, item.placement == .ranked {
                Text(sectionTitle(item.section))
                    .font(AOMFont.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : AOMColor.textSecondary)
                    .lineLimit(1)
            }
            if let keys = item.shortcut {
                HStack(spacing: AOMSpace.x0_5 + 1) {
                    ForEach(Array(AOMShortcutKeys.parts(keys).enumerated()), id: \.offset) { _, part in
                        AOMKeycap(text: part, onSelection: selected)
                    }
                }
            }
        }
        .opacity(item.isDimmed ? 0.55 : 1)
        .frame(height: PaletteMetrics.rowHeight)
    }

    /// The answer large, the question under it, like Raycast's calculator.
    private func calculatorRow(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: AOMSpace.x3) {
            badge(item, selected: selected)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(item.title)
                    .font(AOMFont.metricLarge)
                    .foregroundStyle(selected ? Color.white : AOMColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Text(item.subtitle)
                    .font(AOMFont.callout.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : AOMColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x2)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(AOMFont.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : AOMColor.textTertiary)
            }
        }
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: PaletteMetrics.calculatorHeight)
    }

    /// The selected item's actions with their keys, Raycast-style.
    private func actionBar(_ item: PaletteItem?) -> some View {
        HStack(spacing: AOMSpace.x3) {
            Text(item.map { sectionTitle($0.section) } ?? " ")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
            Spacer()
            if let item {
                actionHint(item.primary.title, keys: "↩", prominent: true) { item.primary.run() }
                if let secondary = item.secondaries.first {
                    actionHint(secondary.title, keys: "⌘↩", prominent: false) { secondary.run() }
                }
                if item.actions.count > 1 {
                    actionHint("Actions", keys: "⌘K", prominent: false) { toggleActions(item) }
                }
            }
            actionHint(isSearching || showsActions ? "Back" : "Close", keys: "esc", prominent: false) {
                if showsActions { showsActions = false } else if isSearching { query = "" } else { close() }
            }
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: AOMSize.rowStandard)
        .background(AOMColor.track)
    }

    /// A title and its keycap, grouped tighter than the hints are spaced.
    private func actionHint(_ title: String, keys: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x1) {
                Text(title)
                    .font(AOMFont.caption.weight(prominent ? .semibold : .regular))
                    .foregroundStyle(prominent ? AOMColor.text : AOMColor.textSecondary)
                    .lineLimit(1)
                AOMKeycap(text: keys)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(keys)")
    }

    /// Every action of the selected row (⌘K): ↑↓ to move, ↩ to run, esc to close.
    private func actionPanel(_ item: PaletteItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(AOMFont.caption.weight(.semibold))
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, AOMSpace.x3)
                .padding(.top, AOMSpace.x2)
                .padding(.bottom, AOMSpace.x1)
            ForEach(Array(item.actions.enumerated()), id: \.offset) { index, action in
                let isCurrent = index == actionIndex
                Button {
                    showsActions = false
                    action.run()
                } label: {
                    HStack(spacing: AOMSpace.x2) {
                        Image(systemName: action.symbol ?? (index == 0 ? "return" : "bolt"))
                            .font(AOMFont.callout)
                            .foregroundStyle(isCurrent ? Color.white : AOMColor.textSecondary)
                            .frame(width: AOMIcon.row)
                            .accessibilityHidden(true)
                        Text(action.title)
                            .font(AOMFont.body)
                            .foregroundStyle(isCurrent ? Color.white : AOMColor.text)
                            .lineLimit(1)
                        Spacer(minLength: AOMSpace.x3)
                        if index == 0 { AOMKeycap(text: "↩", onSelection: isCurrent) }
                        if index == 1 { AOMKeycap(text: "⌘↩", onSelection: isCurrent) }
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(height: AOMSize.rowSingle + AOMSpace.x1)
                    .background(isCurrent ? AOMColor.selection : .clear,
                                in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AOMSpace.x1)
                .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
            }
            .padding(.bottom, AOMSpace.x0_5)
        }
        .padding(.bottom, AOMSpace.x1)
        .frame(width: PaletteMetrics.actionPanelWidth, alignment: .leading)
        .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                .strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                              lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(item.title)")
    }
}

/// Installed applications for the palette's launcher results. The folders are
/// listed once and cached for five minutes, so typing never touches the disk.
enum PaletteApplications {
    struct App: Equatable {
        let name: String
        let url: URL
    }

    private static var cache: (apps: [App], at: Date)?
    private static let lock = NSLock()

    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } + [home.appendingPathComponent("Applications", isDirectory: true)]
    }

    static func all(now: Date = Date()) -> [App] {
        lock.lock(); defer { lock.unlock() }
        if let cache, now.timeIntervalSince(cache.at) < 300 { return cache.apps }
        let apps = scan(folders)
        cache = (apps, now)
        return apps
    }

    static func scan(_ folders: [URL]) -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
            for url in urls where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name.lowercased()).inserted else { continue }
                apps.append(App(name: name, url: url))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Name prefix first, then any word that starts with the query, then
    /// anywhere in the name; at most eight, so commands are not crowded out.
    static func matching(_ query: String, in apps: [App]? = nil) -> [App] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        func rank(_ app: App) -> Int? {
            let name = app.name
            if name.range(of: needle, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil { return 0 }
            if name.split(separator: " ").contains(where: { $0.range(of: needle, options: [.caseInsensitive, .anchored]) != nil }) { return 1 }
            if name.localizedCaseInsensitiveContains(needle) { return 2 }
            return nil
        }
        let ranked: [(app: App, rank: Int)] = (apps ?? all()).compactMap { app in
            guard let value = rank(app) else { return nil }
            return (app, value)
        }
        let ordered = ranked.sorted { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.app.name.count < rhs.app.name.count
        }
        return ordered.prefix(8).map { $0.app }
    }
}

/// The palette's rows, Spotlight-sized (3.3.6; 3.3.5 had an 18 pt badge on
/// 24 pt rows): a 28 pt badge on a 40 pt row; the calculator's answer row
/// is taller.
private enum PaletteMetrics {
    static let rowBadge: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let calculatorHeight: CGFloat = 56
    static let actionPanelWidth: CGFloat = 280
}

// MARK: - Quicklinks editor

/// "Edit Quicklinks…": the keyword, name and URL template of each link,
/// edited on a copy and saved with Done.
struct PaletteQuicklinksEditor: View {
    @ObservedObject var store: PaletteQuicklinkStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [PaletteQuicklink] = []
    @State private var loaded = false

    private var problems: [UUID: PaletteQuicklinks.Problem] {
        var result: [UUID: PaletteQuicklinks.Problem] = [:]
        for link in draft {
            if let problem = PaletteQuicklinks.validationProblem(link, among: draft) { result[link.id] = problem }
        }
        return result
    }

    var body: some View {
        let issues = problems
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Text("Quicklinks").font(AOMFont.title)
                Text("Type a keyword, a space and a search in ⌘K: “g swift tips” searches Google. {query} marks where the search goes.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AOMSpace.x5)

            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                Text("On").frame(width: QuicklinkColumns.toggle, alignment: .leading)
                Text("Keyword").frame(width: QuicklinkColumns.keyword, alignment: .leading)
                Text("Name").frame(width: QuicklinkColumns.name, alignment: .leading)
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: AOMIcon.row)
            }
            .font(AOMFont.caption.weight(.semibold))
            .foregroundStyle(AOMColor.textSecondary)
            .padding(.horizontal, AOMSpace.x5)
            .padding(.vertical, AOMSpace.x2)
            .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: AOMSpace.x1) {
                    ForEach($draft) { $link in
                        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                            HStack(spacing: AOMSpace.x2) {
                                Toggle("Use \(link.name)", isOn: $link.isEnabled)
                                    .labelsHidden()
                                    .frame(width: QuicklinkColumns.toggle, alignment: .leading)
                                TextField("Keyword", text: $link.keyword)
                                    .frame(width: QuicklinkColumns.keyword)
                                    .accessibilityLabel("Keyword for \(link.name)")
                                TextField("Name", text: $link.name)
                                    .frame(width: QuicklinkColumns.name)
                                TextField("https://example.com/search?q={query}", text: $link.template)
                                    .font(AOMFont.mono)
                                    .accessibilityLabel("URL for \(link.name)")
                                AOMIconButton("minus.circle", label: "Remove \(link.name)") {
                                    draft.removeAll { $0.id == link.id }
                                }
                            }
                            if let problem = issues[link.id] {
                                Label(PaletteQuicklinks.message(for: problem), systemImage: "exclamationmark.triangle.fill")
                                    .font(AOMFont.caption)
                                    .foregroundStyle(AOMColor.warningText)
                                    .padding(.leading, QuicklinkColumns.toggle + AOMSpace.x2)
                            }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, AOMSpace.x5)
                .padding(.bottom, AOMSpace.x3)
            }

            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                Button("Add Quicklink") {
                    draft.append(PaletteQuicklink(keyword: "", name: "", template: "https://"))
                }
                Button("Restore Defaults") { draft = PaletteQuicklinks.defaults }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    store.replace(with: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .aomPrimaryButton()
                .disabled(!issues.isEmpty)
            }
            .padding(AOMSpace.x4)
        }
        .frame(width: 760, height: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = store.links
        }
    }
}

private enum QuicklinkColumns {
    static let toggle: CGFloat = 36
    static let keyword: CGFloat = 80
    static let name: CGFloat = 150
}
