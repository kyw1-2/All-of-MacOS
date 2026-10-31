import XCTest
@testable import AllOfMacOS

/// The link router (Velja/Choosy): tracking parameters, rules, the fallback
/// that never points back at AOM, app links and stored settings. Nothing is
/// opened and no default browser is changed.
final class PaletteLinkRouterTests: XCTestCase {
    private let defaults = PaletteLinkRouterSettings().trackingParameters

    func testTrackingParametersAreRemovedAndTheRestKept() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a?id=7&utm_source=x&utm_medium=y&fbclid=Z&q=%EA%B0%80&gclid=1#top"))
        XCTAssertEqual(PaletteLinkCleaner.clean(url, parameters: defaults).absoluteString, "https://example.com/a?id=7&q=%EA%B0%80#top",
                       "order, encoding and the fragment stay")
        let only = try XCTUnwrap(URL(string: "https://youtu.be/abc?si=XYZ"))
        XCTAssertEqual(PaletteLinkCleaner.clean(only, parameters: defaults).absoluteString, "https://youtu.be/abc",
                       "no empty ? is left behind")
        let clean = try XCTUnwrap(URL(string: "https://example.com/?page=2"))
        XCTAssertEqual(PaletteLinkCleaner.clean(clean, parameters: defaults), clean)
        XCTAssertEqual(PaletteLinkCleaner.clean(url, parameters: []), url, "an empty list changes nothing")
    }

    func testParameterPatterns() {
        XCTAssertTrue(PaletteLinkCleaner.matches("utm_campaign", pattern: "utm_*"))
        XCTAssertTrue(PaletteLinkCleaner.matches("FBCLID", pattern: "fbclid"))
        XCTAssertFalse(PaletteLinkCleaner.matches("utmost", pattern: "utm_*"))
        XCTAssertFalse(PaletteLinkCleaner.matches("sid", pattern: "si"), "names match whole")
        XCTAssertFalse(PaletteLinkCleaner.matches("x", pattern: " "))
    }

    func testRulesAndFallback() throws {
        var settings = PaletteLinkRouterSettings()
        settings.isEnabled = true
        settings.fallbackBrowserBundleID = "com.google.Chrome"
        settings.rules = [
            PaletteLinkRule(match: .hostContains, pattern: "uos.ac.kr", browserBundleID: "com.apple.Safari"),
            PaletteLinkRule(match: .hostIs, pattern: "github.com", browserBundleID: "com.google.Chrome.canary"),
            PaletteLinkRule(match: .urlStartsWith, pattern: "http://localhost", browserBundleID: "org.mozilla.firefox"),
            PaletteLinkRule(match: .urlContains, pattern: "/meet/", browserBundleID: "com.example.Off", isEnabled: false),
        ]
        func target(_ text: String, own: String? = "com.kyw.allofmacos") throws -> String {
            PaletteLinkRouting.destination(for: try XCTUnwrap(URL(string: text)), settings: settings, ownBundleID: own)
        }
        XCTAssertEqual(try target("https://portal.uos.ac.kr/main"), "com.apple.Safari")
        XCTAssertEqual(try target("https://www.github.com/apple"), "com.google.Chrome.canary", "Host is allows www.")
        XCTAssertEqual(try target("https://gist.github.com/x"), "com.google.Chrome", "Host is is not Host contains")
        XCTAssertEqual(try target("http://localhost:3000/app"), "org.mozilla.firefox")
        XCTAssertEqual(try target("https://example.com/meet/1"), "com.google.Chrome", "switched-off rules don't match")
        settings.fallbackBrowserBundleID = "com.kyw.allofmacos"
        XCTAssertEqual(try target("https://example.com/"), "com.apple.Safari", "the fallback never routes back to AOM")
        settings.rules = [PaletteLinkRule(match: .hostContains, pattern: "example", browserBundleID: "com.kyw.allofmacos")]
        XCTAssertEqual(try target("https://example.com/"), "com.apple.Safari", "nor does a rule")
        XCTAssertFalse(PaletteLinkRule(match: .hostContains, pattern: "  ", browserBundleID: "x").matches(URL(string: "https://a.b")!))
    }

    func testAppLinks() throws {
        let zoom = try XCTUnwrap(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://uos.zoom.us/j/123456789?pwd=abc"))))
        XCTAssertEqual(zoom.bundleID, "us.zoom.xos")
        let parts = try XCTUnwrap(URLComponents(url: zoom.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "zoommtg")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "confno" }?.value, "123456789")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "pwd" }?.value, "abc")

        let figma = try XCTUnwrap(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://www.figma.com/design/KEY123/Poster?node-id=1-2"))))
        XCTAssertEqual(figma.bundleID, "com.figma.Desktop")
        XCTAssertEqual(figma.url.absoluteString, "figma://design/KEY123/Poster?node-id=1-2")

        let notion = try XCTUnwrap(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://www.notion.so/team/Notes-abc"))))
        XCTAssertEqual(notion.url.absoluteString, "notion://www.notion.so/team/Notes-abc")

        let korean = try XCTUnwrap(PaletteLinkRouting.appLink(for: try XCTUnwrap(
            URL(string: "https://www.figma.com/file/KEY/%ED%8F%AC%EC%8A%A4%ED%84%B0"))))
        XCTAssertEqual(korean.url.absoluteString, "figma://file/KEY/%ED%8F%AC%EC%8A%A4%ED%84%B0", "an escaped name stays escaped")

        XCTAssertNil(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://www.figma.com/pricing"))),
                     "only file links go to the app")
        XCTAssertNil(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://zoom.us/pricing"))))
        XCTAssertNil(PaletteLinkRouting.appLink(for: try XCTUnwrap(URL(string: "https://example.com/j/1"))))
    }

    func testSettingsRoundTrip() throws {
        let suite = "aom-link-router-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PaletteLinkRouterSettings.storageKey, "AOMPaletteLinkRouter")
        let fresh = PaletteLinkRouterSettings.load(from: store)
        XCTAssertFalse(fresh.isEnabled, "routing is off until the user turns it on")
        XCTAssertEqual(fresh.rules.first?.pattern, "uos.ac.kr")
        var changed = fresh
        changed.isEnabled = true
        changed.trackingParameters.append("ref_src")
        changed.save(to: store)
        XCTAssertEqual(PaletteLinkRouterSettings.load(from: store), changed)
    }
}
