import XCTest
import AppKit
@testable import AllOfMacOS

/// The UGREEN side buttons arrive as ⌃fn← / ⌃fn→ with a single-press and a
/// double-press trigger on the same shortcut (the user's preset).
final class SideButtonDoublePressTests: XCTestCase {
    private var now: TimeInterval = 100
    private var pending: [(at: TimeInterval, work: () -> Void)] = []
    private var fired: [String] = []

    private func makeMonitor(defaults: UserDefaults) -> KeyboardMonitor {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false, builtinHandler: { _, _ in false })
        monitor.clock = { [unowned self] in now }
        monitor.scheduler = { [unowned self] delay, work in pending.append((now + delay, work)) }
        monitor.timingDefaults = defaults
        monitor.onFire = { [unowned self] in fired.append($0.name) }
        let shortcut = KeyboardShortcut(keyCode: 123, modifiers: NSEvent.ModifierFlags(rawValue: 8650752))
        var single = Trigger(name: "single", input: .keyboardShortcut(shortcut)); single.pressCount = 1
        var double = Trigger(name: "double", input: .keyboardShortcut(shortcut)); double.pressCount = 2
        monitor.registerTriggers([single, double])
        return monitor
    }

    private func advance(to time: TimeInterval) {
        now = time
        let due = pending.filter { $0.at <= time }
        pending.removeAll { $0.at <= time }
        due.forEach { $0.work() }
    }

    private func click(_ monitor: KeyboardMonitor, at time: TimeInterval) {
        let flags = NSEvent.ModifierFlags(rawValue: 8650752)
        advance(to: time)
        _ = monitor.handleInput(keyCode: 123, modifiers: flags, isDown: true)
        advance(to: time + 0.08)
        _ = monitor.handleInput(keyCode: 123, modifiers: flags, isDown: false)
    }

    func run(gap: TimeInterval, defaults: UserDefaults = UserDefaults(suiteName: "t-\(UUID())")!) -> [String] {
        fired = []; pending = []; now = 100
        let monitor = makeMonitor(defaults: defaults)
        click(monitor, at: 100)
        click(monitor, at: 100 + gap)
        advance(to: 105)
        return fired
    }

    func testQuickDoubleFiresDoubleOnly() {
        XCTAssertEqual(run(gap: 0.2), ["double"])
    }

    func testSingleFiresSingle() {
        fired = []; pending = []; now = 100
        let monitor = makeMonitor(defaults: UserDefaults(suiteName: "t-\(UUID())")!)
        click(monitor, at: 100)
        advance(to: 105)
        XCTAssertEqual(fired, ["single"])
    }

    func testRelaxedDoubleWithinSystemIntervalFiresDouble() {
        // A comfortable double press on a side button is 300–450 ms apart;
        // 3.6.0's fixed 300 ms window split it into two singles.
        let d = UserDefaults(suiteName: "t-\(UUID())")!
        d.set(500, forKey: TriggerTimingSettings.keyboardDoublePressKey)
        XCTAssertEqual(run(gap: 0.4, defaults: d), ["double"])
    }

    func testDefaultWindowFollowsSystemDoubleClickSpeed() throws {
        try XCTSkipIf(NSEvent.doubleClickInterval < 0.45, "This Mac uses a fast double-click speed")
        XCTAssertEqual(run(gap: 0.4), ["double"])
    }
}
