import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class DeviceGroupingStorageTests: XCTestCase {
    func testDeviceGroupsPreserveIndividualBindings() {
        let input = TriggerInput.keyboardShortcut(KeyboardShortcut(keyCode: 17, modifiers: .option))
        let deck = Trigger(name: "Ulanzi · Mission Control", input: input)
        let mouse = Trigger(name: "UGREEN Rear ×2 · Mission Control", input: input)
        var custom = Trigger(name: "Custom Mapping", input: input)
        custom.folder = "Ulanzi Deck"
        XCTAssertEqual(ModernGesturesWorkspace.deviceGroup(for: deck), "Ulanzi Deck")
        XCTAssertEqual(ModernGesturesWorkspace.deviceGroup(for: mouse), "UGREEN Mouse")
        XCTAssertEqual(ModernGesturesWorkspace.deviceGroup(for: custom), "Ulanzi Deck")
        XCTAssertNil(ModernGesturesWorkspace.deviceGroup(for: Trigger(name: "Regular Shortcut", input: input)))
        XCTAssertNil(ModernGesturesWorkspace.deviceGroup(for: Trigger(name: "Not Ulanzi", input: input)))
        XCTAssertEqual(deck.input, input)
        XCTAssertEqual(mouse.input, input)
    }

    func testStorageShortcutsUseExistingActionsAndConfirmation() {
        let triggers = AppState.storageShortcutTemplates()
        XCTAssertEqual(triggers.map { $0.input.displayName }, ["⌥T", "⌥Y"])
        XCTAssertEqual(triggers[0].actions.first?.actionType, .emptyTrash)
        XCTAssertEqual(triggers[0].actions.first?.parameters.requiresConfirmation, true)
        XCTAssertEqual(triggers[1].actions.first?.actionType, .openURL)
        XCTAssertEqual(triggers[1].actions.first?.parameters.url, "aom://open-free-up-space")
    }

    func testStorageLinkOnlyOpensReviewAndRejectsParameters() {
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://open-free-up-space")!), .openFreeUpSpace)
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://open-free-up-space?force=1")!))
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://open-free-up-space/delete")!))
        let requests = SystemToolsRequests()
        XCTAssertFalse(requests.takeFreeUpSpace())
        requests.requestFreeUpSpace()
        XCTAssertTrue(requests.takeFreeUpSpace())
        XCTAssertFalse(requests.takeFreeUpSpace())
    }
}
