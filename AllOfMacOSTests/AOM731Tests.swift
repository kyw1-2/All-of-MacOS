import XCTest
@testable import AllOfMacOS

/// 7.3.1: the code-hygiene audit of 7.3 — what was verified and fixed.
final class AOM731Tests: XCTestCase {
    /// The audit's Item 02: the compiler said the loop that builds the
    /// imported triggers "will never be executed". A one-trigger import
    /// must come back with its trigger, in a release build too.
    func testBTTImportBuildsTheTrigger() throws {
        let json = #"{"BTTTriggerClass":"BTTTriggerTypeKeyboardShortcut","BTTTriggerType":0,"BTTShortcutKeyCode":46,"BTTShortcutModifierKeys":1048576,"BTTPredefinedActionType":5,"BTTEnabled2":1,"BTTUUID":"A"}"#
        let report = try BTTPresetImport.parse(Data(json.utf8))
        XCTAssertEqual(report.triggers.count, 1, "\(report.entries.map(\.reasons))")
        XCTAssertEqual(report.triggers.first?.actions.first?.actionType, .missionControl)
    }
}

extension AOM731Tests {
    /// AUD-02: small sample-time slips no longer count as an IO gap (and
    /// so don't restart the fade-in); a missing cycle still does.
    func testIOGapNeedsHalfACycle() {
        var detector = AudioIOGapDetector()
        _ = detector.observe(sampleTime: 0, valid: true, frames: 128)
        XCTAssertEqual(detector.observe(sampleTime: 129, valid: true, frames: 128), 0, "a one-frame slip is jitter")
        XCTAssertEqual(detector.observe(sampleTime: 290, valid: true, frames: 128), 0, "33 frames late is still jitter")
        XCTAssertEqual(detector.observe(sampleTime: 546, valid: true, frames: 128), 128, "a whole missing cycle is a gap")
    }
}

extension AOM731Tests {
    /// AUD-08: the load notice states the measurement, without app names or guesses.
    func testLoadNoticeStatesTheMeasurement() {
        let detail = AudioSystemLoad.detail([.memory(swappedGB: 6.2), .heat(.serious)])
        XCTAssertTrue(detail.contains("6.2 GB"))
        XCTAssertTrue(detail.contains("serious"))
        XCTAssertFalse(detail.contains("Ulanzi") || detail.contains("sun") || detail.contains("browser"))
    }
}

extension AOM731Tests {
    /// 7.3.2 (agy NEW-08): a host that starts with "-" or holds other
    /// characters is refused before /sbin/ping runs.
    func testPingRefusesOptionLikeHosts() {
        XCTAssertThrowsError(try NetworkTools.ping(host: "-f"))
        XCTAssertThrowsError(try NetworkTools.ping(host: "example.com; ls"))
    }

    /// 7.3.2 (agy NEW-03): the mention pattern is compiled once and still parses.
    func testMentionParsingStillWorks() {
        XCTAssertEqual(AOMAIRecordScope.parse("@wiki hi").scope.sources, [.wiki])
    }
}
