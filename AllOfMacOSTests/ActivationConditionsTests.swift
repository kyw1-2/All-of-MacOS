import XCTest
@testable import AllOfMacOS

/// Conditional activation groups (BTT CAG parity): app scope AND every set
/// condition; presets without conditions behave exactly as before.
final class ActivationConditionsTests: XCTestCase {
    private func snapshot(_ date: Date = Date(), power: String? = "ac", displays: Int = 1,
                          windows: Set<String>? = nil) -> ActivationConditions.Snapshot {
        .init(date: date, powerSource: power, displayCount: displays, bundleIDsWithWindows: windows)
    }

    private func group(_ conditions: ActivationConditions?) -> ActivationGroup {
        var group = ActivationGroup(name: "Work")
        group.includedBundleIDs = ["com.apple.Safari"]
        group.conditions = conditions
        return group
    }

    func testNoConditionsKeepsTheAppRule() {
        let plain = group(nil)
        XCTAssertTrue(plain.matches("com.apple.Safari", snapshot: snapshot()))
        XCTAssertFalse(plain.matches("com.apple.Notes", snapshot: snapshot()))
        XCTAssertTrue(ActivationConditions().isEmpty)
    }

    func testEveryConditionMustHold() {
        var conditions = ActivationConditions()
        conditions.powerSource = "battery"
        conditions.minimumDisplayCount = 2
        let g = group(conditions)
        XCTAssertFalse(g.matches("com.apple.Safari", snapshot: snapshot(power: "battery", displays: 1)))
        XCTAssertFalse(g.matches("com.apple.Safari", snapshot: snapshot(power: "ac", displays: 2)))
        XCTAssertTrue(g.matches("com.apple.Safari", snapshot: snapshot(power: "battery", displays: 2)))
        XCTAssertFalse(g.matches("com.apple.Notes", snapshot: snapshot(power: "battery", displays: 2)), "app scope still applies")
    }

    func testTimeWindowAndRequiredWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday10 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10)))
        let sunday10 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10)))
        var conditions = ActivationConditions()
        conditions.timeWindow = TriggerTimeWindow(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1080)
        XCTAssertTrue(conditions.isSatisfied(by: snapshot(monday10), calendar: calendar))
        XCTAssertFalse(conditions.isSatisfied(by: snapshot(sunday10), calendar: calendar))
        conditions.timeWindow = nil
        conditions.requiresWindowOfBundleID = "com.apple.Music"
        XCTAssertFalse(conditions.isSatisfied(by: snapshot(windows: ["com.apple.Safari"])))
        XCTAssertTrue(conditions.isSatisfied(by: snapshot(windows: ["com.apple.Music"])))
    }

    func testOldPresetsDecodeAndConditionsRoundTrip() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Legacy","includedBundleIDs":["com.apple.Safari"]}"#
        let legacy = try JSONDecoder().decode(ActivationGroup.self, from: Data(old.utf8))
        XCTAssertNil(legacy.conditions)
        XCTAssertTrue(legacy.isEnabled)
        var conditions = ActivationConditions()
        conditions.powerSource = "ac"
        conditions.maximumDisplayCount = 1
        let saved = try JSONDecoder().decode(ActivationGroup.self, from: JSONEncoder().encode(group(conditions)))
        XCTAssertEqual(saved.conditions, conditions)
        XCTAssertEqual(conditions.summary, "On power adapter · Up to 1 display")
    }
}

/// BTT placeVariablesIntoString parity: an action's result feeds the next one.
final class WorkflowVariableInterpolationTests: XCTestCase {
    private let values = ["user": "kim", "ticket_id": "AOM-42"]

    func testKnownVariablesArePlacedAndUnknownOnesLeftAsWritten() {
        let lookup: (String) -> String? = { self.values[$0] }
        XCTAssertEqual(WorkflowVariables.interpolate("https://x.test/{{var:ticket_id}}?u={{var:user}}", lookup: lookup),
                       "https://x.test/AOM-42?u=kim")
        XCTAssertEqual(WorkflowVariables.interpolate("{{var:missing}} {{user}} {var:user}", lookup: lookup),
                       "{{var:missing}} {{user}} {var:user}", "only the explicit var: form is replaced")
        XCTAssertEqual(WorkflowVariables.interpolate("no variables", lookup: lookup), "no variables")
    }

    func testOnlyTextBearingParametersChange() {
        var action = TriggerAction(actionType: .openURL)
        action.parameters.url = "https://x.test/{{var:ticket_id}}"
        action.parameters.scriptContent = "echo {{var:user}}"
        let resolved = WorkflowVariables.interpolated(action) { self.values[$0] }
        XCTAssertEqual(resolved.parameters.url, "https://x.test/AOM-42")
        XCTAssertEqual(resolved.parameters.scriptContent, "echo {{var:user}}", "scripts are never rewritten (no injection)")
    }
}
