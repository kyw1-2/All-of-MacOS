import XCTest
@testable import AllOfMacOS

/// AppleScript commands become the aom:// links the app already validates.
final class AOMScriptingTests: XCTestCase {
    func testCaptureModesMapOntoExistingLinks() throws {
        XCTAssertEqual(try AOMScriptingRoute.capture(mode: nil).absoluteString, "aom://capture-area")
        XCTAssertEqual(try AOMScriptingRoute.capture(mode: "Full Screen").absoluteString, "aom://capture-fullscreen")
        XCTAssertEqual(try AOMScriptingRoute.capture(mode: "all-in-one").absoluteString, "aom://all-in-one")
        for mode in AOMScriptingRoute.captureModes.keys {
            XCTAssertNotNil(AOMCaptureDeepLink.parse(try AOMScriptingRoute.capture(mode: mode)), mode)
        }
        XCTAssertThrowsError(try AOMScriptingRoute.capture(mode: "everything"))
    }

    func testRunTriggerEncodesTheName() throws {
        let url = try AOMScriptingRoute.runTrigger(named: "Arrange & Share 한글")
        XCTAssertEqual(AOMAutomationLink.parse(url), .trigger("Arrange & Share 한글"))
        XCTAssertThrowsError(try AOMScriptingRoute.runTrigger(named: "  "))
    }

    func testOpenURLAcceptsOnlyAOMLinks() throws {
        XCTAssertNoThrow(try AOMScriptingRoute.validated("aom://open-history"))
        XCTAssertThrowsError(try AOMScriptingRoute.validated("https://example.com"))
        XCTAssertThrowsError(try AOMScriptingRoute.validated("aom://format-disk"))
        XCTAssertNotNil(AOMCaptureDeepLink.parse(AOMScriptingRoute.restoreQuickAccess))
    }

    func testDictionaryIsDeclaredAndShipped() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("AllOfMacOS/App/Info.plist")))
        XCTAssertEqual(plist["NSAppleScriptEnabled"] as? Bool, true)
        XCTAssertEqual(plist["OSAScriptingDefinition"] as? String, "AllOfMacOS.sdef")
        let sdef = try String(contentsOf: root.appendingPathComponent("AllOfMacOS/App/AllOfMacOS.sdef"), encoding: .utf8)
        for cocoaClass in ["AOMScriptRunTriggerCommand", "AOMScriptCaptureCommand", "AOMScriptRestoreCommand", "AOMScriptOpenURLCommand"] {
            XCTAssertTrue(sdef.contains(cocoaClass))
            XCTAssertNotNil(NSClassFromString(cocoaClass), "\(cocoaClass) must exist under its Objective-C name")
        }
        let script = try String(contentsOf: root.appendingPathComponent("build-and-sign.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("AllOfMacOS.sdef"), "the release bundle must include the dictionary")
    }
}
