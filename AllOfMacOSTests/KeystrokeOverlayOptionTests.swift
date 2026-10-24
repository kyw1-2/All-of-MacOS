import AppKit
import XCTest
@testable import AllOfMacOS

/// CleanShot's keystroke-overlay options: which keys, position, size, style.
final class KeystrokeOverlayOptionTests: XCTestCase {
    func testShortcutsOnlyByDefaultAndAllKeysOnRequest() {
        XCTAssertNil(ScreenRecordingService.keystrokeLabel(keyCode: 0, flags: [], characters: "a", allKeys: false),
                     "plain typing is not collected unless All Keys is chosen")
        XCTAssertEqual(ScreenRecordingService.keystrokeLabel(keyCode: 0, flags: [], characters: "a", allKeys: true), "a")
        XCTAssertEqual(ScreenRecordingService.keystrokeLabel(keyCode: 8, flags: [.command, .shift], characters: "c", allKeys: false), "⇧⌘C")
        XCTAssertEqual(ScreenRecordingService.keystrokeLabel(keyCode: 36, flags: [], characters: "\r", allKeys: false), "↩")
        XCTAssertEqual(ScreenRecordingService.keystrokeLabel(keyCode: 49, flags: [], characters: " ", allKeys: false), "Space")
    }

    func testPositionAndSizeMapOntoStudioValues() {
        XCTAssertEqual(KeystrokeOverlayPosition.top.studioY, 0.1)
        XCTAssertEqual(KeystrokeOverlayPosition.bottom.studioY, 0.9)
        XCTAssertLessThan(KeystrokeOverlaySize.small.studioScale, KeystrokeOverlaySize.large.studioScale)
        XCTAssertEqual(KeystrokeOverlaySize.medium.studioScale, 1)
    }

    func testStudioProjectsSavedBeforeTheStyleOptionStillDecode() throws {
        var settings = AOMStudioSettings()
        settings.keystrokeStyle = .light
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(json["keystrokeStyle"] as? String, "light")
        json.removeValue(forKey: "keystrokeStyle")
        let old = try JSONDecoder().decode(AOMStudioSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.keystrokeStyle)
    }
}
