import XCTest
@testable import AllOfMacOS

final class ActivationGroupTests: XCTestCase {
    private func gesture(_ app: String? = nil, group: UUID? = nil) -> Trigger {
        var t = Trigger(name: "test", input: .trackpadGesture(.fourFingerTap), appBundleID: app)
        t.activationGroupID = group
        return t
    }
    private func resolve(_ all: [Trigger], app: String, groups: [ActivationGroup]) -> [Trigger] {
        TriggerResolver.resolve(all, payload: TrackpadGesture.fourFingerTap,
            frontBundleID: app,
            payloadOf: { if case .trackpadGesture(let kind) = $0.input { return kind }; return nil },
            appBundleIDOf: { $0.appBundleID }, requiredModifiersOf: { $0.requiredModifiers },
            groups: groups, activationGroupIDOf: { $0.activationGroupID })
    }
    func testExplicitAppOverridesGroupAndGlobal() {
        var group = ActivationGroup(name: "Browsers")
        group.includedBundleIDs = ["com.apple.Safari", "com.google.Chrome"]
        let global = gesture(), grouped = gesture(group: group.id), explicit = gesture("com.apple.Safari")
        XCTAssertEqual(resolve([global, grouped, explicit], app: "com.apple.Safari", groups: [group]).map(\.id), [explicit.id])
        XCTAssertEqual(resolve([global, grouped, explicit], app: "com.google.Chrome", groups: [group]).map(\.id), [grouped.id])
        XCTAssertEqual(resolve([global, grouped, explicit], app: "com.apple.finder", groups: [group]).map(\.id), [global.id])
    }
    func testExclusionsAndGlobalBlocking() {
        var group = ActivationGroup(name: "Development")
        group.includedBundleIDs = ["test.dev", "test.prohibited"]
        group.excludedBundleIDs = ["test.prohibited"]
        group.disableGlobalTriggers = true
        let global = gesture(), local = gesture(group: group.id)
        XCTAssertEqual(resolve([global, local], app: "test.dev", groups: [group]).map(\.id), [local.id])
        XCTAssertEqual(resolve([global], app: "test.dev", groups: [group]).count, 0)
        XCTAssertEqual(resolve([global, local], app: "test.prohibited", groups: [group]).map(\.id), [global.id])
        group.isEnabled = false
        XCTAssertEqual(resolve([global, local], app: "test.dev", groups: [group]).map(\.id), [global.id])
    }
    func testGroupOrderingAndModifierPriority() {
        var first = ActivationGroup(name: "A"), second = ActivationGroup(name: "B")
        first.includedBundleIDs = ["test.shared"]; second.includedBundleIDs = ["test.shared"]
        let a = gesture(group: first.id), b = gesture(group: second.id)
        XCTAssertEqual(resolve([b, a], app: "test.shared", groups: [first, second]).map(\.id), [a.id])
        var exact = gesture(group: first.id)
        exact.requiredModifiers = 0
        XCTAssertEqual(resolve([b, a, exact], app: "test.shared", groups: [first, second]).map(\.id), [exact.id])
    }
    func testPresetSerializationAndLegacyCompatibility() throws {
        var preset = Preset(name: "CAG")
        var group = ActivationGroup(name: "Work")
        group.includedBundleIDs = ["test.one", "test.two"]
        group.excludedBundleIDs = ["test.two"]
        group.disableGlobalTriggers = true
        preset.activationGroups = [group]
        preset.triggers = [gesture(group: group.id)]
        let data = try PresetCodec.encode(preset, envelope: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 9)
        let recovered = try PresetCodec.decode(data)
        XCTAssertEqual(recovered.activationGroups, [group])
        XCTAssertEqual(recovered.triggers.first?.activationGroupID, group.id)
        var old = Preset(name: "Legacy")
        old.triggers = [gesture()]
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(old)) as? [String: Any])
        oldJSON.removeValue(forKey: "activationGroups")
        XCTAssertTrue(try PresetCodec.decode(JSONSerialization.data(withJSONObject: oldJSON)).activationGroups.isEmpty)
    }
    func testMissingGroupReferenceRejected() throws {
        var preset = Preset(name: "Invalid")
        preset.triggers = [gesture(group: UUID())]
        XCTAssertThrowsError(try PresetCodec.decode(PresetCodec.encode(preset)))
    }
}

extension ActivationGroupTests {
    func testAllExceptGroupAndLegacyDecoding() throws {
        var group = ActivationGroup(name: "Everything except browsers")
        group.appliesToAllApps = true
        group.excludedBundleIDs = ["com.google.Chrome", "com.apple.Safari"]
        XCTAssertTrue(group.matches("com.apple.finder"))
        XCTAssertFalse(group.matches("com.google.Chrome"))
        XCTAssertFalse(group.matches(nil))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        json.removeValue(forKey: "appliesToAllApps")
        let older = try JSONDecoder().decode(ActivationGroup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(older.appliesToAllApps)
        XCTAssertFalse(older.matches("com.apple.finder"))
    }
}
