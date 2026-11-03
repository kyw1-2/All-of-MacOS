import XCTest
import AppKit
import Combine
import IOKit.pwr_mgt
@testable import AllOfMacOS

@MainActor
final class Efficiency3411Tests: XCTestCase {
    func testPermissionRevocationDebouncesThenRecoversWithoutRestart() {
        var trusted = true
        var prompts = 0
        var recoveries = 0
        let center = NotificationCenter()
        let watchdog = PermissionWatchdog(trustCheck: { trusted }, requestPrompt: { prompts += 1 },
                                           notifications: center, workspaceNotifications: NotificationCenter())
        watchdog.onRecovered = { recoveries += 1 }
        watchdog.start()
        defer { watchdog.stop() }
        XCTAssertEqual(watchdog.pollingInterval, 10)
        trusted = false
        watchdog.check()
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(watchdog.pollingInterval, 2)
        trusted = true
        watchdog.check()
        XCTAssertEqual(recoveries, 0, "One failed probe must not restart all input monitors.")
        XCTAssertEqual(watchdog.pollingInterval, 10)
        trusted = false
        watchdog.check()
        watchdog.check()
        watchdog.check()
        XCTAssertEqual(prompts, 1)
        trusted = true
        watchdog.check()
        watchdog.check()
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(watchdog.pollingInterval, 10)
    }

    func testActivationAndWakeCheckImmediatelyAndStopRemovesObservers() {
        var checks = 0
        var trusted = false
        var recovered = 0
        let center = NotificationCenter(), workspace = NotificationCenter()
        let watchdog = PermissionWatchdog(trustCheck: { checks += 1; return trusted }, requestPrompt: {},
                                           notifications: center, workspaceNotifications: workspace)
        watchdog.onRecovered = { recovered += 1 }
        watchdog.start()
        watchdog.start()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(watchdog.pollingInterval, 2)
        trusted = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(recovered, 1)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(checks, 3)
        watchdog.stop()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        watchdog.check()
        XCTAssertEqual(checks, 3)
        XCTAssertNil(watchdog.pollingInterval)
    }

    func testRecoveryCallbackMayStopWatchdogWithoutRescheduling() {
        var trusted = false
        let watchdog = PermissionWatchdog(trustCheck: { trusted }, requestPrompt: {},
                                           notifications: NotificationCenter(), workspaceNotifications: NotificationCenter())
        watchdog.onRecovered = { [weak watchdog] in watchdog?.stop() }
        watchdog.start()
        trusted = true
        watchdog.check()
        XCTAssertNil(watchdog.pollingInterval)
    }

    func testStatusSnapshotPublishesOnceAndIgnoresUnchangedSamples() {
        let monitor = SystemStatusMonitor()
        var snapshots: [SystemStatusMonitor.Snapshot] = []
        let token = monitor.$snapshot.dropFirst().sink { snapshots.append($0) }
        var next = monitor.snapshot
        next.cpuPercent = 42
        next.uptime = 300
        next.memory = .init(used: 1024, total: 4096, pressureLevel: 1)
        next.hasBattery = false
        monitor.publish(next)
        monitor.publish(next)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first, next)
        XCTAssertEqual(monitor.cpuPercent, 42)
        XCTAssertEqual(monitor.memory?.used, 1024)
        next.cpuPercent = 10
        monitor.publish(next)
        XCTAssertEqual(snapshots.count, 2)
        withExtendedLifetime(token) {}
    }

    func testSlowRefreshCadenceAllowsActionsAndInvalidationImmediately() {
        var gate = RefreshThrottle(interval: 30)
        XCTAssertTrue(gate.shouldStart(at: 100))
        for time in [104.0, 108, 112, 116, 120, 124, 128] {
            XCTAssertFalse(gate.shouldStart(at: time))
        }
        XCTAssertTrue(gate.shouldStart(at: 132))
        XCTAssertTrue(gate.shouldStart(at: 133, force: true))
        XCTAssertFalse(gate.shouldStart(at: 136))
        gate.invalidate()
        XCTAssertTrue(gate.shouldStart(at: 137))
        XCTAssertTrue(gate.shouldStart(at: 10), "A reset monotonic clock must not stall refreshes.")
    }

    func testHiddenToolsDoNotLaunchSlowRefreshEvenWhenForced() {
        let model = SystemToolsModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        model.refreshSlowStates(force: true)
        XCTAssertFalse(model.slowRefreshRunning)
        let generation = model.slowRefreshGeneration
        model.disappear()
        XCTAssertGreaterThan(model.slowRefreshGeneration, generation)
    }

    func testNativeAssertionsFilterInactiveAndDeduplicateRows() {
        func entry(_ type: String, _ level: Int?, _ name: String) -> [String: Any] {
            var value: [String: Any] = [kIOPMAssertionTypeKey as String: type, kIOPMAssertionNameKey as String: name]
            if let level { value[kIOPMAssertionLevelKey as String] = NSNumber(value: level) }
            return value
        }
        let active = entry("PreventUserIdleSystemSleep", 255, "Playback")
        let input: [NSNumber: [[String: Any]]] = [
            42: [active, active, entry("PreventUserIdleSystemSleep", 0, "Inactive"),
                 entry("UserIsActive", 255, "Input"), entry("PreventUserIdleSystemSleep", nil, "Unknown")],
            7: [entry("PreventUserIdleDisplaySleep", 255, "Presentation")],
            -1: [active]
        ]
        var resolutions: [pid_t] = []
        let values = PowerTools.parseNativeAssertions(input) { resolutions.append($0); return "App \($0)" }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.map(\.pid)), [7, 42])
        XCTAssertEqual(Set(resolutions), [7, 42])
        XCTAssertEqual(resolutions.count, 2)
        XCTAssertTrue(values.contains { $0.pid == 42 && $0.name == "Playback" && $0.process == "App 42" })
        XCTAssertTrue(PowerTools.parseNativeAssertions([:]) { _ in XCTFail(); return "" }.isEmpty)
    }

    func testMergedMouseMonitorRoutesEachButtonExactlyOnce() throws {
        final class Probe: TrackpadMonitor {
            var presses: [NSEvent.EventType] = []
            var releases: [NSEvent.EventType] = []
            override func handleMousePress(_ event: NSEvent? = nil) { if let event { presses.append(event.type) } }
            override func handleMouseRelease(_ event: NSEvent? = nil) { if let event { releases.append(event.type) } }
        }
        let monitor = Probe(systemMonitoringEnabled: false, frontmostBundleID: { nil })
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                                       timestamp: 1, windowNumber: 0, context: nil,
                                                       eventNumber: 1, clickCount: 1, pressure: 0))
            monitor.receiveMonitoredEvent(event)
        }
        XCTAssertEqual(monitor.presses, [.leftMouseDown, .rightMouseDown])
        XCTAssertEqual(monitor.releases, [.leftMouseUp, .rightMouseUp])
    }
}
