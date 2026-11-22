import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.8: Codex's menu bar & window UI spec (MB-01/02, ME-01…03, HB-01,
/// WIN-01, UI-01) and the launcher's themes.
@MainActor
final class AOM78Tests: XCTestCase {
    private typealias Node = AOMMenuExtraNode
    private typealias Entry = AOMStatusMenuLayout.Entry

    // MARK: MB-01 — containers are walked

    /// The macOS 27 MenuBarAgent shape Codex read: two live activities, then
    /// four nameless hosting views each holding one menu extra.
    private var agent: [Node] {
        let live = Node(role: "AXGroup", subrole: "AXLiveActivity", description: "Timer", identifier: "live.1", actions: ["AXPress"],
                        children: [Node(role: "AXGroup"), Node(role: "AXGroup"), Node(role: "AXImage")])
        func host(_ name: String, _ id: String, image: Bool = false) -> Node {
            var kids = [Node(role: "AXMenuBarItem", subrole: "AXMenuExtra", description: name, identifier: id, actions: ["AXShowMenu", "AXPress"])]
            if image { kids.append(Node(role: "AXImage")) }
            return Node(role: "AXHostingView", children: kids)
        }
        return [live, live, host("Battery", "com.apple.menuextra.battery"), host("Sound", "com.apple.menuextra.sound"),
                host("Control Center", "com.apple.menuextra.controlcenter", image: true), host("Clock", "com.apple.menuextra.clock")]
    }

    func testMB01HostingViewsGiveTheirMenuExtras() {
        let result = AOMMenuExtraFlatten.items(agent)
        XCTAssertEqual(result.paths, [[0], [1], [2, 0], [3, 0], [4, 0], [5, 0]])
        XCTAssertFalse(result.truncated)
        let names = result.paths.compactMap { AOMMenuExtraFlatten.node(at: $0, in: agent)?.description }
        XCTAssertEqual(names, ["Timer", "Timer", "Battery", "Sound", "Control Center", "Clock"])
    }

    func testMB01PressableOrNamedItemsAreKeptAsTheyAre() {
        let plain = [Node(role: "AXMenuBarItem", subrole: "AXMenuExtra", title: "Dropbox", actions: ["AXPress"]),
                     Node(role: "AXMenuBarItem", description: "Named", children: [Node(role: "AXMenuBarItem", actions: ["AXPress"])])]
        XCTAssertEqual(AOMMenuExtraFlatten.items(plain).paths, [[0], [1]], "a named item isn't replaced by its child")
    }

    func testMB01DeepContainersAreReadInPartAndEmptyOnesStay() {
        let deep = Node(role: "AXHostingView", children: [Node(role: "AXGroup", children: [Node(role: "AXGroup", children: [
            Node(role: "AXGroup", children: [Node(role: "AXMenuBarItem", subrole: "AXMenuExtra", description: "Far")])])])])
        let result = AOMMenuExtraFlatten.items([deep, Node(role: "AXHostingView", children: [Node(role: "AXImage")])], maxDepth: 3)
        XCTAssertTrue(result.truncated, "a walk cut short says so")
        XCTAssertEqual(result.paths, [[0], [1]], "nothing found: the container stays one row")
    }

    func testMB01SystemItemsGetTheirOwnNamesAndSymbols() {
        let bundle = "com.apple.MenuBarAgent"
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "com.apple.menuextra.battery", description: "Battery, 80 percent")?.name, "Battery")
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "com.apple.menuextra.sound", description: "")?.symbol, "speaker.wave.2.fill")
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "com.apple.menuextra.controlcenter", description: "")?.name, "Control Center")
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "com.apple.menuextra.clock", description: "")?.name, "Clock")
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "com.apple.menuextra.timemachine", description: "")?.name, "Time Machine",
                       "Time Machine isn't read as the clock")
        XCTAssertEqual(AOMMenuBarIdentity.identify(ownerBundleID: bundle, identifier: "", description: "Sound")?.name, "Sound")
        XCTAssertNil(AOMMenuBarIdentity.identify(ownerBundleID: "com.getdropbox.dropbox", identifier: "battery", description: "Battery"),
                     "another app's item keeps its own name")
    }

    private func item(_ title: String, id: String = "", description: String = "", owner: String = "com.apple.MenuBarAgent",
                      ordinal: Int = 0, unique: Bool = true) -> AOMMenuShelfItem {
        AOMMenuShelfItem(pid: 42, ownerBundleID: owner, ownerName: "MenuBarAgent", title: title, axIdentifier: id,
                         ordinal: ordinal, siblings: 4, identifierIsUnique: unique, axDescription: description)
    }

    func testMB01FourSystemRowsAreFourNames() {
        let rows = [item("Battery", id: "com.apple.menuextra.battery", description: "Battery"),
                    item("Sound", id: "com.apple.menuextra.sound", description: "Sound", ordinal: 1),
                    item("Control Center", id: "com.apple.menuextra.controlcenter", description: "Control Center", ordinal: 2),
                    item("Clock", id: "com.apple.menuextra.clock", description: "Clock", ordinal: 3)]
        XCTAssertEqual(Set(rows.map(\.baseName)).count, 4)
        XCTAssertFalse(rows.contains { $0.baseName == "MenuBarAgent" })
    }

    // MARK: MB-02 — aliases keep to the item, not its value or place

    func testMB02StableKeyIgnoresChangingValuesAndPlaces() {
        let loud = item("Sound, 80 %", id: "com.apple.menuextra.sound", description: "Sound, 80 %")
        let quiet = item("Sound, 20 %", id: "com.apple.menuextra.sound", description: "Sound, 20 %", ordinal: 3)
        XCTAssertEqual(loud.stableKey, quiet.stableKey, "the volume changing keeps the alias")
        XCTAssertEqual(loud.baseName, "Sound")
        XCTAssertEqual(loud.detail, "Sound, 80 %")
        let weather = item("18°C", owner: "com.example.weather")
        XCTAssertNil(weather.stableKey, "a reading and a place are no identity")
        XCTAssertEqual(weather.baseName, "MenuBarAgent")
        let twins = item("Mail", id: "status", owner: "com.example.mail", unique: false)
        XCTAssertEqual(twins.stableKey, "com.example.mail|desc:Mail", "shared identifiers fall back to a steady description")
    }

    func testMB02AliasStoreSavesAndRestores() {
        let defaults = UserDefaults(suiteName: "AOM78-\(UUID().uuidString)")!
        let store = AOMMenuBarAliasStore(defaults: defaults)
        store.set(AOMMenuBarAlias(name: "Meeting volume", symbol: "speaker.wave.2.fill", group: "Meeting"), for: "k")
        XCTAssertEqual(AOMMenuBarAliasStore(defaults: defaults).alias(for: "k")?.name, "Meeting volume")
        XCTAssertEqual(store.groups, ["Meeting"])
        store.set(AOMMenuBarAlias(), for: "k")
        XCTAssertNil(AOMMenuBarAliasStore(defaults: defaults).alias(for: "k"), "an empty alias is the default again")
    }

    // MARK: ME-02 — what the menu draws

    func testME02NormalizedDropsStrayLinesEmptyGroupsAndMissingCommands() {
        let known: Set<String> = ["a", "b"]
        let entries: [Entry] = [.separator, .command("a"), .separator, .separator, .command("gone"),
                                .group("Empty", [.command("gone")]), .group("Meeting", [.separator, .command("b"), .separator]), .separator]
        let out = AOMStatusMenuLayout.normalized(entries, known: known)
        XCTAssertEqual(out.map(\.kind), [.command, .separator, .group])
        XCTAssertEqual(out.last?.children?.map(\.kind), [.command])
        XCTAssertEqual(AOMStatusMenuLayout.clampedPerRow(9), 4)
        XCTAssertEqual(AOMStatusMenuLayout.clampedPerRow(0), 1)
    }

    func testME01DraftEditsInsertMoveRegroupRename() {
        let a = Entry.command("a"), b = Entry.command("b"), group = Entry.group("Meeting")
        var list = [a, group, b]
        list = AOMMenuDraftOps.insert(.command("c"), after: group.id, in: list)
        XCTAssertEqual(list[1].children?.first?.command, "c", "added on a group goes into it")
        list = AOMMenuDraftOps.regroup(b.id, into: group.id, in: list)
        XCTAssertEqual(list.map(\.kind), [.command, .group])
        XCTAssertEqual(list[1].children?.map(\.command), ["c", "b"])
        list = AOMMenuDraftOps.move(b.id, by: -1, in: list)
        XCTAssertEqual(list[1].children?.map(\.command), ["b", "c"], "moves stay inside the group")
        list = AOMMenuDraftOps.regroup(b.id, into: nil, in: list)
        XCTAssertEqual(list.map { $0.command ?? $0.title }, ["a", "Meeting", "b"], "out of a group lands after it")
        list = AOMMenuDraftOps.rename(b.id, to: "  Meeting volume ", in: list)
        XCTAssertEqual(list[2].title, "Meeting volume")
        list = AOMMenuDraftOps.remove(group.id, from: list)
        XCTAssertEqual(list.map(\.command), ["a", "b"])
        XCTAssertEqual(AOMMenuDraftOps.move(a.id, by: -1, in: list).map(\.command), ["a", "b"], "the first can't go higher")
    }

    func testME02SaveRefusesAStaleDraftAndRestoreClears() {
        let defaults = UserDefaults(suiteName: "AOM78-\(UUID().uuidString)")!
        let store = AOMStatusMenuStore(defaults: defaults)
        var draft = store.layout
        draft.menu = [.command("qa.captureArea")]
        draft.panelPerRow = 7
        XCTAssertEqual(store.save(draft, basedOn: 0), .saved)
        XCTAssertEqual(store.layout.revision, 1)
        XCTAssertEqual(store.layout.panelPerRow, 4)
        XCTAssertEqual(store.save(draft, basedOn: 0), .conflict, "a second editor's older draft is refused")
        XCTAssertEqual(AOMStatusMenuStore(defaults: defaults).layout.menu?.first?.command, "qa.captureArea", "saved across launches")
        store.restoreDefaults()
        XCTAssertNil(store.layout.menu)
        XCTAssertNil(store.layout.panel)
    }

    func testME03StarterBeginsWithWorkspaceQuickActions() {
        let starter = AOMStatusMenuLayout.starter(quickActions: [.recordScreen, .captureArea])
        XCTAssertEqual(starter.prefix(2).map(\.command), ["qa.recordScreen", "qa.captureArea"])
        XCTAssertTrue(starter.contains { $0.command == "aom.settings" })
        let known = Set(AOMMenuCommandCatalog.all().map(\.id))
        XCTAssertEqual(AOMStatusMenuLayout.normalized(starter, known: known).filter { $0.kind == .command }.count,
                       starter.filter { $0.kind == .command }.count, "every starter command exists")
    }

    // MARK: HB-01 — not hidden while in use

    func testHB01CountdownWaitsWhileTheMenuBarIsInUse() {
        XCTAssertTrue(MenuBarRehidePolicy.isBusy(pointerInMenuBar: false, menuOpen: true, buttonsDown: false))
        XCTAssertFalse(MenuBarRehidePolicy.isBusy(pointerInMenuBar: false, menuOpen: false, buttonsDown: false))
        var deadline: TimeInterval = 15
        // 20 s of browsing a menu: never due.
        for now in stride(from: 0.0, through: 20, by: 0.5) {
            deadline = MenuBarRehidePolicy.deadline(now: now, current: deadline, busy: true, seconds: 15)
            XCTAssertFalse(MenuBarRehidePolicy.shouldCollapse(now: now, deadline: deadline, busy: true))
        }
        XCTAssertEqual(deadline, 35, "counting starts again from the full time")
        XCTAssertFalse(MenuBarRehidePolicy.shouldCollapse(now: 34, deadline: deadline, busy: false))
        XCTAssertTrue(MenuBarRehidePolicy.shouldCollapse(now: 35, deadline: deadline, busy: false))
    }

    // MARK: WIN-01 — the desktop shows through

    func testWIN01MoreColourThanSevenSevenWithoutGhostText() {
        // Codex's measured 7.7 numbers (8/255 margin, 2/255 card in light mode)
        // fit a blur passing ~10 %. 7.9 keeps that heavy blur at every level
        // (a lighter one let the text of windows behind show through) and
        // lets more of its colour through with lighter tints.
        let swing: CGFloat = 199, blur: CGFloat = 0.106
        let old = AOMTranslucency.Level.subtle, level = AOMTranslucency.Level.balanced, clear = AOMTranslucency.Level.clear
        let oldMargin = AOMTranslucency.passThrough(blur: blur, page: old.page.light) * swing
        XCTAssertGreaterThan(AOMTranslucency.passThrough(blur: blur, page: level.page.light) * swing, oldMargin * 1.35)
        XCTAssertGreaterThan(AOMTranslucency.passThrough(blur: blur, page: clear.page.light) * swing, 14)
        for each in AOMTranslucency.Level.allCases { XCTAssertEqual(each.material, .underWindowBackground) }
        XCTAssertEqual(AOMTranslucency.pageAlpha(enabled: true, reduceTransparency: true, increaseContrast: false, dark: false, level: .clear), 1,
                       "Reduce Transparency stays solid at every level")
    }

    // MARK: UI-01 — rows follow the card's corners

    func testUI01RowCardsClipAndPaddedCardsDont() {
        XCTAssertTrue(AOMCardSurface.clipsContent(padding: 0, radius: 12))
        XCTAssertTrue(AOMCardSurface.clipsContent(padding: nil, radius: 12))
        XCTAssertFalse(AOMCardSurface.clipsContent(padding: 14, radius: 12))
    }

    // MARK: Launcher themes

    func testLauncherThemesAreDistinctAndResolve() {
        let ids = AOMLauncherTheme.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(AOMLauncherTheme.named("nope"), .system)
        XCTAssertNil(AOMLauncherTheme.system.appearance)
        XCTAssertEqual(AOMLauncherTheme.named("midnight").appearance?.name, .darkAqua)
        XCTAssertEqual(AOMLauncherTheme.named("rose").appearance?.name, .aqua)
        XCTAssertEqual(QuickCommandPalette.theme(forRow: QuickCommandPalette.themeRowPrefix + "ocean")?.name, "Ocean")
        XCTAssertNil(QuickCommandPalette.theme(forRow: "launcher.opacity.68"))
    }

    func testLauncherOpacityIsClampedAndDefaultsSeeThrough() {
        XCTAssertEqual(AOMLauncherAppearance.clampOpacity(0.1), 0.3)
        XCTAssertEqual(AOMLauncherAppearance.clampOpacity(4), 1)
        XCTAssertEqual(AOMLauncherAppearance.clampOpacity(.nan), AOMLauncherAppearance.defaultOpacity)
        XCTAssertLessThan(AOMLauncherAppearance.defaultOpacity, 0.86, "more of the desktop than 7.7's 86 % base")
    }

    func testThemeScreenIsReachableByName() {
        XCTAssertTrue(QuickCommandPalette.screenCommands.contains { $0.route == .themes })
        XCTAssertEqual(QuickCommandPalette.previewRoute72("themes"), .themes)
        XCTAssertEqual(PaletteRoute.themes.title, "Launcher Theme")
    }
}
