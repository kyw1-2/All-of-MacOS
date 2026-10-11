import XCTest
import AppKit
@testable import AllOfMacOS

final class TriggerWorkspaceTests: XCTestCase {
    private func tap(_ name: String, app: String? = nil) -> Trigger {
        Trigger(name: name, input: .trackpadGesture(.threeFingerTap), appBundleID: app)
    }
    func testQuotedFiltersAndNestedActionLabels() {
        var preset = Preset(name: "Search")
        let group = ActivationGroup(name: "Work Desk")
        preset.activationGroups = [group]
        var trigger = tap("Workspace")
        trigger.activationGroupID = group.id; trigger.isEnabled = false
        var action = TriggerAction(actionType: .showHUD)
        action.parameters.label = "Paste preview"
        var parent = TriggerAction(actionType: .actionGroup)
        parent.parameters.children = [action]
        trigger.actions = [parent]
        XCTAssertTrue(TriggerListQuery.matches(trigger, query: "group:\"Work Desk\" type:trackpad action:paste enabled:no", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trigger, query: "enabled:yes", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trigger, query: "app:Work", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trigger, query: "enabled:maybe", preset: preset))
        XCTAssertEqual(TriggerListQuery.tokens("group:\"Work Desk\" enabled:no"), ["group:Work Desk", "enabled:no"])
    }
    func testSearchUsesInputAndAppNameButDoesNotIndexTextPayload() {
        var preset = Preset(name: "Search")
        preset.appTargets = [AppTarget(id: UUID(), bundleID: "com.apple.Safari", name: "Safari", iconPath: nil)]
        var trigger = tap("", app: "com.apple.Safari")
        var action = TriggerAction(actionType: .typeText)
        action.parameters.text = "private-fixture-value"
        trigger.actions = [action]
        XCTAssertTrue(TriggerListQuery.matches(trigger, query: "app:safari 3", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trigger, query: "private-fixture-value", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trigger, query: "app:", preset: preset))
    }

    /// `type:` selects one input family, so a query for another family must not
    /// match. Only the positive direction was covered before, which meant a
    /// filter that returned everything would still pass.
    func testTypeFilterSelectsExactlyOneInputFamily() {
        let preset = Preset(name: "Types")
        let trackpad = tap("Trackpad binding")
        let keyboard = Trigger(name: "Keyboard binding",
                               input: .keyboardShortcut(.init(keyCode: 0, modifiers: .command)))

        XCTAssertTrue(TriggerListQuery.matches(trackpad, query: "type:trackpad", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(keyboard, query: "type:trackpad", preset: preset),
                       "a keyboard binding must not answer a trackpad query")
        XCTAssertTrue(TriggerListQuery.matches(keyboard, query: "type:keyboard", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trackpad, query: "type:keyboard", preset: preset),
                       "a trackpad binding must not answer a keyboard query")
    }

    /// The aliases exist so a user can type the word they think of rather than
    /// the enum's spelling.
    ///
    /// A filter value cannot contain a space: the tokenizer splits on
    /// whitespace, so the two-word aliases are reachable only through a quoted
    /// value. That is the same rule `group:"Work Desk"` follows, and the
    /// unquoted form is asserted below so the split stays visible.
    func testTypeFilterAcceptsAliasesAndRejectsUnknownValues() {
        let preset = Preset(name: "Aliases")
        let mouse = Trigger(name: "Middle click", input: .mouseButton(.button3))
        let drawing = Trigger(name: "Triangle", input: .drawingPattern("Triangle"))

        XCTAssertTrue(TriggerListQuery.matches(mouse, query: "type:mouse", preset: preset))
        XCTAssertTrue(TriggerListQuery.matches(mouse, query: "type:\"normal mouse\"", preset: preset))
        XCTAssertTrue(TriggerListQuery.matches(drawing, query: "type:drawing", preset: preset))
        XCTAssertTrue(TriggerListQuery.matches(drawing, query: "type:\"mouse gestures\"", preset: preset))

        XCTAssertFalse(TriggerListQuery.matches(mouse, query: "type:trackpad", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(drawing, query: "type:keyboard", preset: preset))

        // Unquoted, the second word becomes a separate term and the phrase
        // stops selecting the family it names.
        XCTAssertFalse(TriggerListQuery.matches(drawing, query: "type:mouse gestures", preset: preset))
        XCTAssertEqual(TriggerListQuery.tokens("type:mouse gestures"), ["type:mouse", "gestures"])
    }

    /// The drawing alias deliberately carries "mouse", because a drawing
    /// gesture is also reached as a mouse gesture. Both families answering
    /// `type:mouse` is the intended overlap, not a leak — the trackpad family
    /// must still reject it.
    func testMouseAliasOverlapsDrawingsButNotTrackpad() {
        let preset = Preset(name: "Overlap")
        let mouse = Trigger(name: "Middle click", input: .mouseButton(.button3))
        let drawing = Trigger(name: "Triangle", input: .drawingPattern("Triangle"))
        let trackpad = tap("Swipe")

        XCTAssertTrue(TriggerListQuery.matches(mouse, query: "type:mouse", preset: preset))
        XCTAssertTrue(TriggerListQuery.matches(drawing, query: "type:mouse", preset: preset))
        XCTAssertFalse(TriggerListQuery.matches(trackpad, query: "type:mouse", preset: preset))
    }

    func testLegacyEqualOrdersReorderOnlyPeersAndPersist() throws {
        var preset = Preset(name: "Ordering")
        let a = tap("A"), b = tap("B"), c = tap("C", app: "another.app")
        let key = Trigger(name: "Keys", input: .keyboardShortcut(.init(keyCode: 0, modifiers: .command)))
        let group = ActivationGroup(name: "Work")
        preset.activationGroups = [group]
        var grouped = tap("Group"); grouped.activationGroupID = group.id
        preset.triggers = [b, c, key, a, grouped]
        XCTAssertFalse(preset.moveTrigger(a.id, offset: -1))
        XCTAssertTrue(preset.moveTrigger(b.id, offset: -1))
        XCTAssertEqual(preset.movePeers(of: a).map(\.id), [b.id, a.id])
        XCTAssertEqual(preset.triggers.first { $0.id == c.id }, c)
        XCTAssertEqual(preset.triggers.first { $0.id == key.id }, key)
        XCTAssertEqual(preset.triggers.first { $0.id == grouped.id }, grouped)
        XCTAssertFalse(preset.moveTrigger(a.id, offset: 2))
        let restored = try PresetCodec.decode(PresetCodec.encode(preset))
        XCTAssertEqual(restored.movePeers(of: a).map(\.id), [b.id, a.id])
        XCTAssertEqual(restored.triggers.map(\.actions), preset.triggers.map(\.actions))
    }
    func testPinnedManualOrderSurvivesCoreDataRoundTrip() throws {
        let store = try TrackpadPresetStore(url: nil, inMemory: true)
        var preset = Preset(name: "Stored order")
        var a = tap("A"), b = tap("B")
        a.isFavorite = true; b.isFavorite = true
        preset.triggers = [a, b]
        XCTAssertTrue(preset.moveTrigger(b.id, offset: -1))
        try store.save(preset)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.movePeers(of: a).map(\.id), [b.id, a.id])
        XCTAssertTrue(restored.triggers.allSatisfy(\.isFavorite))
    }

    func testNewTriggersAppendAndOverflowNormalizes() {
        var preset = Preset(name: "Append")
        var old = tap("Z"); old.order = Int.max
        let new = tap("A")
        preset.triggers = [old]; preset.addTrigger(new)
        XCTAssertEqual(preset.movePeers(of: old).map(\.id), [old.id, new.id])
        XCTAssertEqual(preset.triggers.map(\.order), [0, 1])
    }
    func testFavoritesAreBackwardCompatibleAndDoNotRefreshHardware() throws {
        var trigger = tap("Z")
        let before = MonitorBindings([trigger], groups: [])
        trigger.isFavorite = true
        XCTAssertEqual(before, MonitorBindings([trigger], groups: []))
        XCTAssertEqual(TriggerListQuery.sorted([tap("A"), trigger], mode: .alphabetical).first?.id, trigger.id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? [String: Any])
        json.removeValue(forKey: "isFavorite")
        XCTAssertFalse(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: json)).isFavorite)
        XCTAssertTrue(try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger)).isFavorite)
    }
    func testConflictKeysSeparateScopeModifiersAndKeyboardPhase() {
        let a = tap("A"); var b = tap("B"); b.isEnabled = false
        var modified = tap("Modifier"); modified.requiredModifiers = NSEvent.ModifierFlags.command.rawValue
        let app = tap("App", app: "other.app")
        var group = tap("Group"); group.activationGroupID = UUID()
        let counts = TriggerConflictKey.counts([a, b, modified, app, group])
        XCTAssertEqual(counts[a.id], 1); XCTAssertEqual(counts[b.id], 1)
        XCTAssertEqual(counts[modified.id], 0); XCTAssertEqual(counts[app.id], 0); XCTAssertEqual(counts[group.id], 0)
        var key = Trigger(name: "Key", input: .keyboardShortcut(.init(keyCode: 0, modifiers: .command)))
        var release = key; release.keyboardPhase = .keyUp
        key.keyboardPhase = .keyDown
        XCTAssertNotEqual(TriggerConflictKey(key), TriggerConflictKey(release))
    }
    func testSingleInstanceLeaseExcludesSecondOwnerAndReleases() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var first: SingleInstanceLease? = try XCTUnwrap(SingleInstanceLease(path: path))
        XCTAssertNotNil(first); XCTAssertNil(SingleInstanceLease(path: path))
        first = nil
        XCTAssertNotNil(SingleInstanceLease(path: path))
    }
    func testSingleInstanceLeaseRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data().write(to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(SingleInstanceLease(path: link.path))
    }
    @MainActor func testGlobalSearchIgnoresSelectedCategoryAndPersistsManualMoveInIsolation() throws {
        XCTAssertTrue(PresetManager.isRunningTests)
        XCTAssertTrue(PresetManager.presetFilePath.contains("AOMTestPresets-"))
        let state = AppState(); state.currentPreset = Preset(name: "Isolated")
        let a = tap("A"), b = tap("B"), remote = tap("Remote", app: "other.app")
        state.currentPreset.triggers = [a, b, remote]
        state.selectedAppTarget = .allApps; state.selectedTriggerCategory = .keyboard
        state.triggerSearch = "Remote"
        XCTAssertEqual(state.displayedTriggers.map(\.id), [remote.id])
        XCTAssertFalse(state.canMoveTrigger(a, offset: 1))
        state.triggerSearch = ""; state.selectedTriggerCategory = .trackpad
        state.moveTrigger(b, offset: -1)
        XCTAssertEqual(state.displayedTriggers.map(\.id), [b.id, a.id])
        XCTAssertEqual(try XCTUnwrap(PresetManager.loadPreset()).movePeers(of: a).map(\.id), [b.id, a.id])
        state.triggerSortMode = .alphabetical
        XCTAssertEqual(state.displayedTriggers.map(\.id), [a.id, b.id])
        XCTAssertFalse(state.canMoveTrigger(a, offset: 1))
    }
}
