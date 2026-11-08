import AppKit
import Combine
import XCTest
@testable import AllOfMacOS

@MainActor
final class CPU3435Tests: XCTestCase {
    func testShortcutIndexPreservesScopeAndRebuildsOnEdit() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        defer { monitor.unregisterAll() }
        let chord = KeyboardShortcut(keyCode: 12, modifiers: [.command])
        let global = Trigger(name: "Global", input: .keyboardShortcut(chord))
        let local = Trigger(name: "Local", input: .keyboardShortcut(chord), appBundleID: "test.editor")
        var group = ActivationGroup(name: "Editors")
        group.includedBundleIDs = ["test.group"]
        var grouped = Trigger(name: "Group", input: .keyboardShortcut(chord))
        grouped.activationGroupID = group.id
        let unrelated = Trigger(name: "Other", input: .keyboardShortcut(.init(keyCode: 13, modifiers: [.command])))
        monitor.registerTriggers([global, local, grouped, unrelated], groups: [group])
        XCTAssertEqual(monitor.matchingShortcuts(chord, frontBundleID: "test.editor").map(\.id), [local.id])
        XCTAssertEqual(monitor.matchingShortcuts(chord, frontBundleID: "test.group").map(\.id), [grouped.id])
        XCTAssertEqual(monitor.matchingShortcuts(chord, frontBundleID: nil).map(\.id), [global.id])
        XCTAssertTrue(monitor.matchingShortcuts(.init(keyCode: 14, modifiers: []), frontBundleID: nil).isEmpty)
        monitor.registeredTriggers.removeAll { $0.id == local.id }
        XCTAssertEqual(monitor.matchingShortcuts(chord, frontBundleID: "test.editor").map(\.id), [global.id])
        monitor.unregisterAll()
        XCTAssertTrue(monitor.matchingShortcuts(chord, frontBundleID: nil).isEmpty)
    }

    func testIndexedResolutionMatchesOriginalAcrossChordsAndScopes() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        defer { monitor.unregisterAll() }
        var group = ActivationGroup(name: "Block globals")
        group.includedBundleIDs = ["test.group"]
        group.disableGlobalTriggers = true
        var triggers: [Trigger] = []
        for index in 0..<128 {
            var trigger = Trigger(name: "T\(index)", input: .keyboardShortcut(.init(keyCode: UInt16(index % 16),
                modifiers: index % 2 == 0 ? [.command] : [.option, .shift])), appBundleID: index % 3 == 0 ? "test.editor" : nil)
            if index % 5 == 0 { trigger.activationGroupID = group.id }
            triggers.append(trigger)
        }
        monitor.registerTriggers(triggers, groups: [group])
        for app in [nil, "test.editor", "test.group", "test.other"] as [String?] {
            for code: UInt16 in 0..<20 {
                for flags: NSEvent.ModifierFlags in [[], [.command], [.option, .shift]] {
                    let shortcut = KeyboardShortcut(keyCode: code, modifiers: flags)
                    let original = TriggerResolver.resolve(triggers, payload: shortcut, frontBundleID: app,
                        payloadOf: { if case .keyboardShortcut(let chord) = $0.input { return chord }; return nil },
                        appBundleIDOf: { $0.appBundleID }, groups: [group], activationGroupIDOf: { $0.activationGroupID })
                    XCTAssertEqual(monitor.matchingShortcuts(shortcut, frontBundleID: app).map(\.id), original.map(\.id))
                }
            }
        }
    }

    func testMissionControlSuspensionsComposeAndStopDoesNotRestart() {
        let service = MissionControlOverlayService()
        service.start()
        defer { service.stop() }
        XCTAssertTrue(service.isPolling)
        service.setSuspended(true, reason: .system)
        service.setSuspended(true, reason: .screens)
        XCTAssertFalse(service.isPolling)
        service.start()
        XCTAssertFalse(service.isPolling, "Repeated start cannot override sleep")
        service.setSuspended(false, reason: .system)
        XCTAssertFalse(service.isPolling, "Display is still asleep")
        service.setSuspended(false, reason: .screens)
        XCTAssertTrue(service.isPolling)
        service.stop()
        service.setSuspended(false, reason: .session)
        XCTAssertFalse(service.isPolling)
    }

    func testHiddenSystemToolsDoNotReadOrPublishOnRefresh() {
        let defaults = UserDefaults(suiteName: "CPU3435Tests.\(UUID().uuidString)")!
        let model = SystemToolsModel(defaults: defaults)
        var emissions = 0
        let subscription = model.objectWillChange.sink { emissions += 1 }
        model.refreshStates()
        model.refreshAudioStates()
        model.refreshSoon()
        model.refreshSlowStates(force: true)
        XCTAssertFalse(model.slowRefreshRunning)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertEqual(emissions, 0)
        withExtendedLifetime(subscription) {}
    }

    func testAudioFallbackKeepsUniqueOwnershipAndPathBoundaries() {
        let apps = [AudioOwnerIdentity(pid: 1, bundleID: "test.browser", bundlePath: "/Applications/Browser.app"),
                    AudioOwnerIdentity(pid: 2, bundleID: "test.other", bundlePath: "/Applications/Other.app")]
        XCTAssertEqual(AudioOwnerIdentity.uniqueOwner(bundleID: "test.browser.helper", processPath: nil, among: apps), 1)
        XCTAssertEqual(AudioOwnerIdentity.uniqueOwner(bundleID: "helper", processPath: "/Applications/Browser.app/Contents/Helper", among: apps), 1)
        XCTAssertNil(AudioOwnerIdentity.uniqueOwner(bundleID: "test.browser2", processPath: "/Applications/Browser.app2/Helper", among: apps))
        XCTAssertNil(AudioOwnerIdentity.uniqueOwner(bundleID: "test.browser", processPath: "/Applications/Other.app/Helper", among: apps), "Conflicting evidence must remain ambiguous")
        XCTAssertNil(AudioOwnerIdentity.uniqueOwner(bundleID: "unknown", processPath: nil, among: apps))
    }
}

@MainActor
private final class CPUVisibilityWindow: NSWindow {
    var shown = true
    var uncovered = true
    override var isVisible: Bool { shown }
    override var occlusionState: NSWindow.OcclusionState { uncovered ? [.visible] : [] }
}

extension CPU3435Tests {
    func testVisibilityReaderBalancesDemandAndIgnoresOtherWindows() async throws {
        _ = NSApplication.shared
        let window = CPUVisibilityWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let other = CPUVisibilityWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let view = AOMWindowVisibilityReader.WindowView()
        var states: [Bool] = []
        view.changed = { states.append($0) }
        window.contentView = view
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true])
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true], "Expose must not add another sensor demand")
        window.uncovered = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true, false])
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: other)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true, false], "A floating panel cannot resume a hidden page")
        window.uncovered = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true, false, true])
        view.stop()
        view.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(states, [true, false, true, false], "Dismantling balances exactly one outstanding demand")
        window.contentView = nil
    }
}
