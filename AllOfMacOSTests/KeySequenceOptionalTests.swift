import XCTest
@testable import AllOfMacOS

/// Optional and unordered strokes, following BTT's BTTKEYRequired and
/// BTTKEYOrderRelevant. The detector is exercised directly so the rules are
/// pinned without a live keyboard.
final class KeySequenceOptionalTests: XCTestCase {
    private func stroke(_ code: UInt16, required: Bool = true) -> KeySequenceStroke {
        KeySequenceStroke(keyCode: code, modifiers: 0, isRequired: required)
    }
    private func detector(_ codes: [UInt16]) -> KeySequenceDetector {
        let detector = KeySequenceDetector()
        for (index, code) in codes.enumerated() {
            // 100 ms apart, inside the 450 ms gap limit these tests use.
            detector.press(stroke(code), at: Double(index) * 0.1, in: "app")
        }
        return detector
    }

    func testAbsentIsRequiredSoOlderPresetsKeepMatching() throws {
        // A preset written before optional strokes existed has no isRequired
        // key at all, and it must still mean "required".
        let json = #"{"keyCode":12,"modifiers":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeySequenceStroke.self, from: json)
        XCTAssertTrue(decoded.isRequired)

        let encoded = try JSONEncoder().encode(KeySequenceStroke(keyCode: 12, modifiers: 0, isRequired: false))
        let round = try JSONDecoder().decode(KeySequenceStroke.self, from: encoded)
        XCTAssertFalse(round.isRequired)
    }

    func testOptionalStrokeMayBeSkippedButRequiredOnesMayNot() {
        let pattern = [stroke(1), stroke(2, required: false), stroke(3)]
        // Without the optional stroke.
        XCTAssertTrue(detector([1, 3]).matches(pattern, maxGapMs: 450))
        // With it, in place.
        XCTAssertTrue(detector([1, 2, 3]).matches(pattern, maxGapMs: 450))
        // A missing required stroke still fails.
        XCTAssertFalse(detector([1, 3, 9]).matches([stroke(1), stroke(2), stroke(3)], maxGapMs: 450))
    }

    func testAllOptionalPatternNeverMatchesBecauseNothingPinsIt() {
        let pattern = [stroke(1, required: false), stroke(2, required: false)]
        XCTAssertFalse(detector([1, 2]).matches(pattern, maxGapMs: 450))
    }

    func testUnorderedAcceptsRequiredStrokesInAnyOrder() {
        let pattern = [stroke(1), stroke(2), stroke(3)]
        XCTAssertFalse(detector([3, 2, 1]).matches(pattern, maxGapMs: 450, orderRelevant: true))
        XCTAssertTrue(detector([3, 2, 1]).matches(pattern, maxGapMs: 450, orderRelevant: false))
        // Unordered still requires every stroke to be present.
        XCTAssertFalse(detector([3, 2, 9]).matches(pattern, maxGapMs: 450, orderRelevant: false))
    }

    func testGapLimitStillAppliesToUnorderedSequences() {
        let pattern = [stroke(1), stroke(2)]
        let detector = KeySequenceDetector()
        detector.press(stroke(1), at: 0, in: "app")
        detector.press(stroke(2), at: 5, in: "app")
        XCTAssertFalse(detector.matches(pattern, maxGapMs: 450, orderRelevant: false))
    }

    func testOrderFlagDefaultsToRelevantForOlderPresets() throws {
        var trigger = Trigger(name: "Seq", input: .keySequence([stroke(1), stroke(2)]))
        trigger.sequenceMaxGapMs = 450
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? [String: Any])
        raw.removeValue(forKey: "sequenceOrderRelevant")
        let decoded = try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(decoded.sequenceOrderRelevant)
    }
}
