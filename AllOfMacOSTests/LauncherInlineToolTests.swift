import XCTest
@testable import AllOfMacOS

final class LauncherInlineToolTests: XCTestCase {
    func testCodexPickerUsesOnlyUniqueVisibleModels() {
        let json = #"{"models":[{"slug":"fast","display_name":"Fast","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"fast","visibility":"list"},{"slug":"other","visibility":"list"}]}"#
        XCTAssertEqual(CodexModelCatalog.options(Data(json.utf8)).map(\.id), ["fast", "other"])
        XCTAssertEqual(CodexModelCatalog.options(Data("{}".utf8)), [])
    }

    func testModelReachesCodexAndDefaultDelegatesToCLI() {
        let codex = PaletteAIProvider.codex
        let args = codex.arguments(prompt: "--help", session: nil, model: "choice")
        XCTAssertEqual(Array(args.suffix(4)), ["--model", "choice", "--", "--help"])
        XCTAssertFalse(codex.arguments(prompt: "hello", session: nil).contains("--model"))
        XCTAssertTrue(codex.terminalCommand(session: "thread", prompt: nil, model: "choice").hasSuffix("--model 'choice' resume 'thread'"))
    }

    func testBrewRoutesKeepTheOriginalSearchAndSelection() {
        var navigation = PaletteNavigation()
        for tool in LauncherTool.entries {
            navigation.push(.tool(tool), query: tool.aliases[0], selection: tool.id)
            XCTAssertEqual(navigation.current, .tool(tool))
            let frame = navigation.pop()
            XCTAssertEqual(frame?.returnQuery, tool.aliases[0])
            XCTAssertEqual(frame?.returnSelection, tool.id)
        }
        XCTAssertEqual(Set(LauncherTool.entries.map(\.id)).count, LauncherTool.entries.count)
    }
}
