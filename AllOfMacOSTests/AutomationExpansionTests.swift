import XCTest
import CoreMIDI
@testable import AllOfMacOS

final class AutomationExpansionTests: XCTestCase {
    func testMenusPersistActionsAndWidgetsWithoutLosingIDs() throws {
        let suite = "AOM.MenuTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FloatingMenuStore(defaults: defaults)
        var menu = FloatingMenuDefinition()
        menu.items = [FloatingMenuItem(title: "Time", kind: "clock"),
                      FloatingMenuItem(title: "Value", kind: "variable", variableName: "result"),
                      FloatingMenuItem(title: "Run", actions: [TriggerAction(actionType: .volumeUp), TriggerAction(actionType: .wait)])]
        try store.save(menu)
        XCTAssertEqual(FloatingMenuStore(defaults: defaults).menus, [menu])
        menu.columns = 3; try store.save(menu)
        XCTAssertEqual(store.menus.count, 1)
        XCTAssertEqual(store.find(menu.name), menu)
        XCTAssertEqual(store.find(menu.id.uuidString), menu)
        store.remove(menu.id)
        XCTAssertTrue(FloatingMenuStore(defaults: defaults).menus.isEmpty)
    }
    func testMenuRejectsInvalidImportBeforeReplacingStoredData() throws {
        let suite = "AOM.MenuTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FloatingMenuStore(defaults: defaults)
        let original = FloatingMenuDefinition(); try store.save(original)
        var bad = original; bad.items.append(bad.items[0])
        XCTAssertThrowsError(try store.save(bad))
        bad = original; bad.items[0].kind = "unsupported"
        XCTAssertThrowsError(try store.save(bad))
        bad = original; bad.columns = 0
        XCTAssertThrowsError(try store.save(bad))
        XCTAssertEqual(store.menus, [original])
    }
    func testMIDIStreamRetainsRunningStatusAndIgnoresRealtimeBytes() {
        var decoder = MIDIMessageDecoder()
        XCTAssertTrue(decoder.consume([0x92, 60]).isEmpty)
        let messages = decoder.consume([0xF8, 120, 61, 0, 0xB2, 7, 64, 0xF0, 12, 13, 0xF7, 11, 12])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].status, 0x90); XCTAssertEqual(messages[0].channel, 3)
        XCTAssertEqual(messages[0].number, 60); XCTAssertEqual(messages[0].value, 120)
        XCTAssertEqual(messages[1].status, 0x80, "zero-velocity Note On is release")
        XCTAssertEqual(messages[2].status, 0xB0)
    }
    func testMIDIPacketTraversalReadsOriginalMultiPacketAllocation() throws {
        let capacity = 4096
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        let list = memory.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        let first = Array(repeating: UInt8(0xF8), count: 300) + [0x90, 60, 127]
        let second: [UInt8] = [0xB0, 7, 80]
        packet = try XCTUnwrap(first.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, packet, 1, $0.count, $0.baseAddress!) })
        _ = try XCTUnwrap(second.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, packet, 2, $0.count, $0.baseAddress!) })
        XCTAssertEqual(list.pointee.numPackets, 2)
        XCTAssertEqual(MIDIInputMonitor.packetBytes(UnsafePointer(list)), first + second)
    }
    func testDeviceFilterAndValueRangesAreAppliedBeforeDispatch() {
        let trigger = SystemTriggerKind.midiMessage(device: "regex:^Keys [0-9]+$", status: 0xB0, channel: 2, number: 7, minimumValue: 64, maximumValue: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(trigger, .midi(device: "Keys 49", status: 0xB0, channel: 2, number: 7, value: 90)))
        XCTAssertFalse(SystemSignalMatcher.matches(trigger, .midi(device: "Keys 49", status: 0xB0, channel: 3, number: 7, value: 90)))
        XCTAssertFalse(SystemSignalMatcher.matches(trigger, .midi(device: "Keys 49", status: 0xB0, channel: 2, number: 7, value: 12)))
        XCTAssertTrue(SystemSignalMatcher.networkMatches("regex:^Office-(A|B)$", "Office-A"))
        XCTAssertFalse(SystemSignalMatcher.networkMatches("Office", "Office-A"), "plain SSID remains exact")
        XCTAssertFalse(SystemSignalMatcher.nameMatches("regex:[", "anything"), "bad regex fails closed")
        let gamepad = SystemTriggerKind.gamepadButton(device: "Xbox", control: "a", pressed: true)
        XCTAssertTrue(SystemSignalMatcher.matches(gamepad, .gamepad(device: "Xbox Wireless", control: "a", pressed: true)))
        XCTAssertFalse(SystemSignalMatcher.matches(gamepad, .gamepad(device: "Xbox Wireless", control: "a", pressed: false)))
    }
    func testHardwareTriggersRoundTripAndOnlyInstallNeededSources() throws {
        let kinds: [SystemTriggerKind] = [.midiMessage(device: "", status: 144, channel: 0, number: 60, minimumValue: 1, maximumValue: 127), .gamepadButton(device: "", control: "a", pressed: true)]
        for kind in kinds { XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: JSONEncoder().encode(kind)), kind) }
        XCTAssertEqual(SignalSource.needs(for: kinds), [.midi, .gamepad])
    }
    func testScriptResultStoresFailureAndTruncatesToWorkflowLimit() {
        let name = "script_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { [name, name + "_exitCode", name + "_timedOut"].forEach(WorkflowVariables.remove) }
        ScriptActionResults.record(name: name, output: String(repeating: "z", count: 1_000), code: 9, timedOut: true)
        XCTAssertEqual(WorkflowVariables.value(name)?.count, 512)
        XCTAssertEqual(WorkflowVariables.value(name + "_exitCode"), "9")
        XCTAssertEqual(WorkflowVariables.value(name + "_timedOut"), "true")
        XCTAssertEqual(ScriptRunnerKinds.command(for: "swift")?.executable, "/usr/bin/xcrun")
        XCTAssertEqual(ScriptRunnerKinds.command(for: "swift")?.arguments, ["swift"])
    }
    func testAXSelectorRequiresExplicitTitleOrIdentifier() {
        XCTAssertFalse(AccessibilityElementSelector(title: "", identifier: "", role: "AXButton").matches(title: "Delete", identifier: "delete", role: "AXButton"))
        let selector = AccessibilityElementSelector(title: "Save", identifier: "save", role: "AXButton")
        XCTAssertTrue(selector.matches(title: "Save", identifier: "save", role: "AXButton"))
        XCTAssertFalse(selector.matches(title: "Save As", identifier: "save", role: "AXButton"))
        XCTAssertFalse(selector.matches(title: "Save", identifier: "save", role: "AXMenuItem"))
    }
    func testTimeWindowHandlesOvernightWeekdaysAndInclusiveCalendarDates() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour))! }
        let window = TriggerTimeWindow(weekdays: [2], startMinute: 22 * 60, endMinute: 6 * 60,
                                       firstDate: date(5, 0), lastDate: date(6, 0))
        XCTAssertFalse(window.contains(date(5, 5), calendar: calendar), "Monday morning belongs to Sunday")
        XCTAssertTrue(window.contains(date(5, 23), calendar: calendar))
        XCTAssertTrue(window.contains(date(6, 5), calendar: calendar), "Tuesday morning belongs to Monday")
        XCTAssertFalse(window.contains(date(6, 7), calendar: calendar))
        XCTAssertFalse(window.contains(date(12, 23), calendar: calendar), "next Monday is past the date bound")
        let kind = SystemTriggerKind.everyMinutesInWindow(interval: 5, window: window)
        XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: JSONEncoder().encode(kind)), kind)
    }
    func testDailyScheduleDoesNotCollideOnSameDayNumberInDifferentMonths() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "month regression", input: .systemEvent(.daily(hour: 3, minute: 17)))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var count = 0
        ActionExecutor.onActionExecuted = { _ in count += 1 }
        defer { ActionExecutor.onActionExecuted = nil; monitor.unregisterAll() }
        ActionExecutor.registerTriggers([trigger]); monitor.registerTriggers([trigger])
        let baseline = count
        for month in [1, 2] {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 5, hour: 3, minute: 17))!
            monitor.tick(now: date); monitor.tick(now: date)
        }
        XCTAssertEqual(count - baseline, 2)
    }
    func testGenericHIDRequiresExactDeviceElementAndValue() {
        let kind = SystemTriggerKind.hidInput(vendorID: 123, productID: 456, usagePage: 12, usage: 1, minimumValue: 1, maximumValue: 1)
        XCTAssertTrue(SystemSignalMatcher.matches(kind, .hid(vendorID: 123, productID: 456, usagePage: 12, usage: 1, value: 1)))
        XCTAssertFalse(SystemSignalMatcher.matches(kind, .hid(vendorID: 124, productID: 456, usagePage: 12, usage: 1, value: 1)))
        XCTAssertFalse(SystemSignalMatcher.matches(kind, .hid(vendorID: 123, productID: 456, usagePage: 12, usage: 1, value: 0)))
        XCTAssertEqual(SignalSource.needs(for: [kind]), [.hid([GenericHIDFilter(vendorID: 123, productID: 456)])])
    }
    func testWatcherHandlesMissingTargetAndRepeatedAtomicReplacements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOMWatcher-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target.txt")
        let appeared = expectation(description: "created"), replaced = expectation(description: "replaced"), edited = expectation(description: "edited after replacement")
        var seen = Set<String>()
        let watcher = ResilientFileWatcher(path: file.path) {
            guard let content = try? String(contentsOf: file), seen.insert(content).inserted else { return }
            if content == "one" { appeared.fulfill() }
            if content == "two" { replaced.fulfill() }
            if content == "three" { edited.fulfill() }
        }
        watcher.start(); defer { watcher.stop() }
        try "one".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [appeared], timeout: 3)
        try "two".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [replaced], timeout: 3)
        try "three".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [edited], timeout: 3)
    }
}
