import CoreGraphics
import XCTest
@testable import AllOfMacOS

/// Copy formats, label text and the stored settings (in a throwaway defaults suite).
final class ScreenRulerFormatTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ScreenRulerFormatTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testNumbersStayWholeOrKeepUpToTwoDecimals() {
        XCTAssertEqual(ScreenRulerFormat.number(120), "120")
        XCTAssertEqual(ScreenRulerFormat.number(60.5), "60.5")
        XCTAssertEqual(ScreenRulerFormat.number(100.0 / 3), "33.33")
        XCTAssertEqual(ScreenRulerFormat.number(0.5), "0.5")
        XCTAssertEqual(ScreenRulerFormat.number(44.999), "45")
        XCTAssertEqual(ScreenRulerFormat.number(.nan), "0")
    }

    func testTheThreeCopyFormats() {
        XCTAssertEqual(ScreenRulerFormat.copyText(width: 120, height: 44, format: .times), "120 × 44")
        XCTAssertEqual(ScreenRulerFormat.copyText(width: 120, height: 44, format: .compact), "120x44")
        XCTAssertEqual(ScreenRulerFormat.copyText(width: 120, height: 44, format: .css), "width: 120px; height: 44px;")
        XCTAssertEqual(ScreenRulerFormat.copyText(width: 60.5, height: 22, format: .css), "width: 60.5px; height: 22px;")
        XCTAssertEqual(ScreenRulerCopyFormat.allCases.map(\.example),
                       ["120 × 44", "120x44", "width: 120px; height: 44px;"])
    }

    func testCopiedMeasurementsUseTheShownUnitButCSSAlwaysUsesPoints() {
        let display = ScreenRulerDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        let area = ScreenRulerMeasurement.area(ScreenRulerArea(display: display,
                                                               rect: ScreenRulerPixelRect(x: 0, y: 0, width: 240, height: 88),
                                                               snapped: true))
        XCTAssertEqual(ScreenRulerFormat.copyText(for: area, unit: .points, format: .times), "120 × 44")
        XCTAssertEqual(ScreenRulerFormat.copyText(for: area, unit: .pixels, format: .times), "240 × 88")
        XCTAssertEqual(ScreenRulerFormat.copyText(for: area, unit: .pixels, format: .compact), "240x88")
        XCTAssertEqual(ScreenRulerFormat.copyText(for: area, unit: .pixels, format: .css), "width: 120px; height: 44px;",
                       "a CSS pixel is a point")
        let distances = ScreenRulerMeasurement.distances(ScreenRulerDistances(
            display: display, pixel: ScreenRulerPixel(x: 5, y: 5),
            horizontal: ScreenRulerSpan(lower: 0, upper: 31, reachesLowerBorder: true, reachesUpperBorder: false),
            vertical: ScreenRulerSpan(lower: 2, upper: 12, reachesLowerBorder: false, reachesUpperBorder: false)))
        XCTAssertEqual(ScreenRulerFormat.copyText(for: distances, unit: .points, format: .times), "15.5 × 5")
        XCTAssertEqual(ScreenRulerFormat.spoken(distances, unit: .points), "Distances: width 15.5 points, height 5 points")
        XCTAssertEqual(ScreenRulerFormat.spoken(area, unit: .pixels), "Object: width 240 pixels, height 88 pixels")
    }

    func testLabelsShowTheSecondUnitOnlyWhereTheyDiffer() {
        XCTAssertEqual(ScreenRulerFormat.length(pixels: 240, scale: 2, unit: .points, showsBoth: false), "120 pt")
        XCTAssertEqual(ScreenRulerFormat.length(pixels: 240, scale: 2, unit: .points, showsBoth: true), "120 pt · 240 px")
        XCTAssertEqual(ScreenRulerFormat.length(pixels: 240, scale: 2, unit: .pixels, showsBoth: true), "240 px · 120 pt")
        XCTAssertEqual(ScreenRulerFormat.length(pixels: 240, scale: 1, unit: .points, showsBoth: true), "240 pt",
                       "on a 1× display both units are the same number")
        XCTAssertEqual(ScreenRulerFormat.length(pixels: 100, scale: 3, unit: .points, showsBoth: false), "33.33 pt")
        XCTAssertEqual(ScreenRulerFormat.size(width: 240, height: 88, scale: 2, unit: .points, showsBoth: false), "120 × 44 pt")
        XCTAssertEqual(ScreenRulerFormat.size(width: 240, height: 88, scale: 2, unit: .points, showsBoth: true),
                       "120 × 44 pt · 240 × 88 px")
    }

    func testSettingsDefaultsClampingAndStorage() {
        let settings = ScreenRulerSettings(defaults: defaults)
        XCTAssertEqual(settings.options, ScreenRulerOptions())
        XCTAssertEqual(settings.tolerance, 0.1)
        XCTAssertEqual(settings.unit, .points)
        XCTAssertEqual(settings.copyFormat, .times)
        XCTAssertTrue(settings.snapsArea)
        XCTAssertFalse(settings.hidesCursor)
        XCTAssertFalse(settings.showsColor)
        XCTAssertFalse(settings.showsBothUnits)
        XCTAssertEqual(settings.guideColor.hex, "#E0004DFF")

        settings.tolerance = 2
        XCTAssertEqual(settings.tolerance, 0.5, "kept inside the slider's range")
        settings.tolerance = -1
        XCTAssertEqual(settings.tolerance, 0)
        defaults.set("furlongs", forKey: ScreenRulerSettings.unitKey)
        XCTAssertEqual(settings.unit, .points, "an unknown stored unit falls back to points")
        settings.unit = .pixels
        settings.copyFormat = .css
        settings.guideColor = AOMRGBAColor(red: 0, green: 0.5, blue: 1)
        settings.hidesCursor = true
        let options = settings.options
        XCTAssertEqual(options.unit, .pixels)
        XCTAssertEqual(options.copyFormat, .css)
        XCTAssertEqual(options.guideColor.hex, "#0080FFFF")
        XCTAssertTrue(options.hidesCursor)
        XCTAssertEqual(defaults.string(forKey: ScreenRulerSettings.unitKey), "px")
        XCTAssertEqual(defaults.string(forKey: ScreenRulerSettings.copyFormatKey), "css")
    }

    func testEverySettingIsAnAOMKeyAndBackedUp() {
        XCTAssertEqual(Set(ScreenRulerSettings.backedUpKeys).count, 8)
        for key in ScreenRulerSettings.backedUpKeys {
            XCTAssertTrue(key.hasPrefix("AOMScreenRuler"), key)
            XCTAssertTrue(PreferenceResetRegistry.isAOMKey(key), "\(key) is reset by Reset Preferences")
        }
    }

    func testLabelTextKeepsContrastOnTheGuideColour() {
        XCTAssertFalse(ScreenRulerStyle.prefersDarkText(on: ScreenRulerSettings.defaultGuideColor), "white on the default")
        XCTAssertTrue(ScreenRulerStyle.prefersDarkText(on: AOMRGBAColor(red: 1, green: 0.9, blue: 0)), "black on yellow")
        XCTAssertFalse(ScreenRulerStyle.prefersDarkText(on: AOMRGBAColor(red: 0, green: 0.2, blue: 0.8)), "white on blue")
    }
}
