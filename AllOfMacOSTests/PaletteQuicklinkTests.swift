import XCTest
@testable import AllOfMacOS

/// Quicklinks: keyword matching, URL building with percent-encoding (Korean
/// text included), validation and storage in a private defaults domain.
final class PaletteQuicklinkTests: XCTestCase {
    private let google = PaletteQuicklink(keyword: "g", name: "Google", template: "https://www.google.com/search?q={query}")
    private let github = PaletteQuicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
    private let brew = PaletteQuicklink(keyword: "brew", name: "Homebrew Formula", template: "https://formulae.brew.sh/formula/{query}")

    func testEncodingLeavesOnlyUnreservedCharacters() {
        XCTAssertEqual(PaletteQuicklinks.encode("a b&c=d#e+f%g/h?i"), "a%20b%26c%3Dd%23e%2Bf%25g%2Fh%3Fi")
        XCTAssertEqual(PaletteQuicklinks.encode("swift-format_1.0~"), "swift-format_1.0~")
    }

    func testKoreanQueryIsUTF8PercentEncoded() throws {
        XCTAssertEqual(PaletteQuicklinks.encode("고양이"), "%EA%B3%A0%EC%96%91%EC%9D%B4")
        let url = try XCTUnwrap(PaletteQuicklinks.url(for: google, query: "서울 날씨"))
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=%EC%84%9C%EC%9A%B8%20%EB%82%A0%EC%94%A8")
        let naver = try XCTUnwrap(PaletteQuicklinks.defaults.first { $0.keyword == "n" })
        XCTAssertEqual(PaletteQuicklinks.url(for: naver, query: "시립대")?.absoluteString,
                       "https://search.naver.com/search.naver?query=%EC%8B%9C%EB%A6%BD%EB%8C%80")
    }

    func testQueryCannotEscapeItsComponent() throws {
        let url = try XCTUnwrap(PaletteQuicklinks.url(for: google, query: "x&redirect=https://evil.example/#frag"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.queryItems?.count, 1, "an & in the search is data, not a second parameter")
        XCTAssertEqual(components.queryItems?.first?.value, "x&redirect=https://evil.example/#frag")
        XCTAssertNil(components.fragment)
        let path = try XCTUnwrap(PaletteQuicklinks.url(for: brew, query: "../../etc"))
        XCTAssertEqual(path.absoluteString, "https://formulae.brew.sh/formula/..%2F..%2Fetc", "a slash can't climb the path")
    }

    func testEmojiAndTrimming() {
        XCTAssertEqual(PaletteQuicklinks.url(for: google, query: "  🍣 sushi  ")?.absoluteString,
                       "https://www.google.com/search?q=%F0%9F%8D%A3%20sushi")
    }

    func testAlternatePlaceholder() {
        let link = PaletteQuicklink(keyword: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s")
        XCTAssertEqual(PaletteQuicklinks.url(for: link, query: "a b")?.absoluteString, "https://duckduckgo.com/?q=a%20b")
        XCTAssertTrue(PaletteQuicklinks.hasPlaceholder(link))
    }

    func testMatchingNeedsTheKeywordAndASpace() {
        let links = [google, github, brew]
        XCTAssertEqual(PaletteQuicklinks.match("g cats", in: links)?.link, google)
        XCTAssertEqual(PaletteQuicklinks.match("g cats", in: links)?.query, "cats")
        XCTAssertEqual(PaletteQuicklinks.match("gh swift-format", in: links)?.link, github, "the whole first word is the keyword")
        XCTAssertEqual(PaletteQuicklinks.match("G  Cats ", in: links)?.query, "Cats", "keywords match without case")
        XCTAssertEqual(PaletteQuicklinks.match("g ", in: links)?.query, "", "a keyword and a space waits for the search")
        XCTAssertNil(PaletteQuicklinks.match("g", in: links))
        XCTAssertNil(PaletteQuicklinks.match("gcats", in: links))
        XCTAssertNil(PaletteQuicklinks.match("x cats", in: links))
        var disabled = google
        disabled.isEnabled = false
        XCTAssertNil(PaletteQuicklinks.match("g cats", in: [disabled]))
    }

    func testSuggestionsBeforeTheSpace() {
        let links = [google, github, brew]
        XCTAssertEqual(PaletteQuicklinks.suggestions("gh", in: links).map(\.keyword), ["gh"])
        XCTAssertEqual(PaletteQuicklinks.suggestions("Git", in: links).map(\.keyword), ["gh"], "a name prefix of two or more letters")
        XCTAssertTrue(PaletteQuicklinks.suggestions("g cats", in: links).isEmpty)
    }

    func testValidation() {
        XCTAssertNil(PaletteQuicklinks.validationProblem(google))
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "", name: "X", template: "https://x.com/{query}")),
                       .emptyKeyword)
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "a b", name: "X", template: "https://x.com/{query}")),
                       .keywordHasSpace)
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "G", name: "Other", template: "https://x.com/{query}"),
                                                           among: [google]), .duplicateKeyword)
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "f", name: "File", template: "file:///etc/{query}")),
                       .refusedScheme)
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "j", name: "JS", template: "javascript:alert({query})")),
                       .refusedScheme)
        XCTAssertEqual(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "h", name: "Host", template: "https://")),
                       .notAURL)
        XCTAssertNil(PaletteQuicklinks.url(for: PaletteQuicklink(keyword: "f", name: "File", template: "file:///{query}"), query: "x"))
        XCTAssertNil(PaletteQuicklinks.validationProblem(PaletteQuicklink(keyword: "maps", name: "Maps", template: "maps://?q={query}")),
                     "app links are allowed")
    }

    func testDefaultsHaveTheTenKeywordsAndAreValid() {
        XCTAssertEqual(PaletteQuicklinks.defaults.map(\.keyword), ["g", "n", "gh", "yt", "r", "w", "p", "maps", "so", "brew"])
        for link in PaletteQuicklinks.defaults {
            XCTAssertNil(PaletteQuicklinks.validationProblem(link, among: PaletteQuicklinks.defaults), link.keyword)
            XCTAssertNotNil(PaletteQuicklinks.url(for: link, query: "test"), link.keyword)
        }
    }

    @MainActor
    func testStorageRoundTripUnderTheAOMKey() throws {
        let suite = "aom-palette-quicklinks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PaletteQuicklinks.storageKey, "AOMPaletteQuicklinks")
        XCTAssertEqual(PaletteQuicklinks.load(from: defaults).count, 10, "nothing stored: the defaults")
        let store = PaletteQuicklinkStore(defaults: defaults)
        store.replace(with: [github])
        XCTAssertEqual(PaletteQuicklinks.load(from: defaults), [github])
        XCTAssertEqual(PaletteQuicklinkStore(defaults: defaults).links, [github])
        store.restoreDefaults()
        XCTAssertEqual(PaletteQuicklinks.load(from: defaults).map(\.keyword).first, "g")
        defaults.set(Data("not json".utf8), forKey: PaletteQuicklinks.storageKey)
        XCTAssertEqual(PaletteQuicklinks.load(from: defaults).count, 10, "unreadable data falls back to the defaults")
    }
}
