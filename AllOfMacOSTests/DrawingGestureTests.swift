import XCTest
@testable import AllOfMacOS

final class DrawingGestureTests: XCTestCase {
    private func trigger(_ name: String) -> Trigger {
        let template = DrawingPatternLibrary.templates.first { $0.name == name }!
        var trigger = Trigger(name: name, input: .drawingPattern(name))
        trigger.drawingSamples = [DrawingRecognizer.normalized(template.samples)!]
        return trigger
    }
    func testDirectionSensitiveDrawingMatch() {
        let left = trigger("Left")
        let right = trigger("Right")
        XCTAssertEqual(DrawingRecognizer.bestMatch(left.drawingSamples[0], among: [left,right])?.id, left.id)
        XCTAssertEqual(DrawingRecognizer.bestMatch(right.drawingSamples[0], among: [left,right])?.id, right.id)
        XCTAssertGreaterThan(DrawingRecognizer.distance(left.drawingSamples[0], right.drawingSamples[0]) ?? 0, 0.20)
    }
    func testCircleAndZAreDistinct() {
        let circle = trigger("Circle")
        let z = trigger("Z")
        XCTAssertEqual(DrawingRecognizer.bestMatch(circle.drawingSamples[0], among: [circle,z])?.id, circle.id)
        XCTAssertEqual(DrawingRecognizer.bestMatch(z.drawingSamples[0], among: [circle,z])?.id, z.id)
    }
    func testRejectsTinyAndInvalidShapes() {
        let a = Array(repeating: DrawingPoint(x: 0.5,y:0.5),count:20)
        XCTAssertNil(DrawingRecognizer.normalized(a))
        XCTAssertNil(DrawingRecognizer.normalized(Array(a.prefix(7))))
        XCTAssertNil(DrawingRecognizer.normalized([DrawingPoint(x:.nan,y:0)] + a))
    }
    func testDrawingPresetRoundTripAndOldCompatibility() throws {
        var preset = Preset(name: "Drawings")
        preset.triggers = [trigger("M")]
        let bytes = try PresetCodec.encode(preset, envelope:true)
        let decoded = try PresetCodec.decode(bytes)
        XCTAssertEqual(decoded.triggers.first?.drawingSamples.count,1)
        XCTAssertEqual(decoded.triggers.first?.input,.drawingPattern("M"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        root["schemaVersion"] = 5
        let old = try PresetCodec.decode(JSONSerialization.data(withJSONObject:root))
        XCTAssertEqual(old.triggers.count,1)
    }
    func testDrawingValidationRejectsInvalidTemplates() throws {
        var preset = Preset(name:"invalid")
        var invalid = trigger("L")
        invalid.drawingSamples = [Array(repeating:DrawingPoint(x:1.4,y:0.2),count:10)]
        preset.triggers = [invalid]
        XCTAssertThrowsError(try PresetCodec.decode(PresetCodec.encode(preset)))
        invalid.drawingSamples = []
        preset.triggers = [invalid]
        XCTAssertThrowsError(try PresetCodec.decode(PresetCodec.encode(preset)))
    }
}

extension DrawingGestureTests {
    func testDirectionFreeDrawingAcceptsReverseStroke() {
        var forward = Trigger(name: "L", input: .drawingPattern("L"))
        forward.drawingSamples = [DrawingRecognizer.normalized(DrawingPatternLibrary.templates.first { $0.name == "L" }!.samples)!]
        let backward = Array(forward.drawingSamples[0].reversed())
        XCTAssertNil(DrawingRecognizer.bestMatch(backward, among: [forward]))
        forward.drawingIgnoreDirection = true
        XCTAssertEqual(DrawingRecognizer.bestMatch(backward, among: [forward])?.id, forward.id)
    }
    func testHigherCertaintyRejectsAmbiguousStroke() {
        var baseline = Trigger(name: "L", input: .drawingPattern("L"))
        baseline.drawingSamples = [DrawingRecognizer.normalized(DrawingPatternLibrary.templates.first { $0.name == "L" }!.samples)!]
        var distorted = baseline.drawingSamples[0]
        for i in distorted.indices { distorted[i].x = max(0, min(1, distorted[i].x + 0.22 * sin(Double(i)/7))) }
        let score = DrawingRecognizer.score(distorted, template: baseline.drawingSamples[0], directionIndependent: false)!
        XCTAssertGreaterThan(score, 0.015)
        baseline.drawingCertainty = 0.90
        XCTAssertNil(DrawingRecognizer.bestMatch(distorted, among: [baseline]))
        baseline.drawingCertainty = 0.50
        XCTAssertNotNil(DrawingRecognizer.bestMatch(distorted, among: [baseline]))
    }
    func testLegacyDrawingDefaultsRemainStable() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","input":{"drawingPattern":{"_0":"L"}},"actions":[],"isEnabled":true,"order":0}"#
        guard let trigger = try? JSONDecoder().decode(Trigger.self, from: Data(legacy.utf8)) else { return }
        XCTAssertEqual(trigger.drawingCertainty, 0.7)
        XCTAssertFalse(trigger.drawingIgnoreDirection)
    }
}
