import AppKit
import XCTest
@testable import AllOfMacOS

final class TextTypingTests: XCTestCase {
    private func strokes(_ text: String) -> [TextTypingCursor.Stroke] {
        var cursor = TextTypingCursor(text), result: [TextTypingCursor.Stroke] = []
        while let stroke = cursor.next() { result.append(stroke) }
        return result
    }

    func testOnePairPerVisibleKoreanCombiningAndEmojiCharacter() {
        let text = "한글e\u{301}👩🏽‍💻🇰🇷한"
        let keys = strokes(text)
        XCTAssertEqual(keys.count, text.count)
        XCTAssertEqual(keys.flatMap(\.units), Array(text.utf16))
        XCTAssertEqual(keys.map { String(decoding: $0.units, as: UTF16.self) }, text.map(String.init))
    }
    func testLongCombiningClusterKeepsEveryScalarAndBoundsPayload() {
        let text = "a" + String(repeating: "\u{301}", count: 80) + "😀"
        let keys = strokes(text)
        XCTAssertEqual(keys.flatMap(\.units), Array(text.utf16))
        XCTAssertTrue(keys.allSatisfy { !$0.units.isEmpty && $0.units.count <= 20 })
        for key in keys {
            XCTAssertFalse((0xDC00...0xDFFF).contains(key.units.first!))
            XCTAssertFalse((0xD800...0xDBFF).contains(key.units.last!))
        }
    }
    func testCRLFIsOneReturnAndTabsUseTabKey() {
        let keys = strokes("a\r\nb\nc\rd\t")
        XCTAssertEqual(keys.map(\.keyCode), [0,36,11,36,8,36,2,48])
        XCTAssertEqual(keys.filter { $0.keyCode == 36 }.map(\.units), [[13],[13],[13]])
        XCTAssertEqual(keys.last?.units, [9])
    }
    func testASCIIUsesMatchingPhysicalKeysAndOnlyItsOwnShift() throws {
        let letters = strokes("aAzZ09 !@{}:|~")
        XCTAssertEqual(letters.map(\.keyCode), [0,0,6,6,29,25,49,18,19,33,30,41,42,50])
        XCTAssertEqual(letters.map(\.shifted), [false,true,false,true,false,false,false,true,true,true,true,true,true,true])
        for stroke in letters {
            let (down, up) = try XCTUnwrap(ActionExecutor.textEvents(stroke.units, keyCode: stroke.keyCode, shifted: stroke.shifted))
            XCTAssertEqual(down.type, .keyDown); XCTAssertEqual(up.type, .keyUp)
            for event in [down, up] {
                XCTAssertEqual(event.flags, stroke.shifted ? .maskShift : [])
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(stroke.keyCode))
                XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 0x475454)
                var count = 0, output = [UInt16](repeating: 0, count: 20)
                event.keyboardGetUnicodeString(maxStringLength: 20, actualStringLength: &count, unicodeString: &output)
                XCTAssertEqual(Array(output.prefix(count)), stroke.units)
            }
        }
    }

    private final class Rig {
        var cancelled = false, ready = true, released = true, canSend = true
        var now = 0.0
        var sent: [TextTypingCursor.Stroke] = []
        var results: [Bool] = []
        var pending: [(TimeInterval, () -> Void)] = []
        var environment: TextTypingSession.Environment {
            .init(isCancelled: { self.cancelled }, targetIsReady: { self.ready },
                  modifiersAreReleased: { self.released }, now: { self.now },
                  send: { stroke in self.sent.append(stroke); return self.canSend },
                  schedule: { delay, work in self.pending.append((delay, work)) })
        }
        func session(_ text: String, interval: Int? = nil) -> TextTypingSession {
            TextTypingSession(text: text, intervalMs: interval, environment: environment) { self.results.append($0) }
        }
        func tick() { let (delay, work) = pending.removeFirst(); now += delay; work() }
    }
    func testPacesEveryCharacterAndCompletesAfterLastKey() {
        let rig = Rig()
        let run = rig.session("한a😀", interval: 45)
        run.start(); run.start()
        XCTAssertEqual(rig.sent.count, 1); XCTAssertTrue(rig.results.isEmpty)
        XCTAssertEqual(rig.pending.first?.0, 0.045)
        rig.tick(); XCTAssertEqual(rig.sent.count, 2); XCTAssertTrue(rig.results.isEmpty)
        rig.tick(); XCTAssertEqual(rig.sent.count, 3); XCTAssertEqual(rig.results, [true]); XCTAssertTrue(rig.pending.isEmpty)
    }

    func testDefaultIntervalAndClampedImportedValues() {
        for (interval, expected) in [(nil,0.02),(-10,0),(Int.max,0.5)] as [(Int?,Double)] {
            let rig = Rig(); let run = rig.session("ab", interval: interval); run.start()
            XCTAssertEqual(rig.pending.first?.0, expected)
            rig.tick(); XCTAssertEqual(rig.results, [true])
        }
    }
    func testCancellationStopsBeforeNextCharacterAndFailsOnce() {
        let rig = Rig(); let run = rig.session("abcd"); run.start()
        rig.cancelled = true; rig.tick()
        XCTAssertEqual(rig.sent.count, 1); XCTAssertEqual(rig.results, [false]); XCTAssertTrue(rig.pending.isEmpty)
    }
    func testFocusChangeStopsBeforeTypingIntoAnotherApp() {
        let rig = Rig(); let run = rig.session("abcd"); run.start()
        rig.ready = false; rig.tick()
        XCTAssertEqual(rig.sent.count, 1); XCTAssertEqual(rig.results, [false])
    }
    func testWaitsForShortcutReleaseWithoutBlockingAndTimesOut() {
        let rig = Rig(); rig.released = false
        let run = rig.session("a"); run.start()
        XCTAssertTrue(rig.sent.isEmpty); XCTAssertTrue(rig.results.isEmpty)
        rig.released = true; rig.tick(); XCTAssertEqual(rig.sent.count, 1); XCTAssertEqual(rig.results, [true])
        let held = Rig(); held.released = false
        let timed = held.session("a"); timed.start()
        for _ in 0..<160 where !held.pending.isEmpty { held.tick() }
        XCTAssertTrue(held.sent.isEmpty); XCTAssertEqual(held.results, [false]); XCTAssertTrue(held.pending.isEmpty)
    }
    func testEmptyTextAndDeliveryFailureFinishWithoutFurtherWork() {
        let empty = Rig(); let run = empty.session(""); run.start()
        XCTAssertTrue(empty.sent.isEmpty); XCTAssertEqual(empty.results, [true])
        let failed = Rig(); failed.canSend = false
        let attempt = failed.session("abc"); attempt.start()
        XCTAssertEqual(failed.sent.count, 1); XCTAssertEqual(failed.results, [false]); XCTAssertTrue(failed.pending.isEmpty)
    }
    func testOptionalIntervalPreservesOldPresetsAndRoundTripsNewOnes() throws {
        let old = try JSONDecoder().decode(ActionParameters.self, from: Data("{\"text\":\"한글\"}".utf8))
        XCTAssertEqual(old.text, "한글"); XCTAssertNil(old.typingIntervalMs)
        var new = old; new.typingIntervalMs = 75
        XCTAssertEqual(try JSONDecoder().decode(ActionParameters.self, from: JSONEncoder().encode(new)), new)
    }
}
