import XCTest
@testable import AllOfMacOS

@MainActor
final class AutomationAccessTests: XCTestCase {
    func testAutomationGrantAndRevocationPersistPerClientWithoutExpandingPeers() throws {
        let suite = "AutomationAccess.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardMCPSettings(defaults: defaults)
        let firstToken = try settings.connect(name: "First", client: "Test")
        let secondToken = try settings.connect(name: "Second", client: "Test")
        let firstID = try XCTUnwrap(settings.tool(forToken: firstToken)?.id)
        settings.setAutomationAccess(true, for: firstID)
        XCTAssertEqual(settings.tool(forToken: firstToken)?.automationAccess, true)
        XCTAssertNotEqual(settings.tool(forToken: secondToken)?.automationAccess, true)
        let restored = ClipboardMCPSettings(defaults: defaults)
        XCTAssertEqual(restored.tool(forToken: firstToken)?.automationAccess, true)
        restored.setAutomationAccess(false, for: firstID)
        XCTAssertEqual(ClipboardMCPSettings(defaults: defaults).tool(forToken: firstToken)?.automationAccess, false)
    }
    func testLegacyClientsHaveNoAutomationScope() throws {
        let client = ClipboardMCPTool(name: "Legacy", client: "Test", tokenHash: "hashed")
        let data = try JSONEncoder().encode(client)
        let decoded = try JSONDecoder().decode(ClipboardMCPTool.self, from: data)
        XCTAssertNil(decoded.automationAccess)
    }

    func testAutomationToolsAreHiddenAndRejectedWithoutScope() async throws {
        let store = ClipboardStore()
        await store.ready()
        let list: [String: Any] = ["id": 1, "method": "tools/list"]
        func names(_ access: Bool) -> [String] {
            let response = ClipboardMCPHandler.handle(list, store: store, automationAccess: access)
            return ((response?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        XCTAssertFalse(names(false).contains { $0.hasPrefix("automation_") })
        XCTAssertTrue(names(true).contains("automation_catalog"))
        let denied = ClipboardMCPHandler.handle(["id": 2, "method": "tools/call", "params": ["name": "automation_catalog"]], store: store)
        XCTAssertEqual((denied?["result"] as? [String: Any])?["isError"] as? Bool, true)
        let granted = ClipboardMCPHandler.handle(["id": 3, "method": "tools/call", "params": ["name": "automation_catalog"]], store: store, automationAccess: true)
        XCTAssertEqual((granted?["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testAutomationLinksRejectAmbiguityAndKeepNamedAlias() {
        XCTAssertEqual(AOMAutomationLink.parse(URL(string: "aom://trigger_named?trigger_name=Hello")!), .trigger("Hello"))
        XCTAssertEqual(AOMAutomationLink.parse(URL(string: "AOM://TRIGGER_NAMED?trigger_name=Hello")!), .trigger("Hello"))
        XCTAssertEqual(AOMAutomationLink.parse(URL(string: "aom://show-menu?name=Tools")!), .showMenu("Tools"))
        XCTAssertEqual(AOMAutomationLink.parse(URL(string: "aom://edit-menus")!), .editMenus)
        for value in ["aom://show-menu?name=one&name=two", "aom://user@trigger?name=test",
                      "aom://trigger?name=", "aom://hide-menus?script=x", "aom://trigger/path?name=x"] {
            XCTAssertNil(AOMAutomationLink.parse(URL(string: value)!))
        }
    }
}
