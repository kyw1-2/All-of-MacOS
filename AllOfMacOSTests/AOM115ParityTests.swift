import XCTest
import AppKit
@testable import AllOfMacOS

final class AOM115ParityTests: XCTestCase {

    // MARK: - Spotlight Shape & Opacity Parity

    func testSpotlightShapeAndOpacityProperties() throws {
        var style = AnnotationStyle()
        XCTAssertNil(style.spotlightShape)
        XCTAssertNil(style.spotlightOpacity)

        style.spotlightShape = .ellipse
        style.spotlightOpacity = 0.75

        let encoded = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: encoded)

        XCTAssertEqual(decoded.spotlightShape, .ellipse)
        XCTAssertEqual(decoded.spotlightOpacity, 0.75)
    }

    func testSpotlightRenderingDoesNotCrashWithEllipse() {
        let size = CGSize(width: 200, height: 150)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let baseImage = ctx.makeImage()!

        var document = AnnotationDocument(baseImage: baseImage)
        var obj = AnnotationObject(kind: .spotlight, rect: CGRect(x: 20, y: 20, width: 80, height: 60))
        obj.style.spotlightShape = .ellipse
        obj.style.spotlightOpacity = 0.85
        document.add(obj)

        let rendered = document.render(scale: 1)
        XCTAssertNotNil(rendered)
    }

    // MARK: - Counter Styles Parity

    func testCounterStyleFormatting() {
        XCTAssertEqual(CounterStyle.numbers.format(1), "1")
        XCTAssertEqual(CounterStyle.numbers.format(42), "42")

        XCTAssertEqual(CounterStyle.upperAlpha.format(1), "A")
        XCTAssertEqual(CounterStyle.upperAlpha.format(26), "Z")
        XCTAssertEqual(CounterStyle.upperAlpha.format(27), "AA")

        XCTAssertEqual(CounterStyle.lowerAlpha.format(1), "a")
        XCTAssertEqual(CounterStyle.lowerAlpha.format(3), "c")
        XCTAssertEqual(CounterStyle.lowerAlpha.format(28), "ab")

        XCTAssertEqual(CounterStyle.roman.format(1), "I")
        XCTAssertEqual(CounterStyle.roman.format(4), "IV")
        XCTAssertEqual(CounterStyle.roman.format(9), "IX")
        XCTAssertEqual(CounterStyle.roman.format(14), "XIV")
        XCTAssertEqual(CounterStyle.roman.format(2026), "MMXXVI")
    }

    // MARK: - Clipboard Timed Pause & Ignored Apps

    @MainActor
    func testClipboardTimedPauseAndResume() {
        let suite = "AOM115ClipboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ClipboardStore(defaults: defaults)
        XCTAssertFalse(store.paused)
        XCTAssertEqual(store.pauseRemainingSeconds, 0)

        // Indefinite pause
        store.pause(for: 0)
        XCTAssertTrue(store.paused)
        XCTAssertEqual(store.pauseRemainingSeconds, 0)

        store.resume()
        XCTAssertFalse(store.paused)

        // Timed pause
        store.pause(for: 300)
        XCTAssertTrue(store.paused)
        XCTAssertEqual(store.pauseRemainingSeconds, 300)

        store.resume()
        XCTAssertFalse(store.paused)
        XCTAssertEqual(store.pauseRemainingSeconds, 0)
    }

    func testIgnoredAppsTrimming() {
        var settings = ClipboardStore.Settings()
        settings.ignoredApps = ["  com.example.app1  ", "", "\n", "com.example.app2"]
        let bounded = settings.bounded
        XCTAssertEqual(bounded.ignoredApps, ["com.example.app1", "com.example.app2"])
    }

    // MARK: - Named Trigger Execution & URL Scheme

    func testExecuteNamedTriggerDispatchesMatchingActions() {
        let name = "UnitTestTrigger-\(UUID().uuidString)"
        var action = TriggerAction(actionType: .showHUD)
        action.parameters.label = "HUD From Named"
        var trigger = Trigger(name: "Test", input: .namedTrigger(name))
        trigger.actions = [action]

        ActionExecutor.registerTriggers([trigger])
        defer { ActionExecutor.registerTriggers([]) }

        var executedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { executedAction = $0 }
        defer { ActionExecutor.onActionExecuted = nil }

        let exp = expectation(description: "named trigger executed")
        ActionExecutor.executeNamedTrigger(name) { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(executedAction?.parameters.label, "HUD From Named")
    }

    // MARK: - Dominant Script Determinism

    func testDominantScriptDeterminismWithTies() {
        for _ in 0..<10 {
            XCTAssertEqual(TextScriptClassifier.dominantScript("안녕하세요 world"), .hangul)
        }
    }
}
