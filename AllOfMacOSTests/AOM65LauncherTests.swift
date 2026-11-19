import AppKit
import XCTest
@testable import AllOfMacOS

/// 6.5 second round: the ⌥Space launcher, the glass design rules, the HomePod
/// load diagnosis and the defects confirmed from the 14-item review.
final class LauncherRoutingTests: XCTestCase {
    func testSheetsKeepThePanelAndAOMWindowsDoNotRestoreTheFrontApp() {
        XCTAssertTrue(PaletteLauncherRouting.keepsPanel("quicklinks.edit"))
        XCTAssertTrue(PaletteLauncherRouting.keepsPanel("links.router"))
        XCTAssertFalse(PaletteLauncherRouting.keepsPanel("window.left"))
        XCTAssertFalse(PaletteLauncherRouting.restoresFocus(id: "go.Audio", section: .navigation, action: "Open"))
        XCTAssertFalse(PaletteLauncherRouting.restoresFocus(id: "action.Copy", section: .commands, action: "Configure Automation"))
        XCTAssertFalse(PaletteLauncherRouting.restoresFocus(id: "trigger.x", section: .automations, action: "Open in Editor"))
        XCTAssertTrue(PaletteLauncherRouting.restoresFocus(id: "trigger.x", section: .automations, action: "Run Now"))
        XCTAssertFalse(PaletteLauncherRouting.restoresFocus(id: "app./Applications/Tool.app", section: .applications,
                                                            action: "Uninstall…"))
        XCTAssertTrue(PaletteLauncherRouting.restoresFocus(id: "app./Applications/Tool.app", section: .applications,
                                                           action: "Hide"))
        XCTAssertTrue(PaletteLauncherRouting.restoresFocus(id: "window.left", section: .commands, action: "Run"),
                      "tiling acts on the app that was in front")
        XCTAssertTrue(PaletteLauncherRouting.restoresFocus(id: "menu.12", section: .menuItems, action: "Choose in Safari"))
    }

    @MainActor
    func testPanelSitsInTheUpperMiddleOfTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 25, width: 1920, height: 1030)
        let frame = AOMLauncherController.frame(on: visible)
        XCTAssertEqual(frame.size, AOMLauncherController.size)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
        XCTAssertLessThan(frame.maxY, visible.maxY)
        XCTAssertGreaterThan(frame.minY, visible.midY - frame.height, "upper half, like Raycast")
        let short = CGRect(x: 0, y: 0, width: 800, height: 500)
        XCTAssertGreaterThanOrEqual(AOMLauncherController.frame(on: short).minY, short.minY)
    }

    func testShortcutChoicesAvoidMacOSSpaceKeys() {
        XCTAssertEqual(AOMLauncherShortcut.optionSpace.displayString, "⌥Space")
        XCTAssertNil(AOMLauncherShortcut.off.carbonModifiers)
        XCTAssertTrue(AOMLauncherShortcut.off.keycaps.isEmpty)
        for choice in AOMLauncherShortcut.allCases where choice != .off {
            XCTAssertNotNil(choice.carbonModifiers)
            XCTAssertEqual(choice.keyCode, 49)
        }
        XCTAssertFalse(AOMLauncherShortcut.allCases.map(\.displayString).contains("⌃Space"), "input source switching")
    }

    func testResultsAreBuiltOncePerQueryAndChange() {
        let cache = PaletteResultsCache()
        var builds = 0
        func items(_ key: PaletteResultsCache.Key) -> Int {
            cache.items(for: key) { builds += 1; return [] }.count
        }
        _ = items(.init(query: "sa", refresh: 0, generation: 0))
        _ = items(.init(query: "sa", refresh: 0, generation: 0))
        _ = items(.init(query: "sa", refresh: 0, generation: 0))
        XCTAssertEqual(builds, 1, "hover and arrow keys reuse the list")
        _ = items(.init(query: "saf", refresh: 0, generation: 0))
        _ = items(.init(query: "saf", refresh: 0, generation: 1))
        _ = items(.init(query: "saf", refresh: 1, generation: 1))
        XCTAssertEqual(builds, 4)
    }

    func testLauncherLink() {
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://open-launcher")!), .openLauncher)
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://open-launcher?query=x")!))
    }
}

final class AOM65ReviewDefectTests: XCTestCase {
    private func stroke(_ code: UInt16, required: Bool = true) -> KeySequenceStroke {
        KeySequenceStroke(keyCode: code, modifiers: 0, isRequired: required)
    }

    func testSequenceGapIsMeasuredBetweenMatchedStrokesOnly() {
        let detector = KeySequenceDetector()
        // An unrelated key long before; the sequence itself typed in time.
        detector.press(stroke(7), at: 0, in: "app"); detector.release(7)
        detector.press(stroke(11), at: 10, in: "app"); detector.release(11)
        detector.press(stroke(8), at: 10.2, in: "app"); detector.release(8)
        let pattern = [stroke(0, required: false), stroke(11), stroke(8)]
        XCTAssertTrue(detector.matches(pattern, maxGapMs: 500))
        XCTAssertTrue(detector.matches(pattern, maxGapMs: 500, orderRelevant: false))
        // Slow between the strokes that matter still fails.
        let slow = KeySequenceDetector()
        slow.press(stroke(11), at: 0, in: "app"); slow.release(11)
        slow.press(stroke(8), at: 2, in: "app"); slow.release(8)
        XCTAssertFalse(slow.matches([stroke(11), stroke(8)], maxGapMs: 500))
    }

    func testActivationContextAnswersFromAStaleCacheWhileItRefreshes() {
        typealias Context = ActivationConditionsContext
        XCTAssertEqual(Context.cacheUse(age: nil, hasWindows: false, needsWindows: false), .miss)
        XCTAssertEqual(Context.cacheUse(age: 0.5, hasWindows: false, needsWindows: false), .fresh)
        XCTAssertEqual(Context.cacheUse(age: 3, hasWindows: false, needsWindows: false), .stale)
        XCTAssertEqual(Context.cacheUse(age: 30, hasWindows: true, needsWindows: true), .miss)
        XCTAssertEqual(Context.cacheUse(age: 0.2, hasWindows: false, needsWindows: true), .miss,
                       "a window condition never reads a cache without windows")
    }

    func testCustomColorKeepsItsAlpha() throws {
        var style = AnnotationStyle()
        style.customColorHex = "00FF0080"
        let color = try XCTUnwrap(style.resolvedColor.usingColorSpace(.sRGB))
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(color.alphaComponent, 128.0 / 255, accuracy: 0.01)
        style.customColorHex = "00FF00"
        XCTAssertEqual(try XCTUnwrap(style.resolvedColor.usingColorSpace(.sRGB)).alphaComponent, 1, accuracy: 0.01)
    }

    func testCursorIsDrawnInsideItsBox() throws {
        let width = 120, height = 120
        let base = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        base.setFillColor(NSColor.white.cgColor)
        base.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var document = AnnotationDocument(baseImage: try XCTUnwrap(base.makeImage()))
        var style = AnnotationStyle()
        style.customColorHex = "FF0000"
        document.add(AnnotationObject(kind: .cursor, rect: CGRect(x: 30, y: 20, width: 40, height: 40), style: style))
        let image = try XCTUnwrap(document.render(scale: 1))
        // Read back top-down: row 0 is the top of the image.
        let reader = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(reader.data).assumingMemoryBound(to: UInt8.self)
        var rows: [Int] = []
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4
                if pixels[i] > 200, pixels[i + 1] < 60, pixels[i + 2] < 60 { rows.append(row) }
            }
        }
        // The bitmap's first row in memory is the image's top row.
        let top = try XCTUnwrap(rows.min()), bottom = try XCTUnwrap(rows.max())
        XCTAssertGreaterThanOrEqual(top, 18, "the tip is at the box's top-left")
        XCTAssertLessThanOrEqual(bottom, 62, "the pointer stays inside its 40 pt box")
    }

    func testTranslucencyFollowsAccessibilityAndTheSetting() {
        XCTAssertEqual(AOMTranslucency.pageAlpha(enabled: true, reduceTransparency: false, increaseContrast: false, dark: false),
                       AOMTranslucency.pageAlphaLight)
        XCTAssertEqual(AOMTranslucency.pageAlpha(enabled: true, reduceTransparency: true, increaseContrast: false, dark: true), 1)
        XCTAssertEqual(AOMTranslucency.pageAlpha(enabled: true, reduceTransparency: false, increaseContrast: true, dark: true), 1)
        XCTAssertEqual(AOMTranslucency.pageAlpha(enabled: false, reduceTransparency: false, increaseContrast: false, dark: true), 1)
    }

    func testRunsTodayCountsFiredEventsOfListedInputs() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let events = [GestureEvent(gesture: "Tap", timestamp: start.addingTimeInterval(-60), fired: true),
                      GestureEvent(gesture: "Tap", timestamp: start.addingTimeInterval(60), fired: true),
                      GestureEvent(gesture: "Tap", timestamp: start.addingTimeInterval(70), fired: false),
                      GestureEvent(gesture: "Swipe", timestamp: start.addingTimeInterval(80), fired: true)]
        XCTAssertEqual(AutomationRunsToday.count(events, since: start, names: ["Tap"]), 1)
        XCTAssertEqual(AutomationRunsToday.count(events, since: start, names: ["Tap", "Swipe"]), 2)
    }
}

final class AudioSystemLoadTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824

    func testSwapAndHeatAreNamed() {
        XCTAssertEqual(AudioSystemLoad.causes(swapUsed: 7 * gb, swapTotal: 8 * gb, thermal: .nominal),
                       [.memory(swappedGB: 7)])
        XCTAssertEqual(AudioSystemLoad.causes(swapUsed: 0, swapTotal: 0, thermal: .serious), [.heat(.serious)])
        XCTAssertTrue(AudioSystemLoad.causes(swapUsed: gb / 2, swapTotal: 2 * gb, thermal: .fair).isEmpty)
        XCTAssertNil(AudioSystemLoad.summary([]))
        XCTAssertEqual(AudioSystemLoad.summary([.memory(swappedGB: 7.2)]),
                       "Crackle likely: the Mac is short of memory (7.2 GB swapped)")
    }
}
