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
    /// 6.5: in AOM's window (previews) or the launcher panel (everywhere else).
    var host: Host = .window
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
    /// Bumped when a suggestion is forgotten, so the list redraws.
    @State private var refreshToken = 0
    /// Bumped when a source of rows changes (clipboard, captures, menus,
    /// files, Keep Awake, the preset): the cached results are rebuilt.
    @State private var generation = 0
    @State private var appeared = false
    @StateObject private var resultsCache = PaletteResultsCache()
    @FocusState private var isFieldFocused: Bool
    /// 6.7: the screens pushed over the root search, the question one of
    /// them asks, and what they load.
    @State private var navigation = PaletteNavigation()
    @State private var confirmation: PaletteConfirmation?
    /// The selected row to give back once a popped screen's query is restored.
    @State private var pendingSelection: String?
    @StateObject private var screens = PaletteRouteModels()
    @ObservedObject private var ai = PaletteAIChat.shared

    enum Host: Equatable { case window, launcher }

    struct PaletteAction {
        /// 6.7: what the launcher does around the action. `.close` (the
        /// default) hides the panel first; `.stay` runs it in place (a
        /// quicklink that waits for its search, a quit that keeps the list);
        /// `.push` opens one of the launcher's screens.
        enum Effect: Equatable {
            case close, stay, push(PaletteRoute)
        }

        let title: String
        var symbol: String? = nil
        var effect: Effect = .close
        /// Drawn in red (Force Quit, Move to Trash, Empty Trash).
        var isDestructive = false
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
        /// Listed under Suggestions (an empty palette's most used rows),
        /// keeping its own section's colour.
        var isSuggestion = false
        var shortcut: String?
        let primary: PaletteAction
        /// ⌘↩ runs the first; all of them are in the Actions panel (⌘K).
        private(set) var secondaries: [PaletteAction]
        var keywords: String = ""
        var placement: Placement = .ranked
        /// Short trailing text: a folder, a time, a profile.
        var accessory: String?
        /// An app or file icon instead of the symbol.
        var image: NSImage?
        /// Shown but unavailable (a disabled menu item).
        var isDimmed = false
        /// 5.0: a destination's own mark (pages, Settings categories).
        var identity: AOMIdentity?
        /// 6.7: the header a launcher screen groups its rows under.
        var group: String?
        /// 6.7: names typed for this row ("killapps", "앱 삭제"); an exact
        /// alias ranks with a title prefix.
        var aliases: [String] = []
        /// 6.7: a checklist row (the uninstall review): ticked or not.
        var checked: Bool?

        /// Opens a launcher screen rather than running something.
        var pushes: Bool {
            if case .push = primary.effect { return true }
            return false
        }

        /// The palette stays a launcher, not a context menu. App rows keep
        /// their whole fixed list (6.5: Hide, Quit, Force Quit, Uninstall).
        static let secondaryLimit = 3

        init(id: String, title: String, subtitle: String, icon: String, section: Section,
             shortcut: String? = nil, primary: PaletteAction, secondaries: [PaletteAction] = [],
             placement: Placement = .ranked, accessory: String? = nil, image: NSImage? = nil, isDimmed: Bool = false,
             secondaryLimit: Int = PaletteItem.secondaryLimit) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.section = section
            self.shortcut = shortcut
            self.primary = primary
            self.secondaries = Array(secondaries.prefix(secondaryLimit))
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
            /// 6.7: on a launcher screen, back to the one below (its search
            /// and selection come back), whatever is typed here.
            case pop
        }

        static func trimmedQuery(_ query: String) -> String {
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Esc backs out one level: clear the query first, then close.
        static func escapeOutcome(query: String) -> EscapeOutcome {
            escapeOutcome(query: query, depth: 0)
        }

        /// Esc on a pushed screen pops it (Raycast); at the root it clears
        /// the query, then closes.
        static func escapeOutcome(query: String, depth: Int) -> EscapeOutcome {
            if depth > 0 { return .pop }
            return trimmedQuery(query).isEmpty ? .close : .clearQuery
        }

        /// Lower rank sorts first; nil means the item does not match.
        static func rank(of item: PaletteItem, matching query: String, matchingSection: Bool = true) -> Int? {
            let needle = query.lowercased()
            if item.aliases.contains(where: { $0.lowercased() == needle }) { return 0 }
            if item.title.lowercased().hasPrefix(needle) { return 0 }
            if needle.count >= 3, item.aliases.contains(where: { $0.lowercased().hasPrefix(needle) }) { return 2 }
            if item.title.localizedCaseInsensitiveContains(query) { return 1 }
            if item.subtitle.localizedCaseInsensitiveContains(query) { return 2 }
            if !item.keywords.isEmpty,
               SettingsSearch.matches(query: query, title: item.title, subtitle: item.subtitle, keywords: [item.keywords]) { return 2 }
            // A screen's rows share one section; its name matching would list them all.
            if matchingSection, item.section.rawValue.localizedCaseInsensitiveContains(query) { return 3 }
            if let score = PaletteFuzzy.score(query, item.title), score >= PaletteFuzzy.subsequenceFloor + 40 { return 4 }
            return nil
        }

        /// `knowledge`: what ⌘K learnt from use. With an empty query up to
        /// five most-used rows move into Suggestions; while searching the
        /// row picked for this exact query comes first (Alfred), and rows of
        /// the same match quality order by use (Raycast).
        static func results(for items: [PaletteItem], query: String,
                            knowledge: PaletteKnowledge = PaletteKnowledge(), now: Date = Date()) -> [PaletteItem] {
            let trimmed = trimmedQuery(query)
            let ranked = items.filter { $0.placement == .ranked }
            guard !trimmed.isEmpty else {
                let suggested = knowledge.suggestions(among: ranked.map(\.id), limit: 5, now: now)
                let suggestions = suggested.compactMap { id -> PaletteItem? in
                    guard var item = ranked.first(where: { $0.id == id }) else { return nil }
                    item.isSuggestion = true
                    return item
                }
                let rest = ranked.filter { !suggested.contains($0.id) }
                return suggestions + Section.allCases.flatMap { section in rest.filter { $0.section == section } }
            }
            // Fuzzy matches (rank 4) are ordered by how well they match:
            // "pms" puts Paste and Match Style before Pick Color from Screen.
            let pick = knowledge.pick(for: trimmed)
            var ordered = ranked.compactMap { item -> (item: PaletteItem, rank: Int, closeness: Int, use: Double)? in
                guard let level = Self.rank(of: item, matching: trimmed) else { return nil }
                return (item: item, rank: level, closeness: level == 4 ? -(PaletteFuzzy.score(trimmed, item.title) ?? 0) : 0,
                        use: -knowledge.decayedScore(item.id, now: now))
            }
                .enumerated()
                .sorted { ($0.element.rank, $0.element.closeness, $0.element.use, $0.offset)
                    < ($1.element.rank, $1.element.closeness, $1.element.use, $1.offset) }
                .map(\.element.item)
            if let pick, let index = ordered.firstIndex(where: { $0.id == pick }), index > 0 {
                ordered.insert(ordered.remove(at: index), at: 0)
            }
            return items.filter { $0.placement == .pinned } + ordered + items.filter { $0.placement == .fallback }
        }

        /// 6.7: a launcher screen's rows keep their groups in order; within
        /// a group, matches rank like the root's (prefix, contains, keywords,
        /// fuzzy), stable. An empty query lists everything as built.
        static func filtered(_ items: [PaletteItem], query: String) -> [PaletteItem] {
            let trimmed = trimmedQuery(query)
            guard !trimmed.isEmpty else { return items }
            var groupOrder: [String: Int] = [:]
            for item in items where groupOrder[item.group ?? ""] == nil { groupOrder[item.group ?? ""] = groupOrder.count }
            return items.enumerated().compactMap { offset, item -> (item: PaletteItem, key: (Int, Int, Int))? in
                guard let level = rank(of: item, matching: trimmed, matchingSection: false) else { return nil }
                return (item, (groupOrder[item.group ?? ""] ?? 0, level, offset))
            }
            .sorted { $0.key < $1.key }
            .map(\.item)
        }

        /// The action ⌘1…⌘3 or a click in the Actions panel runs, clamped.
        static func action(at index: Int, of item: PaletteItem) -> PaletteAction? {
            let actions = item.actions
            return actions.indices.contains(index) ? actions[index] : nil
        }
    }

    // MARK: Items

    private func close() { isPresented = false }

    /// Rows that lead into AOM's own window: in the launcher, AOM comes forward.
    private func showAOM() {
        if host == .launcher { AppDelegate.current?.showMainWindow() }
    }

    private func openAOMSettings() {
        if host == .launcher { AppDelegate.current?.openSettingsWindow() } else { openSettings() }
    }

    private func captureKeys(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    private var keepAwakeTitle: String {
        KeepAwakeService.shared.isActive
            ? "Turn Off Keep Awake\(KeepAwakeService.shared.remainingDescription.map { " (\($0))" } ?? "")"
            : "Keep Awake"
    }

    /// A rule's session comes back at the next display or power change.
    private var keepAwakeSubtitle: String {
        let awake = KeepAwakeService.shared
        guard awake.isActive else { return "Hold a prevent-idle-sleep power assertion" }
        return awake.origin == .externalDisplay
            ? "Started by the external display rule; it turns on again at the next display or power change"
            : "Let the Mac sleep again"
    }

    struct WindowLayout {
        let id: String
        let title: String
        let subtitle: String
        let type: ActionType
        let keywords: String
    }

    /// 6.7: a root command that opens a launcher screen.
    struct ScreenCommand {
        let id: String
        let route: PaletteRoute
        let subtitle: String
        let aliases: [String]
        var keywords = ""
    }

    static let screenCommands: [ScreenCommand] = [
        .init(id: "system.screen.killApps", route: .killApps,
              subtitle: "Quit or force quit a running app · 앱 종료",
              aliases: ["killapps", "kill apps", "kill app", "kill", "quit apps", "quit app", "force quit",
                        "앱 종료", "강제 종료", "종료", "앱 끄기"],
              keywords: "process activity monitor memory 메모리 작업 관리자"),
        .init(id: "system.screen.uninstall", route: .uninstallApps,
              subtitle: "Review an app and its leftovers, then move them to the Trash · 앱 삭제",
              aliases: ["uninstall", "uninstall app", "uninstall apps", "unistall", "unistall app", "uninstal",
                        "remove app", "delete app", "앱 삭제", "앱 제거", "삭제", "제거"],
              keywords: "appcleaner pearcleaner leftovers 잔여 파일 trash"),
        .init(id: "audio.screen.devices", route: .soundDevices,
              subtitle: "Output, input and volume · 사운드 출력·입력",
              aliases: ["sound", "output", "input", "audio output", "speaker", "출력", "입력", "스피커", "사운드"],
              keywords: "airpods homepod airplay microphone 마이크 볼륨 volume 홈팟 에어팟"),
        .init(id: "clipboard.screen.history", route: .clipboard,
              subtitle: "Search everything you copied and paste it · 클립보드 기록",
              aliases: ["clipboard", "clipboard history", "clip", "클립보드", "복사 기록"],
              keywords: "paste history copied 붙여넣기"),
        .init(id: "window.screen.layouts", route: .windowLayouts,
              subtitle: "Halves, quarters, thirds and pins for the front window · 창 배치",
              aliases: ["window", "windows", "tile", "layout", "창", "창 배치", "창 정렬"],
              keywords: "rectangle moom snap 분할 maximize"),
        .init(id: "system.screen.keepAwake", route: .keepAwake,
              subtitle: "Keep the Mac awake for a while · 잠자기 방지",
              aliases: ["keep awake", "caffeinate", "caffeine", "amphetamine", "잠자기 방지", "카페인"],
              keywords: "sleep timer awake 깨어 있기"),
        .init(id: "ai.screen.ask", route: .ai,
              subtitle: "Claude Code or Codex answers here; ⇥ from any search asks it · AI 질문",
              aliases: ["ai", "ask", "ask ai", "claude", "claude code", "codex", "chatgpt", "질문", "물어보기", "에이아이"],
              keywords: "llm assistant agent quick ai 클로드 코덱스"),
        .init(id: "battery.screen", route: .battery,
              subtitle: "Charge limit, hold, top up and discharge · 배터리 (AlDente)",
              aliases: ["battery", "배터리", "aldente", "charge limit", "충전 제한", "bypass", "바이패스"],
              keywords: "hold top up discharge sailing 방전 완충 충전"),
        .init(id: "system.screen.commands", route: .system,
              subtitle: "Lock, sleep, restart, empty Trash, dark mode … · 시스템 명령",
              aliases: ["system", "system commands", "시스템", "시스템 명령"],
              keywords: "lock sleep restart shut down log out trash eject dark mode 잠금 재시동"),
    ]

    /// Layouts WindowManager already performs (halves, quarters, thirds).
    static let windowLayouts: [WindowLayout] = [
        .init(id: "topHalf", title: "Tile Window Top Half", subtitle: "Move the front window to the top half",
              type: .snapWindowTopHalf, keywords: "위 절반 top half"),
        .init(id: "bottomHalf", title: "Tile Window Bottom Half", subtitle: "Move the front window to the bottom half",
              type: .snapWindowBottomHalf, keywords: "아래 절반 bottom half"),
        .init(id: "topLeft", title: "Tile Window Top Left Quarter", subtitle: "Move the front window to the top left quarter",
              type: .snapWindowTopLeft, keywords: "4분할 왼쪽 위 quarter corner"),
        .init(id: "topRight", title: "Tile Window Top Right Quarter", subtitle: "Move the front window to the top right quarter",
              type: .snapWindowTopRight, keywords: "4분할 오른쪽 위 quarter corner"),
        .init(id: "bottomLeft", title: "Tile Window Bottom Left Quarter", subtitle: "Move the front window to the bottom left quarter",
              type: .snapWindowBottomLeft, keywords: "4분할 왼쪽 아래 quarter corner"),
        .init(id: "bottomRight", title: "Tile Window Bottom Right Quarter", subtitle: "Move the front window to the bottom right quarter",
              type: .snapWindowBottomRight, keywords: "4분할 오른쪽 아래 quarter corner"),
        .init(id: "leftThird", title: "Tile Window Left Third", subtitle: "Move the front window to the left third",
              type: .snapWindowLeftThird, keywords: "3분할 왼쪽 1/3 third"),
        .init(id: "centerThird", title: "Tile Window Center Third", subtitle: "Move the front window to the center third",
              type: .snapWindowCenterThird, keywords: "3분할 가운데 1/3 third"),
        .init(id: "rightThird", title: "Tile Window Right Third", subtitle: "Move the front window to the right third",
              type: .snapWindowRightThird, keywords: "3분할 오른쪽 1/3 third"),
        .init(id: "leftTwoThirds", title: "Tile Window Left Two Thirds", subtitle: "Move the front window to the left two thirds",
              type: .snapWindowLeftTwoThirds, keywords: "3분할 왼쪽 2/3 two thirds"),
        .init(id: "rightTwoThirds", title: "Tile Window Right Two Thirds", subtitle: "Move the front window to the right two thirds",
              type: .snapWindowRightTwoThirds, keywords: "3분할 오른쪽 2/3 two thirds"),
        .init(id: "center", title: "Center Window", subtitle: "Center the front window on its screen",
              type: .centerWindow, keywords: "가운데 center"),
    ]

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
        } else {
            items += suggestedApplicationItems()
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
                                    section: .quicklinks,
                                    primary: PaletteAction(title: "Type a Search", effect: .stay) { isFieldFocused = true },
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
                        // 6.7 (report L1): the panel stays while the keyword waits for its search.
                        primary: PaletteAction(title: PaletteQuicklinks.hasPlaceholder(link) ? "Use Quicklink" : "Open",
                                               effect: PaletteQuicklinks.hasPlaceholder(link) ? .stay : .close) {
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
                     keywords: String = "",
                     primaryTitle: String = "Run", secondaries: [PaletteAction] = [], _ run: @escaping () -> Void) {
            var item = PaletteItem(id: id, title: title, subtitle: subtitle, icon: icon, section: .commands, shortcut: keys,
                                   primary: PaletteAction(title: primaryTitle) { close(); run() }, secondaries: secondaries)
            // Search aliases (Korean names among them); `keys` is only the keycap.
            item.keywords = keywords
            items.append(item)
        }
        // 6.7: commands that open a screen of their own come first, with the
        // verbs people type for them (the Codex spec's aliases, typo included).
        for screen in Self.screenCommands {
            var item = PaletteItem(id: screen.id, title: screen.route.title, subtitle: screen.subtitle,
                                   icon: screen.route.symbol, section: .commands,
                                   primary: PaletteAction(title: "Open", symbol: "chevron.right", effect: .push(screen.route)) {})
            item.aliases = screen.aliases
            item.keywords = screen.keywords
            items.append(item)
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
        command("links.copyCurrent", "Copy Link to Current Item", linkSubtitle, "link.badge.plus", primaryTitle: "Copy Link",
                secondaries: [
                    PaletteAction(title: "Copy as Markdown", symbol: "text.badge.checkmark") { close(); session.copyLink(style: .markdown) },
                    PaletteAction(title: "Copy URL", symbol: "link") { close(); session.copyLink(style: .plainURL) },
                ]) {
            session.copyLink(style: .rich)
        }
        if let app = source {
            command("menus.shortcuts", "Show Keyboard Shortcuts for \(app)", "Every menu shortcut in \(app), grouped by menu",
                    "command.square", primaryTitle: "Show") {
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
        // 6.5: the tiling layouts that already exist, runnable from a search
        // (only while searching, so the browsing list stays short).
        if isSearching {
            for layout in Self.windowLayouts {
                command("window.\(layout.id)", layout.title, layout.subtitle, layout.type.iconName, keywords: layout.keywords) {
                    ActionExecutor.executeAction(TriggerAction(actionType: layout.type))
                }
            }
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
        let awake = KeepAwakeService.shared
        let rules = KeepAwakeRules.shared
        // The toggle keeps its ID and keys; running, it is "Turn Off" (지금 종료).
        command("system.keepAwake", keepAwakeTitle, keepAwakeSubtitle, "flask",
                keys: captureKeys(.keepAwake),
                keywords: awake.isActive ? "지금 종료 끄기 stop caffeine 잠자기 방지" : "잠자기 방지 카페인 caffeine amphetamine") {
            awake.toggle(minutes: nil, keepDisplay: false)
        }
        // 6.5: durations and the display from ⌘K (KeepingYouAwake's menu).
        // Each replaces a running session: the new assertion first, so a
        // refusal leaves the old one running. 6.7: the whole list is the
        // Keep Awake screen; these three stay findable by name.
        if isSearching {
        command("system.keepAwake.30", "Keep Awake for 30 Minutes", "Then the Mac may sleep again · 30분 잠자기 방지", "timer",
                keywords: "30분 30 minutes 30m caffeine 잠자기") {
            awake.start(minutes: 30, keepDisplay: false)
        }
        command("system.keepAwake.60", "Keep Awake for 1 Hour", "Then the Mac may sleep again · 1시간 잠자기 방지", "timer",
                keywords: "1시간 60분 1 hour 60 minutes caffeine 잠자기") {
            awake.start(minutes: 60, keepDisplay: false)
        }
        command("system.keepAwake.display", "Keep Display On", "The display and the Mac stay awake until turned off · 화면 계속 켜기",
                "sun.max", keywords: "화면 켜기 화면 유지 화면 계속 display screen awake caffeine") {
            awake.start(minutes: nil, keepDisplay: true)
        }
        }
        if rules.whileExternalDisplay {
            // A manual Turn Off lasts until the next display or power change;
            // this one stops the rule itself (자동 규칙 끄기).
            command("system.keepAwake.rule", "Turn Off Keep Awake While a Display Is Connected",
                    "Stops the automatic rule, not just this session · 자동 규칙 끄기", "display.2",
                    keywords: "외장 모니터 자동 규칙 끄기 external display rule keep awake") {
                rules.whileExternalDisplay = false
                GestureHUD.shared.show(title: "Keep Awake Rule Off", detail: "A connected display no longer keeps the Mac awake.")
            }
        }
        command("audio.mixer", "App Audio Mixer", "Per-app volume and mute (macOS 14.2+)", "slider.horizontal.3") {
            AppAudioMixerService.shared.showPanel()
        }
        // 6.5: HomePod plays nothing while the app's controls work.
        command("audio.reconnect", "Reconnect App Audio",
                "When a HomePod stays silent while the app plays · 홈팟 소리 복구", "arrow.triangle.2.circlepath",
                keywords: "homepod airplay 홈팟 에어플레이 소리 무음 복구 다시 연결 reconnect repair silent") {
            AudioRecovery.reconnect()
        }
        command("audio.check", "Check HomePod Audio", "Why it crackles: memory, heat · 홈팟 지지직 점검", "stethoscope",
                keywords: "homepod airplay 홈팟 지지직 끊김 crackle 점검 check memory 메모리") {
            AudioRecovery.checkHomePod()
        }
        command("audio.restartCoreAudio", "Restart Core Audio…",
                "Silent in every app · asks for a password · 오디오 재시작",
                "waveform.badge.exclamationmark",
                keywords: "coreaudiod core audio homepod airplay 홈팟 오디오 재시작 restart") {
            AudioRecovery.restartCoreAudio()
        }
        command("menus.edit", "Floating Menus & Widgets", "Create menus, clocks and variable widgets · 플로팅 메뉴",
                "rectangle.grid.2x2") {
            FloatingMenuController.shared.edit()
        }
        items.append(PaletteItem(id: "quicklinks.edit", title: "Edit Quicklinks…",
                                 subtitle: "Keywords that search a site: g Google, n Naver, gh GitHub …", icon: "link.circle",
                                 section: .commands, primary: PaletteAction(title: "Edit", effect: .stay) { editingQuicklinks = true }))
        items.append(PaletteItem(id: "links.router", title: "Link Rules…",
                                 subtitle: "Open links in the right browser or app and remove tracking parameters",
                                 icon: "arrow.triangle.branch", section: .commands,
                                 primary: PaletteAction(title: "Edit", effect: .stay) { editingLinkRouter = true }))
        // 6.7: Raycast's System Commands are found from the root search too.
        if isSearching {
            items += PaletteSystemCommand.all.map(systemCommandItem)
            items += batteryItems()
            items += PaletteAICommand.all.map(aiCommandItem)
        }
        // Every action is searchable, including capabilities which previously
        // existed only inside the automation picker. Opening creates a draft.
        if isSearching {
            for type in ActionType.allCases {
                items.append(PaletteItem(id: "action.\(type.rawValue)", title: type.rawValue,
                    subtitle: type.description + " · Configure Automation", icon: type.iconName, section: .commands,
                    primary: PaletteAction(title: "Configure Automation") { close(); showAOM(); appState.createDraft(for: type) }))
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
                                   showAOM()
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
                    close(); copyEntry(entry.id, plainText: false)
                },
                secondaries: entry.kind == .text || entry.kind == .link
                    ? [PaletteAction(title: "Copy as Plain Text", symbol: "textformat") {
                        close(); copyEntry(entry.id, plainText: true)
                    }]
                    : [])
        }
    }

    /// 6.7 (report A3): a copy that fails says so instead of closing silently.
    @discardableResult
    private func copyEntry(_ id: UUID, plainText: Bool) -> Bool {
        do {
            _ = try clipboardStore.write(entryIDs: [id], plainText: plainText)
            return true
        } catch {
            GestureHUD.shared.show(title: "Couldn't Copy", detail: error.localizedDescription)
            return false
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
            var item = PaletteItem(id: "go.\(tab.rawValue)", title: tab.title, subtitle: tab.subtitle,
                                  icon: tab.sidebarSymbol, section: .navigation,
                                  shortcut: tab.shortcutKey.map { "⌘\($0.character)" },
                                  primary: PaletteAction(title: "Open") { close(); appState.selectedMainTab = tab; showAOM() })
            item.keywords = tab.discoveryKeywords
            item.identity = tab.identity
            return item
        }
        items += SettingsCategory.allCases.map { category in
            var item = PaletteItem(id: "settings.\(category.rawValue)", title: "\(category.title) Settings",
                        subtitle: "Settings › \(category.title)", icon: category.symbol, section: .navigation,
                        primary: PaletteAction(title: "Open Settings") {
                            close(); openAOMSettings()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                NotificationCenter.default.post(name: .aomShowSettingsCategory, object: category.rawValue)
                            }
                        })
            item.keywords = category.discoveryKeywords
            item.identity = category.identity
            return item
        }
        items.append(Self.homebrewItem {
            close()
            appState.selectedMainTab = .tools
            showAOM()
            HomebrewModel.shared.present(.outdated, refresh: true)
        })
        items.append(PaletteItem(id: "go.settings", title: "Settings", subtitle: "Open All of MacOS Settings",
                                 icon: "gearshape", section: .navigation, shortcut: "⌘,",
                                 primary: PaletteAction(title: "Open") { close(); openAOMSettings() }))
        return items
    }

    /// A native manager entry, distinct from the brew formula web quicklink.
    /// Always discoverable; the sheet explains when Homebrew is not installed.
    static func homebrewItem(open: @escaping () -> Void) -> PaletteItem {
        PaletteItem(id: "go.homebrew", title: "Homebrew",
                    subtitle: "System Tools · brew outdated packages, updates, services, doctor · 홈브루",
                    icon: "mug", section: .navigation,
                    primary: PaletteAction(title: "Open Homebrew", run: open))
    }

    // BTT / Raycast launcher: installed apps, plus running apps elsewhere
    // (an external volume, Downloads). 6.5: Hide, Quit, Force Quit… and
    // Uninstall… after Show in Finder, so ↩ and ⌘↩ never change meaning.
    private var runningAppURLs: [URL] {
        NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular && !$0.isTerminated ? $0.bundleURL : nil }
    }

    private func applicationItems() -> [PaletteItem] {
        let runningKeys = PaletteAppControl.runningKeys()
        let apps = PaletteApplications.merged(PaletteApplications.all(), running: runningAppURLs)
        return PaletteApplications.matching(trimmed, in: apps).map { applicationItem($0, runningKeys: runningKeys) }
    }

    /// 6.7 (report L3): apps picked from a search come back under
    /// Suggestions in the empty launcher, as the commands always did.
    private func suggestedApplicationItems() -> [PaletteItem] {
        let apps = PaletteApplications.merged(PaletteApplications.all(), running: runningAppURLs)
        let byID = Dictionary(apps.map { ("app.\($0.url.path)", $0) }, uniquingKeysWith: { first, _ in first })
        let picked = PaletteKnowledgeStore.shared.knowledge.suggestions(among: Array(byID.keys), limit: 5, now: Date())
        guard !picked.isEmpty else { return [] }
        let runningKeys = PaletteAppControl.runningKeys()
        return picked.compactMap { byID[$0] }.map { applicationItem($0, runningKeys: runningKeys) }
    }

    private func applicationItem(_ app: PaletteApplications.App, runningKeys: Set<String>) -> PaletteItem {
        let key = PaletteAppControl.installedKey(app.url)
        let bundleID = PaletteApplications.bundleID(for: app.url)
        let isRunning = runningKeys.contains(key)
        let secondaries = PaletteAppControl.commands(isRunning: isRunning, bundleID: bundleID, path: key).map { command in
            appCommandAction(command, app: app)
        }
        return PaletteItem(id: "app.\(app.url.path)", title: app.name, subtitle: app.url.deletingLastPathComponent().path,
                           icon: "app", section: .applications,
                           primary: PaletteAction(title: "Open", symbol: "arrow.up.forward.app") {
                               close(); NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
                           },
                           secondaries: secondaries, accessory: isRunning ? "Running" : nil,
                           image: session.icon(forPath: app.url.path), secondaryLimit: .max)
    }

    /// 6.7: Force Quit… asks in the panel and Uninstall… opens the review in
    /// the panel (the Codex spec, test 14); the rest close it as before.
    private func appCommandAction(_ command: PaletteAppControl.Command, app: PaletteApplications.App) -> PaletteAction {
        switch command {
        case .uninstall:
            return PaletteAction(title: command.title, symbol: command.symbol, effect: .push(.uninstallReview(app.url))) {}
        case .forceQuit:
            return PaletteAction(title: command.title, symbol: command.symbol, effect: .stay, isDestructive: true) {
                confirmForceQuit(PaletteAppControl.instances(of: app.url), name: app.name, path: PaletteAppControl.installedKey(app.url))
            }
        default:
            return PaletteAction(title: command.title, symbol: command.symbol) { runAppCommand(command, app: app) }
        }
    }

    private func runAppCommand(_ command: PaletteAppControl.Command, app: PaletteApplications.App) {
        close()
        switch command {
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([app.url])
        case .hide: PaletteAppControl.hide(app.url, name: app.name)
        case .quit: PaletteAppControl.quit(app.url, name: app.name)
        case .forceQuit, .uninstall: break
        }
    }

    /// Force Quit inside the panel: the app's name and copy in the question,
    /// Cancel selected, and the same instances checked again on confirm.
    private func confirmForceQuit(_ instances: [NSRunningApplication], name: String, path: String?) {
        let targets = instances.filter { !$0.isTerminated && !PaletteAppControl.isProtected($0.bundleIdentifier) }
        guard !targets.isEmpty else {
            screens.show("\(name) isn't running")
            return
        }
        let place = path.map { (URL(fileURLWithPath: $0).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        let count = targets.count > 1 ? " (\(targets.count) instances)" : ""
        confirm(PaletteConfirmation(
            title: "Force Quit “\(name)”\(count)?",
            message: "\(name)\(place.map { " from \($0)" } ?? "") closes at once. Unsaved changes in it are lost.",
            confirmTitle: "Force Quit \(name)", symbol: "exclamationmark.octagon.fill") {
            let sent = targets.filter { target in
                !target.isTerminated && target.bundleURL?.standardizedFileURL.path == path && target.forceTerminate()
            }
            GestureLog.shared.logFromAnyThread("Force quit \(name) from the launcher (\(sent.count) of \(targets.count))", level: .action)
            guard !sent.isEmpty else { announce("\(name) had already quit or changed; nothing was force quit"); return }
            announce("Force quitting \(name)…")
            // forceTerminate() can return before the process ends (Codex review K3).
            Self.whenTerminated(sent, triesLeft: 30) { ended in
                announce(ended ? "\(name) was force quit" : "\(name) is still running after Force Quit")
            }
        })
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
        // 6.9: Raycast's Quick AI fallback (⇥ does the same from the field).
        let question = trimmed
        items.append(PaletteItem(id: "fallback.ai", title: "Ask \(ai.provider.title) “\(question)”",
                                 subtitle: "Answers here, read-only · ⇥", icon: "sparkles", section: .fallback,
                                 primary: PaletteAction(title: "Ask", symbol: "sparkles", effect: .stay) { askAI(question) },
                                 placement: .fallback, accessory: "⇥"))
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
    /// 6.5: built once per query and change of a source, not on every
    /// hover or arrow key (each rebuild ranked every row, the apps and, while
    /// searching, all 242 actions).
    private var results: [PaletteItem] {
        let route = navigation.current
        return resultsCache.items(for: .init(query: query, refresh: refreshToken, generation: generation,
                                             route: route.map { "\($0)" } ?? "")) {
            let items: [PaletteItem]
            if let route {
                switch route {
                case .confirm: items = confirmationItems()
                // The field is the composer here, not a filter.
                case .ai: items = aiItems()
                // The main window's matcher (body text, from:, type:), not titles only.
                case .clipboard: items = clipboardHistoryItems()
                // Results and progress rows are never filtered away (Codex review U4).
                case .uninstallReview where screens.uninstall?.phase != .review: items = uninstallReviewItems()
                default: items = PaletteSearch.filtered(routeItems(route), query: query)
                }
            } else {
                items = PaletteSearch.results(for: allItems, query: query, knowledge: PaletteKnowledgeStore.shared.knowledge)
            }
            screens.remember(items.map(\.id))
            return items
        }
    }

    private func sourcesChanged() {
        // After the change lands (objectWillChange fires before it).
        DispatchQueue.main.async { generation &+= 1 }
    }

    /// Runs one of a row's actions and lets ⌘K learn the pick. In the
    /// launcher the panel goes first and, unless the row opens AOM itself,
    /// the app that was in front is active again when the action runs.
    private func perform(_ action: PaletteAction?, of item: PaletteItem) {
        guard let action, !item.isDimmed else { return }
        // ⌘K learns root picks only: a row inside a screen (an app to kill,
        // a confirmation) never becomes the default for a similar search.
        if navigation.isRoot { PaletteKnowledgeStore.shared.record(itemID: item.id, query: query) }
        switch action.effect {
        case .push(let route):
            push(route)
            return
        case .stay:
            action.run()
            sourcesChanged()
            return
        case .close:
            break
        }
        guard host == .launcher, !PaletteLauncherRouting.keepsPanel(item.id) else { action.run(); return }
        AOMLauncherController.shared.dismiss(restoringFocus: PaletteLauncherRouting.restoresFocus(id: item.id,
                                                                                                 section: item.section,
                                                                                                 action: action.title)) {
            action.run()
        }
    }

    // MARK: Screens

    private func push(_ route: PaletteRoute) {
        navigation.push(route, query: query, selection: selectedID ?? results.first?.id)
        pendingSelection = nil
        query = ""
        selectedID = nil
        showsActions = false
        enter(route)
        isFieldFocused = true
        generation &+= 1
    }

    private func pop() {
        guard let frame = navigation.pop() else { return }
        leave(frame.route)
        showsActions = false
        if frame.returnQuery == query {
            selectedID = frame.returnSelection
        } else {
            pendingSelection = frame.returnSelection
            query = frame.returnQuery
        }
        isFieldFocused = true
        generation &+= 1
    }

    /// What a screen starts when it opens.
    private func enter(_ route: PaletteRoute) {
        switch route {
        case .killApps: screens.watchApps(true)
        case .uninstallReview(let app): screens.beginUninstall(app)
        case .soundDevices: screens.loadSound()
        // Read once when the screen opens, never per keystroke.
        case .battery: HardwareCareModel.shared.refreshBattery()
        case .uninstallApps, .clipboard, .windowLayouts, .keepAwake, .system, .ai, .confirm: break
        }
    }

    /// What it stops when it goes (a screen still lower on the stack keeps its own).
    private func leave(_ route: PaletteRoute) {
        switch route {
        case .killApps where !navigation.frames.contains { $0.route == .killApps }:
            screens.watchApps(false)
        case .uninstallReview:
            screens.endUninstall()
        case .soundDevices:
            screens.clearSound()
        case .confirm:
            confirmation = nil
        default:
            break
        }
    }

    // MARK: AI (6.9)

    /// Opens Ask AI (if needed) and sends the question.
    private func askAI(_ question: String) {
        if navigation.current != .ai { push(.ai) }
        query = ""
        ai.ask(question)
    }

    private var frontAppForAI: NSRunningApplication? {
        host == .launcher ? AOMLauncherController.shared.frontApp : PaletteSession.previousApp()
    }

    private func runAICommand(_ command: PaletteAICommand) {
        let front = frontAppForAI
        Task { @MainActor in
            let selection = command.needsSelection ? await PaletteAICommand.selectedText(in: front) : nil
            let clipboard = NSPasteboard.general.string(forType: .string)
            guard let prompt = PaletteAICommand.fill(command.template, selection: selection, clipboard: clipboard) else {
                screens.show(command.needsSelection ? "Select some text in \(front?.localizedName ?? "an app") first" : "The clipboard has no text")
                if navigation.current != .ai { push(.ai) }
                return
            }
            askAI(prompt)
        }
    }

    private func aiCommandItem(_ command: PaletteAICommand) -> PaletteItem {
        var item = PaletteItem(id: command.id, title: command.title,
                               subtitle: command.needsSelection ? "The text selected in the front app · \(ai.provider.title)"
                                                                : "The text on the clipboard · \(ai.provider.title)",
                               icon: command.symbol, section: .commands,
                               primary: PaletteAction(title: "Ask", symbol: "sparkles", effect: .stay) { runAICommand(command) })
        item.aliases = command.aliases
        item.group = "AI commands"
        return item
    }

    private func pasteAnswer() {
        guard let answer = ai.lastAnswer else { return }
        let target = frontAppForAI
        let write = {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(answer, forType: .string)
        }
        guard host == .launcher, let target, AXIsProcessTrusted() else { write(); screens.show("Answer copied"); return }
        AOMLauncherController.shared.dismiss(restoringFocus: true) {
            write()
            Self.paste(into: target, triesLeft: 10) { pasted in
                if !pasted { GestureHUD.shared.show(title: "Answer Copied", detail: "Press ⌘V in \(target.localizedName ?? "the app").") }
            }
        }
    }

    /// The Ask AI screen: with a conversation, one row carrying its actions
    /// (the transcript is drawn above); without, the AI commands and agents.
    private func aiItems() -> [PaletteItem] {
        let other = ai.provider == .claude ? PaletteAIProvider.codex : .claude
        let switchAgent = PaletteAction(title: "Switch to \(other.title)", symbol: other.symbol, effect: .stay) { ai.provider = other }
        if !ai.messages.isEmpty {
            let pasteTitle = frontAppForAI.map { "Paste Answer to \($0.localizedName ?? "App")" } ?? "Copy Answer"
            return [PaletteItem(id: "ai.answer", title: ai.lastAnswer.map { String($0.prefix(80)) } ?? "Waiting for the answer…",
                                subtitle: ai.provider.title, icon: "sparkles", section: .commands,
                                primary: PaletteAction(title: pasteTitle, symbol: "doc.on.clipboard") { pasteAnswer() },
                                secondaries: [
                                    PaletteAction(title: "Copy Answer", symbol: "doc.on.doc", effect: .stay) {
                                        if let answer = ai.lastAnswer { copyToClipboard(answer, announce: "Answer") }
                                    },
                                    PaletteAction(title: "Continue in Terminal", symbol: "terminal") { _ = ai.continueInTerminal() },
                                    switchAgent,
                                    PaletteAction(title: "New Chat", symbol: "square.and.pencil", effect: .stay) { ai.newChat() },
                                    PaletteAction(title: "Stop", symbol: "stop.circle", effect: .stay) { ai.cancel() },
                                ],
                                isDimmed: ai.lastAnswer == nil, secondaryLimit: .max)]
        }
        var items: [PaletteItem] = []
        if isSearching {
            let question = trimmed
            var ask = screenRow("ai.ask", "Ask \(ai.provider.title)", "“\(question)”", icon: "sparkles", group: "Ask",
                                primary: PaletteAction(title: "Ask", symbol: "sparkles", effect: .stay) { askAI(question) })
            ask.accessory = "↩"
            items.append(ask)
        }
        for provider in PaletteAIProvider.allCases {
            let installed = provider.executable != nil
            var row = screenRow("ai.provider.\(provider.rawValue)", provider.title,
                                installed ? (provider == .claude ? "Read-only here (plan mode); ⌘J continues in Terminal"
                                                                 : "Read-only sandbox here; ⌘J continues in Terminal")
                                          : "Not installed on this Mac",
                                icon: provider.symbol, group: "Agent",
                                primary: PaletteAction(title: provider == ai.provider ? "In Use" : "Use \(provider.title)", effect: .stay) {
                                    ai.provider = provider
                                }, dimmed: !installed)
            row.accessory = provider == ai.provider ? "✓ In use" : nil
            items.append(row)
        }
        items += PaletteAICommand.all.map(aiCommandItem)
        return items
    }

    private func confirm(_ question: PaletteConfirmation) {
        confirmation = question
        push(.confirm)
    }

    /// The confirmation's two rows: Cancel first (selected), then the action.
    private func confirmationItems() -> [PaletteItem] {
        guard let question = confirmation else { return [] }
        var cancel = PaletteItem(id: "confirm.cancel", title: "Cancel", subtitle: "Go back without changing anything",
                                 icon: "arrow.uturn.backward", section: .commands,
                                 primary: PaletteAction(title: "Cancel", effect: .stay) { pop() })
        cancel.group = question.title
        var accept = PaletteItem(id: "confirm.accept", title: question.confirmTitle, subtitle: question.message,
                                 icon: question.symbol, section: .commands,
                                 primary: PaletteAction(title: question.confirmTitle, effect: .stay,
                                                        isDestructive: question.destructive) { acceptConfirmation() })
        accept.group = question.title
        return [cancel, accept]
    }

    private func acceptConfirmation() {
        guard let question = confirmation else { return }
        confirmation = nil
        switch question.after {
        case .pop:
            pop()
            question.run()
        case .close(let restoresFocus):
            guard host == .launcher else { close(); question.run(); return }
            AOMLauncherController.shared.dismiss(restoringFocus: restoresFocus) { question.run() }
        }
    }

    // MARK: Screen rows

    private func routeItems(_ route: PaletteRoute) -> [PaletteItem] {
        switch route {
        case .killApps: return killAppItems()
        case .uninstallApps: return uninstallListItems()
        case .uninstallReview: return uninstallReviewItems()
        case .soundDevices: return soundItems()
        case .clipboard: return clipboardHistoryItems()
        case .windowLayouts: return windowLayoutItems()
        case .keepAwake: return keepAwakeItems()
        case .system: return PaletteSystemCommand.all.map(systemCommandItem)
        case .battery: return batteryItems()
        case .ai: return aiItems()
        case .confirm: return confirmationItems()
        }
    }

    private func screenRow(_ id: String, _ title: String, _ subtitle: String, icon: String, group: String?,
                     section: Section = .commands, primary: PaletteAction, secondaries: [PaletteAction] = [],
                     accessory: String? = nil, image: NSImage? = nil, dimmed: Bool = false) -> PaletteItem {
        var item = PaletteItem(id: id, title: title, subtitle: subtitle, icon: icon, section: section,
                               primary: primary, secondaries: secondaries, accessory: accessory, image: image,
                               isDimmed: dimmed, secondaryLimit: .max)
        item.group = group
        return item
    }

    private func folder(of path: String?) -> String {
        guard let path else { return "" }
        return (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // Kill Apps (Codex spec 03): ↩ quits the normal way and keeps the list,
    // ⌘K holds Force Quit…, Hide, Switch To and Show in Finder.
    private func killAppItems() -> [PaletteItem] {
        let entries = PaletteKillApps.entries()
        // 6.8 (Codex review K2): the app captured when the launcher opened,
        // not the session's guess; with none, there is no "all except".
        let frontApp = host == .launcher ? AOMLauncherController.shared.frontApp : PaletteSession.previousApp()
        let front = frontApp.map { (pid: $0.processIdentifier, name: $0.localizedName ?? "the Front App") }
        let quittable = entries.filter { !$0.isProtected }
        var items: [PaletteItem] = []
        let now = Date()
        for entry in entries {
            let path = entry.path
            let image = path.map { session.icon(forPath: $0) }
            guard !entry.isProtected else {
                items.append(screenRow(entry.id, entry.name, "AOM doesn't quit itself, Finder or the system's own hosts from here",
                                 icon: "lock", group: "Can't quit from here", primary: PaletteAction(title: "Protected") {},
                                 image: image, dimmed: true))
                continue
            }
            let state = PaletteKillApps.quitState(askedAt: screens.quitting[entry.pid], now: now)
            var accessory = [PaletteKillApps.memoryDescription(entry.memory), entry.isHidden ? "Hidden" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            switch state {
            case .quitting: accessory = "Quitting…"
            case .stillRunning: accessory = "Still running · ⌘K to force quit"
            case nil: break
            }
            var secondaries = [
                PaletteAction(title: "Force Quit…", symbol: "exclamationmark.octagon", effect: .stay, isDestructive: true) {
                    confirmForceQuit([PaletteKillApps.resolve(entry)].compactMap { $0 }, name: entry.name, path: entry.path)
                },
                PaletteAction(title: entry.isHidden ? "Unhide" : "Hide", symbol: entry.isHidden ? "eye" : "eye.slash", effect: .stay) {
                    guard let app = PaletteKillApps.resolve(entry) else { screens.show("\(entry.name) has quit"); return }
                    _ = entry.isHidden ? app.unhide() : app.hide()
                },
                PaletteAction(title: "Switch To \(entry.name)", symbol: "macwindow") {
                    PaletteKillApps.resolve(entry)?.activate(options: [.activateAllWindows])
                },
            ]
            if let path {
                secondaries.append(PaletteAction(title: "Show in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
            var item = screenRow(entry.id, entry.name, folder(of: path), icon: "app",
                           group: "Running · \(quittable.count)",
                           primary: PaletteAction(title: state == .stillRunning ? "Ask Again" : "Quit", symbol: "xmark.circle",
                                                  effect: .stay) { quit(entry) },
                           secondaries: secondaries, accessory: accessory.isEmpty ? nil : accessory, image: image)
            item.keywords = entry.bundleID ?? ""
            items.append(item)
        }
        // Bulk commands after the apps, so ↩ on open never starts with "all".
        if !isSearching, quittable.count > 1, let front {
            let others = quittable.filter { $0.pid != front.pid }
            let frontName = front.name
            items.append(screenRow("kill.all", "Quit All Apps Except \(frontName)…",
                             "\(others.count) app\(others.count == 1 ? "" : "s") are asked to quit; each can still ask to save",
                             icon: "xmark.circle", group: "All apps",
                             primary: PaletteAction(title: "Quit All…", effect: .stay) { confirmQuitAll(others, keeping: frontName) }))
            items.append(screenRow("kill.hideOthers", "Hide All Apps Except \(frontName)", "Their windows come back when you switch to them",
                             icon: "eye.slash", group: "All apps",
                             primary: PaletteAction(title: "Hide Others") {
                                 ActionExecutor.executeAction(TriggerAction(actionType: .hideOtherApps))
                             }))
        }
        return items
    }

    /// A result line on a screen; at the root (the panel may be closing) a HUD.
    private func announce(_ text: String) {
        screens.show(text)
        if navigation.isRoot || host == .window { GestureHUD.shared.show(title: text, detail: nil) }
    }

    static func whenTerminated(_ apps: [NSRunningApplication], triesLeft: Int, then done: @escaping (Bool) -> Void) {
        if apps.allSatisfy(\.isTerminated) { done(true); return }
        guard triesLeft > 0 else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenTerminated(apps, triesLeft: triesLeft - 1, then: done) }
    }

    private func quit(_ entry: PaletteKillApps.Entry) {
        guard let app = PaletteKillApps.resolve(entry) else {
            screens.show("\(entry.name) has already quit")
            return
        }
        guard !PaletteAppControl.isProtected(app.bundleIdentifier) else { return }
        if app.terminate() {
            screens.markQuitting(entry.pid)
            screens.show("Asked \(entry.name) to quit — it can still ask to save")
        } else {
            screens.show("\(entry.name) refused to quit · ⌘K for Force Quit…")
        }
    }

    private func confirmQuitAll(_ entries: [PaletteKillApps.Entry], keeping front: String) {
        guard !entries.isEmpty else { screens.show("No other app to quit"); return }
        let names = entries.prefix(4).map(\.name).joined(separator: ", ") + (entries.count > 4 ? " and \(entries.count - 4) more" : "")
        confirm(PaletteConfirmation(title: "Quit \(entries.count) App\(entries.count == 1 ? "" : "s")?",
                                    message: "\(names) are asked to quit the normal way; \(front) stays open. An app with unsaved work can still ask.",
                                    confirmTitle: "Quit \(entries.count) App\(entries.count == 1 ? "" : "s")",
                                    symbol: "xmark.circle.fill", destructive: false) {
            var asked = 0
            for entry in entries {
                guard let app = PaletteKillApps.resolve(entry), !PaletteAppControl.isProtected(app.bundleIdentifier) else { continue }
                if app.terminate() { asked += 1; screens.markQuitting(entry.pid) }
            }
            screens.show("Asked \(asked) app\(asked == 1 ? "" : "s") to quit")
        })
    }

    // Uninstall App (Codex spec 04): the installed apps it can remove, then
    // a review in the panel with System Tools' rules.
    private func uninstallListItems() -> [PaletteItem] {
        let runningKeys = PaletteAppControl.runningKeys()
        let apps = PaletteApplications.merged(PaletteApplications.all(), running: runningAppURLs).filter { app in
            PaletteAppControl.isUninstallable(bundleID: PaletteApplications.bundleID(for: app.url),
                                              path: PaletteAppControl.installedKey(app.url))
        }
        var items: [PaletteItem] = []
        if !isSearching, let recent = PaletteUninstallFlow.recent, Date().timeIntervalSince(recent.date) < 3600 {
            let stayed = !recent.outcome.failures.isEmpty && FileManager.default.fileExists(atPath: recent.app.path)
            items.append(screenRow("uninstall.recent", PaletteUninstallFlow.title(for: recent.outcome, app: recent.app, name: recent.name),
                                   "\(recent.outcome.summary) · \(AOMRelativeTime.string(recent.date))", icon: "clock.arrow.circlepath",
                                   group: "Last uninstall",
                                   primary: stayed
                                       ? PaletteAction(title: "Review Again", effect: .push(.uninstallReview(recent.app))) {}
                                       : PaletteAction(title: "Open Trash") {
                                           NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                                       }))
        }
        return items + apps.map { app in
            let key = PaletteAppControl.installedKey(app.url)
            var item = screenRow("uninstall.\(app.url.path)", app.name, folder(of: app.url.path), icon: "app",
                           group: "Installed apps · \(apps.count)",
                           primary: PaletteAction(title: "Review…", symbol: "list.bullet.rectangle",
                                                  effect: .push(.uninstallReview(app.url))) {},
                           secondaries: [PaletteAction(title: "Show in Finder", symbol: "folder") {
                               NSWorkspace.shared.activateFileViewerSelecting([app.url])
                           }],
                           accessory: runningKeys.contains(key) ? "Running" : nil, image: session.icon(forPath: app.url.path))
            item.keywords = PaletteApplications.bundleID(for: app.url) ?? ""
            return item
        }
    }

    private func uninstallReviewItems() -> [PaletteItem] {
        guard let flow = screens.uninstall else { return [] }
        let back = screenRow("uninstall.back", "Back to Installed Apps", "Nothing changes", icon: "chevron.left", group: nil,
                       primary: PaletteAction(title: "Back", effect: .stay) { pop() })
        switch flow.phase {
        case .checking, .scanning, .quitting, .moving:
            return []
        case .needsQuit(let name):
            return [screenRow("uninstall.quit", "Quit \(name) and Review", "\(name) is asked to quit the normal way first; it can still ask to save",
                        icon: "xmark.circle", group: nil,
                        primary: PaletteAction(title: "Quit and Review", effect: .stay) { flow.quitAndReview() }),
                    back]
        case .failed:
            return [screenRow("uninstall.retry", "Check Again", "Run the checks and the scan once more", icon: "arrow.clockwise",
                        group: nil, primary: PaletteAction(title: "Check Again", effect: .stay) { flow.start() }),
                    back]
        case .done(let outcome):
            var items: [PaletteItem] = []
            if flow.canRetry {
                items.append(screenRow("uninstall.retry", "Try Again for What Stayed", "Only the items that didn't move, ticked again",
                                       icon: "arrow.clockwise", group: "Next",
                                       primary: PaletteAction(title: "Review Again", effect: .stay) { flow.retryFailed() }))
            }
            items.append(screenRow("uninstall.done", "Done", "Back to the installed apps", icon: "checkmark", group: "Next",
                             primary: PaletteAction(title: "Done", effect: .stay) { pop() }))
            items.append(screenRow("uninstall.trash", "Open the Trash", "Put Back works for everything moved", icon: "trash",
                             group: "Next", primary: PaletteAction(title: "Open Trash") {
                                 NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                             }))
            items += outcome.failures.enumerated().map { index, failure in
                screenRow("uninstall.failure.\(index)", failure, "Stayed where it was", icon: "exclamationmark.triangle",
                          group: "Not moved", primary: PaletteAction(title: "Stayed", effect: .stay) {}, dimmed: true)
            }
            return items
        case .review:
            let count = flow.chosen.count
            let trashTitle = "Move \(count) Item\(count == 1 ? "" : "s") to Trash…"
            return flow.candidates.map { candidate in
                let ticked = flow.selected.contains(candidate.id)
                let nameOnly = flow.isNameOnly(candidate)
                let path = (candidate.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                var item = screenRow("review.\(candidate.id)", candidate.url.lastPathComponent,
                               nameOnly ? "Matches the app's name only · \(path)" : path,
                               icon: candidate.note == "App" ? "app" : "doc", group: candidate.note,
                               primary: PaletteAction(title: ticked ? "Untick" : "Tick", effect: .stay) { flow.toggle(candidate.id) },
                               secondaries: (count > 0 ? [
                                   PaletteAction(title: trashTitle, symbol: "trash", effect: .stay, isDestructive: true) {
                                       confirmTrash(flow)
                                   }] : []) + [
                                   PaletteAction(title: "Show in Finder", symbol: "folder") {
                                       NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
                                   },
                                   PaletteAction(title: "Tick All", symbol: "checklist.checked", effect: .stay) { flow.selectAll() },
                                   PaletteAction(title: "Untick All", symbol: "checklist.unchecked", effect: .stay) { flow.selectNone() },
                               ],
                               accessory: SystemStatus.size(candidate.size),
                               image: candidate.note == "App" ? session.icon(forPath: candidate.url.path) : nil)
                item.checked = ticked
                return item
            }
        }
    }

    private func confirmTrash(_ flow: PaletteUninstallFlow) {
        let chosen = flow.chosen
        guard !chosen.isEmpty else { screens.show("Tick at least one item first"); return }
        let appIncluded = chosen.contains { $0.url == flow.app }
        confirm(PaletteConfirmation(
            title: "Move \(chosen.count) Item\(chosen.count == 1 ? "" : "s") to the Trash?",
            message: "\(appIncluded ? "\(flow.name) and \(chosen.count - 1) leftover\(chosen.count == 2 ? "" : "s")" : "\(chosen.count) leftover\(chosen.count == 1 ? "" : "s")") · \(SystemStatus.size(flow.selectedSize)). Finder's Put Back can restore them.",
            confirmTitle: "Move to Trash", symbol: "trash.fill") { flow.trash() })
    }

    // Sound devices (Raycast's Manage Sound Output/Input Devices).
    private func soundItems() -> [PaletteItem] {
        guard let sound = screens.sound else { return [] }
        var items: [PaletteItem] = sound.outputs.map { device in
            let current = device.id == sound.currentOutput
            return screenRow("sound.out.\(device.uid)", device.name, current ? "Current output" : "Sound output",
                       icon: current ? "speaker.wave.2.fill" : "speaker.wave.2", group: "Output",
                       primary: PaletteAction(title: current ? "Current Output" : "Use for Sound Output", effect: .stay) {
                           AudioOutputService.shared.select(name: device.name, uid: device.uid) { ok in
                               DispatchQueue.main.async {
                                   screens.show(ok ? "Sound output: \(device.name)" : "\(device.name) didn't take the output")
                                   screens.loadSound()
                               }
                           }
                       }, accessory: current ? "✓ Current" : nil)
        }
        items += sound.inputs.map { device in
            let current = device.id == sound.currentInput
            return screenRow("sound.in.\(device.uid)", device.name, current ? "Current input" : "Sound input",
                       icon: current ? "mic.fill" : "mic", group: "Input",
                       primary: PaletteAction(title: current ? "Current Input" : "Use for Sound Input", effect: .stay) {
                           let ok = AudioOutputService.selectInput(uid: device.uid)
                           screens.show(ok ? "Sound input: \(device.name)" : "\(device.name) didn't take the input")
                           screens.loadSound()
                       }, accessory: current ? "✓ Current" : nil)
        }
        items.append(screenRow("sound.mute", sound.isMuted ? "Unmute" : "Mute", "The current output · 음소거",
                         icon: sound.isMuted ? "speaker.wave.2" : "speaker.slash", group: "Volume",
                         primary: PaletteAction(title: sound.isMuted ? "Unmute" : "Mute", effect: .stay) {
                             AudioOutputService.shared.toggleOutputMute { _ in DispatchQueue.main.async { screens.loadSound() } }
                         }))
        for level in [25, 50, 75, 100] {
            var item = screenRow("sound.volume.\(level)", "Set Volume to \(level)%", "The current output", icon: "speaker.wave.\(level >= 75 ? 3 : level >= 50 ? 2 : 1)",
                           group: "Volume", primary: PaletteAction(title: "Set \(level)%", effect: .stay) {
                               AudioOutputService.shared.setVolume(percent: Double(level)) { ok in
                                   DispatchQueue.main.async { screens.show(ok ? "Volume \(level)%" : "This output has no volume control") }
                               }
                           })
            item.aliases = ["\(level)", "\(level)%"]
            items.append(item)
        }
        return items
    }

    // Clipboard History (Raycast, Spotlight in macOS 26): every entry, not
    // the root's 20; ↩ pastes into the app that was in front.
    private func clipboardHistoryItems() -> [PaletteItem] {
        let target = host == .launcher ? AOMLauncherController.shared.frontApp : PaletteSession.previousApp()
        let canPaste = AXIsProcessTrusted() && target != nil
        let pasteTitle = canPaste ? "Paste to \(target?.localizedName ?? "App")" : "Copy"
        let search = isSearching ? ClipboardSearchQuery(trimmed) : nil
        let boards = clipboardStore.boards
        let matching = search.map { query in clipboardStore.entries.lazy.filter { query.matches($0, boards: boards) } }
        let entries = matching.map { Array($0.prefix(300)) } ?? Array(clipboardStore.entries.prefix(300))
        return entries.map { entry in
            var secondaries = [PaletteAction(title: "Copy", symbol: "doc.on.doc") { copyEntry(entry.id, plainText: false) }]
            if entry.kind == .text || entry.kind == .link {
                secondaries.append(PaletteAction(title: "Copy as Plain Text", symbol: "textformat") { copyEntry(entry.id, plainText: true) })
            }
            var item = screenRow("cliphistory.\(entry.id.uuidString)", entry.title,
                           [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                           icon: entry.kind.symbol, group: nil, section: .clipboard,
                           primary: PaletteAction(title: pasteTitle, symbol: "doc.on.clipboard") {
                               guard copyEntry(entry.id, plainText: false), canPaste, let target else { return }
                               Self.paste(into: target, triesLeft: 10) { pasted in
                                   if !pasted {
                                       GestureHUD.shared.show(title: "Copied",
                                                              detail: "\(target.localizedName ?? "The app") didn't come back in time — press ⌘V there.")
                                   }
                               }
                           },
                           secondaries: secondaries)
            item.keywords = entry.sourceName ?? ""
            return item
        }
    }

    /// ⌘V to the app once it is frontmost again (the panel gave focus back).
    static func paste(into target: NSRunningApplication, triesLeft: Int, done: @escaping (Bool) -> Void = { _ in }) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            done(ClipboardStackPasteMonitor.sendPaste(to: target))
        } else if triesLeft > 0, !target.isTerminated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { paste(into: target, triesLeft: triesLeft - 1, done: done) }
        } else {
            done(false)
        }
    }

    // Window Management: every layout WindowManager performs, grouped.
    private func windowLayoutItems() -> [PaletteItem] {
        func layout(_ id: String, _ title: String, _ subtitle: String, _ type: ActionType, _ group: String) -> PaletteItem {
            screenRow("window.\(id)", title, subtitle, icon: type.iconName, group: group, section: .commands,
                primary: PaletteAction(title: "Apply") { ActionExecutor.executeAction(TriggerAction(actionType: type)) })
        }
        var items = [
            layout("left", "Left Half", "Move the front window to the left half", .snapWindowLeft, "Halves"),
            layout("right", "Right Half", "Move the front window to the right half", .snapWindowRight, "Halves"),
            layout("maximize", "Maximize", "Fill the visible screen", .maximizeWindow, "Whole screen"),
        ]
        for entry in Self.windowLayouts {
            let group = entry.id.contains("Third") ? "Thirds" : entry.id.contains("Half") ? "Halves"
                : entry.id == "center" ? "Whole screen" : "Quarters"
            var item = layout(entry.id, entry.title.replacingOccurrences(of: "Tile Window ", with: ""), entry.subtitle, entry.type, group)
            item.keywords = entry.keywords
            items.append(item)
        }
        let order = ["Halves", "Quarters", "Thirds", "Whole screen"]
        items = items.enumerated().sorted {
            ((order.firstIndex(of: $0.element.group ?? "") ?? 9), $0.offset) < ((order.firstIndex(of: $1.element.group ?? "") ?? 9), $1.offset)
        }.map(\.element)
        items.append(screenRow("window.pinFront", "Pin Front Window", "Keep it above the others", icon: "pin", group: "Pins & windows",
                         primary: PaletteAction(title: "Pin") { ActionExecutor.executeAction(TriggerAction(actionType: .togglePinFrontWindow)) }))
        items.append(screenRow("window.unpinAll", "Unpin All Windows", "Remove every live pin", icon: "pin.slash", group: "Pins & windows",
                         primary: PaletteAction(title: "Unpin All") { ActionExecutor.executeAction(TriggerAction(actionType: .unpinAllWindows)) }))
        items.append(screenRow("window.switcher", "Window Switcher", "Every window with thumbnails", icon: "rectangle.stack",
                         group: "Pins & windows", primary: PaletteAction(title: "Show") { WindowSwitcherController.shared.show() }))
        return items
    }

    // Keep Awake: durations (KeepingYouAwake, Amphetamine), the display rule.
    private func keepAwakeItems() -> [PaletteItem] {
        let awake = KeepAwakeService.shared
        let rules = KeepAwakeRules.shared
        var items: [PaletteItem] = []
        if awake.isActive {
            items.append(screenRow("awake.off", "Turn Off Keep Awake", "Running \(awake.remainingDescription ?? "")", icon: "cup.and.saucer.fill",
                             group: "Now", primary: PaletteAction(title: "Turn Off") { awake.stop() }))
        }
        for choice in PaletteKeepAwakeChoices.all {
            var item = screenRow(choice.id, choice.title, choice.keepDisplay ? "The display stays on too, until turned off" : "Then the Mac may sleep again",
                           icon: choice.keepDisplay ? "sun.max" : "timer", group: "Keep the Mac awake",
                           primary: PaletteAction(title: "Start") { awake.start(minutes: choice.minutes, keepDisplay: choice.keepDisplay) })
            item.aliases = choice.aliases
            items.append(item)
        }
        items.append(screenRow("awake.rule", "While a Display Is Connected", "Turn Keep Awake on whenever an external display is connected",
                         icon: "display.2", group: "Rules",
                         primary: PaletteAction(title: rules.whileExternalDisplay ? "Turn Off Rule" : "Turn On Rule", effect: .stay) {
                             rules.whileExternalDisplay.toggle()
                             screens.show(rules.whileExternalDisplay ? "Rule on: a display keeps the Mac awake" : "Rule off")
                         }, accessory: rules.whileExternalDisplay ? "On" : "Off"))
        return items
    }

    /// 6.10: AlDente's controls from the launcher. Each shows the result it
    /// actually got (macOS's confirmation or refusal), when it arrives.
    private func batteryItems() -> [PaletteItem] {
        let battery = HardwareCareModel.shared
        let report: (String) -> Void = { text in GestureHUD.shared.show(title: "Battery", detail: text) }
        func row(_ id: String, _ title: String, _ subtitle: String, _ icon: String, _ aliases: [String],
                 _ run: @escaping (@escaping (String) -> Void) -> Void) -> PaletteItem {
            var item = screenRow(id, title, subtitle, icon: icon, group: "Battery",
                                 primary: PaletteAction(title: "Run") { run(report) })
            item.aliases = aliases
            item.keywords = "battery 배터리 aldente 충전"
            return item
        }
        let level = battery.power?.percent.map { "\($0)%" } ?? "—"
        var items = [
            row("battery.hold", "Hold Battery Here", "Stop charging at \(level) and run on the adapter (80% at least) · 바이패스",
                "pause.circle", ["hold", "bypass", "hold here", "바이패스", "충전 멈춤", "충전 중지"]) { battery.holdHere(done: $0) },
        ]
        // Only when it can do something: a limit to lift, on the adapter.
        if battery.canTopUp {
            items.append(row("battery.topup", "Top Up Battery to 100%", "Once; your limit comes back when full · 완충", "arrow.up.circle",
                             ["top up", "full charge", "완충", "100%"]) { battery.topUp(done: $0) })
        }
        for limit in HardwareCareModel.limits {
            items.append(row("battery.limit.\(limit)", "Charge Limit \(limit)%", battery.nativeLimit == limit ? "In use" : "macOS's own limit",
                             "battery.75percent", ["limit \(limit)", "충전 제한 \(limit)"]) { battery.setLimit(limit, done: $0) })
        }
        items.append(row("battery.limit.off", "Charge Limit Off", "Charge to 100% every time", "battery.100percent",
                         ["no limit", "limit off", "충전 제한 끄기"]) { battery.setLimit(nil, done: $0) })
        if battery.dischargeTarget != nil {
            items.append(row("battery.stopDischarge", "Stop Discharge", "Give the adapter back", "stop.circle",
                             ["stop discharge", "방전 중지"]) { battery.stopDischarge(done: $0) })
        } else if battery.power?.externalConnected ?? false {
            for target in [80, 60] {
                items.append(row("battery.discharge.\(target)", "Discharge Battery to \(target)%", "Cut the adapter until \(target)% (hardware helper) · 방전",
                                 "arrow.down.circle", ["discharge", "방전", "sailing"]) { battery.discharge(to: target, done: $0) })
            }
        }
        return items
    }

    private func systemCommandItem(_ command: PaletteSystemCommand) -> PaletteItem {
        let action: PaletteAction
        if let words = command.confirmation {
            action = PaletteAction(title: "Run…", effect: .stay, isDestructive: true) {
                confirm(PaletteConfirmation(title: words.title, message: words.message, confirmTitle: words.button,
                                            after: .close(restoresFocus: true)) { command.run() })
            }
        } else {
            action = PaletteAction(title: "Run") { command.run() }
        }
        var item = screenRow(command.id, command.title, command.subtitle, icon: command.symbol, group: command.group, primary: action)
        item.aliases = command.aliases
        return item
    }

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
        // A row that went away (an app that quit) hands the selection to its neighbour.
        let selected = items.first { $0.id == selectedID }
            ?? screens.neighbor(of: selectedID).flatMap { id in items.first { $0.id == id } }
            ?? items.first
        let size = host == .launcher ? AOMLauncherController.shared.panelSize
            : CGSize(width: AOMSize.paletteWidth, height: AOMFeatureSize.paletteHeight)
        let header = routeHeader
        ZStack {
            if host == .window {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                searchField(count: items.count)
                AOMDivider()
                if let header {
                    routeHeaderView(header, fills: items.isEmpty)
                    if !items.isEmpty { AOMDivider() }
                } else if let notice = screens.notice, !navigation.isRoot {
                    noticeLine(notice)
                }
                if navigation.current == .ai, !ai.messages.isEmpty {
                    aiTranscript
                } else if !items.isEmpty {
                    resultList(items, selected: selected)
                } else if header == nil {
                    emptyState
                }
                AOMDivider()
                actionBar(selected)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomTrailing) {
                if showsActions, let selected {
                    actionPanel(selected)
                        .padding(.trailing, AOMSpace.x3)
                        .padding(.bottom, PaletteMetrics.actionBarHeight + AOMSpace.x1)
                        // Grows from the Actions key it belongs to (report 04 §5.3).
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
                }
            }
            // Glass chrome draws its own shadow; nothing is added on top (c.4).
            .aomFloatingSurface(.panel, radius: PaletteMetrics.panelRadius, inWindow: host == .window)
            // Raycast's entrance: 0.98 → 1 with the fade (report 04 §5.3);
            // 6.7 (report A4): a fade only with Reduce Motion.
            .scaleEffect(appeared || Self.reducesMotion ? 1 : 0.98)
            .opacity(appeared ? 1 : 0)
            .background(alignment: .topLeading) {
                // ⌘K inside the palette opens the Actions panel (Raycast).
                Button("Actions") { toggleActions(selected) }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
                // 6.9: Raycast's Quick AI keys on Ask AI.
                if navigation.current == .ai {
                    Button("Continue in Terminal") { _ = ai.continueInTerminal() }
                        .keyboardShortcut("j", modifiers: .command).opacity(0).accessibilityHidden(true)
                    Button("New Chat") { ai.newChat() }
                        .keyboardShortcut("n", modifiers: .command).opacity(0).accessibilityHidden(true)
                }
                // ⌘, opens Settings from the palette, as in Raycast.
                Button("Settings") { close(); openAOMSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .aomAnimation(.quick, value: showsActions)
        .onAppear {
            appear()
            withAnimation(PresetManager.isUIPreview ? nil : Self.reducesMotion ? .linear(duration: 0.1) : .smooth(duration: 0.22)) {
                appeared = true
            }
        }
        // Every source of rows; hover and arrow keys reuse the cached list.
        .onReceive(clipboardStore.objectWillChange) { _ in sourcesChanged() }
        .onReceive(captureHistory.objectWillChange) { _ in sourcesChanged() }
        .onReceive(quicklinks.objectWillChange) { _ in sourcesChanged() }
        .onReceive(session.objectWillChange) { _ in sourcesChanged() }
        .onReceive(recentFiles.objectWillChange) { _ in sourcesChanged() }
        .onReceive(KeepAwakeService.shared.objectWillChange) { _ in sourcesChanged() }
        .onReceive(appState.objectWillChange) { _ in sourcesChanged() }
        .onReceive(screens.objectWillChange) { _ in sourcesChanged() }
        .onReceive(PaletteUninstallFlow.recentDidChange) { _ in sourcesChanged() }
        .onReceive(ai.objectWillChange) { _ in if navigation.current == .ai { sourcesChanged() } }
        // 6.9: ⇥ asks AI from the root (Raycast's Quick AI); on Ask AI it switches agent.
        .onKeyPress(.tab) {
            if navigation.current == .ai {
                ai.provider = ai.provider == .claude ? .codex : .claude
                return .handled
            }
            guard navigation.isRoot, host == .launcher || host == .window else { return .ignored }
            let question = trimmed
            if question.isEmpty { push(.ai) } else { askAI(question) }
            return .handled
        }
        .onDisappear {
            session.end()
            recentFiles.stop()
            screens.end()
        }
        .onExitCommand {
            // Esc goes back one level: the Actions panel, the screen (6.7),
            // the query, then the palette.
            if showsActions { showsActions = false; return }
            switch PaletteSearch.escapeOutcome(query: query, depth: navigation.depth) {
            case .pop: pop()
            case .clearQuery: query = ""
            case .close: close()
            }
        }
        .onKeyPress(.upArrow) { moveSelection(-1, in: items, selected: selected); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1, in: items, selected: selected); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            // On Ask AI a typed line is a question, not a row choice.
            if navigation.current == .ai, !trimmed.isEmpty, !press.modifiers.contains(.command) {
                askAI(trimmed)
                return .handled
            }
            guard let item = selected else { return .handled }
            if showsActions {
                let action = PaletteSearch.action(at: actionIndex, of: item)
                showsActions = false
                perform(action, of: item)
            } else if press.modifiers.contains(.command) {
                // ⌘↩ keeps running the first secondary, as before. A
                // confirmation has none: ⌘↩ never skips its Cancel row.
                perform(item.secondaries.first, of: item)
            } else {
                perform(item.primary, of: item)
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
        // One battery read per launcher open (its rows are found from the root search).
        HardwareCareModel.shared.refreshBattery()
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
        // 6.7: `--aom-preview-palette-route killApps|uninstallApps|sound|clipboard|
        // windows|keepAwake|system|confirm|review:<app path>` opens a screen.
        if let index = arguments.lastIndex(of: "--aom-preview-palette-route"), arguments.indices.contains(index + 1) {
            let name = arguments[index + 1]
            let filter = arguments.lastIndex(of: "--aom-preview-palette-route-query").flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                switch name {
                case "confirm":
                    push(.killApps)
                    confirmQuitAll(PaletteKillApps.entries().filter { !$0.isProtected }, keeping: session.target?.name ?? "Finder")
                case let review where review.hasPrefix("review:"):
                    push(.uninstallApps)
                    push(.uninstallReview(URL(fileURLWithPath: String(review.dropFirst("review:".count)))))
                default:
                    if name == "ai", let question = arguments.lastIndex(of: "--aom-preview-ai-question").flatMap({
                        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }) {
                        askAI(question)
                        return
                    }
                    let routes: [String: PaletteRoute] = ["ai": .ai, "killApps": .killApps, "uninstallApps": .uninstallApps,
                                                          "sound": .soundDevices, "clipboard": .clipboard,
                                                          "windows": .windowLayouts, "keepAwake": .keepAwake, "system": .system]
                    if let route = routes[name] { push(route) }
                }
                if let filter { query = filter }
            }
        }
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

    // MARK: Screen header

    /// What a screen says above its rows: the question, the progress, the result.
    struct RouteHeader {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
        var busy = false
        var image: NSImage?
    }

    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var routeHeader: RouteHeader? {
        switch navigation.current {
        case .confirm?:
            guard let question = confirmation else { return nil }
            return RouteHeader(symbol: question.symbol, tint: question.destructive ? AOMColor.danger : AOMColor.warning,
                               title: question.title, detail: question.message)
        case .uninstallReview?:
            guard let flow = screens.uninstall else { return nil }
            let icon = session.icon(forPath: flow.app.path)
            switch flow.phase {
            case .checking:
                return RouteHeader(symbol: "magnifyingglass", tint: AOMModule.systemTools.hue, title: "Checking \(flow.name)…",
                                   detail: "Whether it may be removed and whether a copy is open.", busy: true, image: icon)
            case .needsQuit(let name):
                return RouteHeader(symbol: "xmark.circle", tint: AOMColor.warning, title: "Quit \(name) First?",
                                   detail: "\(name) is open. AOM asks it to quit the normal way (it can still ask to save), then lists what would move to the Trash. Nothing moves until you confirm.",
                                   image: icon)
            case .quitting(let name):
                return RouteHeader(symbol: "hourglass", tint: AOMColor.warning, title: "Waiting for \(name) to Quit…",
                                   detail: "If it asks about unsaved work, answer it in \(name). Nothing is moved meanwhile.", busy: true, image: icon)
            case .scanning:
                return RouteHeader(symbol: "magnifyingglass", tint: AOMModule.systemTools.hue, title: "Looking for \(flow.name)'s Leftovers…",
                                   detail: "~/Library: Application Support, Caches, Preferences, Containers, Saved State, Logs …", busy: true, image: icon)
            case .review:
                let count = flow.chosen.count
                let unread = flow.unreadable.isEmpty ? ""
                    : " Not checked (no access): \(flow.unreadable.joined(separator: ", "))."
                return RouteHeader(symbol: "trash", tint: AOMColor.danger, title: "Uninstall \(flow.name)",
                                   detail: (count == 0
                                       ? "Nothing ticked. ↩ ticks a row; ⌘↩ appears once something is ticked."
                                       : "\(count) of \(flow.candidates.count) ticked · \(SystemStatus.size(flow.selectedSize)). ↩ ticks a row, ⌘↩ moves the ticked items to the Trash (Put Back works). Items that only share the app's name start unticked.")
                                       + unread,
                                   image: icon)
            case .moving:
                return RouteHeader(symbol: "trash", tint: AOMColor.danger, title: "Moving to the Trash…",
                                   detail: "\(flow.chosen.count) item\(flow.chosen.count == 1 ? "" : "s").", busy: true, image: icon)
            case .done(let outcome):
                return RouteHeader(symbol: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                   tint: outcome.failures.isEmpty ? AOMColor.success : AOMColor.warning,
                                   title: PaletteUninstallFlow.title(for: outcome, app: flow.app, name: flow.name),
                                   detail: outcome.summary + ".", image: icon)
            case .failed(let title, let detail):
                return RouteHeader(symbol: "exclamationmark.triangle.fill", tint: AOMColor.warning, title: title, detail: detail, image: icon)
            }
        case .ai?:
            let installed = ai.provider.executable != nil
            return RouteHeader(symbol: ai.provider.symbol, tint: AOMBrand.start,
                               title: ai.isRunning ? "\(ai.provider.title) is answering…" : ai.provider.title,
                               detail: installed
                                   ? "Your own \(ai.provider.title) CLI, read-only here. ↩ pastes the answer into \(frontAppForAI?.localizedName ?? "the app you were in"), ⌘↩ copies, ⌘J continues in Terminal (it can edit and run there, asking first), ⌘N new chat, ⇥ switches agent."
                                   : "\(ai.provider.title) isn't installed on this Mac. ⇥ switches agent.",
                               busy: ai.isRunning)
        case .soundDevices? where screens.sound == nil:
            return RouteHeader(symbol: "hifispeaker.2", tint: AOMModule.audio.hue, title: "Reading Sound Devices…",
                               detail: "Outputs, inputs and the current volume.", busy: true)
        default:
            return nil
        }
    }

    private func routeHeaderView(_ header: RouteHeader, fills: Bool) -> some View {
        HStack(alignment: .top, spacing: AOMSpace.x3) {
            ZStack(alignment: .bottomTrailing) {
                if let image = header.image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    Image(systemName: header.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(header.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if header.image != nil {
                    Image(systemName: header.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(header.tint, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                HStack(spacing: AOMSpace.x2) {
                    Text(header.title).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                    if header.busy { ProgressView().controlSize(.small).scaleEffect(0.8) }
                }
                Text(header.detail)
                    .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = screens.notice {
                    Text(notice).font(AOMFont.caption.weight(.medium)).foregroundStyle(AOMColor.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.x4)
        .padding(.vertical, AOMSpace.x3)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(header.tint.opacity(contrast == .increased ? 0.14 : 0.06))
        .accessibilityElement(children: .combine)
    }

    /// The conversation: each question, then its answer (Markdown inline,
    /// selectable), errors in red; follows the newest line.
    private var aiTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.x3) {
                    ForEach(ai.messages) { message in
                        switch message.role {
                        case .user:
                            Text(message.text)
                                .font(AOMFont.body.weight(.semibold))
                                .foregroundStyle(AOMColor.textSecondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        case .assistant:
                            if message.text.isEmpty {
                                HStack(spacing: AOMSpace.x2) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").font(AOMFont.callout).foregroundStyle(AOMColor.textTertiary)
                                }
                            } else {
                                Text(Self.markdown(message.text))
                                    .font(AOMFont.body)
                                    .foregroundStyle(AOMColor.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .error:
                            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                                .font(AOMFont.callout)
                                .foregroundStyle(AOMColor.dangerText)
                                .padding(AOMSpace.x2)
                                .background(AOMColor.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 1).id("ai.bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AOMSpace.x4)
                .padding(.vertical, AOMSpace.x3)
            }
            .onChange(of: ai.messages) { _, _ in proxy.scrollTo("ai.bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("ai.bottom", anchor: .bottom) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The result of an action that kept the screen ("Asked Safari to quit").
    private func noticeLine(_ text: String) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: "info.circle").foregroundStyle(AOMColor.accent).accessibilityHidden(true)
            Text(text).font(AOMFont.caption.weight(.medium)).foregroundStyle(AOMColor.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: 28)
        .background(AOMColor.accent.opacity(0.08))
        .accessibilityAddTraits(.updatesFrequently)
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
            if let route = navigation.current {
                // 6.7: where you are, as Raycast's navigation title; click to go back.
                Button { pop() } label: {
                    HStack(spacing: AOMSpace.x1) {
                        Image(systemName: "chevron.left").font(AOMFont.caption.weight(.bold))
                        Text(navigation.breadcrumb.last ?? route.title).font(AOMFont.token.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(route == .confirm ? AOMColor.dangerText : AOMColor.accent)
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(minHeight: AOMSize.tokenHeight)
                    .background((route == .confirm ? AOMColor.danger : AOMColor.accent).opacity(contrast == .increased ? 0.22 : 0.12),
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Back (esc)")
                .accessibilityLabel("Back from \(route.title)")
            } else if let match = PaletteQuicklinks.match(query, in: quicklinks.links) {
                // The matched quicklink reads as a token before the search.
                Text(match.link.name)
                    .font(AOMFont.token.weight(.medium))
                    .foregroundStyle(AOMColor.accent)
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(minHeight: AOMSize.tokenHeight)
                    .background(AOMColor.accent.opacity(contrast == .increased ? 0.22 : 0.12), in: Capsule())
                    .accessibilityLabel("Quicklink \(match.link.name)")
            }
            TextField(navigation.current?.placeholder ?? "Search apps, commands, menus, files, or calculate…", text: $query)
                .textFieldStyle(.plain)
                // Raycast's search line is the largest type in the panel.
                .font(host == .launcher ? PaletteMetrics.launcherQueryFont : AOMFont.pageStatus.weight(.regular))
                .focused($isFieldFocused)
                .onChange(of: query) { _, _ in
                    // A popped screen gives its selected row back with its query.
                    if let restore = pendingSelection {
                        selectedID = restore
                        pendingSelection = nil
                    } else {
                        selectedID = nil
                    }
                    showsActions = false
                    // A confirmation is answered, not searched.
                    if navigation.current?.isSearchable == false, !query.isEmpty { query = "" }
                }
                .accessibilityLabel("Search")
            if recentFiles.isLoading {
                // Spotlight is still answering (report 04 §5.5).
                ProgressView().controlSize(.small).scaleEffect(0.8)
                    .accessibilityLabel("Searching files")
            }
            if isSearching {
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(AOMColor.textTertiary)
            } else if host == .launcher, navigation.isRoot, AOMLauncherShortcut.isRegistered {
                // The key that brings this back from any app.
                HStack(spacing: AOMSpace.x0_5 + 1) {
                    ForEach(AOMLauncherShortcut.current.keycaps, id: \.self) { AOMKeycap(text: $0) }
                }
                .help("Open from any app with \(AOMLauncherShortcut.current.displayString)")
            }
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: host == .launcher ? PaletteMetrics.launcherSearchHeight : AOMSize.rowDetail)
    }

    /// 6.7: "No search results" and "nothing to list" read differently,
    /// and a screen never falls back to a web search.
    private var emptyTitle: String {
        switch navigation.current {
        case nil: return "No results for “\(query)”"
        case .killApps?: return isSearching ? "No running app matches “\(query)”" : "No app AOM can quit is running"
        case .uninstallApps?: return isSearching ? "No installed app matches “\(query)”" : "No app AOM can uninstall"
        case .clipboard?: return isSearching ? "Nothing copied matches “\(query)”" : "Clipboard history is empty"
        case let route?: return isSearching ? "Nothing in \(route.title) matches “\(query)”" : "Nothing here yet"
        }
    }

    private var emptyDetail: String {
        switch navigation.current {
        case nil: return "Try an automation name, an app, a menu item or a sum such as 12 × 11."
        case .killApps?: return "Only apps with a Dock icon are listed; Finder and AOM itself are never quit from here."
        case .uninstallApps?: return "Apps that come with macOS and All of MacOS itself aren't listed."
        default: return "esc goes back to the previous screen."
        }
    }

    private var emptyState: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: "magnifyingglass")
                .font(AOMFont.title.weight(.regular)).imageScale(.large)
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.bottom, AOMSpace.x1)
                .accessibilityHidden(true)
            Text(emptyTitle).font(AOMFont.headline).foregroundStyle(AOMColor.text)
            Text(emptyDetail)
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
                            Text(headerTitle(item))
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
    private func headerTitle(_ item: PaletteItem) -> String {
        if !navigation.isRoot { return item.group ?? "" }
        return item.placement == .fallback ? "Search with" : item.isSuggestion ? "Suggestions" : sectionTitle(item.section)
    }

    private func showsHeader(at index: Int, in items: [PaletteItem]) -> Bool {
        let item = items[index]
        let previous = index > 0 ? items[index - 1] : nil
        // A screen groups its rows by `group`, searching or not.
        if !navigation.isRoot {
            guard let group = item.group, !group.isEmpty, navigation.current != .confirm else { return false }
            return previous?.group != group
        }
        if !isSearching {
            guard let previous else { return true }
            return previous.isSuggestion != item.isSuggestion || (!item.isSuggestion && previous.section != item.section)
        }
        if item.placement == .fallback { return previous?.placement != .fallback }
        return false
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        // The hover lives in the row (6.5): moving the pointer redraws one
        // row, not the palette and its search. 6.7: a destructive answer is
        // selected in red.
        PaletteRowButton(selected: selected,
                         tint: item.isDimmed ? Color.gray.opacity(0.55)
                             : item.primary.isDestructive && navigation.current == .confirm ? AOMColor.danger : nil) {
            // 6.8 (Codex review K1): inside a screen a click selects and a
            // second click (or ↩) acts — one click never quits or trashes.
            if !navigation.isRoot, !selected {
                selectedID = item.id
                return
            }
            selectedID = item.id
            perform(item.primary, of: item)
        } label: {
            if item.section == .calculator {
                calculatorRow(item, selected: selected)
            } else {
                standardRow(item, selected: selected)
            }
        }
        .contextMenu {
            ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { perform(action, of: item) }
            }
            if PaletteKnowledgeStore.shared.knowledge.decayedScore(item.id, now: Date()) > 0 {
                Divider()
                Button("Forget This Suggestion") { PaletteKnowledgeStore.shared.forget(item.id); refreshToken += 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityValue(item.checked.map { $0 ? "ticked" : "not ticked" } ?? "")
        .accessibilityHint(item.primary.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
            // 5.0: every row wears a mark — the destination's own, the hue
            // of the tool a command belongs to, or its section's hue
            // (Raycast's coloured command icons).
            AOMAppIcon(item.identity ?? AOMIdentity(symbol: item.icon,
                                                    color: Self.commandColor(id: item.id) ?? Self.sectionColor(item.section)),
                       size: PaletteMetrics.rowBadge, active: !item.isDimmed)
        }
    }

    /// The tool a command row belongs to, from its id's prefix.
    static func commandColor(id: String) -> Color? {
        let prefix = id.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "capture": return AOMModule.capture.hue
        case "clipboard": return AOMModule.clipboard.hue
        case "window": return AOMModule.tiling.hue
        case "audio": return AOMModule.audio.hue
        case "system": return AOMModule.systemTools.hue
        case "files": return AOMModule.files.hue
        // 6.7: the launcher screens' rows.
        case "kill", "uninstall", "review": return AOMModule.systemTools.hue
        case "sound": return AOMModule.audio.hue
        case "cliphistory": return AOMModule.clipboard.hue
        case "ai": return AOMBrand.start
        case "awake": return AOMModule.focus.hue
        case "battery": return AOMColor.success
        case "confirm": return id == "confirm.accept" ? AOMColor.danger : AOMBrand.graphite
        default: return nil
        }
    }

    /// The hue of a section's rows: the module that owns them, graphite for
    /// system-wide rows.
    static func sectionColor(_ section: Section) -> Color {
        switch section {
        case .commands: return AOMBrand.start
        case .automations: return AOMModule.automation.hue
        case .clipboard: return AOMModule.clipboard.hue
        case .captures: return AOMModule.capture.hue
        case .recentFiles, .files: return AOMModule.files.hue
        case .quicklinks, .bookmarks: return AOMModule.tiling.hue
        case .calculator, .navigation, .applications, .menuItems, .fallback: return AOMBrand.graphite
        }
    }

    private func standardRow(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: AOMSpace.x2) {
            if let checked = item.checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.white : checked ? AOMColor.accent : AOMColor.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            badge(item, selected: selected)
            Text(item.title)
                .font(AOMFont.body.weight(.medium))
                .foregroundStyle(selected ? Color.white
                                 : item.primary.isDestructive && navigation.current == .confirm ? AOMColor.dangerText : AOMColor.text)
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
            } else if isSearching, navigation.isRoot, item.placement == .ranked, !item.pushes {
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
            if item.pushes {
                // Raycast: a command that opens a screen.
                Image(systemName: "chevron.right")
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : AOMColor.textTertiary)
                    .accessibilityHidden(true)
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
            Text(navigation.current.map { _ in navigation.breadcrumb.joined(separator: " › ") }
                 ?? item.map { sectionTitle($0.section) } ?? " ")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
            Spacer()
            if let item, item.isDimmed {
                // A protected row says why instead of offering a dead ↩.
                Label(item.id == "ai.answer" ? "Waiting for the answer…" : item.id.hasPrefix("kill.") ? "Protected" : "Unavailable",
                      systemImage: item.id == "ai.answer" ? "hourglass" : "lock")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            } else if let item {
                actionHint(item.primary.title, keys: "↩", prominent: true) { perform(item.primary, of: item) }
                if let secondary = item.secondaries.first {
                    actionHint(secondary.title, keys: "⌘↩", prominent: false) { perform(secondary, of: item) }
                }
                if item.actions.count > 1 {
                    actionHint("Actions", keys: "⌘K", prominent: false) { toggleActions(item) }
                }
            }
            actionHint(isSearching || showsActions || !navigation.isRoot ? "Back" : "Close", keys: "esc", prominent: false) {
                if showsActions { showsActions = false } else if !navigation.isRoot { pop() } else if isSearching { query = "" } else { close() }
            }
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: PaletteMetrics.actionBarHeight)
        .background(AOMColor.track.opacity(host == .launcher ? 0.6 : 1))
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
                    perform(action, of: item)
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
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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

    /// 6.7: after an uninstall the list is read again on the next search.
    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
        bundleIDs.removeAll()
    }

    private static var bundleIDs: [String: String?] = [:]

    /// Read once per path (the Info.plist), never a Library scan.
    static func bundleID(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = bundleIDs[url.path] { return cached }
        let id = Bundle(url: url)?.bundleIdentifier
        if bundleIDs.count > 512 { bundleIDs.removeAll() }
        bundleIDs[url.path] = id
        return id
    }

    /// The installed list plus running apps that live outside the scanned
    /// folders (an external volume, Downloads), each copy once. Pure.
    /// 6.7 (report L2): a running app is dropped only when that very copy
    /// is listed already (by its path or the path a listed symlink points
    /// to), not because it sits somewhere under a scanned folder — an app
    /// in /Applications/Vendor/ used to vanish from the list.
    static func merged(_ installed: [App], running: [URL], folders: [URL] = folders) -> [App] {
        var known = Set(installed.map { $0.url.standardizedFileURL.path })
        known.formUnion(installed.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        var extra: [App] = []
        for url in running where url.pathExtension == "app" {
            let path = url.standardizedFileURL.path
            // The system's own apps are listed from /System/Applications; an
            // app inside another app's bundle is that app's helper.
            guard !path.hasPrefix("/System/"), !isInsideAnotherBundle(path), known.insert(path).inserted else { continue }
            extra.append(App(name: url.deletingPathExtension().lastPathComponent, url: url))
        }
        return extra.isEmpty ? installed : installed + extra
    }

    /// Pure: "/Applications/Xcode.app/Contents/Applications/Simulator.app".
    static func isInsideAnotherBundle(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents.contains { $0.lowercased().hasSuffix(".app") }
    }

    /// The folders' apps and, one level down, apps in plain subfolders
    /// ("/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app").
    static func scan(_ folders: [URL]) -> [App] {
        var seen = Set<URL>()
        var apps: [App] = []
        func add(_ url: URL) {
            let name = url.deletingPathExtension().lastPathComponent
            guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL).inserted else { return }
            apps.append(App(name: name, url: url))
        }
        let scannedPaths = Set(folders.map { $0.standardizedFileURL.path })
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                if url.pathExtension == "app" { add(url); continue }
                // Utilities is scanned on its own; packages are not folders.
                guard !scannedPaths.contains(url.standardizedFileURL.path), url.pathExtension.isEmpty,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let inner = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                for app in inner where app.pathExtension == "app" { add(app) }
            }
        }
        return apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    /// Name prefix first, then any word that starts with the query, then
    /// anywhere in the name; at most eight, so commands are not crowded out.
    static func matching(_ query: String, in apps: [App]? = nil) -> [App] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fuzzyQuery = PaletteFuzzy.Query(needle) else { return [] }
        func rank(_ app: App) -> Int? {
            let name = app.name
            if name.range(of: needle, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil { return 0 }
            if name.split(separator: " ").contains(where: { $0.range(of: needle, options: [.caseInsensitive, .anchored]) != nil }) { return 1 }
            if name.localizedCaseInsensitiveContains(needle) { return 2 }
            guard let score = PaletteFuzzy.score(fuzzyQuery, PaletteFuzzy.Candidate(name)),
                  score >= PaletteFuzzy.subsequenceFloor + 40 else { return nil }
            return 3 + PaletteFuzzy.exactScore - score
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
    /// Report 04 §5.1 (Raycast's 46 pt rows on AOM's 13 pt type): 44.
    static let rowBadge: CGFloat = 26
    static let rowHeight: CGFloat = 44
    static let calculatorHeight: CGFloat = 60
    static let actionPanelWidth: CGFloat = 280
    static let actionBarHeight: CGFloat = 36
    static let launcherSearchHeight: CGFloat = 52
    static let launcherQueryFont = Font.system(size: 19, weight: .regular)
    /// 6.8: Raycast's rounder panel and rows (was 16 and 9).
    static let panelRadius: CGFloat = 26
    static let rowRadius: CGFloat = 12
}

/// A result row's button with its own hover state, so the pointer moving
/// over the list redraws only the rows it crosses. The selected row is the
/// accent with a faint top light (Raycast's raised selection).
private struct PaletteRowButton<Label: View>: View {
    let selected: Bool
    /// The selection colour when not the accent (a destructive answer).
    var tint: Color? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteMetrics.rowRadius, style: .continuous)
        Button(action: action) {
            label()
                .padding(.horizontal, AOMSpace.x2 + 2)
                .background {
                    if selected {
                        shape.fill(LinearGradient(colors: [tint ?? AOMColor.selection, (tint ?? AOMColor.selection).opacity(0.88)],
                                                  startPoint: .top, endPoint: .bottom))
                            .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 0.75))
                    } else if hovering {
                        shape.fill(AOMColor.rowHover)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The ranked rows for one (query, refresh, generation), kept across
/// renders that change neither (hover, selection, the actions panel).
final class PaletteResultsCache: ObservableObject {
    struct Key: Equatable {
        let query: String
        let refresh: Int
        let generation: Int
        /// 6.7: the launcher screen the rows belong to ("" at the root).
        var route: String = ""
    }
    private var key: Key?
    private var items: [QuickCommandPalette.PaletteItem] = []
    private(set) var builds = 0

    func items(for key: Key, build: () -> [QuickCommandPalette.PaletteItem]) -> [QuickCommandPalette.PaletteItem] {
        if key == self.key { return items }
        items = build()
        self.key = key
        builds += 1
        return items
    }
}

/// Where a launcher row's action runs (pure, for tests): rows that open a
/// sheet keep the panel; rows that open AOM's window bring AOM forward; the
/// rest give the front app its focus back first (menus, tiling, links).
enum PaletteLauncherRouting {
    static func keepsPanel(_ id: String) -> Bool {
        id == "quicklinks.edit" || id == "links.router"
    }

    static func restoresFocus(id: String, section: QuickCommandPalette.Section, action: String) -> Bool {
        if section == .navigation { return false }
        if id.hasPrefix("action.") { return false }
        if id.hasPrefix("trigger."), action == "Open in Editor" { return false }
        if id.hasPrefix("app."), ["Uninstall…", "Force Quit…", "Open"].contains(action) { return false }
        if ["audio.restartCoreAudio", "menus.edit"].contains(id) { return false }
        return true
    }
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
                Color.clear.frame(width: AOMIcon.row, height: 0)
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
                .keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle())
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
