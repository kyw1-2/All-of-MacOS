import XCTest
import Carbon
@testable import AllOfMacOS

/// Key remapping, Hyper key and wheel reversal. Pure planners only: nothing
/// here runs hidutil or installs an event tap.
final class InputRemappingTests: XCTestCase {
    private let caps: UInt32 = 0x39, escape: UInt32 = 0x29, rightCommand: UInt32 = 0xE7, f19: UInt32 = 0x6E

    func testDesiredPairsUseTheKeyboardPageAndLetHyperWin() {
        let remaps = [KeyRemap(from: caps, to: escape), KeyRemap(from: rightCommand, to: f19),
                      KeyRemap(from: rightCommand, to: escape), KeyRemap(from: f19, to: f19)]
        XCTAssertEqual(HIDKeyMapping.desired(remaps: remaps, hyperSource: nil),
                       [HIDKeyMapping.pair(caps, escape), HIDKeyMapping.pair(rightCommand, escape)])
        XCTAssertEqual(HIDKeyMapping.desired(remaps: remaps, hyperSource: caps),
                       [HIDKeyMapping.pair(caps, HIDKeyMapping.f18), HIDKeyMapping.pair(rightCommand, escape)])
        XCTAssertEqual(HIDKeyMapping.pair(caps, HIDKeyMapping.f18), HIDMappingPair(src: 0x700000039, dst: 0x70000006D))
        XCTAssertTrue(HIDKeyMapping.desired(remaps: [], hyperSource: nil).isEmpty)
    }

    func testMergeKeepsOtherToolsAndReplacesOnlyOwnedOrConflictingPairs() {
        let foreign = HIDKeyMapping.pair(0xE2, 0xE3)          // someone else's Option → Command
        let foreignCaps = HIDKeyMapping.pair(caps, 0xE0)      // someone else's Caps → Control
        let oldOwned = HIDKeyMapping.pair(rightCommand, f19)
        let desired = [HIDKeyMapping.pair(caps, HIDKeyMapping.f18)]
        let merged = HIDKeyMapping.merged(current: [foreign, foreignCaps, oldOwned, foreign], previouslyOwned: [oldOwned], desired: desired)
        XCTAssertEqual(merged, [foreign] + desired)
        // Turning everything off gives back exactly AOM's pairs.
        XCTAssertEqual(HIDKeyMapping.merged(current: merged, previouslyOwned: desired, desired: []), [foreign])
    }

    func testParsesHidutilOutputAcrossServices() {
        let output = """
        RegistryID  Key                   Value
        10000082d   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771182;
                HIDKeyboardModifierMappingSrc = 30064771183;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        100000346   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771182;
                HIDKeyboardModifierMappingSrc = 30064771183;
            }
        )
        100000347   UserKeyMapping   (null)
        """
        XCTAssertEqual(HIDKeyMapping.parse(output), [HIDMappingPair(src: 30064771183, dst: 30064771182),
                                                     HIDMappingPair(src: 30064771129, dst: 30064771113)])
        XCTAssertEqual(HIDKeyMapping.parse("RegistryID  Key  Value\n10000082d   UserKeyMapping   (null)"), [])
    }

    func testJSONIsWhatHidutilAccepts() {
        XCTAssertEqual(HIDKeyMapping.json([HIDMappingPair(src: 30064771183, dst: 30064771182)]),
                       #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771183,"HIDKeyboardModifierMappingDst":30064771182}]}"#)
        XCTAssertEqual(HIDKeyMapping.json([]), #"{"UserKeyMapping":[]}"#)
    }

    func testHyperKeyAddsModifiersWhileHeldAndTapsEscapeAlone() {
        var state = (held: false, used: false)
        let f18 = Int64(kVK_F18), j = Int64(kVK_ANSI_J)
        XCTAssertEqual(decision(.keyDown, f18, &state), Decision(pass: false, addHyper: false, sendEscape: false))
        XCTAssertTrue(state.held)
        XCTAssertEqual(decision(.keyDown, f18, &state), Decision(pass: false, addHyper: false, sendEscape: false), "auto-repeat is swallowed")
        XCTAssertEqual(decision(.keyDown, j, &state), Decision(pass: true, addHyper: true, sendEscape: false))
        XCTAssertEqual(decision(.keyUp, j, &state), Decision(pass: true, addHyper: true, sendEscape: false))
        XCTAssertEqual(decision(.keyUp, f18, &state), Decision(pass: false, addHyper: false, sendEscape: false), "used, so no Escape")
        XCTAssertFalse(state.held)
        XCTAssertEqual(decision(.keyDown, j, &state), Decision(pass: true, addHyper: false, sendEscape: false))
        _ = decision(.keyDown, f18, &state)
        XCTAssertEqual(decision(.keyUp, f18, &state), Decision(pass: false, addHyper: false, sendEscape: true), "tapped alone")
        // AOM's own synthetic keys are never changed.
        _ = decision(.keyDown, f18, &state)
        var synthetic = state
        let result = HyperKeyTap.process(type: .keyDown, keyCode: j, isSynthetic: true, state: &synthetic)
        XCTAssertTrue(result.pass); XCTAssertFalse(result.addHyper)
    }

    func testWheelReversalSkipsTrackpadsAndSyntheticScrolls() {
        XCTAssertTrue(ScrollWheelReverser.shouldReverse(isContinuous: 0, isSynthetic: false))
        XCTAssertFalse(ScrollWheelReverser.shouldReverse(isContinuous: 1, isSynthetic: false))
        XCTAssertFalse(ScrollWheelReverser.shouldReverse(isContinuous: 0, isSynthetic: true))
    }

    func testWheelReversalFlipsEveryDeltaField() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0))
        let before = (event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        ScrollWheelReverser.reverse(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -before.0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), -before.1)
        XCTAssertNotEqual(before.0, 0)
    }

    func testHyperSourcesAreInTheCatalog() {
        XCTAssertTrue(HIDKey.hyperSources.contains { $0.usage == caps })
        XCTAssertEqual(Set(HIDKey.catalog.map(\.usage)).count, HIDKey.catalog.count)
        XCTAssertEqual(HIDKey.title(0xFE), "Key 0xFE")
    }

    private struct Decision: Equatable { var pass: Bool; var addHyper: Bool; var sendEscape: Bool }
    private func decision(_ type: CGEventType, _ code: Int64, _ state: inout (held: Bool, used: Bool)) -> Decision {
        let result = HyperKeyTap.process(type: type, keyCode: code, isSynthetic: false, state: &state)
        return Decision(pass: result.pass, addHyper: result.addHyper, sendEscape: result.sendEscape)
    }
}
