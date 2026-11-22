import AppKit
import SwiftUI

// AOM 7.2: the launcher's new screens and keys.
//
// Codex's 7.2 patch (2026-11-21, ~/Documents/Codex/2026-11-21/new-chat-2)
// opened Homebrew, Network Info, VPN, Spotlight and the folder-rule preview
// inside the launcher by embedding their System Tools sheets: segmented
// pickers, Back buttons and lists the keyboard couldn't reach (its own UI
// check failed on Esc, Services and Network Info). Here each is a screen of
// launcher rows — ↑↓, ↩, ⌘K, esc, the same footer — and the Oracle report
// 05 (DeepSeek, 2026-11-21) adds emoji, recent searches, clipboard filters,
// ⌘1…⌘9, row density, command hotkeys, snippets, script commands, Send To,
// calendar and contacts, and file browsing. What was adopted or not and why:
// docs/design-7.2-launcher.md.

extension QuickCommandPalette {
    // MARK: Keys

    /// The launcher's own keys (PaletteNavigationKeys); true when used.
    func handleKey(_ event: NSEvent, items: [PaletteItem], selected: PaletteItem?) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .command, .control, .option, .function])
        // 7.11: ⌘[ goes back a screen even though the search field has the
        // cursor — the Back gesture (and mouse button) sends ⌘[ (user report).
        if event.keyCode == 33, mods == .command, navigation.current != .hotkeyFinder, navigation.depth > 0 {
            if !event.isARepeat { if showsActions { showsActions = false } else { pop() } }
            return true
        }
        // 7.3: Find a Shortcut — any key combination is looked up, nothing is set.
        if navigation.current == .hotkeyFinder {
            if event.keyCode == 53, mods.isEmpty { if !event.isARepeat { pop() }; return true }
            if !event.isARepeat, [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(event.keyCode) == false {
                PaletteHotkeyFinder.shared.shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: mods)
                sourcesChanged()
            }
            return true
        }
        // Recording a hotkey: the next key is the hotkey, whatever it is.
        if case .hotkey(let itemID, let title) = navigation.current {
            if event.keyCode == 53, mods.isEmpty { if !event.isARepeat { pop() }; return true }
            if !event.isARepeat { recordHotkey(KeyboardShortcut(keyCode: event.keyCode, modifiers: mods), itemID: itemID, title: title) }
            return true
        }
        if event.keyCode == 53, mods.isEmpty, !navigation.isRoot || showsActions {
            if !event.isARepeat { if showsActions { showsActions = false } else { pop() } }
            return true
        }
        if event.keyCode == 48, isFieldFocused, !showsActions, mods.isEmpty || mods == .shift {
            guard !event.isARepeat else { return true }
            let backwards = mods == .shift
            if navigation.isRoot { guard !backwards else { return false }; quickAsk(); return true }
            if navigation.current == .ai { guard !backwards else { return false }; nextModel(); return true }
            if navigation.current == .clipboard { cycleClipboardFilter(backwards: backwards); return true }
            if case .tool(.brew(let tab, _))? = navigation.current { cycleBrewTab(from: tab, backwards: backwards); return true }
            return false
        }
        // 7.3: ⌘⇧M opens Records for the Next Question (there, it adds the
        // last question's records); ⌘⇧0 clears them.
        if navigation.current == .ai || navigation.current == .aiRecords, mods == [.command, .shift], [46, 29].contains(event.keyCode) {
            guard !event.isARepeat else { return true }
            if event.keyCode == 29 { ai.clearPendingScope(); screens.show("Records cleared") }
            else if navigation.current == .ai { push(.aiRecords) }
            else { ai.reuseLastScope(); screens.show("Records: \(ai.pendingScope.summary)") }
            return true
        }
        // ⌥↩: Send To (LaunchBar's Instant Send).
        if [36, 76].contains(event.keyCode), mods == .option, !showsActions, let selected, selected.sendText != nil {
            if !event.isARepeat, let payload = sendPayload(for: selected) { push(.sendTo(payload)) }
            return true
        }
        // ⌘- and ⌘=: row density.
        if [27, 24].contains(event.keyCode), mods == .command || mods == [.command, .shift] {
            if !event.isARepeat {
                AOMLauncherDensity.step(event.keyCode == 24 ? 1 : -1)
                screens.show("Rows: \(AOMLauncherDensity.current.title)")
                generation &+= 1
            }
            return true
        }
        // ⌘1…⌘9: the row with that number, at once.
        if mods == .command, let digit = Self.quickRunDigit(event.keyCode), quickRunAllowed, !showsActions {
            guard !event.isARepeat, items.indices.contains(digit - 1) else { return true }
            let item = items[digit - 1]
            showsQuickRunHints = false
            selectedID = item.id
            perform(item.primary, of: item)
            return true
        }
        return false
    }

    /// Pure: 1…9 for the number row's key codes.
    static func quickRunDigit(_ keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    var quickRunAllowed: Bool {
        guard !showsActions else { return false }
        return navigation.current.map(\.allowsQuickRun) ?? true
    }

    /// ⌘ held for 0.35 s shows the ⌘1…⌘9 hints; any other key or release hides them.
    func commandFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        commandDownTicket &+= 1
        let ticket = commandDownTicket
        let onlyCommand = flags.intersection([.command, .option, .control, .shift]) == .command
        guard onlyCommand, quickRunAllowed else {
            if showsQuickRunHints { showsQuickRunHints = false }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if commandDownTicket == ticket { showsQuickRunHints = true }
        }
    }

    // MARK: Actions every row may add

    /// The Actions panel (⌘K): the row's own actions, then Send To… and the hotkey.
    func panelActions(_ item: PaletteItem) -> [PaletteAction] {
        var actions = item.actions
        let inSendTo: Bool = { if case .sendTo? = navigation.current { return true }; return false }()
        if !inSendTo, let payload = sendPayload(for: item) {
            actions.append(PaletteAction(title: "Send To…", symbol: "paperplane", effect: .push(.sendTo(payload))) {})
        }
        if item.hotkeyable, navigation.isRoot {
            if let binding = hotkeys.binding(for: item.id) {
                actions.append(PaletteAction(title: "Change Hotkey (\(binding.display))…", symbol: "keyboard",
                                             effect: .push(.hotkey(itemID: item.id, title: binding.title))) {})
                actions.append(PaletteAction(title: "Remove Hotkey", symbol: "keyboard.badge.ellipsis", effect: .stay) {
                    hotkeys.remove(item.id)
                    screens.show("Hotkey for “\(binding.title)” removed")
                })
            } else {
                actions.append(PaletteAction(title: "Set Hotkey…", symbol: "keyboard",
                                             effect: .push(.hotkey(itemID: item.id, title: item.title))) {})
            }
        }
        return actions
    }

    func sendPayload(for item: PaletteItem) -> PaletteSendPayload? {
        guard let text = item.sendText, !text.isEmpty else { return nil }
        let entry: UUID? = {
            for prefix in ["cliphistory.", "clipboard."] where item.id.hasPrefix(prefix) {
                return UUID(uuidString: String(item.id.dropFirst(prefix.count)))
            }
            return nil
        }()
        return PaletteSendPayload(text: text, title: item.title, clipboardEntry: entry)
    }

    /// Root rows that may get a hotkey: commands, screens, apps, Settings
    /// pages, quicklinks, snippets and scripts (not files, menus or text).
    static func canHaveHotkey(_ item: PaletteItem) -> Bool {
        guard item.placement == .ranked, !item.isDimmed else { return false }
        switch item.section {
        case .commands, .navigation, .applications, .quicklinks, .snippets, .scripts: return !item.id.hasPrefix("menu.")
        default: return false
        }
    }

    func withHotkey(_ item: PaletteItem) -> PaletteItem {
        guard Self.canHaveHotkey(item) else { return item }
        var item = item
        item.hotkeyable = true
        if item.shortcut == nil, let binding = hotkeys.binding(for: item.id) { item.shortcut = binding.display }
        return item
    }

    func recordHotkey(_ shortcut: KeyboardShortcut, itemID: String, title: String) {
        hotkeys.resume()
        do {
            let binding = try hotkeys.set(shortcut, for: itemID, title: title, triggers: appState.currentPreset.triggers)
            pop()
            screens.show("“\(title)” · \(binding.display) from any app")
        } catch {
            hotkeys.suspend()
            screens.show("\(shortcut.displayString): \(error.localizedDescription)")
        }
    }

    /// A launcher hotkey's row: the rows that exist without a search first,
    /// then those its title finds. A row that closes the launcher runs
    /// without the panel ever showing; a screen shows it.
    func runHotkeyItem(_ binding: PaletteHotkey) {
        DispatchQueue.main.async {
            if let item = results.first(where: { $0.id == binding.itemID }) { runFromHotkey(item); return }
            query = binding.title
            DispatchQueue.main.async {
                if let item = results.first(where: { $0.id == binding.itemID }) {
                    runFromHotkey(item)
                } else {
                    AOMLauncherController.shared.reveal()
                    screens.show("“\(binding.title)” isn't available right now")
                }
            }
        }
    }

    private func runFromHotkey(_ item: PaletteItem) {
        query = ""
        if item.primary.effect != .close { AOMLauncherController.shared.reveal() }
        perform(item.primary, of: item)
    }

    // MARK: Lifetime

    func enter72(_ route: PaletteRoute) {
        switch route {
        case .tool(.brew(let tab, let term)):
            brew.launcherConfirm = { title, message, button, destructive, proceed in
                confirm(PaletteConfirmation(title: title, message: message, confirmTitle: button,
                                            symbol: destructive ? "trash.fill" : "mug.fill", destructive: destructive, run: proceed))
            }
            if tab == .search, !term.isEmpty { DispatchQueue.main.async { query = term } }
        case .tool(.files(let term)):
            if !term.isEmpty { DispatchQueue.main.async { query = term } }
        case .tool(.network): data.loadNetwork()
        case .tool(.vpn):
            vpn.refreshForTiles()
            vpn.startLive()
        case .folder(let url): data.browse(url)
        case .rulePreview(let id): data.previewRule(id)
        case .scripts: data.loadScripts()
        case .schedule: schedule.load()
        case .contacts: contacts.load()
        case .hotkey: hotkeys.suspend()
        default: break
        }
    }

    func leave72(_ route: PaletteRoute) {
        switch route {
        // 7.3: going back from the form leaves the typed text as it was.
        case .snippetArguments: PaletteSnippetForm.shared.cancel()
        case .tool(.brew):
            let stillBrew = navigation.frames.contains { if case .tool(.brew) = $0.route { return true }; return false }
            if !stillBrew { brew.launcherConfirm = nil }
        case .tool(.vpn): vpn.stopLive()
        case .tool(.files): data.resetFiles()
        case .hotkey: hotkeys.resume()
        default: break
        }
    }

    func end72() {
        data.end()
        hotkeys.resume()
        brew.launcherConfirm = nil
        vpn.stopLive()
    }

    func queryChanged72() {
        switch navigation.current {
        case .tool(.files)?:
            data.searchFiles(query)
        case .tool(.brew(.search, _))?:
            let term = LauncherTool.packageQuery(trimmed)
            // Opening the screen with a term already searches for it.
            guard term != brew.searchText else { return }
            brew.searchText = term
            guard Homebrew.isValidSearchText(term) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard brew.searchText == term, isBrewSearchScreen else { return }
                brew.whenIdle { if brew.searchText == term { brew.search() } }
            }
        case nil:
            // People and events join the root search once access was given.
            if isSearching, contacts.people == nil, contacts.access == .granted { DispatchQueue.main.async { contacts.load() } }
        default:
            break
        }
    }

    /// Read when the launcher opens: cheap, and only what access allows.
    func appear72() {
        data.loadScripts()
        if schedule.access == .granted, schedule.loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { schedule.load() }
    }

    var isBrewScreen: Bool {
        if case .tool(.brew)? = navigation.current { return true }
        return false
    }

    var isBrewSearchScreen: Bool {
        if case .tool(.brew(.search, _))? = navigation.current { return true }
        return false
    }

    // MARK: Text into the app in front

    /// Types `text` into the app that was in front (the launcher has gone
    /// by then); without Accessibility, copies it and says so. Long text is
    /// pasted instead of typed.
    func insertIntoFrontApp(_ text: String, announce: String) {
        let target = host == .launcher ? AOMLauncherController.shared.frontApp : PaletteSession.previousApp()
        guard AXIsProcessTrusted(), let target else {
            copyToClipboard(text, announce: announce)
            return
        }
        if text.count > 600 {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            Self.paste(into: target, triesLeft: 10) { pasted in
                if !pasted { GestureHUD.shared.show(title: "Copied", detail: "Press ⌘V in \(target.localizedName ?? "the app").") }
            }
        } else {
            ActionExecutor.typeReplacementText(text) { typed in
                if !typed { DispatchQueue.main.async { copyToClipboard(text, announce: "Couldn't type it — copied instead") } }
            }
        }
    }

    // MARK: Recent searches (report 05 §3-D)

    func recentQueryItems() -> [PaletteItem] {
        guard !isSearching, navigation.isRoot else { return [] }
        return PaletteRecentQueryStore.shared.value.recent(limit: 4).map { entry in
            PaletteItem(id: "recent.\(entry.text)", title: entry.text, subtitle: AOMRelativeTime.string(entry.date),
                        icon: "clock.arrow.circlepath", section: .recent,
                        primary: PaletteAction(title: "Search Again", symbol: "magnifyingglass", effect: .stay) {
                            query = entry.text
                            isFieldFocused = true
                        },
                        secondaries: [
                            PaletteAction(title: "Remove from Recent Searches", symbol: "xmark", effect: .stay) {
                                PaletteRecentQueryStore.shared.remove(entry.text)
                            },
                            PaletteAction(title: "Clear Recent Searches", symbol: "trash", effect: .stay) {
                                PaletteRecentQueryStore.shared.clear()
                            },
                        ])
        }
    }

    // MARK: Emoji (report 05 §3-A)

    /// ":fire" in the root search: the matches first, pinned.
    func emojiRootItems() -> [PaletteItem] {
        guard isSearching, trimmed.hasPrefix(":"), PaletteEmojiIndex.needle(trimmed).count >= 2 else { return [] }
        return PaletteEmojiIndex.matches(trimmed, in: PaletteEmojiIndex.all(), limit: 6).map { emoji in
            var row = emojiRow(emoji, group: nil)
            row.placement = .pinned
            return row
        }
    }

    func emojiItems() -> [PaletteItem] {
        let all = PaletteEmojiIndex.all()
        guard isSearching else {
            let recent = PaletteRecentEmoji.all
            return PaletteEmojiIndex.browsing(recent: recent, in: all).map { emoji in
                emojiRow(emoji, group: recent.contains(emoji.glyph) ? "Recently used" : "Frequently used")
            }
        }
        return PaletteEmojiIndex.matches(trimmed, in: all, limit: 80).map { emojiRow($0, group: nil) }
    }

    func emojiRow(_ emoji: PaletteEmoji, group: String?) -> PaletteItem {
        var row = screenRow("emoji.\(emoji.glyph)", emoji.displayName,
                            [emoji.otherName, emoji.codePoints].compactMap { $0 }.joined(separator: " · "), icon: "face.smiling", group: group,
                            section: .emoji,
                            primary: PaletteAction(title: "Type Emoji", symbol: "keyboard") {
                                PaletteRecentEmoji.record(emoji.glyph)
                                insertIntoFrontApp(emoji.glyph, announce: emoji.glyph)
                            },
                            secondaries: [
                                PaletteAction(title: "Copy Emoji", symbol: "doc.on.doc") {
                                    PaletteRecentEmoji.record(emoji.glyph)
                                    copyToClipboard(emoji.glyph, announce: emoji.glyph)
                                },
                                PaletteAction(title: "Copy Code Point", symbol: "number") { copyToClipboard(emoji.codePoints, announce: emoji.codePoints) },
                                PaletteAction(title: "Copy Name", symbol: "textformat") { copyToClipboard(emoji.name, announce: emoji.name) },
                            ])
        row.glyph = emoji.glyph
        row.sendText = emoji.glyph
        return row
    }

    // MARK: Clipboard filters (report 05 §3-E)

    static let clipboardFilters: [ClipboardEntry.Kind?] = [nil] + ClipboardEntry.Kind.allCases.map { $0 }

    func cycleClipboardFilter(backwards: Bool) {
        let filters = Self.clipboardFilters
        let index = filters.firstIndex(of: clipboardFilter) ?? 0
        clipboardFilter = filters[(index + (backwards ? filters.count - 1 : 1)) % filters.count]
        selectedID = nil
        generation &+= 1
    }

    static func filterTitle(_ kind: ClipboardEntry.Kind?) -> String {
        switch kind {
        case nil: return "All"
        case .text?: return "Text"
        case .link?: return "Links"
        case .image?: return "Images"
        case .file?: return "Files"
        case .color?: return "Colors"
        }
    }

    var clipboardFilterBar: some View {
        HStack(spacing: AOMSpace.x1 + 2) {
            ForEach(Array(Self.clipboardFilters.enumerated()), id: \.offset) { _, kind in
                let on = kind == clipboardFilter
                Button {
                    clipboardFilter = kind
                    selectedID = nil
                    generation &+= 1
                    isFieldFocused = true
                } label: {
                    HStack(spacing: 4) {
                        if let kind { Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold)) }
                        Text(Self.filterTitle(kind)).font(.system(size: 12, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? AOMColor.accent : AOMCraftColor.inkSecondary)
                    .padding(.horizontal, AOMSpace.x2 + 2)
                    .frame(height: 24)
                    .background(on ? AOMColor.accent.opacity(contrast == .increased ? 0.22 : 0.13) : AOMCraftColor.rowHover, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(Self.filterTitle(kind))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Text("⇥ next filter").font(.system(size: 11)).foregroundStyle(AOMCraftColor.inkTertiary)
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: 36)
    }

    // MARK: Homebrew

    func toolItems(_ tool: LauncherTool) -> [PaletteItem] {
        switch tool {
        case .brew(let tab, _): return brewItems(tab)
        case .files: return data.files.map { fileRow($0, group: nil) }
        case .pasteStack: return pasteStackItems()
        case .rulePreview: return ruleListItems()
        case .vpn: return vpnItems()
        case .network: return networkItems()
        }
    }

    func cycleBrewTab(from tab: HomebrewModel.Tab, backwards: Bool) {
        let tabs = HomebrewModel.Tab.allCases
        let index = tabs.firstIndex(of: tab) ?? 0
        let next = tabs[(index + (backwards ? tabs.count - 1 : 1)) % tabs.count]
        pop()
        push(.tool(.brew(next, "")))
    }

    static func brewPage(_ package: Homebrew.Package) -> URL? {
        URL(string: "https://formulae.brew.sh/\(package.kind == .cask ? "cask" : "formula")/\(package.name)")
    }

    func packageActions(_ package: Homebrew.Package, homepage: String? = nil) -> [PaletteAction] {
        var actions: [PaletteAction] = []
        if let homepage, let url = URL(string: homepage) {
            actions.append(PaletteAction(title: "Open Homepage", symbol: "safari") { NSWorkspace.shared.open(url) })
        }
        if let page = Self.brewPage(package) {
            actions.append(PaletteAction(title: "Open on formulae.brew.sh", symbol: "mug") { NSWorkspace.shared.open(page) })
        }
        actions.append(PaletteAction(title: "Copy Name", symbol: "doc.on.doc", effect: .stay) {
            copyToClipboard(package.name, announce: package.name); screens.show("Copied \(package.name)")
        })
        let install = "brew install \(package.kind == .cask ? "--cask " : "")\(package.name)"
        actions.append(PaletteAction(title: "Copy Install Command", symbol: "terminal", effect: .stay) {
            copyToClipboard(install, announce: install); screens.show("Copied \(install)")
        })
        return actions
    }

    func brewItems(_ tab: HomebrewModel.Tab) -> [PaletteItem] {
        guard brew.brew != nil else {
            return [screenRow("brew.missing", "Install Homebrew…", "Opens brew.sh · AOM looks in /opt/homebrew and /usr/local",
                              icon: "mug", group: nil,
                              primary: PaletteAction(title: "Open brew.sh") { if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) } })]
        }
        var items: [PaletteItem] = []
        if let job = brew.job {
            items.append(screenRow("brew.cancel", "Cancel \(job.command.title)", brew.log.last?.text ?? "brew is running…",
                                   icon: "stop.circle", group: "Running",
                                   primary: PaletteAction(title: "Cancel", effect: .stay, isDestructive: true) { brew.cancel() }))
        }
        switch tab {
        case .outdated:
            if let outdated = brew.outdated {
                let upgradable = outdated.filter { !$0.pinned }
                let group = outdated.isEmpty ? "Everything is up to date" : "Updates · \(outdated.count)"
                if upgradable.count > 1 {
                    items.append(screenRow("brew.upgradeAll", "Upgrade All (\(upgradable.count))",
                                           upgradable.prefix(4).map(\.name).joined(separator: ", ") + (upgradable.count > 4 ? " …" : ""),
                                           icon: "arrow.up.circle.fill", group: group,
                                           primary: PaletteAction(title: "Upgrade All…", effect: .stay) { brew.requestUpgradeAll() }))
                }
                for package in outdated {
                    let primary = package.pinned
                        ? PaletteAction(title: "Pinned", effect: .stay) { screens.show("\(package.name) is pinned — brew unpin \(package.name) to upgrade it") }
                        : PaletteAction(title: "Upgrade", symbol: "arrow.up.circle", effect: .stay) {
                            brew.upgrade(package); screens.show("Upgrading \(package.name)…")
                        }
                    var row = screenRow("brew.outdated.\(package.id)", package.name, package.change,
                                        icon: package.kind == .cask ? "macwindow" : "shippingbox", group: group,
                                        primary: primary, secondaries: packageActions(package.package),
                                        accessory: package.pinned ? "Pinned" : package.kind.title)
                    row.sendText = package.name
                    items.append(row)
                }
            }
        case .installed:
            if let installed = brew.installed {
                let outdatedByID = Dictionary((brew.outdated ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for package in installed {
                    var secondaries: [PaletteAction] = []
                    if let update = outdatedByID[package.id], !update.pinned {
                        secondaries.append(PaletteAction(title: "Upgrade to \(update.currentVersion)", symbol: "arrow.up.circle", effect: .stay) {
                            brew.upgrade(update); screens.show("Upgrading \(package.name)…")
                        })
                    }
                    secondaries += packageActions(package.package, homepage: package.homepage)
                    secondaries.append(PaletteAction(title: "Uninstall…", symbol: "trash", effect: .stay, isDestructive: true) {
                        brew.uninstall(package.package)
                    })
                    let group = package.kind == .cask ? "Casks" : (package.onRequest ? "Formulae" : "Dependencies")
                    var row = screenRow("brew.installed.\(package.id)", package.name,
                                        [package.version, package.summary].filter { !$0.isEmpty }.joined(separator: " · "),
                                        icon: package.kind == .cask ? "macwindow" : "shippingbox", group: group,
                                        primary: PaletteAction(title: "Copy Name", symbol: "doc.on.doc", effect: .stay) {
                                            copyToClipboard(package.name, announce: package.name); screens.show("Copied \(package.name)")
                                        },
                                        secondaries: secondaries,
                                        accessory: package.pinned ? "Pinned" : package.outdated ? "Update" : nil)
                    row.keywords = package.summary
                    row.sendText = package.name
                    items.append(row)
                }
                let order = ["Running", "Formulae", "Casks", "Dependencies"]
                items = items.enumerated().sorted {
                    ((order.firstIndex(of: $0.element.group ?? "") ?? 9), $0.offset) < ((order.firstIndex(of: $1.element.group ?? "") ?? 9), $1.offset)
                }.map(\.element)
            }
        case .services:
            for service in brew.services ?? [] {
                let running = service.status.isRunning
                var row = screenRow("brew.service.\(service.name)", service.name,
                                    [service.status.title, service.user.map { "as \($0)" }].compactMap { $0 }.joined(separator: " · "),
                                    icon: running ? "play.circle.fill" : "pause.circle", group: "Services",
                                    primary: PaletteAction(title: running ? "Stop" : "Start", symbol: running ? "stop.circle" : "play.circle",
                                                           effect: .stay) {
                                        brew.service(running ? .stop : .start, service)
                                        screens.show("\(running ? "Stopping" : "Starting") \(service.name)…")
                                    },
                                    secondaries: [PaletteAction(title: "Restart", symbol: "arrow.clockwise", effect: .stay) {
                                        brew.service(.restart, service); screens.show("Restarting \(service.name)…")
                                    }],
                                    accessory: service.status.title)
                row.sendText = service.name
                items.append(row)
            }
        case .search:
            let term = LauncherTool.packageQuery(trimmed)
            if let found = brew.searchResults, brew.searchText == term, !term.isEmpty {
                for package in found {
                    let installed = brew.isInstalled(package)
                    let primary = installed
                        ? PaletteAction(title: "Uninstall…", symbol: "trash", effect: .stay, isDestructive: true) { brew.uninstall(package) }
                        : PaletteAction(title: "Install…", symbol: "arrow.down.circle", effect: .stay) { brew.install(package) }
                    var row = screenRow("brew.search.\(package.id)", package.name, package.kind == .cask ? "App (cask)" : "Formula",
                                        icon: package.kind == .cask ? "macwindow" : "shippingbox", group: "Results · \(found.count)",
                                        primary: primary, secondaries: packageActions(package),
                                        accessory: installed ? "Installed" : nil)
                    row.sendText = package.name
                    items.append(row)
                }
            }
        }
        items += brewMoreRows(tab)
        return items
    }

    private func brewMoreRows(_ tab: HomebrewModel.Tab) -> [PaletteItem] {
        var rows: [PaletteItem] = []
        for other in HomebrewModel.Tab.allCases where other != tab {
            let tool = LauncherTool.brew(other, "")
            rows.append(screenRow("brew.go.\(other.rawValue)", tool.title, "⇥ switches lists", icon: tool.symbol, group: "Homebrew",
                                  primary: PaletteAction(title: "Show", effect: .stay) { cycleTo(other) }))
        }
        rows.append(screenRow("brew.update", "Update Homebrew", "brew update, then check for updates", icon: "arrow.triangle.2.circlepath",
                              group: "Homebrew", primary: PaletteAction(title: "Update", effect: .stay) { brew.update() }))
        rows.append(screenRow("brew.cleanup", "Clean Up…", "Shows how much brew cleanup frees, then asks", icon: "sparkles",
                              group: "Homebrew", primary: PaletteAction(title: "Clean Up…", effect: .stay) { brew.cleanUp() }))
        rows.append(screenRow("brew.doctor", "Run brew doctor", "Checks the installation for problems", icon: "stethoscope",
                              group: "Homebrew", primary: PaletteAction(title: "Run", effect: .stay) { brew.doctor() }))
        return rows
    }

    private func cycleTo(_ tab: HomebrewModel.Tab) {
        pop()
        push(.tool(.brew(tab, "")))
    }

    func brewHeader(_ tab: HomebrewModel.Tab) -> RouteHeader? {
        let tint = Color(red: 0.85, green: 0.6, blue: 0.2)
        guard brew.brew != nil else {
            return RouteHeader(symbol: "mug", tint: tint, title: "Homebrew Isn't Installed",
                               detail: "AOM looks for brew at /opt/homebrew/bin/brew and /usr/local/bin/brew.")
        }
        if let job = brew.job {
            return RouteHeader(symbol: "mug.fill", tint: tint, title: "\(job.command.title)…",
                               detail: brew.log.last?.text ?? "brew is running. Cancel stops it.", busy: true)
        }
        switch tab {
        case .outdated where brew.outdated == nil:
            return RouteHeader(symbol: "mug", tint: tint, title: "Checking for Updates…", detail: "brew outdated, without updating Homebrew first.", busy: true)
        case .installed where brew.installed == nil:
            return RouteHeader(symbol: "mug", tint: tint, title: "Reading Installed Packages…", detail: "brew info --installed", busy: true)
        case .services where brew.services == nil:
            return RouteHeader(symbol: "mug", tint: tint, title: "Reading Services…", detail: "brew services list", busy: true)
        case .services where brew.services?.isEmpty == true:
            return RouteHeader(symbol: "mug", tint: tint, title: "No Homebrew Services", detail: "Formulae that run in the background (databases, servers) are listed here.")
        case .search where trimmed.isEmpty:
            return RouteHeader(symbol: "magnifyingglass", tint: tint, title: "Search Homebrew",
                               detail: "Type a formula or app name; results come from brew search, formulae and casks.")
        case .search where brew.searchResults?.isEmpty == true && brew.searchText == LauncherTool.packageQuery(trimmed):
            return RouteHeader(symbol: "magnifyingglass", tint: tint, title: "Nothing Called “\(trimmed)”",
                               detail: "brew search found no formula or cask with that name.")
        case .search where brew.searchText == LauncherTool.packageQuery(trimmed) && brew.searchResults == nil && Homebrew.isValidSearchText(brew.searchText):
            return RouteHeader(symbol: "magnifyingglass", tint: tint, title: "Searching…", detail: "brew search \(brew.searchText)", busy: true)
        default:
            return nil
        }
    }

    // MARK: Network, VPN

    func networkItems() -> [PaletteItem] {
        guard let net = data.network else { return [] }
        var items: [PaletteItem] = []
        func value(_ id: String, _ title: String, _ subtitle: String, _ icon: String, group: String, copy: String?) {
            var row = screenRow(id, title, subtitle, icon: icon, group: group,
                                primary: PaletteAction(title: "Copy", symbol: "doc.on.doc", effect: .stay) {
                                    if let copy { copyToClipboard(copy, announce: copy); screens.show("Copied \(copy)") }
                                }, dimmed: copy == nil)
            row.sendText = copy
            items.append(row)
        }
        value("network.local", net.local ?? "No IPv4 address", "Local address\(net.interface.map { " · \($0)" } ?? "")", "laptopcomputer",
              group: "This Mac", copy: net.local)
        value("network.public", net.publicIP ?? (net.checkingPublic ? "Checking…" : net.publicError ?? "Not checked"),
              "Public address · api64.ipify.org", "globe", group: "This Mac", copy: net.publicIP)
        for (index, line) in net.wifi.enumerated() {
            value("network.wifi.\(index)", line, "Wi-Fi", "wifi", group: "Wi-Fi", copy: line)
        }
        for server in net.dns {
            value("network.dns.\(server)", server, "DNS server", "server.rack", group: "DNS servers", copy: server)
        }
        if net.dns.count > 1 {
            value("network.dns.all", "Copy All DNS Servers", net.dns.joined(separator: ", "), "doc.on.doc", group: "DNS servers",
                  copy: net.dns.joined(separator: "\n"))
        }
        items.append(screenRow("network.refresh", "Refresh", "Read the addresses again", icon: "arrow.clockwise", group: "More",
                               primary: PaletteAction(title: "Refresh", effect: .stay) { data.loadNetwork() }))
        items.append(screenRow("network.settings", "Network Settings…", "System Settings › Network", icon: "gearshape", group: "More",
                               primary: PaletteAction(title: "Open") {
                                   if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
                               }))
        return items
    }

    func vpnItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        for service in vpn.services {
            let busy = vpn.busy.contains(service.id)
            let up = service.state.isUp
            items.append(screenRow("vpn.\(service.id)", service.name, "\(service.kindTitle) · \(busy ? "Working…" : service.state.title)",
                                   icon: up ? "lock.shield.fill" : "lock.shield", group: "VPN",
                                   primary: PaletteAction(title: up ? "Disconnect" : "Connect", symbol: up ? "xmark.shield" : "checkmark.shield",
                                                          effect: .stay) { vpn.toggle(service) },
                                   accessory: up ? "Connected" : nil, dimmed: busy || !service.enabled))
        }
        if vpn.hasTailscale {
            let status = vpn.tailscale
            let running = status?.backend == .running
            let detail = [status?.backend.title, status?.ipv4, status?.exitNode.map { "exit node \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            var row = screenRow("vpn.tailscale", "Tailscale", detail.isEmpty ? (vpn.tailscaleMessage ?? "Reading…") : detail,
                                icon: running ? "network.badge.shield.half.filled" : "network", group: "Tailscale",
                                primary: PaletteAction(title: running ? "Disconnect" : "Connect", effect: .stay) { vpn.setTailscale(up: !running) },
                                secondaries: [PaletteAction(title: "Open Tailscale", symbol: "arrow.up.forward.app") { vpn.openTailscaleApp() }],
                                accessory: running ? "Connected" : nil, dimmed: vpn.busy.contains("tailscale"))
            row.sendText = status?.ipv4
            items.append(row)
        }
        items.append(screenRow("vpn.settings", "VPN Settings…", "System Settings › VPN", icon: "gearshape", group: "More",
                               primary: PaletteAction(title: "Open") { vpn.openVPNSettings() }))
        if vpn.openVPNURL != nil {
            items.append(screenRow("vpn.openvpn", "OpenVPN Connect", "Its profiles stay in its own app", icon: "arrow.up.forward.app",
                                   group: "More", primary: PaletteAction(title: "Open") { vpn.openOpenVPN() }))
        }
        return items
    }

    // MARK: Files and folders (report 05 §3-I)

    func fileRow(_ hit: PaletteFileHit, group: String?) -> PaletteItem {
        let parent = hit.url.deletingLastPathComponent()
        let folder = (parent.path as NSString).abbreviatingWithTildeInPath
        let primary = hit.isFolder
            ? PaletteAction(title: "Browse Folder", symbol: "folder", effect: .push(.folder(hit.url))) {}
            : PaletteAction(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(hit.url) }
        var secondaries = [PaletteAction(title: hit.isFolder ? "Open in Finder" : "Show in Finder", symbol: "folder") {
            if hit.isFolder { NSWorkspace.shared.open(hit.url) } else { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
        }]
        secondaries.append(PaletteAction(title: "Copy Path", symbol: "doc.on.doc", effect: .stay) {
            copyToClipboard(hit.url.path, announce: hit.url.path); screens.show("Copied the path")
        })
        if !hit.isFolder {
            secondaries.append(PaletteAction(title: "Browse Enclosing Folder", symbol: "folder.badge.questionmark", effect: .push(.folder(parent))) {})
        }
        // 7.5 (Codex F03, F07, F08): the same windows as the Files page's Tools menu.
        if AOMModuleSwitches.shared.isOn(.files) {
            switch (hit.isFolder, hit.url.pathExtension.lowercased()) {
            case (false, "zip"):
                secondaries.insert(PaletteAction(title: "Extract Files…", symbol: "doc.zipper") { AOMFileToolsLauncher.openZip(hit.url) }, at: 0)
            case (false, "pdf"):
                secondaries.insert(PaletteAction(title: "Compare With Another PDF…", symbol: "rectangle.split.2x1") {
                    AOMFileToolsLauncher.comparePDFs([hit.url])
                }, at: 0)
            case (true, _):
                secondaries.append(PaletteAction(title: "Compare With Another Folder…", symbol: "folder.badge.questionmark") {
                    AOMFileToolsLauncher.compareFolders([hit.url])
                })
            default: break
            }
        }
        var row = screenRow("file.\(hit.url.path)", hit.name, folder, icon: hit.isFolder ? "folder" : "doc", group: group,
                            section: .files, primary: primary, secondaries: secondaries,
                            accessory: hit.date.map { AOMRelativeTime.string($0) }, image: session.icon(forPath: hit.url.path))
        row.sendText = hit.url.path
        return row
    }

    func folderItems(_ url: URL) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let parent = url.deletingLastPathComponent()
        if url.path != "/" {
            items.append(screenRow("folder.up", "Enclosing Folder", (parent.path as NSString).abbreviatingWithTildeInPath,
                                   icon: "arrow.turn.left.up", group: nil,
                                   primary: PaletteAction(title: "Go Up", effect: .stay) { pop(); push(.folder(parent)) }))
        }
        guard let folder = data.folder, folder.url == url else { return items }
        if folder.loading {
            items.append(screenRow("folder.loading", "Reading \(url.lastPathComponent)…", "Large and network folders take a moment",
                                   icon: "hourglass", group: nil, primary: PaletteAction(title: "Wait", effect: .stay) {}))
            return items
        }
        if let error = folder.error {
            items.append(screenRow("folder.error", "Couldn't Read This Folder", error, icon: "exclamationmark.triangle", group: nil,
                                   primary: PaletteAction(title: "Try Again", effect: .stay) { data.browse(url) }))
            return items
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 7.3: typing searches every item; the list without a search draws a page at a time.
        let candidates = search.isEmpty ? Array(folder.items.prefix(folder.shown))
            : folder.items.count > 2_000 ? PaletteLauncherData.folderMatches(folder.items, query: search) : folder.items
        for hit in candidates.prefix(search.isEmpty ? .max : 2_000) {
            items.append(fileRow(hit, group: hit.isFolder ? "Folders" : "Files"))
        }
        // 7.3: this folder (and the filter typed) as a launcher favorite.
        var favorite = screenRow("folder.favorite", search.isEmpty ? "Save Folder as Favorite" : "Save Folder and “\(search)” as Favorite",
                                 "Opens again from the launcher's search", icon: "star", group: "Folder",
                                 primary: PaletteAction(title: "Save Favorite", symbol: "star", effect: .stay) {
                                     if let dropped = PaletteFolderFavorites.shared.add(url, query: search) {
                                         screens.show("Saved — the oldest favorite, “\(dropped.name)”, made room (30 at most)")
                                     } else {
                                         screens.show("Saved — search for “\(url.lastPathComponent)” to open it")
                                     }
                                 })
        favorite.placement = .fallback
        items.append(favorite)
        if search.isEmpty, folder.items.count > folder.shown {
            var more = screenRow("folder.more", "Show \(min(PaletteLauncherData.folderPage, folder.items.count - folder.shown)) More",
                                 "\(folder.items.count - folder.shown) of \(folder.items.count) not shown yet — typing searches all of them",
                                 icon: "ellipsis.circle", group: "\(folder.items.count) items",
                                 primary: PaletteAction(title: "Show More", effect: .stay) { data.showMoreOfFolder() })
            more.placement = .fallback
            items.append(more)
        }
        return items
    }

    // MARK: Paste Stack, folder rules

    func pasteStackItems() -> [PaletteItem] {
        let state = ClipboardPanelController.shared.state
        let byID = Dictionary(clipboardStore.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let queue = (state.stackReversed ? Array(state.stack.reversed()) : state.stack).compactMap { byID[$0] }
        var items = queue.enumerated().map { index, entry -> PaletteItem in
            var row = screenRow("stack.\(entry.id.uuidString)", entry.title, index == 0 ? "Pasted next" : "Then \(index + 1)",
                                icon: entry.kind.symbol, group: "Queued · \(queue.count)", section: .clipboard,
                                primary: PaletteAction(title: "Paste Next", symbol: "doc.on.clipboard") { ClipboardPanelController.shared.pasteNext() },
                                secondaries: [PaletteAction(title: "Remove from Stack", symbol: "minus.circle", effect: .stay) {
                                    state.stack.removeAll { $0 == entry.id }
                                }],
                                accessory: "\(index + 1)")
            row.sendText = entry.text
            return row
        }
        if !queue.isEmpty {
            items.append(screenRow("stack.reverse", state.stackReversed ? "Paste Oldest First" : "Paste Newest First",
                                   "Change the order", icon: "arrow.up.arrow.down", group: "Stack",
                                   primary: PaletteAction(title: "Change", effect: .stay) { state.stackReversed.toggle() }))
            items.append(screenRow("stack.clear", "Clear Stack", "Remove every queued item (the history keeps them)",
                                   icon: "trash", group: "Stack",
                                   primary: PaletteAction(title: "Clear", effect: .stay, isDestructive: true) { state.stack.removeAll() }))
        }
        return items
    }

    func ruleListItems() -> [PaletteItem] {
        let config = FolderRulesEngine.shared.config
        return config.rules.map { rule in
            let folder = config.folders.first { $0.id == rule.folderID }.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
            return screenRow("rules.\(rule.id.uuidString)", rule.name, folder, icon: "folder.badge.gearshape",
                             group: rule.isEnabled ? "On" : "Off",
                             primary: PaletteAction(title: "Preview", symbol: "eye", effect: .push(.rulePreview(rule.id))) {},
                             accessory: rule.isEnabled ? "On" : "Off")
        }
        .sorted { ($0.group == "On" ? 0 : 1) < ($1.group == "On" ? 0 : 1) }
    }

    func rulePreviewItems(_ id: UUID) -> [PaletteItem] {
        guard let preview = data.rulePreview, preview.ruleID == id else { return [] }
        return preview.items.map { item in
            let group: String
            switch item.state {
            case .willRun: group = "Would run now"
            case .waiting: group = "Still downloading"
            case .handled: group = "Already handled"
            case .earlierRule(let name): group = "Taken by “\(name)”"
            case .noMatch: group = "Doesn't match"
            }
            var row = screenRow("ruleitem.\(item.id)", item.info.name, item.steps.joined(separator: " → "),
                                icon: item.info.isDirectory ? "folder" : "doc", group: group, section: .files,
                                primary: PaletteAction(title: "Show in Finder", symbol: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.info.url])
                                },
                                image: session.icon(forPath: item.info.url.path))
            row.sendText = item.info.url.path
            return row
        }
    }

    // MARK: Snippets (report 05 §3-F)

    var snippets: [PaletteSnippets.Snippet] { PaletteSnippets.snippets(in: appState.currentPreset.triggers) }

    func snippetRow(_ snippet: PaletteSnippets.Snippet, group: String?, section: Section = .snippets) -> PaletteItem {
        // 7.3: a snippet with placeholders shows what it would insert now
        // (the snippet test), or what is wrong with it.
        let preview = (snippet.usesPlaceholders ? PaletteSnippets.preview(snippet) : snippet.text).replacingOccurrences(of: "\n", with: " ⏎ ")
        let fields = snippet.fields
        let primary = !fields.isEmpty
            ? PaletteAction(title: "Fill In…", symbol: "keyboard", effect: .stay) {
                PaletteSnippetForm.shared.begin(.init(snippetID: snippet.id, fields: fields))
                push(.snippetArguments(snippet.id))
            }
            : PaletteAction(title: "Type Snippet", symbol: "keyboard") {
                if snippet.usesPlaceholders { insertSnippet(snippet, arguments: [:], erase: 0, targetPID: nil) }
                else { insertIntoFrontApp(snippet.text, announce: snippet.abbreviation) }
            }
        var row = screenRow("snippet.\(snippet.id.uuidString)", snippet.name, preview, icon: "text.badge.plus", group: group,
                            section: section,
                            primary: primary,
                            secondaries: [
                                PaletteAction(title: "Copy Text", symbol: "doc.on.doc") { copyToClipboard(snippet.text, announce: snippet.abbreviation) },
                                PaletteAction(title: "Edit in Automation", symbol: "pencil") { editTrigger(snippet.id) },
                                PaletteAction(title: "Delete Snippet…", symbol: "trash", effect: .stay, isDestructive: true) { confirmDelete(snippet) },
                            ],
                            accessory: snippet.abbreviation, dimmed: false)
        row.aliases = [snippet.abbreviation]
        row.keywords = snippet.text
        row.sendText = snippet.text
        return row
    }

    /// 7.3: one row per field; ↩ takes the field's text and goes to the
    /// next, the last one inserts the snippet. 7.5 (Codex F02): a choice
    /// lists its options and an optional section Include / Leave Out, the
    /// default first; typing narrows the options.
    func snippetArgumentItems(_ id: UUID) -> [PaletteItem] {
        guard let snippet = snippets.first(where: { $0.id == id }), let request = PaletteSnippetForm.shared.request,
              request.snippetID == id, let field = request.currentField else {
            return [screenRow("snippetarg.gone", "This snippet isn't there any more", "Go back with esc", icon: "exclamationmark.triangle",
                              group: nil, primary: PaletteAction(title: "Back", effect: .stay) { pop() }, dimmed: true)]
        }
        let (number, total) = request.step
        let group = "\(snippet.abbreviation) · \(number) of \(total)"
        /// The row that answers the current field with `value`.
        func answerRow(_ key: String, _ title: String, value: String, icon: String, accessory: String? = nil) -> PaletteItem {
            var after = request
            after.answer(value)
            let isLast = after.isComplete
            let preview = PaletteSnippets.preview(snippet, arguments: after.values).replacingOccurrences(of: "\n", with: " ⏎ ")
            let action = isLast
                ? PaletteAction(title: "Insert", symbol: "keyboard") {
                    _ = PaletteSnippetForm.shared.submit(value)
                    if let done = PaletteSnippetForm.shared.finish() {
                        insertSnippet(snippet, arguments: done.values, erase: done.erase, targetPID: done.targetPID, typed: done.typed)
                    }
                }
                : PaletteAction(title: "Next", symbol: "arrow.right", effect: .stay) {
                    _ = PaletteSnippetForm.shared.submit(value)
                    query = ""
                    sourcesChanged()
                }
            var row = screenRow("snippetarg.\(request.index).\(key)", title, preview, icon: icon, group: group, primary: action)
            row.accessory = accessory.map { "\($0) · ↩ \(isLast ? "Insert" : "Next")" } ?? (isLast ? "↩ Insert" : "↩ Next")
            return row
        }
        switch field.kind {
        case .text:
            let value = query
            return [answerRow("text", "\(field.name): \(value.isEmpty ? "…" : value)", value: value, icon: "character.cursor.ibeam")]
        case .choice(let options, let defaultIndex):
            let ordered = [defaultIndex] + options.indices.filter { $0 != defaultIndex }
            let typed = query.trimmingCharacters(in: .whitespaces)
            let shown = ordered.filter { typed.isEmpty || options[$0].localizedCaseInsensitiveContains(typed) }
            guard !shown.isEmpty else {
                return [screenRow("snippetarg.none", "No option matches “\(typed)”", "\(field.name) has \(options.map { $0.isEmpty ? "(nothing)" : $0 }.joined(separator: ", "))",
                                  icon: "list.bullet", group: group, primary: PaletteAction(title: "Clear", effect: .stay) { query = ""; sourcesChanged() }, dimmed: true)]
            }
            return shown.map { index in
                answerRow("option\(index)", "\(field.name): \(options[index].isEmpty ? "(nothing)" : options[index])", value: options[index],
                          icon: "list.bullet", accessory: index == defaultIndex ? "Default" : nil)
            }
        case .optional(let defaultOn):
            let include = answerRow("in", "Include “\(field.name)”", value: SnippetField.on, icon: "checkmark.square",
                                    accessory: defaultOn ? "Default" : nil)
            let leave = answerRow("out", "Leave Out “\(field.name)”", value: SnippetField.off, icon: "square",
                                  accessory: defaultOn ? nil : "Default")
            let rows = defaultOn ? [include, leave] : [leave, include]
            // Typing narrows the two rows; yes/no, on/off and 포함/제외 count too, and no match keeps both.
            let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !typed.isEmpty else { return rows }
            let yes = ["y", "yes", "on", "in", "include", "포함", "넣기", "예", "네"].contains { $0.hasPrefix(typed) }
            let no = ["n", "no", "off", "out", "leave", "제외", "빼기", "아니오", "아니요"].contains { $0.hasPrefix(typed) }
            let narrowed = yes != no ? [yes ? include : leave] : rows.filter { $0.title.lowercased().contains(typed) }
            return narrowed.isEmpty ? rows : narrowed
        }
    }

    /// Renders and inserts a snippet with placeholders. From a typed
    /// abbreviation (`erase` > 0) the abbreviation is erased first, and only
    /// in the app it was typed in.
    func insertSnippet(_ snippet: PaletteSnippets.Snippet, arguments: [String: String], erase: Int, targetPID: pid_t?, typed: String = "") {
        guard case .success(let render) = SnippetTemplate.render(text: snippet.text, syntax: snippet.syntax,
                                                                 context: .init(arguments: arguments)) else {
            screens.show("This snippet's text has a mistake — fix it in Automation")
            return
        }
        let delay = host == .launcher ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let front = NSWorkspace.shared.frontmostApplication
            if let targetPID, front?.processIdentifier != targetPID {
                GestureHUD.shared.show(title: "Snippet Not Inserted", detail: "The app you typed in isn't in front any more; the text is as you left it.")
                return
            }
            // Checked before the abbreviation is erased, so a refusal leaves it as typed.
            if let refusal = SnippetInserter.refusal(for: render) {
                GestureHUD.shared.show(title: "Snippet Not Inserted", detail: refusal)
                return
            }
            guard erase > 0 else { insertRendered(render, into: front); return }
            // Backspaces go out off the main thread; the insert (and any caret
            // position it reads) waits until they have landed.
            DispatchQueue.global(qos: .userInitiated).async {
                TypedStringEngine.shared.erase(erase)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { insertRendered(render, into: front, typed: typed) }
            }
        }
    }

    /// `typed`: the abbreviation as it was typed, put back when the text
    /// can't go in after it was erased.
    private func insertRendered(_ render: SnippetRender, into front: NSRunningApplication?, typed: String = "") {
        SnippetInserter.insert(render, into: front) { inserted, note in
            if !inserted {
                if !typed.isEmpty { ActionExecutor.typeReplacementText(typed) }
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(render.text, forType: .string)
                GestureHUD.shared.show(title: "Snippet Copied", detail: (note ?? "Couldn't insert it") + " — press ⌘V.")
            } else if let note {
                GestureHUD.shared.show(title: "Snippet", detail: note)
            }
        }
    }

    func snippetItems() -> [PaletteItem] {
        var items = snippets.map { snippetRow($0, group: "Snippets · \(snippets.count)") }
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty,
           !ClipboardSecretScanner.containsSecret(inText: clip) {
            items.append(screenRow("snippets.fromClipboard", "New Snippet from Clipboard", String(clip.prefix(80)),
                                   icon: "doc.on.clipboard", group: "New",
                                   primary: PaletteAction(title: "Choose Keyword", effect: .push(.newSnippet(clip))) {}))
        }
        if isSearching {
            let text = trimmed
            items.append(screenRow("snippets.fromQuery", "New Snippet “\(text.prefix(40))”", "Save the text typed above",
                                   icon: "text.badge.plus", group: "New",
                                   primary: PaletteAction(title: "Choose Keyword", effect: .push(.newSnippet(text))) {}))
        }
        return items
    }

    /// 7.3: Find a Shortcut's rows — each use of the key pressed, where it
    /// applies, and the way to change it.
    func hotkeyFinderItems() -> [PaletteItem] {
        guard let shortcut = PaletteHotkeyFinder.shared.shortcut else {
            return [screenRow("hkfind.wait", "Press a key combination", "Such as ⌘⇧M or ⌃⌥←; AOM only looks it up", icon: "keyboard",
                              group: nil, primary: PaletteAction(title: "Waiting", effect: .stay) {}, dimmed: true)]
        }
        let usages = hotkeys.usages(of: shortcut, triggers: appState.currentPreset.triggers, groups: appState.currentPreset.activationGroups)
        let group = "\(shortcut.displayString) · \(usages.isEmpty ? "free" : "\(usages.count) use\(usages.count == 1 ? "" : "s")")"
        guard !usages.isEmpty else {
            return [screenRow("hkfind.free", "Nothing in AOM or Mission Control uses \(shortcut.displayString)", "Other apps may still use it inside their own windows",
                              icon: "checkmark.circle", group: group, primary: PaletteAction(title: "OK", effect: .stay) {})]
        }
        return usages.map { usage in
            let action: PaletteAction
            switch usage.kind {
            case .launcher: action = PaletteAction(title: "Change in Settings", effect: .stay) { AOMModuleSwitches.openSettings(.shortcuts) }
            case .launcherRow(let itemID, let title): action = PaletteAction(title: "Change Hotkey", effect: .push(.hotkey(itemID: itemID, title: title))) {}
            case .aomShortcut: action = PaletteAction(title: "Open Shortcuts Settings", effect: .stay) { AOMModuleSwitches.openSettings(.shortcuts) }
            case .automation(let id): action = PaletteAction(title: "Edit Automation", symbol: "pencil") { editTrigger(id) }
            case .macOS:
                action = PaletteAction(title: "Open Keyboard Shortcuts") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            return screenRow("hkfind.\(usage.id)", usage.title, usage.scope + (usage.isEnabled ? "" : " · turned off"),
                             icon: usage.kind == .macOS ? "apple.logo" : "keyboard", group: group, primary: action, dimmed: !usage.isEnabled)
        }
    }

    /// 7.3: saved folder favorites; one whose folder moved or can't be read
    /// says so and lets the folder be chosen again.
    func folderFavoriteRows() -> [PaletteItem] {
        PaletteFolderFavorites.shared.items.map { favorite in
            guard favorite.exists else {
                return screenRow("favfolder.\(favorite.id.uuidString)", "Folder: \(favorite.name)",
                                 "\((favorite.path as NSString).abbreviatingWithTildeInPath) isn't there any more — ↩ chooses it again",
                                 icon: "folder.badge.questionmark", group: nil,
                                 primary: PaletteAction(title: "Choose Again…", effect: .stay) { relocateFavorite(favorite) },
                                 secondaries: [PaletteAction(title: "Remove Favorite", symbol: "trash", effect: .stay, isDestructive: true) {
                                     PaletteFolderFavorites.shared.remove(favorite.id)
                                 }])
            }
            var row = screenRow("favfolder.\(favorite.id.uuidString)", "Folder: \(favorite.name)",
                                (favorite.path as NSString).abbreviatingWithTildeInPath + (favorite.query.isEmpty ? "" : " · filter “\(favorite.query)”"),
                                icon: "star.square.on.square", group: nil,
                                primary: PaletteAction(title: "Open", effect: .stay) {
                                    push(.folder(favorite.url))
                                    query = favorite.query
                                },
                                secondaries: [PaletteAction(title: "Remove Favorite", symbol: "trash", effect: .stay, isDestructive: true) {
                                    PaletteFolderFavorites.shared.remove(favorite.id)
                                }])
            row.keywords = "folder favorite 폴더 즐겨찾기 " + favorite.path
            return row
        }
    }

    private func relocateFavorite(_ favorite: PaletteFolderFavorite) {
        guard !PresetManager.isUIPreview else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Where is “\(favorite.name)” now?"
        AOMOverlayActivation.activateForOverlay()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { PaletteFolderFavorites.shared.relocate(favorite.id, to: url) }
        }
    }

    /// 7.3: Find a Shortcut from the root search.
    func finderRootItems() -> [PaletteItem] {
        var row = screenRow("finder.shortcut", "Find a Shortcut…", "Press a key combination to see what in AOM and macOS uses it",
                            icon: "keyboard.badge.eye", group: nil,
                            primary: PaletteAction(title: "Find", effect: .push(.hotkeyFinder)) {})
        row.aliases = ["shortcut", "hotkey", "단축키", "키 충돌", "conflict"]
        row.keywords = "shortcut hotkey keyboard conflict 단축키 충돌 사용처"
        return [row]
    }

    /// 7.3: scenes in the root search — ↩ runs one, ⌘↩ shows its plan in Window Tiling.
    func sceneRootItems() -> [PaletteItem] {
        SceneStore.shared.scenes.map { scene in
            var row = screenRow("scene.\(scene.id.uuidString)", "Scene: \(scene.name)",
                                ScenePlanner.steps(scene).map(\.title).joined(separator: " → "), icon: "theatermasks", group: nil,
                                primary: PaletteAction(title: "Run Scene", symbol: "play.fill") { SceneRunner.shared.run(scene) },
                                secondaries: [PaletteAction(title: "Edit Scenes…", symbol: "pencil") {
                                    appState.selectedMainTab = .snapping
                                    showAOM()
                                }])
            row.keywords = "scene 씬 작업 모드 workspace " + scene.name
            row.aliases = [scene.name.lowercased()]
            return row
        }
    }

    func snippetRootItems() -> [PaletteItem] {
        snippets.filter(\.isEnabled).map { snippetRow($0, group: nil) }
    }

    /// A snippet made from the clipboard stays literal text (code with braces).
    private func fromClipboard(_ text: String) -> Bool {
        NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }

    func newSnippetItems(_ text: String) -> [PaletteItem] {
        let keyword = trimmed
        if keyword.isEmpty {
            return [screenRow("snippet.new.wait", "Type a keyword above", "Such as ;sig, @@mail or :addr", icon: "keyboard",
                              group: nil, primary: PaletteAction(title: "Waiting", effect: .stay) {}, dimmed: true)]
        }
        if let problem = PaletteSnippets.problem(with: keyword, existing: appState.currentPreset.triggers) {
            return [screenRow("snippet.new.problem", problem, "Change the keyword above", icon: "exclamationmark.triangle",
                              group: nil, primary: PaletteAction(title: "Change It", effect: .stay) {}, dimmed: true)]
        }
        return [screenRow("snippet.new.save", "Save Snippet “\(keyword)”", "Typing \(keyword) in any app types the text",
                          icon: "checkmark.circle.fill", group: nil,
                          primary: PaletteAction(title: "Save", symbol: "checkmark", effect: .stay) {
                              appState.addTrigger(PaletteSnippets.trigger(abbreviation: keyword, text: text,
                                                                          placeholders: !text.isEmpty && SnippetTemplate.hasPlaceholders(text) && !fromClipboard(text)))
                              pop()
                              screens.show("Saved — type \(keyword) anywhere to expand it")
                          })]
    }

    private func editTrigger(_ id: UUID) {
        guard let trigger = appState.currentPreset.triggers.first(where: { $0.id == id }) else { return }
        appState.selectedActivationGroupID = trigger.activationGroupID
        appState.selectedTrigger = trigger
        appState.selectedMainTab = .gestures
        showAOM()
    }

    private func confirmDelete(_ snippet: PaletteSnippets.Snippet) {
        confirm(PaletteConfirmation(title: "Delete “\(snippet.abbreviation)”?",
                                    message: "The snippet and its typed-string automation go; typing \(snippet.abbreviation) no longer expands.",
                                    confirmTitle: "Delete Snippet", symbol: "trash.fill") {
            if let trigger = appState.currentPreset.triggers.first(where: { $0.id == snippet.id }) { appState.removeTrigger(trigger) }
            screens.show("Deleted \(snippet.abbreviation)")
        })
    }

    // MARK: Script commands (report 05 §3-H)

    func scriptRow(_ script: PaletteScript, section: Section = .scripts, group: String?) -> PaletteItem {
        let trusted = PaletteScripts.isTrusted(script) && !script.needsConfirmation
        let effect: PaletteAction.Effect = script.argument != nil ? .push(.scriptArgument(script.id))
            : (!trusted || script.mode == .fullOutput) ? .stay : .close
        var row = screenRow(script.id, script.title, script.description ?? script.packageName ?? script.url.lastPathComponent,
                            icon: "terminal", group: group, section: section,
                            primary: PaletteAction(title: script.argument == nil ? "Run Script" : "Run Script…", symbol: "play", effect: effect) {
                                runScript(script, argument: nil)
                            },
                            secondaries: [
                                PaletteAction(title: "Open in TextEdit", symbol: "pencil") {
                                    NSWorkspace.shared.open([script.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                                            configuration: NSWorkspace.OpenConfiguration())
                                },
                                PaletteAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([script.url]) },
                            ],
                            accessory: script.packageName)
        row.glyph = script.icon
        row.aliases = [script.title.lowercased()]
        return row
    }

    func scriptItems() -> [PaletteItem] {
        var items = data.scripts.map { scriptRow($0, group: "Script commands · \(data.scripts.count)") }
        items.append(screenRow("scripts.folder", "Open Script Commands Folder", (PaletteScripts.folder.path as NSString).abbreviatingWithTildeInPath,
                               icon: "folder", group: "More",
                               primary: PaletteAction(title: "Open") {
                                   try? FileManager.default.createDirectory(at: PaletteScripts.folder, withIntermediateDirectories: true)
                                   NSWorkspace.shared.open(PaletteScripts.folder)
                               }))
        items.append(screenRow("scripts.example", "Create an Example Script", "public-ip.sh, with the metadata a script command needs",
                               icon: "plus.square", group: "More",
                               primary: PaletteAction(title: "Create", effect: .stay) {
                                   do {
                                       let url = try PaletteScripts.createExample()
                                       data.loadScripts()
                                       NSWorkspace.shared.activateFileViewerSelecting([url])
                                       screens.show("Created \(url.lastPathComponent)")
                                   } catch { screens.show("Couldn't create it: \(error.localizedDescription)") }
                               }))
        items.append(screenRow("scripts.reload", "Reload Scripts", "Read the folder again", icon: "arrow.clockwise", group: "More",
                               primary: PaletteAction(title: "Reload", effect: .stay) { data.loadScripts(); screens.show("\(data.scripts.count) script commands") }))
        return items
    }

    func scriptRootItems() -> [PaletteItem] { data.scripts.map { scriptRow($0, group: nil) } }

    /// Asks once per script contents, then runs; full output stays in the
    /// launcher, the rest report in a HUD (and keep running after it closes).
    func runScript(_ script: PaletteScript, argument: String?) {
        if script.argument != nil, argument == nil {
            if navigation.current != .scriptArgument(script.id) { push(.scriptArgument(script.id)) }
            return
        }
        // Checked against the file as it is right now, not the cached hash.
        guard PaletteScripts.isTrusted(script, fresh: true), !script.needsConfirmation else {
            confirm(PaletteConfirmation(title: "Run “\(script.title)”?",
                                        message: "\((script.url.path as NSString).abbreviatingWithTildeInPath) runs as you, with access to your files and the network. AOM asks again if the script changes.",
                                        confirmTitle: "Run Script", symbol: "terminal.fill", destructive: false) {
                PaletteScripts.trust(script)
                execute(script, argument: argument)
            })
            return
        }
        execute(script, argument: argument)
    }

    private func execute(_ script: PaletteScript, argument: String?) {
        if script.mode == .fullOutput {
            AOMLauncherController.shared.reveal()
            if navigation.current != .scriptOutput(script.id) { push(.scriptOutput(script.id)) }
            data.run(script, argument: argument) { _ in }
            return
        }
        PaletteScripts.runInBackground(script, argument: argument)
        if host == .launcher, AOMLauncherController.shared.isVisible {
            AOMLauncherController.shared.dismiss(restoringFocus: true)
        }
    }

    func scriptOutputItems() -> [PaletteItem] {
        guard let run = data.scriptRun else { return [] }
        var items: [PaletteItem] = []
        if run.running {
            items.append(screenRow("script.stop", "Stop", "Cancel the script", icon: "stop.circle", group: nil,
                                   primary: PaletteAction(title: "Stop", effect: .stay, isDestructive: true) { data.cancelScript() }))
        }
        if let output = run.outcome?.output, !output.isEmpty {
            var copy = screenRow("script.copy", "Copy Output", "\(output.split(separator: "\n").count) lines", icon: "doc.on.doc", group: nil,
                                 primary: PaletteAction(title: "Copy", effect: .stay) { copyToClipboard(output, announce: "Output"); screens.show("Copied the output") })
            copy.sendText = output
            items.append(copy)
        }
        if !run.running, let script = data.scripts.first(where: { $0.id == run.scriptID }) {
            items.append(screenRow("script.again", "Run Again", script.title, icon: "arrow.clockwise", group: nil,
                                   primary: PaletteAction(title: "Run", effect: .stay) { data.run(script, argument: nil) { _ in } }))
        }
        return items
    }

    /// 7.2.2 (audit B11): the field hides what is typed for a password argument.
    var secureEntry: Bool {
        guard case .scriptArgument(let id)? = navigation.current else { return false }
        return data.scripts.first { $0.id == id }?.argument?.secure == true
    }

    func scriptArgumentItems(_ id: String) -> [PaletteItem] {
        guard let script = data.scripts.first(where: { $0.id == id }) else { return [] }
        let argument = trimmed
        let ready = !argument.isEmpty || script.argument?.optional == true
        let effect: PaletteAction.Effect = (PaletteScripts.isTrusted(script) && !script.needsConfirmation && script.mode != .fullOutput) ? .close : .stay
        let secure = script.argument?.secure == true
        let title = argument.isEmpty || secure ? "Run “\(script.title)”" : "Run “\(script.title)” with “\(argument)”"
        let detail = secure && !argument.isEmpty ? "\(script.argument?.placeholder ?? "Password") · \(argument.count) characters, hidden"
            : script.argument?.placeholder ?? "Argument"
        return [screenRow("script.arg.run", title, detail, icon: "play.fill", group: nil,
                          primary: PaletteAction(title: "Run", symbol: "play", effect: ready ? effect : .stay) {
                              if ready { runScript(script, argument: argument) }
                          }, dimmed: !ready)]
    }

    func scriptOutputView(_ run: PaletteLauncherData.ScriptRun) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.outcome?.output.isEmpty == false ? run.outcome!.output : (run.running ? "Running…" : "No output"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(run.outcome.map { $0.succeeded ? AOMCraftColor.ink : AOMColor.dangerText } ?? AOMCraftColor.inkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AOMSpace.x3)
                    .id("script.bottom")
            }
            .frame(maxHeight: 250)
            .onChange(of: run.outcome?.output) { _, _ in proxy.scrollTo("script.bottom", anchor: .bottom) }
        }
    }

    // MARK: Calendar, contacts (report 05 §3-B)

    func eventRow(_ event: PaletteSchedule.Event, group: String?, section: Section = .events, now: Date = Date()) -> PaletteItem {
        let timing = PaletteSchedule.timing(of: event, now: now)
        var secondaries = [PaletteAction(title: "Open in Calendar", symbol: "calendar") { PaletteSchedule.open(event) }]
        if let link = event.meetingLink {
            secondaries.append(PaletteAction(title: "Copy Meeting Link", symbol: "link") { copyToClipboard(link.absoluteString, announce: link.absoluteString) })
        }
        let details = "\(event.title) · \(PaletteSchedule.dayTitle(event.start, now: now)) \(timing)\(event.location.map { " · \($0)" } ?? "")"
        secondaries.append(PaletteAction(title: "Copy Details", symbol: "doc.on.doc") { copyToClipboard(details, announce: event.title) })
        var row = screenRow("event.\(event.id)", event.title,
                            [timing, event.calendar, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: event.meetingLink != nil ? "video" : "calendar", group: group, section: section,
                            primary: event.meetingLink.map { link in
                                PaletteAction(title: "Join Meeting", symbol: "video") { NSWorkspace.shared.open(link) }
                            } ?? PaletteAction(title: "Open in Calendar", symbol: "calendar") { PaletteSchedule.open(event) },
                            secondaries: event.meetingLink == nil ? Array(secondaries.dropFirst()) : secondaries,
                            accessory: event.meetingLink != nil ? "Join" : nil)
        row.sendText = details
        return row
    }

    /// The empty launcher: the next two events today (none after they end).
    func upNextItems(now: Date = Date()) -> [PaletteItem] {
        guard !isSearching, navigation.isRoot, schedule.access == .granted, let events = schedule.events else { return [] }
        let calendar = Calendar.current
        return events.filter { !$0.isAllDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .prefix(2).map { eventRow($0, group: nil, now: now) }
    }

    func eventSearchItems() -> [PaletteItem] {
        guard schedule.access == .granted, let events = schedule.events, trimmed.count >= 2 else { return [] }
        return events.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }.prefix(3).map { eventRow($0, group: nil) }
    }

    func scheduleItems() -> [PaletteItem] {
        switch schedule.access {
        case .notDetermined:
            return [screenRow("schedule.allow", "Allow Calendar Access…", "macOS asks once; AOM only reads events",
                              icon: "calendar.badge.checkmark", group: nil,
                              primary: PaletteAction(title: "Allow", effect: .stay) {
                                  Task { @MainActor in
                                      if await schedule.requestAccess() { schedule.load() } else { screens.show("Calendar access wasn't given") }
                                      sourcesChanged()
                                  }
                              })]
        case .denied:
            return [privacyRow("schedule.settings", "Calendars")]
        case .granted:
            let now = Date()
            var rows = (schedule.events ?? []).filter { $0.end > now || $0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: now) }
                .map { eventRow($0, group: PaletteSchedule.dayTitle($0.start, now: now), section: .commands, now: now) }
            // 7.3 (7.2.1 audit B17): say when the week holds more than is listed.
            if let listed = schedule.events?.count, schedule.totalCount > listed {
                var more = screenRow("schedule.more", "\(schedule.totalCount - listed) more events this week", "Open Calendar to see them all",
                                     icon: "calendar.badge.plus", group: "More",
                                     primary: PaletteAction(title: "Open Calendar") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) })
                more.placement = .fallback
                rows.append(more)
            }
            return rows
        }
    }

    func contactRow(_ person: PaletteContacts.Person, group: String?, section: Section = .contacts) -> PaletteItem {
        var actions: [PaletteAction] = []
        if let email = person.emails.first {
            actions.append(PaletteAction(title: "Copy Email", symbol: "envelope") { copyToClipboard(email, announce: email) })
            actions.append(PaletteAction(title: "Write Email", symbol: "square.and.pencil") {
                if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
            })
        }
        if let phone = person.phones.first {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            actions.append(PaletteAction(title: "Copy Phone Number", symbol: "phone") { copyToClipboard(phone, announce: phone) })
            actions.append(PaletteAction(title: "Call", symbol: "phone.arrow.up.right") {
                if let url = URL(string: "tel:\(digits)") { NSWorkspace.shared.open(url) }
            })
            actions.append(PaletteAction(title: "Send Message", symbol: "message") {
                if let url = URL(string: "sms:\(digits)") { NSWorkspace.shared.open(url) }
            })
        }
        actions.append(PaletteAction(title: "Open in Contacts", symbol: "person.crop.circle") { PaletteContacts.open(person) })
        var row = screenRow("contact.\(person.id)", person.name,
                            [person.organization, person.emails.first ?? person.phones.first].compactMap { $0 }.joined(separator: " · "),
                            icon: "person.crop.circle.fill", group: group, section: section,
                            primary: actions[0], secondaries: Array(actions.dropFirst()))
        row.sendText = person.emails.first ?? person.phones.first
        return row
    }

    func contactRootItems() -> [PaletteItem] {
        guard trimmed.count >= 2, contacts.access == .granted, let people = contacts.people else { return [] }
        return PaletteContacts.matching(trimmed, in: people, limit: 3).map { contactRow($0, group: nil) }
    }

    func contactItems() -> [PaletteItem] {
        switch contacts.access {
        case .notDetermined:
            return [screenRow("contacts.allow", "Allow Contacts Access…", "macOS asks once; AOM only reads names, addresses and numbers",
                              icon: "person.crop.circle.badge.checkmark", group: nil,
                              primary: PaletteAction(title: "Allow", effect: .stay) {
                                  Task { @MainActor in
                                      if await contacts.requestAccess() { contacts.load() } else { screens.show("Contacts access wasn't given") }
                                      sourcesChanged()
                                  }
                              })]
        case .denied:
            return [privacyRow("contacts.settings", "Contacts")]
        case .granted:
            // 7.3 (7.2.1 audit B18): a failed read says so instead of showing nobody.
            if let error = contacts.lastError {
                return [screenRow("contacts.error", "Couldn't Read Contacts", error, icon: "exclamationmark.triangle", group: nil,
                                  primary: PaletteAction(title: "Try Again", effect: .stay) { contacts.reset(); contacts.load() })]
            }
            guard let people = contacts.people else {
                return [screenRow("contacts.loading", "Reading Contacts…", "A large address book takes a moment", icon: "hourglass",
                                  group: nil, primary: PaletteAction(title: "Wait", effect: .stay) {}, dimmed: true)]
            }
            var rows = PaletteContacts.matching(trimmed, in: people, limit: 120).map { contactRow($0, group: nil, section: .commands) }
            if contacts.truncated, !trimmed.isEmpty, rows.isEmpty {
                rows.append(screenRow("contacts.truncated", "Not in the first 5,000 contacts", "Search in Contacts for the rest",
                                      icon: "person.crop.circle.badge.questionmark", group: nil,
                                      primary: PaletteAction(title: "Open Contacts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app")) }))
            }
            return rows
        }
    }

    private func privacyRow(_ id: String, _ pane: String) -> PaletteItem {
        screenRow(id, "Turn On \(pane) Access in System Settings…", "Privacy & Security › \(pane) › All of MacOS",
                  icon: "lock.shield", group: nil,
                  primary: PaletteAction(title: "Open Settings") {
                      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
                  })
    }

    // MARK: Send To (report 05 §3-G)

    func sendToItems(_ payload: PaletteSendPayload) -> [PaletteItem] {
        let text = payload.text
        let front = frontAppForAI?.localizedName ?? "App"
        var items: [PaletteItem] = [
            screenRow("send.paste", "Type into \(front)", "Where you were before the launcher", icon: "keyboard", group: "Send",
                      primary: PaletteAction(title: "Type") { insertIntoFrontApp(text, announce: payload.title) }),
            screenRow("send.copy", "Copy", "To the clipboard", icon: "doc.on.doc", group: "Send",
                      primary: PaletteAction(title: "Copy") { copyToClipboard(text, announce: payload.title) }),
        ]
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmedText), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            items.insert(screenRow("send.open", "Open Link", url.host ?? trimmedText, icon: "safari", group: "Send",
                                   primary: PaletteAction(title: "Open") { NSWorkspace.shared.open(url) }), at: 0)
        } else if trimmedText.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmedText) {
            let url = URL(fileURLWithPath: trimmedText)
            items.insert(screenRow("send.reveal", "Show in Finder", (trimmedText as NSString).abbreviatingWithTildeInPath, icon: "folder",
                                   group: "Send", primary: PaletteAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }), at: 0)
        }
        if let entry = payload.clipboardEntry {
            items.append(screenRow("send.stack", "Add to Paste Stack", "Paste it later with Paste Next in Stack", icon: "square.stack",
                                   group: "Send", primary: PaletteAction(title: "Add", effect: .stay) {
                                       let state = ClipboardPanelController.shared.state
                                       if !state.stack.contains(entry) { state.stack.append(entry) }
                                       pop(); screens.show("Paste Stack · \(state.stack.count) queued")
                                   }))
        }
        var ask = screenRow("send.ask", "Ask \(ai.model.title)…", "Opens Ask AI with the text; add your question", icon: "sparkles",
                            group: "AI", primary: PaletteAction(title: "Ask", effect: .stay) {
                                AOMLauncherController.shared.reveal()
                                pop(); push(.ai); query = text
                            })
        ask.identity = AOMIdentity(symbol: "sparkles", color: AOMBrand.start)
        items.append(ask)
        for command in PaletteAICommand.all where command.needsSelection {
            guard let prompt = PaletteAICommand.fill(command.template, selection: text, clipboard: text) else { continue }
            items.append(screenRow("send.ai.\(command.id)", command.title, ai.model.title, icon: command.symbol, group: "AI",
                                   primary: PaletteAction(title: "Ask", symbol: "sparkles", effect: .stay) { pop(); askAI(prompt) }))
        }
        for keyword in ["g", "n"] {
            guard let link = quicklinks.links.first(where: { $0.isEnabled && $0.keyword == keyword }),
                  let url = PaletteQuicklinks.url(for: link, query: String(trimmedText.prefix(300))) else { continue }
            items.append(screenRow("send.web.\(keyword)", "Search \(link.name)", url.host ?? "", icon: "magnifyingglass", group: "Search",
                                   primary: PaletteAction(title: "Search") { NSWorkspace.shared.open(url) }))
        }
        items.append(screenRow("send.snippet", "Save as Snippet…", "Choose a keyword that types it", icon: "text.badge.plus", group: "Save",
                               primary: PaletteAction(title: "Choose Keyword", effect: .push(.newSnippet(text))) {}))
        // Codex audit R08: kept for presenting, last in the list.
        items.append(screenRow("send.largeType", "Show in Large Type", "Across the screen; any key closes it", icon: "textformat.size",
                               group: "More", primary: PaletteAction(title: "Show") { AOMLargeType.show(text) }))
        return items
    }

    // MARK: Hotkeys (report 05 §3-C)

    func hotkeyItems(itemID: String, title: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let binding = hotkeys.binding(for: itemID) {
            items.append(screenRow("hotkey.remove", "Remove \(binding.display)", "“\(title)” keeps working from the launcher",
                                   icon: "keyboard.badge.ellipsis", group: nil,
                                   primary: PaletteAction(title: "Remove", effect: .stay, isDestructive: true) {
                                       hotkeys.remove(itemID); pop(); screens.show("Hotkey removed")
                                   }))
        }
        items.append(screenRow("hotkey.cancel", "Cancel", "Keep it as it is (esc)", icon: "arrow.uturn.backward", group: nil,
                               primary: PaletteAction(title: "Cancel", effect: .stay) { pop() }))
        return items
    }

    // MARK: Headers

    var routeHeader72: RouteHeader? {
        switch navigation.current {
        case .tool(.brew(let tab, _))?:
            return brewHeader(tab)
        case .tool(.network)? where data.network == nil:
            return RouteHeader(symbol: "network", tint: AOMModule.systemTools.hue, title: "Reading the Network…",
                               detail: "Addresses, Wi-Fi and DNS servers.", busy: true)
        case .tool(.vpn)? where vpn.services.isEmpty && !vpn.hasTailscale:
            return RouteHeader(symbol: "lock.shield", tint: AOMModule.systemTools.hue, title: "No VPN Set Up",
                               detail: "VPN profiles from System Settings › VPN and Tailscale appear here.")
        case .tool(.files)?:
            switch data.fileStatus {
            case .idle where trimmed.isEmpty:
                return RouteHeader(symbol: "doc.text.magnifyingglass", tint: AOMModule.files.hue, title: "Search Files",
                                   detail: "Type part of a file or folder name. Spotlight looks through your home folder; ↩ on a folder browses it here.")
            case .searching:
                return RouteHeader(symbol: "doc.text.magnifyingglass", tint: AOMModule.files.hue, title: "Searching…",
                                   detail: "Spotlight, in your home folder.", busy: true)
            case .done(let total) where total == 0:
                return RouteHeader(symbol: "doc.text.magnifyingglass", tint: AOMModule.files.hue, title: "No File Called “\(trimmed)”",
                                   detail: "Spotlight found nothing in your home folder. Folders Spotlight skips (System Settings › Spotlight › Privacy) aren't searched.")
            case .done(let total) where total > data.files.count:
                return nil
            case .failed:
                return RouteHeader(symbol: "exclamationmark.triangle", tint: AOMColor.warning, title: "Spotlight Didn't Start",
                                   detail: "Spotlight indexing may be off for this disk.")
            default:
                return nil
            }
        case .tool(.pasteStack)? where ClipboardPanelController.shared.state.stack.isEmpty:
            return RouteHeader(symbol: "square.stack", tint: AOMModule.clipboard.hue, title: "Paste Stack Is Empty",
                               detail: "In Clipboard History, ⌘K › Add to Paste Stack (or ⌥↩ › Add to Paste Stack) queues an item.")
        case .tool(.rulePreview)? where FolderRulesEngine.shared.config.rules.isEmpty:
            return RouteHeader(symbol: "folder.badge.gearshape", tint: AOMModule.folderRules.hue, title: "No Folder Rules Yet",
                               detail: "Make one on the Folder Rules page; its preview shows here without opening the editor.")
        case .folder?:
            if let error = data.folder?.error {
                return RouteHeader(symbol: "lock.shield", tint: AOMColor.warning, title: "Can't Read This Folder", detail: error)
            }
            return nil
        case .rulePreview(let id)?:
            let name = FolderRulesEngine.shared.config.rules.first { $0.id == id }?.name ?? "Rule"
            guard let preview = data.rulePreview, preview.ruleID == id else {
                return RouteHeader(symbol: "folder.badge.gearshape", tint: AOMModule.folderRules.hue, title: "Reading the Folder…",
                                   detail: "A dry run of “\(name)”: nothing moves.", busy: true)
            }
            return RouteHeader(symbol: "folder.badge.gearshape", tint: AOMModule.folderRules.hue, title: name,
                               detail: FolderRulesText.previewSummary(preview) + ". A dry run: nothing moved.")
        case .snippets? where snippets.isEmpty && !isSearching:
            return RouteHeader(symbol: "text.badge.plus", tint: AOMModule.textActions.hue, title: "No Snippets Yet",
                               detail: "Type some text above and choose New Snippet, or copy it and choose New Snippet from Clipboard. A snippet types its text when you type its keyword in any app.")
        case .newSnippet(let text)?:
            return RouteHeader(symbol: "text.badge.plus", tint: AOMModule.textActions.hue, title: "New Snippet",
                               detail: "“\(text.prefix(160))\(text.count > 160 ? "…" : "")” — type the keyword above. It types this text from the launcher and whenever you type the keyword in another app.")
        case .scripts? where data.scripts.isEmpty:
            return RouteHeader(symbol: "terminal", tint: AOMBrand.graphite, title: "No Script Commands Yet",
                               detail: "Put scripts with a “# @aom.title” (or Raycast's “# @raycast.title”) comment in \((PaletteScripts.folder.path as NSString).abbreviatingWithTildeInPath).")
        case .scriptOutput?:
            guard let run = data.scriptRun else { return nil }
            let detail: String
            if run.running { detail = "Running…" }
            else if let outcome = run.outcome {
                detail = outcome.timedOut ? "Stopped after two minutes" : outcome.cancelled ? "Stopped"
                    : outcome.succeeded ? "Finished" : "Failed with exit code \(outcome.status)"
            } else { detail = "" }
            return RouteHeader(symbol: "terminal", tint: run.outcome.map { $0.succeeded ? AOMColor.success : AOMColor.danger } ?? AOMBrand.graphite,
                               title: run.title, detail: detail, busy: run.running)
        case .scriptArgument(let id)?:
            guard let script = data.scripts.first(where: { $0.id == id }) else { return nil }
            return RouteHeader(symbol: "terminal", tint: AOMBrand.graphite, title: script.title,
                               detail: "Type \(script.argument?.placeholder.lowercased() ?? "the argument") above\(script.argument?.optional == true ? " (optional)" : ""), then ↩.")
        case .schedule?:
            switch schedule.access {
            case .notDetermined:
                return RouteHeader(symbol: "calendar", tint: AOMColor.danger, title: "My Schedule",
                                   detail: "Today and the next seven days from the Calendar app, with meeting links to join. AOM reads events only after you allow it.")
            case .denied:
                return RouteHeader(symbol: "calendar", tint: AOMColor.warning, title: "Calendar Access Is Off",
                                   detail: "Allow All of MacOS in System Settings › Privacy & Security › Calendars to list your events here.")
            case .granted where schedule.events == nil:
                return RouteHeader(symbol: "calendar", tint: AOMColor.danger, title: "Reading Your Calendars…", detail: "The next seven days.", busy: true)
            case .granted where schedule.events?.isEmpty == true:
                return RouteHeader(symbol: "calendar", tint: AOMColor.danger, title: "Nothing in the Next Seven Days",
                                   detail: "Events from every calendar in the Calendar app show here.")
            default:
                return nil
            }
        case .contacts?:
            switch contacts.access {
            case .notDetermined:
                return RouteHeader(symbol: "person.crop.circle", tint: AOMModule.tiling.hue, title: "Contacts",
                                   detail: "Search people by name, company, address or number, then copy, call or write. AOM reads contacts only after you allow it.")
            case .denied:
                return RouteHeader(symbol: "person.crop.circle", tint: AOMColor.warning, title: "Contacts Access Is Off",
                                   detail: "Allow All of MacOS in System Settings › Privacy & Security › Contacts.")
            case .granted where contacts.people == nil:
                return RouteHeader(symbol: "person.crop.circle", tint: AOMModule.tiling.hue, title: "Reading Contacts…", detail: "", busy: true)
            default:
                return nil
            }
        case .sendTo(let payload)?:
            return RouteHeader(symbol: "paperplane.fill", tint: AOMBrand.start, title: "Send “\(payload.title.prefix(60))”",
                               detail: String(payload.text.prefix(220)).replacingOccurrences(of: "\n", with: " "))
        case .hotkey(_, let title)?:
            return RouteHeader(symbol: "keyboard", tint: AOMColor.accent, title: "Press the New Hotkey for “\(title)”",
                               detail: "⌘, ⌥ or ⌃ with a key, or an F-key alone. It works from any app; a key AOM or an automation already uses is refused with its owner. esc cancels.")
        default:
            return nil
        }
    }

    // MARK: Detail pane

    var showsInfoDetail: Bool {
        switch navigation.current {
        case .emoji?, .snippets?, .contacts?, .schedule?, .folder?, .tool(.files)?, .rulePreview?:
            return true
        case .tool(.brew(let tab, _))?:
            return tab != .services
        default:
            return false
        }
    }

    func detailInfo(_ item: PaletteItem) -> AOMLauncherInfo? {
        let id = item.id
        if id.hasPrefix("emoji.") {
            let glyph = String(id.dropFirst("emoji.".count))
            guard let emoji = PaletteEmojiIndex.all().first(where: { $0.glyph == glyph }) else { return nil }
            return AOMLauncherInfo(title: emoji.displayName, glyph: emoji.glyph,
                                   fields: [("English", emoji.name), ("Code point", emoji.codePoints)]
                                       + (emoji.localizedName.map { [(PaletteEmojiIndex.localLanguageTitle, $0)] } ?? []))
        }
        if id.hasPrefix("file.") || id.hasPrefix("ruleitem.") {
            guard let path = item.sendText else { return nil }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .creationDateKey])
            var fields: [(String, String)] = [("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)]
            if let kind = values?.localizedTypeDescription { fields.append(("Kind", kind)) }
            if let size = values?.fileSize { fields.append(("Size", SystemStatus.size(Int64(size)))) }
            if let date = values?.contentModificationDate { fields.append(("Modified", date.formatted(date: .abbreviated, time: .shortened))) }
            if let date = values?.creationDate { fields.append(("Created", date.formatted(date: .abbreviated, time: .shortened))) }
            if id.hasPrefix("ruleitem.") { fields.append(("Would", item.subtitle)) }
            return AOMLauncherInfo(title: url.lastPathComponent, image: session.icon(forPath: path), fields: fields)
        }
        if id.hasPrefix("contact.") {
            guard let person = contacts.people?.first(where: { "contact.\($0.id)" == id }) else { return nil }
            var fields: [(String, String)] = []
            if let organization = person.organization { fields.append(("Company", organization)) }
            fields += person.emails.map { ("Email", $0) }
            fields += person.phones.map { ("Phone", $0) }
            return AOMLauncherInfo(title: person.name, symbol: "person.crop.circle.fill", fields: fields)
        }
        if id.hasPrefix("event.") {
            guard let event = schedule.events?.first(where: { "event.\($0.id)" == id }) else { return nil }
            var fields: [(String, String)] = [("When", event.isAllDay ? "All day" : "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(PaletteSchedule.clock(event.end))")]
            fields.append(("Calendar", event.calendar))
            if let location = event.location { fields.append(("Where", location)) }
            if let link = event.meetingLink { fields.append(("Meeting", link.host ?? link.absoluteString)) }
            return AOMLauncherInfo(title: event.title, symbol: event.meetingLink == nil ? "calendar" : "video.fill", fields: fields)
        }
        if id.hasPrefix("snippet."), let snippet = snippets.first(where: { "snippet.\($0.id.uuidString)" == id }) {
            return AOMLauncherInfo(title: snippet.name, symbol: "text.badge.plus", body: snippet.text,
                                   fields: [("Keyword", snippet.abbreviation), ("Expands as you type", snippet.isEnabled ? "Yes" : "Off")])
        }
        if id.hasPrefix("brew.installed."), let package = brew.installed?.first(where: { "brew.installed.\($0.id)" == id }) {
            var fields: [(String, String)] = [("Version", package.version), ("Kind", package.kind.title)]
            if package.kind == .formula { fields.append(("Installed", package.onRequest ? "By name" : "As a dependency")) }
            if package.outdated { fields.append(("Update", "Available")) }
            if let homepage = package.homepage { fields.append(("Homepage", homepage)) }
            return AOMLauncherInfo(title: package.name, symbol: package.kind == .cask ? "macwindow" : "shippingbox", body: package.summary, fields: fields)
        }
        if id.hasPrefix("brew.outdated."), let package = brew.outdated?.first(where: { "brew.outdated.\($0.id)" == id }) {
            return AOMLauncherInfo(title: package.name, symbol: "arrow.up.circle",
                                   fields: [("Installed", package.installedVersions.joined(separator: ", ")), ("Newest", package.currentVersion),
                                            ("Kind", package.kind.title), ("Pinned", package.pinned ? "Yes" : "No")])
        }
        if id.hasPrefix("brew.search.") {
            return AOMLauncherInfo(title: item.title, symbol: "shippingbox",
                                   fields: [("Kind", item.subtitle), ("Installed", item.accessory == nil ? "No" : "Yes")])
        }
        if id == "brew.upgradeAll", let outdated = brew.outdated?.filter({ !$0.pinned }) {
            return AOMLauncherInfo(title: item.title, symbol: "arrow.up.circle.fill",
                                   body: outdated.map { "\($0.name)  \($0.change)" }.joined(separator: "\n"),
                                   fields: [("Pinned, kept as they are", "\(brew.outdated?.filter(\.pinned).count ?? 0)")])
        }
        // Any other row on these screens: what it does, rather than an empty pane.
        return AOMLauncherInfo(title: item.title, symbol: item.glyph == nil ? item.icon : nil, glyph: item.glyph,
                               body: item.subtitle.isEmpty ? nil : item.subtitle,
                               fields: [("↩", item.primary.title)])
    }

    // MARK: Previews

    /// `--aom-preview-palette-route` names for the 7.2 screens.
    static func previewRoute72(_ name: String) -> PaletteRoute? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "emoji": return .emoji
        case "snippets": return .snippets
        case "scripts": return .scripts
        case "schedule": return .schedule
        case "contacts": return .contacts
        case "network": return .tool(.network)
        case "vpn": return .tool(.vpn)
        case "stack": return .tool(.pasteStack)
        case "rules": return .tool(.rulePreview)
        case "files": return .tool(.files(argument))
        case "folder": return .folder(URL(fileURLWithPath: argument.isEmpty ? NSHomeDirectory() : argument))
        case "brew": return .tool(.brew(HomebrewModel.Tab(rawValue: argument) ?? .outdated, ""))
        case "sendTo": return .sendTo(PaletteSendPayload(text: argument.isEmpty ? "https://example.com/report" : argument, title: "Preview"))
        case "hotkey": return .hotkey(itemID: "capture.area", title: "Capture Area")
        case "newSnippet": return .newSnippet(argument.isEmpty ? "Best regards,\nYongwoo" : argument)
        // 7.3
        case "aiRecords": return .aiRecords
        case "hotkeyFinder": return .hotkeyFinder
        // 7.4
        case "browserTabs": return .browserTabs
        case "system": return .system
        // 7.8
        case "themes": return .themes
        default: return nil
        }
    }
}

/// 7.2: row density (report 05 §4) — ⌘- and ⌘= in the launcher, Settings › Shortcuts.
enum AOMLauncherDensity: String, CaseIterable, Identifiable {
    case compact, regular, spacious

    static let key = "AOMLauncherDensity"
    nonisolated(unsafe) private static var cached: AOMLauncherDensity?

    var id: String { rawValue }

    static var current: AOMLauncherDensity {
        get {
            if let cached { return cached }
            let value = AOMLauncherDensity(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .regular
            cached = value
            return value
        }
        set {
            cached = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .spacious: return "Spacious"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 36
        case .regular: return 44
        case .spacious: return 52
        }
    }

    var badge: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 26
        case .spacious: return 30
        }
    }

    /// One step denser (-1) or roomier (+1), stopping at the ends.
    static func step(_ direction: Int) {
        let all = allCases
        let index = all.firstIndex(of: current) ?? 1
        current = all[min(all.count - 1, max(0, index + direction))]
    }
}
