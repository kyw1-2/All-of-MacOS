import AppKit
import SwiftUI

/// The command palette, after Raycast's root search and Action Panel: one
/// field that is focused on open, ↑↓ to move, ↩ for the primary action, ⌘↩
/// for the first secondary (further secondaries sit on the row's right-click
/// menu), Esc to clear the query and then to close. With an
/// empty query results are grouped by kind; while searching they are one
/// ranked list. Shortcut hints are the user's real bindings.
struct QuickCommandPalette: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboardStore = ClipboardStore.shared
    @ObservedObject private var captureHistory = CaptureHistory.shared
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var isFieldFocused: Bool

    struct PaletteAction {
        let title: String
        let run: () -> Void
    }

    struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let section: Section
        var shortcut: String?
        let primary: PaletteAction
        /// ⌘↩ runs the first; the rest surface in the row's right-click menu.
        private(set) var secondaries: [PaletteAction]

        /// The palette stays a launcher, not a context menu.
        static let secondaryLimit = 3

        init(id: String, title: String, subtitle: String, icon: String, section: Section,
             shortcut: String? = nil, primary: PaletteAction, secondaries: [PaletteAction] = []) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.section = section
            self.shortcut = shortcut
            self.primary = primary
            self.secondaries = Array(secondaries.prefix(Self.secondaryLimit))
        }
    }

    enum Section: String, CaseIterable {
        case commands = "Commands"
        case automations = "Automations"
        case clipboard = "Clipboard"
        case captures = "Recent Captures"
        case navigation = "Go To"
        // Listed only while searching, like Raycast's root search.
        case applications = "Applications"
        case files = "Files"
    }

    /// Pure search and keyboard decisions, split from the view so they are
    /// testable without a window: with an empty (or blank) query the results
    /// are grouped by section in declaration order; otherwise they form one
    /// ranked list — title prefix, then title, then subtitle, then section
    /// name — stable within a rank.
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
            return nil
        }

        static func results(for items: [PaletteItem], query: String) -> [PaletteItem] {
            let trimmed = trimmedQuery(query)
            guard !trimmed.isEmpty else {
                return Section.allCases.flatMap { section in items.filter { $0.section == section } }
            }
            return items.compactMap { item in rank(of: item, matching: trimmed).map { (item, $0) } }
                .enumerated()
                .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
                .map(\.element.0)
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

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        func command(_ id: String, _ title: String, _ subtitle: String, _ icon: String, keys: String? = nil,
                     _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: id, title: title, subtitle: subtitle, icon: icon, section: .commands, shortcut: keys,
                                     primary: PaletteAction(title: "Run") { close(); run() }))
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
        command("capture.text", "Capture Text", "Recognise text in a region and copy it", "text.viewfinder",
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
        command("window.left", "Tile Window Left Half", "Move the front window to the left half", "rectangle.lefthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowLeft))
        }
        command("window.right", "Tile Window Right Half", "Move the front window to the right half", "rectangle.righthalf.filled") {
            ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowRight))
        }
        command("window.maximize", "Maximize Window", "Fill the visible screen", "arrow.up.left.and.arrow.down.right") {
            ActionExecutor.executeAction(TriggerAction(actionType: .maximizeWindow))
        }
        command("window.switcher", "Window Switcher", "Switch windows with thumbnails, like AltTab", "rectangle.stack",
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
        command("audio.mixer", "App Audio Mixer", "Per-app volume and mute (macOS 14.2+)", "slider.horizontal.3",
                keys: nil) {
            AppAudioMixerService.shared.showPanel()
        }

        command("menus.edit", "Floating Menus & Widgets", "Create menus, clocks and variable widgets · 플로팅 메뉴", "rectangle.grid.2x2", keys: nil) {
            FloatingMenuController.shared.edit()
        }
        // Every action is searchable, including capabilities which previously
        // existed only inside the automation picker. Opening creates a draft.
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for type in ActionType.allCases {
                items.append(PaletteItem(id: "action.\(type.rawValue)", title: type.rawValue,
                    subtitle: type.description + " · Configure Automation", icon: type.iconName, section: .commands,
                    primary: PaletteAction(title: "Configure Automation") { close(); appState.createDraft(for: type) }))
            }
        }

        for trigger in appState.currentPreset.triggers {
            var keys: String?
            if case .keyboardShortcut(let shortcut) = trigger.input { keys = shortcut.displayString }
            // Never offer a list-level run for Type Text (it could type a stored password).
            var secondaries: [PaletteAction] = []
            if trigger.isEnabled, !trigger.actions.isEmpty, !trigger.aomTypesText {
                secondaries = [PaletteAction(title: "Run Now") {
                    close()
                    ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                                  triggerID: trigger.id)
                }]
            }
            items.append(PaletteItem(id: "trigger.\(trigger.id.uuidString)", title: trigger.displayName,
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
                                   secondaries: secondaries))
        }

        for entry in clipboardStore.entries.prefix(20) {
            items.append(PaletteItem(
                id: "clipboard.\(entry.id.uuidString)", title: entry.title,
                subtitle: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                icon: entry.kind.symbol, section: .clipboard,
                primary: PaletteAction(title: "Copy") { close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: false) },
                secondaries: entry.kind == .text || entry.kind == .link
                    ? [PaletteAction(title: "Copy as Plain Text") { close(); _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: true) }]
                    : []))
        }

        for capture in captureHistory.entries.prefix(6) {
            items.append(PaletteItem(
                id: "capture.\(capture.id.uuidString)", title: capture.displayName,
                subtitle: "\(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height)) · \(AOMRelativeTime.string(capture.capturedAt))",
                icon: capture.kind == .videoRecording ? "film" : "photo", section: .captures,
                primary: PaletteAction(title: "Edit") { close(); CaptureItemActions.edit(capture) },
                secondaries: [PaletteAction(title: "Copy") { close(); CaptureItemActions.copy(capture) }]))
        }

        for tab in AOMMainTab.allCases {
            items.append(PaletteItem(id: "go.\(tab.rawValue)", title: tab.title, subtitle: "Show \(tab.title)",
                                     icon: tab.sidebarSymbol, section: .navigation,
                                     shortcut: "⌘\(tab.shortcutKey.character)",
                                     primary: PaletteAction(title: "Open") { close(); appState.selectedMainTab = tab }))
        }
        items.append(PaletteItem(id: "go.settings", title: "Settings", subtitle: "Open All of MacOS Settings",
                                 icon: "gearshape", section: .navigation, shortcut: "⌘,",
                                 primary: PaletteAction(title: "Open") { close(); openSettings() }))
        // BTT / Raycast launcher: installed apps, then a Spotlight file search.
        let trimmed = PaletteSearch.trimmedQuery(query)
        if !trimmed.isEmpty {
            for app in PaletteApplications.matching(trimmed) {
                items.append(PaletteItem(id: "app.\(app.url.path)", title: app.name, subtitle: app.url.deletingLastPathComponent().path,
                                         icon: "app", section: .applications,
                                         primary: PaletteAction(title: "Open") {
                                             close(); NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
                                         },
                                         secondaries: [PaletteAction(title: "Show in Finder") {
                                             close(); NSWorkspace.shared.activateFileViewerSelecting([app.url])
                                         }]))
            }
            items.append(PaletteItem(id: "files.search", title: "Search Files for “\(trimmed)”",
                                     subtitle: "Spotlight results in Finder", icon: "doc.text.magnifyingglass", section: .files,
                                     primary: PaletteAction(title: "Search") {
                                         close(); NSWorkspace.shared.showSearchResults(forQueryString: trimmed)
                                     }))
        }
        return items
    }

    /// Searching ranks one flat list: title prefix, then title, then detail.
    private var results: [PaletteItem] { PaletteSearch.results(for: allItems, query: query) }

    private var isSearching: Bool { !PaletteSearch.trimmedQuery(query).isEmpty }

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
                HStack(spacing: AOMSpace.x3 - AOMSpace.x0_5) {
                    Image(systemName: "magnifyingglass")
                        .font(AOMFont.section.weight(.medium))
                        .foregroundStyle(AOMColor.textSecondary)
                    TextField("Search commands, apps, files, clipboard and captures", text: $query)
                        .textFieldStyle(.plain)
                        .font(AOMFont.pageStatus.weight(.regular))
                        .focused($isFieldFocused)
                        .onChange(of: query) { _, _ in selectedID = nil }
                        .accessibilityLabel("Search")
                    if isSearching {
                        Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                            .font(AOMType.caption.monospacedDigit())
                            .foregroundStyle(AOMTheme.textTertiary)
                    }
                }
                .padding(.horizontal, AOMSpace.m + 2)
                .frame(height: AOMSize.rowDetail + AOMSpace.x0_5)

                AOMDivider()

                if items.isEmpty {
                    VStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                        Image(systemName: "magnifyingglass")
                            .font(AOMFont.hero.weight(.regular))
                            .foregroundStyle(AOMColor.textSecondary)
                            .padding(.bottom, AOMSpace.x1)
                        Text("No Results for “\(query)”").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                        Text("Try an automation name, an app or a word you copied.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        // The empty state needs a mouse-reachable way out too.
                        Button("Clear Search") {
                            query = ""
                            isFieldFocused = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .padding(.top, AOMSpace.x1 + AOMSpace.x0_5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    if !isSearching, index == 0 || items[index - 1].section != item.section {
                                        // Sentence case, no tracking (c.2).
                                        Text(item.section.rawValue)
                                            .font(AOMFont.caption.weight(.semibold))
                                            .foregroundStyle(AOMColor.textSecondary)
                                            .padding(.horizontal, AOMSpace.x3 - AOMSpace.x0_5)
                                            .padding(.top, index == 0 ? AOMSpace.x1 + AOMSpace.x0_5 : AOMSpace.x3)
                                            .padding(.bottom, AOMSpace.x1)
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                    row(item, selected: item.id == selected?.id)
                                        .id(item.id)
                                }
                            }
                            .padding(AOMSpace.x1 + AOMSpace.x0_5)
                        }
                        .onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id, anchor: nil) }
                        }
                    }
                }

                AOMDivider()
                actionBar(selected)
            }
            .frame(width: AOMSize.paletteWidth, height: AOMFeatureSize.paletteHeight)
            // Glass chrome draws its own shadow; nothing is added on top (c.4).
            .aomFloatingSurface(.panel, radius: AOMRadius.panel, inWindow: true)
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand {
            // Esc goes back one level: clear the query, then close.
            switch PaletteSearch.escapeOutcome(query: query) {
            case .clearQuery: query = ""
            case .close: close()
            }
        }
        .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.downArrow) { move(1, in: items); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard let item = selected else { return .handled }
            if press.modifiers.contains(.command) {
                // ⌘↩ keeps running the first secondary, as before.
                item.secondaries.first?.run()
            } else {
                item.primary.run()
            }
            return .handled
        }
    }

    private func move(_ offset: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(items.count - 1, max(0, current + offset))].id
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            selectedID = item.id
            item.primary.run()
        } label: {
            HStack(spacing: AOMSpace.x3 - AOMSpace.x0_5) {
                Image(systemName: item.icon)
                    .font(AOMFont.callout.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? AOMColor.accent : AOMColor.textSecondary)
                    .frame(width: AOMIcon.hitArea - AOMSpace.x1, height: AOMIcon.hitArea - AOMSpace.x1)
                    .background(selected ? AOMColor.accent.opacity(0.14) : AOMColor.track,
                                in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                Text(item.title)
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: AOMSpace.x2)
                if isSearching {
                    Text(item.section.rawValue).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                if let keys = item.shortcut { AOMKeycap(text: keys) }
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: AOMSize.rowStandard)
            .background(selected ? AOMColor.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paletteExtraActionsMenu(Array(item.secondaries.dropFirst()))
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The selected item's actions with their keys, Raycast-style.
    private func actionBar(_ item: PaletteItem?) -> some View {
        HStack(spacing: AOMSpace.x3) {
            Text(item?.section.rawValue ?? " ")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
            Spacer()
            if let item {
                actionHint(item.primary.title, keys: "↩", prominent: true) { item.primary.run() }
                if let secondary = item.secondaries.first {
                    actionHint(secondary.title, keys: "⌘↩", prominent: false) { secondary.run() }
                }
            }
            actionHint(isSearching ? "Clear" : "Close", keys: "esc", prominent: false) {
                if isSearching { query = "" } else { close() }
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: AOMSize.rowStandard + AOMSpace.x1)
        .background(AOMColor.track)
    }

    private func actionHint(_ title: String, keys: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                Text(title)
                    .font(AOMFont.caption.weight(prominent ? .semibold : .regular))
                    .foregroundStyle(prominent ? AOMColor.text : AOMColor.textSecondary)
                AOMKeycap(text: keys)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(keys)")
    }
}

private extension View {
    /// Right-click surface for secondary actions beyond the first, which
    /// already owns the ⌘↩ hint in the action bar. No menu when there are none.
    @ViewBuilder
    func paletteExtraActionsMenu(_ actions: [QuickCommandPalette.PaletteAction]) -> some View {
        if actions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title) { action.run() }
                }
            }
        }
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
