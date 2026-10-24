import XCTest
import AppKit
import ScreenCaptureKit
@testable import AllOfMacOS

final class WindowPinningTests: XCTestCase {
    func testCoordinatesRoundTripAcrossNegativeAndVerticalMonitors() {
        for frame in [CGRect(x: -1800, y: 80, width: 800, height: 600),
                      CGRect(x: 300, y: -1200, width: 900, height: 700),
                      CGRect(x: 20, y: 1300, width: 1000, height: 500)] {
            let appKit = WindowPinningGeometry.appKitFrame(frame, primaryTop: 1080)
            XCTAssertEqual(WindowPinningGeometry.appKitFrame(appKit, primaryTop: 1080), frame)
        }
    }

    func testControlsStayInsideEveryCornerOfOffsetWindow() {
        let frame = CGRect(x: -1400, y: 750, width: 500, height: 300)
        let controls = WindowPinningOptions.Corner.allCases.map { WindowPinningGeometry.controls(in: frame, corner: $0) }
        XCTAssertTrue(controls.allSatisfy { frame.contains($0) })
        XCTAssertEqual(Set(controls.map { "\($0.minX),\($0.minY)" }).count, 4)
    }

    func testOnlyActualOverlapsDuckAndDisablingDuckingWins() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(WindowPinningGeometry.shouldDuck(frame, activeFrame: frame.offsetBy(dx: 50, dy: 50), enabled: true))
        XCTAssertFalse(WindowPinningGeometry.shouldDuck(frame, activeFrame: frame.offsetBy(dx: 100, dy: 0), enabled: true))
        XCTAssertFalse(WindowPinningGeometry.shouldDuck(frame, activeFrame: frame, enabled: false))
        XCTAssertFalse(WindowPinningGeometry.shouldDuck(frame, activeFrame: nil, enabled: true))
    }

    func testWindowFilterExcludesOwnPanelsSystemWindowsAndBlockedApps() {
        var options = WindowPinningOptions()
        func allows(_ bundle: String = "com.example.app", _ title: String = "Document", pid: pid_t = 20, layer: Int = 0) -> Bool {
            options.allows(bundleID: bundle, title: title, ownPID: 10, pid: pid, layer: layer,
                           frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        XCTAssertTrue(allows())
        XCTAssertFalse(allows(pid: 10))
        XCTAssertFalse(allows(layer: 25))
        XCTAssertFalse(allows("com.apple.dock"))
        options.excludedBundleIDs = ["com.example.app"]
        XCTAssertFalse(allows())
        options.excludedBundleIDs = []
        options.showUntitledWindows = false
        XCTAssertFalse(allows("com.example.app", ""))
    }

    func testRefreshRateAndOversizedRetinaCaptureRemainBounded() {
        var options = WindowPinningOptions()
        XCTAssertEqual(options.frameRate(displayRate: 120), 60)
        options.maximumFPS = 120
        XCTAssertEqual(options.frameRate(displayRate: 60), 60)
        options.maximumFPS = 0
        XCTAssertEqual(options.frameRate(displayRate: 144), 144)
        XCTAssertEqual(options.frameRate(displayRate: 0), 1)
        let size = WindowPinningGeometry.pixelSize(CGSize(width: 6000, height: 3000), scale: 2)
        XCTAssertEqual(size, CGSize(width: 7680, height: 3840))
        XCTAssertEqual(WindowPinningGeometry.pixelSize(CGSize(width: CGFloat.nan, height: 0), scale: 2), CGSize(width: 2, height: 2))
    }

    func testPreferencesAndActionsRoundTripWithoutReplacingCapturePin() throws {
        var options = WindowPinningOptions()
        options.activation = .doubleClick; options.corner = .bottomRight
        options.excludedBundleIDs = ["com.example.private"]
        XCTAssertEqual(try JSONDecoder().decode(WindowPinningOptions.self, from: JSONEncoder().encode(options)), options)
        for action in WindowPinningService.actionTypes {
            XCTAssertEqual(action.category, .windowManagement)
            XCTAssertFalse(action.description.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(ActionType.self, from: JSONEncoder().encode(action)), action)
        }
        XCTAssertEqual(ActionType.pinLastCapture.category, .screenCapture)
        XCTAssertEqual(ActionType.bringWindowToFront.rawValue, "Bring Window to Front")
        XCTAssertFalse(ActionType.unpinAllWindows.needsFocusedWindow)
        XCTAssertFalse(ActionType.showPinnedWindowPicker.needsFocusedWindow)
        XCTAssertFalse(ActionType.togglePinWindowUnderCursor.needsFocusedWindow)
        XCTAssertTrue(ActionType.togglePinFrontWindow.needsFocusedWindow)
        for action in [CaptureShortcutAction.choosePinnedWindow, .selectPinnedWindow, .togglePinFrontWindow,
                       .togglePinWindowUnderCursor, .unpinAllWindows] {
            XCTAssertNil(action.defaultShortcut, "New features must not steal existing shortcuts")
            XCTAssertEqual(action.categoryName, "Always on Top")
        }
    }
}

/// Explicit opt-in, limited to a disposable fixture owned by this test process.
/// Never selects, moves or closes a user's window.
@MainActor
final class WindowPinningRuntimeTests: XCTestCase {
    func testTwoLiveWindowsAndTranslucentSourceRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["AOM_PIN_FIXTURE_PATH"] else {
            throw XCTSkip("Set AOM_PIN_FIXTURE_PATH to the disposable com.kyw.aom.pinfixture executable")
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Runtime host needs existing Accessibility and Screen Recording permission")
        }
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        guard bundle?.bundleIdentifier == "com.kyw.aom.pinfixture" else { throw XCTSkip("Refusing a non-fixture application") }
        let process = Process()
        process.executableURL = url
        try process.run()
        let service = WindowPinningService.shared
        let previousOptions = service.options
        defer {
            service.unpinAll()
            service.options = previousOptions
            if process.isRunning { process.terminate() }
        }
        service.options.activation = .click
        var windows: [SCWindow] = []
        for _ in 0..<30 {
            windows = try await service.availableWindows().filter { $0.owningApplication?.processID == process.processIdentifier }
            if windows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(windows.count, 2)
        guard windows.count == 2 else { return }
        for window in windows { let pinned = try await service.pin(window); XCTAssertTrue(pinned) }
        XCTAssertEqual(service.pins.count, 2)
        let first = try XCTUnwrap(service.pins.first)
        let second = try XCTUnwrap(service.pins.last)
        try await waitFor { first.capture.hasFrame && second.capture.hasFrame }
        XCTAssertTrue(first.panel.isVisible)
        XCTAssertEqual(first.panel.level, .floating)
        XCTAssertFalse(first.panel.canBecomeKey)
        let original = try XCTUnwrap(WindowManager.shared.frame(of: first.target))
        XCTAssertTrue(WindowPinRestoration.move(first.target, to: original.origin.applying(CGAffineTransform(translationX: 35, y: 25))))
        try await waitFor { abs(first.frame.minX - original.minX - 35) < 4 }
        let moved = try XCTUnwrap(WindowManager.shared.frame(of: first.target))
        service.setOpacity(0.6, for: first)
        try await waitFor { first.parkedFrame != nil }
        XCTAssertEqual(first.opacity, 0.6)
        service.togglePause(first)
        try await waitFor { first.parkedFrame == nil && first.capture.desired == nil }
        let restored = try XCTUnwrap(WindowManager.shared.frame(of: first.target))
        XCTAssertTrue(WindowGeometry.close(restored, moved))
        service.togglePause(first)
        try await waitFor { first.parkedFrame != nil }
        service.unpin(first.id)
        XCTAssertTrue(WindowGeometry.close(try XCTUnwrap(WindowManager.shared.frame(of: first.target)), moved))
        XCTAssertEqual(service.pins.count, 1)
        service.closeSource(second)
        try await waitFor { service.pins.isEmpty }
        await first.capture.waitUntilSettled()
        await second.capture.waitUntilSettled()
        XCTAssertTrue(first.capture.isClosed && second.capture.isClosed)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<60 { if condition() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("Live pinning did not reach its expected state within six seconds")
    }
}

@MainActor
final class WindowPinCaptureLifecycleTests: XCTestCase {
    private let configuration = PinnedWindowCapture.Configuration(width: 800, height: 600, fps: 60)

    func testRecoveryRecognizesClampedEdgeButPreservesManualReposition() {
        let original = CGRect(x: 100, y: 100, width: 400, height: 300)
        let edge = CGRect(x: 100, y: 1056, width: 400, height: 300)
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        var entry = WindowPinRestoration.Entry(windowID: 20, pid: 10, bundleID: "test", launchDate: Date(), frame: original, parkedFrame: edge)
        XCTAssertTrue(WindowPinRestoration.shouldRecover(entry, current: edge, screens: screens))
        XCTAssertFalse(WindowPinRestoration.shouldRecover(entry, current: original.offsetBy(dx: 50, dy: 50), screens: screens))
        entry.parkedFrame = nil
        XCTAssertTrue(WindowPinRestoration.shouldRecover(entry, current: edge, screens: screens))
        XCTAssertFalse(WindowPinRestoration.shouldRecover(entry, current: original, screens: screens))
    }

    func testUnpinWhileStartIsPendingStopsLateStreamExactlyOnce() async {
        let fake = FakePinStream()
        fake.holdStart = true
        var creations = 0
        let capture = PinnedWindowCapture { _, _ in creations += 1; return fake }
        capture.request(configuration)
        await yieldUntil { fake.startContinuation != nil }
        capture.close()
        fake.finishStart()
        await capture.waitUntilSettled()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertTrue(capture.isClosed)
        XCTAssertNil(capture.desired)
        capture.request(configuration)
        await capture.waitUntilSettled()
        XCTAssertEqual(creations, 1)
    }

    func testResumeWaitsForPendingStopAndUsesLatestSize() async {
        let first = FakePinStream(), second = FakePinStream()
        first.holdStop = true
        var created: [SCStreamConfiguration] = []
        let capture = PinnedWindowCapture { config, _ in
            created.append(config)
            return created.count == 1 ? first : second
        }
        capture.request(configuration)
        await capture.waitUntilSettled()
        capture.request(nil)
        await yieldUntil { first.stopContinuation != nil }
        capture.request(.init(width: 1200, height: 900, fps: 30))
        await Task.yield()
        XCTAssertEqual(created.count, 1, "A second stream cannot overlap a stopping stream")
        first.finishStop()
        await capture.waitUntilSettled()
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.last?.width, 1200)
        XCTAssertEqual(created.last?.height, 900)
        capture.close()
        await capture.waitUntilSettled()
        XCTAssertEqual(second.stopCount, 1)
    }

    func testFailureReportsOnceAndDoesNotRetryForever() async {
        let fake = FakePinStream()
        fake.startError = NSError(domain: "WindowPinningTests", code: 1)
        var creations = 0, failures = 0
        let capture = PinnedWindowCapture { _, _ in creations += 1; return fake }
        capture.onFailure = { _ in failures += 1; capture.close() }
        capture.request(configuration)
        await capture.waitUntilSettled()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertNotNil(capture.failure)
    }

    func testResizeWhileStartingAppliesNewestConfigurationWithoutNewStream() async {
        let fake = FakePinStream()
        fake.holdStart = true
        var creations = 0
        let capture = PinnedWindowCapture { _, _ in creations += 1; return fake }
        capture.request(configuration)
        await yieldUntil { fake.startContinuation != nil }
        capture.request(.init(width: 1000, height: 700, fps: 30))
        capture.request(.init(width: 1400, height: 1000, fps: 120))
        fake.finishStart()
        await capture.waitUntilSettled()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(fake.updates.count, 1)
        XCTAssertEqual(fake.updates.last?.width, 1400)
        capture.close()
        await capture.waitUntilSettled()
    }

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Capture operation did not reach the expected suspension point")
    }
}

@MainActor
private final class FakePinStream: WindowPinCaptureStream {
    var holdStart = false, holdStop = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var startError: Error?
    var stopCount = 0
    var updates: [SCStreamConfiguration] = []
    func startCapture() async throws {
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startError { throw startError }
    }
    func stopCapture() async throws {
        stopCount += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
    }
    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws { updates.append(configuration) }
    func finishStart() { startContinuation?.resume(); startContinuation = nil }
    func finishStop() { stopContinuation?.resume(); stopContinuation = nil }
}
