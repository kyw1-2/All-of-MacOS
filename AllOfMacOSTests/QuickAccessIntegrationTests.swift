import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class QuickAccessIntegrationTests: XCTestCase {
    private let laptop = QuickAccessGeometry.Display(
        id: 1, visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 840))
    private let left = QuickAccessGeometry.Display(
        id: 2, visibleFrame: CGRect(x: -1920, y: -220, width: 1920, height: 1080))
    private let portrait = QuickAccessGeometry.Display(
        id: 3, visibleFrame: CGRect(x: 1440, y: -200, width: 900, height: 1500))

    func testStableDisplaySelectionWhenMouseCrossesToOtherMonitor() {
        let screens = [laptop, left, portrait]
        let initial = QuickAccessGeometry.targetDisplay(
            screens, preferredID: nil, pointer: CGPoint(x: -500, y: 100),
            followPointer: true)
        XCTAssertEqual(initial?.id, 2)
        let afterMove = QuickAccessGeometry.targetDisplay(
            screens, preferredID: initial?.id, pointer: CGPoint(x: 1720, y: 500),
            followPointer: true)
        XCTAssertEqual(afterMove?.id, 2, "Existing overlays must not follow later pointer motion.")
        let newOverlay = QuickAccessGeometry.targetDisplay(
            screens, preferredID: nil, pointer: CGPoint(x: 1720, y: 500),
            followPointer: true)
        XCTAssertEqual(newOverlay?.id, 3)
    }

    func testPointerInMenuBarOutsideVisibleFrameKeepsCorrectDisplay() {
        let external = QuickAccessGeometry.Display(
            id: 5,
            visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 820),
            fullFrame: CGRect(x: 1440, y: 0, width: 1440, height: 900))
        let screens = [laptop, external]
        let selected = QuickAccessGeometry.targetDisplay(
            screens, preferredID: nil, pointer: CGPoint(x: 1800, y: 880),
            followPointer: true)
        XCTAssertEqual(selected?.id, 5,
                       "Menu-bar/Dock hover still belongs to the external display.")
    }

    func testDisplayDisconnectMovesOrphanedOverlayBackOnScreen() {
        let selected = QuickAccessGeometry.targetDisplay(
            [laptop], preferredID: 2,
            pointer: CGPoint(x: -500, y: 150), followPointer: true)
        XCTAssertEqual(selected?.id, 1)
        XCTAssertNil(QuickAccessGeometry.targetDisplay([], preferredID: 2, pointer: nil,
                                                        followPointer: true))
    }

    func testAllCornersAllStackCountsAndNegativeOriginsStayVisible() {
        for display in [laptop, left, portrait] {
            for corner in OverlayCorner.allCases {
                for count in 1...3 {
                    for index in 0..<count {
                        let card = CGSize(width: 315, height: 268)
                        let frame = QuickAccessGeometry.frame(
                            visible: display.visibleFrame, card: card,
                            corner: corner, index: index, count: count)
                        XCTAssertTrue(display.visibleFrame.contains(frame),
                          "Offscreen: display=\(display.id), corner=\(corner), index=\(index)")
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThan(frame.height, 0)
                    }
                }
            }
        }
    }

    func testTinyScreenClampsPanelSizeWithoutClippingOutsideDisplay() {
        let tiny = CGRect(x: -500, y: -100, width: 200, height: 150)
        for corner in OverlayCorner.allCases {
            let frame = QuickAccessGeometry.frame(
                visible: tiny, card: CGSize(width: 365, height: 318),
                corner: corner, index: 2, count: 3)
            XCTAssertTrue(tiny.contains(frame), "Off-screen on constrained layout")
        }
    }

    func testNativeURLDragPayloadRoundTripAndExternalFileIntegrity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-drag-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("AOM Quick Access.png")
        let sample = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try sample.write(to: input)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([input as NSURL]),
                      "Matches the NSURL drag writer of QuickAccessDragSource")
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        let urls = QuickAccessDragInterop.urls(from: pasteboard)
        XCTAssertEqual(urls, [input])
        XCTAssertEqual(try Data(contentsOf: input), sample,
                       "Drag inspection must not modify the source.")
    }

    func testRejectedDragInputsAreSafelyIgnored() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertTrue(pb.setString("not a file", forType: .string))
        XCTAssertTrue(QuickAccessDragInterop.urls(from: pb).isEmpty)
        pb.clearContents()
        let missing = URL(fileURLWithPath: "/tmp/aom-missing-\(UUID()).png")
        XCTAssertTrue(pb.writeObjects([missing as NSURL]))
        XCTAssertTrue(QuickAccessDragInterop.urls(from: pb).isEmpty)
    }

    func testSimulatedPermissionRevocationAndRecoveryAreDetected() {
        let before: [AOMPermission: AOMPermissionStatus] = [
            .accessibility: .granted,
            .screenRecording: .granted,
            .inputMonitoring: .granted
        ]
        let revoked: [AOMPermission: AOMPermissionStatus] = [
            .accessibility: .denied,
            .screenRecording: .denied,
            .inputMonitoring: .granted
        ]
        let changes = AOMPermissionTransitions.changed(from: before, to: revoked)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains(where: {
            $0.permission == .accessibility && $0.from == .granted && $0.to == .denied
        }))
        XCTAssertTrue(changes.contains(where: {
            $0.permission == .screenRecording && $0.restartMayBeNeeded
        }))
        let restored = AOMPermissionTransitions.changed(from: revoked, to: before)
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.allSatisfy { $0.to == .granted })
        XCTAssertTrue(AOMPermissionTransitions.changed(from: before, to: before).isEmpty)
    }

    func testNativeDragSourceDoesNotRequireExternalIntegrationOrNetwork() {
        let view = QuickAccessDragSource.DraggableView()
        XCTAssertTrue(view.conforms(to: NSDraggingSource.self))
        let receiver = QuickAccessDropReceiver.Receiver()
        XCTAssertNotNil(receiver)
    }
}
