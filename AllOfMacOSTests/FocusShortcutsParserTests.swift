import XCTest
@testable import AllOfMacOS

/// Parsing `shortcuts list --show-identifiers` output (fixtures; the real
/// tool is never run in tests).
final class FocusShortcutsParserTests: XCTestCase {
    func testNamesAndIdentifiersAreSplitAtTheTrailingUUID() {
        let output = """
        Do Not Disturb On (6F1C2A3B-1D2E-4F50-8A9B-0C1D2E3F4A5B)
        Focus (Work) (a1b2c3d4-e5f6-4789-9abc-def012345678)
        공부 집중 모드 (11111111-2222-4333-8444-555555555555)

        Plain Name Without Identifier
        Ends In Parentheses (not a uuid)
        """
        let parsed = FocusShortcutsCLI.parseList(output)
        XCTAssertEqual(parsed.map(\.name), ["Do Not Disturb On", "Focus (Work)", "공부 집중 모드",
                                            "Plain Name Without Identifier", "Ends In Parentheses (not a uuid)"])
        XCTAssertEqual(parsed[0].identifier, "6F1C2A3B-1D2E-4F50-8A9B-0C1D2E3F4A5B")
        XCTAssertEqual(parsed[1].identifier, "A1B2C3D4-E5F6-4789-9ABC-DEF012345678", "identifiers are kept upper-case")
        XCTAssertNil(parsed[3].identifier)
        XCTAssertNil(parsed[4].identifier, "parentheses that aren't a UUID stay part of the name")
        XCTAssertEqual(parsed[0].runArgument, "6F1C2A3B-1D2E-4F50-8A9B-0C1D2E3F4A5B", "runs by identifier, so a rename keeps working")
        XCTAssertEqual(parsed[3].runArgument, "Plain Name Without Identifier")
    }

    func testBlankOutputAndDuplicatesGiveAShortList() {
        XCTAssertTrue(FocusShortcutsCLI.parseList("").isEmpty)
        XCTAssertTrue(FocusShortcutsCLI.parseList("\n  \n\t\n").isEmpty)
        let twice = "Same (6F1C2A3B-1D2E-4F50-8A9B-0C1D2E3F4A5B)\nSame (6F1C2A3B-1D2E-4F50-8A9B-0C1D2E3F4A5B)\nOther\nOther\n"
        XCTAssertEqual(FocusShortcutsCLI.parseList(twice).map(\.name), ["Same", "Other"])
        XCTAssertEqual(FocusShortcutsCLI.parseList("  Padded Name  \r\n").map(\.name), ["Padded Name"])
    }

    func testErrorsSayWhy() {
        XCTAssertEqual(FocusShortcutError.timedOut(seconds: 120).errorDescription, "it didn't finish within 120 seconds")
        XCTAssertEqual(FocusShortcutError.failed(status: 1, message: "  Couldn't find shortcut\n").errorDescription,
                       "Couldn't find shortcut")
        XCTAssertEqual(FocusShortcutError.failed(status: 3, message: "").errorDescription, "Shortcuts ended with status 3")
    }

    func testTheProcessRunnerReadsOutputAndStopsAtTheTimeout() throws {
        let echo = try FocusProcess.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "focus"], timeout: 5)
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(echo.stdout, "hello focus\n")
        XCTAssertFalse(echo.timedOut)
        let started = Date()
        let slow = try FocusProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.5)
        XCTAssertTrue(slow.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a stuck child is stopped")
        XCTAssertThrowsError(try FocusProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1))
    }
}
