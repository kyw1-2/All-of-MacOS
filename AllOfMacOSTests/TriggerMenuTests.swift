import XCTest
import AppKit
@testable import AllOfMacOS

/// Exercises the status-menu trigger list. The bundle is injected rather than
/// read from `NSWorkspace`, so the cases do not depend on which app happens to
/// be frontmost while the suite runs.
///
/// The tests never invoke `toggleTrigger`: that writes to the live preset.
@MainActor
final class TriggerMenuTests: XCTestCase {

    private let testBundle = "com.example.frontmost"

    /// A state whose preset holds only what the case puts in it.
    private func emptyState() -> AppState {
        let state = AppState()
        state.currentPreset.triggers.removeAll()
        state.currentPreset.appTargets.removeAll()
        return state
    }

    private func target(_ bundleID: String?, name: String) -> AppTarget {
        AppTarget(id: UUID(), bundleID: bundleID, name: name, iconPath: nil)
    }

    private func trackpadTrigger(_ gesture: TrackpadGesture, name: String,
                                 bundleID: String? = nil) -> Trigger {
        var trigger = Trigger(name: name, input: .trackpadGesture(gesture), appBundleID: bundleID)
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        return trigger
    }

    // MARK: - Section shape

    func testSectionIsOmittedWhenNothingIsBound() {
        let state = emptyState()
        // An empty section would be worse than none.
        XCTAssertNil(TriggerMenu.build(from: state, frontBundleID: testBundle, appName: "Test"))
    }

    func testSectionIsOmittedWhenTheFrontmostAppHasNoTarget() {
        let state = emptyState()
        state.currentPreset.triggers = [trackpadTrigger(.twoFingerTap, name: "Tap")]
        // No app target at all, so nothing is scoped to this app.
        XCTAssertNil(TriggerMenu.build(from: state, frontBundleID: testBundle, appName: "Test"))
    }

    func testSectionListsTheTriggersBoundToTheFrontmostApp() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App")]
        state.currentPreset.triggers = [trackpadTrigger(.threeFingerSwipeUp, name: "Swipe",
                                                        bundleID: testBundle)]

        let section = try XCTUnwrap(TriggerMenu.build(from: state, frontBundleID: testBundle,
                                                      appName: "Test App"))
        XCTAssertEqual(section.title, "Test App")
        let titles = allTitles(in: try XCTUnwrap(section.submenu))
        XCTAssertTrue(titles.contains { $0.contains("Swipe") }, "got \(titles)")
        XCTAssertTrue(titles.contains("Trackpad"), "triggers must be grouped by input family")
    }

    func testGlobalTriggersAppearWithANoteSayingWhereTheyComeFrom() throws {
        let state = emptyState()
        // A global target carries a nil bundleID, not an empty string.
        state.currentPreset.appTargets = [target(nil, name: "All Apps")]
        state.currentPreset.triggers = [trackpadTrigger(.twoFingerTap, name: "Global Tap")]

        let section = try XCTUnwrap(TriggerMenu.build(from: state, frontBundleID: testBundle,
                                                      appName: "Test App"))
        let titles = allTitles(in: try XCTUnwrap(section.submenu))
        XCTAssertTrue(titles.contains { $0.contains("Global Tap") }, "got \(titles)")
        XCTAssertTrue(titles.contains { $0.contains("Global bindings") },
                      "a global binding must say so, got \(titles)")
    }

    func testAppSpecificTriggersSuppressTheGlobalNote() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App"),
                                          target(nil, name: "All Apps")]
        state.currentPreset.triggers = [
            trackpadTrigger(.threeFingerTap, name: "App Tap", bundleID: testBundle),
            trackpadTrigger(.twoFingerTap, name: "Global Tap"),
        ]

        let section = try XCTUnwrap(TriggerMenu.build(from: state, frontBundleID: testBundle,
                                                      appName: "Test App"))
        let titles = allTitles(in: try XCTUnwrap(section.submenu))
        // Both are listed, but the note is only for a purely-global list.
        XCTAssertTrue(titles.contains { $0.contains("App Tap") })
        XCTAssertTrue(titles.contains { $0.contains("Global Tap") })
        XCTAssertFalse(titles.contains { $0.contains("Global bindings") })
    }

    func testKeyboardTriggersAreGroupedUnderKeyboard() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App")]
        let shortcut = KeyboardShortcut(keyCode: 1, modifiers: [.command])
        state.currentPreset.triggers = [
            Trigger(name: "Shortcut", input: .keyboardShortcut(shortcut), appBundleID: testBundle)
        ]

        let section = try XCTUnwrap(TriggerMenu.build(from: state, frontBundleID: testBundle,
                                                      appName: "Test App"))
        let titles = allTitles(in: try XCTUnwrap(section.submenu))
        XCTAssertTrue(titles.contains("Keyboard"), "got \(titles)")
    }

    func testDisabledTriggersStayListedButUnchecked() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App")]
        var trigger = trackpadTrigger(.twoFingerTap, name: "Disabled Tap", bundleID: testBundle)
        trigger.isEnabled = false
        state.currentPreset.triggers = [trigger]

        let submenu = try XCTUnwrap(try XCTUnwrap(TriggerMenu.build(from: state,
                                                                    frontBundleID: testBundle,
                                                                    appName: "Test")).submenu)
        let entry = try XCTUnwrap(submenu.items.first { $0.title.contains("Disabled Tap") },
                                  "a disabled trigger must still be listed")
        // Dimmed rather than hidden, so an accidental disable does not look like
        // a lost binding.
        XCTAssertEqual(entry.state, NSControl.StateValue.off)
    }

    func testTriggerItemsCarryATargetAndARequest() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App")]
        state.currentPreset.triggers = [trackpadTrigger(.twoFingerTap, name: "Tap",
                                                        bundleID: testBundle)]

        let submenu = try XCTUnwrap(try XCTUnwrap(TriggerMenu.build(from: state,
                                                                    frontBundleID: testBundle,
                                                                    appName: "Test")).submenu)
        let actionable = submenu.items.filter { $0.action != nil && $0.submenu == nil }
        XCTAssertFalse(actionable.isEmpty, "the list must offer at least one item")
        for item in actionable {
            XCTAssertNotNil(item.target, "\(item.title) has an action but no target")
            XCTAssertNotNil(item.representedObject, "\(item.title) has an action but no request")
        }
    }

    func testAnUnnamedTriggerFallsBackToItsInputName() throws {
        let state = emptyState()
        state.currentPreset.appTargets = [target(testBundle, name: "Test App")]
        // An empty label means the gesture itself is the only name available.
        state.currentPreset.triggers = [trackpadTrigger(.fourFingerTap, name: "",
                                                        bundleID: testBundle)]

        let section = try XCTUnwrap(TriggerMenu.build(from: state, frontBundleID: testBundle,
                                                      appName: "Test"))
        let titles = allTitles(in: try XCTUnwrap(section.submenu))
        XCTAssertTrue(titles.contains { $0.contains("4 Finger Tap") },
                      "an unnamed trigger must show its input, got \(titles)")
    }

    // MARK: - Enabling by id

    func testSetTriggerEnabledFlipsOnlyTheNamedTrigger() {
        let state = emptyState()
        let a = trackpadTrigger(.twoFingerTap, name: "A")
        let b = trackpadTrigger(.threeFingerTap, name: "B")
        state.currentPreset.triggers = [a, b]

        state.setTriggerEnabled(false, triggerID: a.id)

        XCTAssertEqual(state.currentPreset.triggers.first { $0.id == a.id }?.isEnabled, false)
        XCTAssertEqual(state.currentPreset.triggers.first { $0.id == b.id }?.isEnabled, true,
                       "an unrelated trigger must not be touched")
    }

    func testSetTriggerEnabledIgnoresAnUnknownID() {
        let state = emptyState()
        let a = trackpadTrigger(.twoFingerTap, name: "A")
        state.currentPreset.triggers = [a]

        // The menu may be built before a preset change removes the trigger.
        state.setTriggerEnabled(false, triggerID: UUID())

        XCTAssertEqual(state.currentPreset.triggers.count, 1,
                       "an unknown id must not create a trigger")
        XCTAssertEqual(state.currentPreset.triggers.first?.isEnabled, true)
    }

    func testSetTriggerEnabledIsANoOpWhenAlreadyInThatState() {
        let state = emptyState()
        let a = trackpadTrigger(.twoFingerTap, name: "A")
        state.currentPreset.triggers = [a]
        state.setTriggerEnabled(false, triggerID: a.id)

        let before = state.currentPreset.triggers.first
        state.setTriggerEnabled(false, triggerID: a.id)
        XCTAssertEqual(state.currentPreset.triggers.first, before,
                       "setting the state it already has must change nothing")
    }

    // MARK: - Helpers

    private func allTitles(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            var all = [item.title]
            if let sub = item.submenu { all += allTitles(in: sub) }
            return all
        }
    }
}
