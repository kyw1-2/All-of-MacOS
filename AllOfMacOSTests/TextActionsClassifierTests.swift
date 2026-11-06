import XCTest
@testable import AllOfMacOS

/// Text Actions: what the selected text is (links, domains, addresses,
/// numbers, sums, JSON, line breaks, Korean and other CJK text).
final class TextActionsClassifierTests: XCTestCase {
    func testMultiClickWaitPreventsPrematureFloatingBar() {
        XCTAssertEqual(TextSelectionMonitor.settledDelay(kind: .doubleClick, userDelay: 0.2), 0.42)
        XCTAssertEqual(TextSelectionMonitor.settledDelay(kind: .tripleClick, userDelay: 0.2), 0.2)
        XCTAssertEqual(TextSelectionMonitor.settledDelay(kind: .drag, userDelay: 0.5), 0.5)
        XCTAssertEqual(TextSelectionMonitor.settledDelay(kind: .doubleClick, userDelay: 0.8), 0.8)
    }

    private func traits(_ text: String) -> TextSelectionTraits { TextSelectionClassifier.classify(text) }

    // MARK: Links

    func testWebAddressesWithASchemeAreLinks() {
        let url = traits("https://www.apple.com/kr/")
        XCTAssertEqual(url.link?.absoluteString, "https://www.apple.com/kr/")
        XCTAssertFalse(url.isDomain)
        XCTAssertEqual(traits("<https://example.com>.").link?.absoluteString, "https://example.com",
                       "angle brackets and a closing full stop are not part of the address")
        XCTAssertEqual(traits("(http://example.com/a_(b))").link?.host, "example.com")
    }

    func testKoreanPathsAreEncodedIntoTheLink() throws {
        let link = try XCTUnwrap(traits("https://ko.wikipedia.org/wiki/한국어").link)
        XCTAssertEqual(link.host, "ko.wikipedia.org")
        XCTAssertTrue(link.absoluteString.contains("%ED%95%9C"), link.absoluteString)
    }

    func testBareDomainsOpenOverHTTPS() {
        for (text, expected) in [("naver.com", "https://naver.com"), ("github.com/apple/swift", "https://github.com/apple/swift"),
                                 ("www.example.co.kr", "https://www.example.co.kr"), ("notion.so", "https://notion.so"),
                                 ("perplexity.ai", "https://perplexity.ai")] {
            let found = traits(text)
            XCTAssertEqual(found.link?.absoluteString, expected, text)
            XCTAssertTrue(found.isDomain, text)
        }
    }

    func testLocalAddressesOpenOverHTTP() {
        XCTAssertEqual(traits("localhost:3000").link?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(traits("127.0.0.1:8080/api").link?.absoluteString, "http://127.0.0.1:8080/api")
        XCTAssertNil(traits("999.1.1.1").link, "not an IPv4 address")
    }

    func testFileNamesAndAbbreviationsAreNotLinks() {
        for text in ["README.md", "Safari.app", "main.swift", "setup.py", "e.g.", "U.S.A.", "3.14", "v1.2.3", "index.html"] {
            XCTAssertNil(traits(text).link, text)
        }
    }

    func testOnlyWebSchemesOpen() {
        // Text on a page must never run an app's URL scheme through Open Link.
        for text in ["shortcuts://run-shortcut?name=x", "file:///etc/hosts", "javascript:alert(1)", "x-apple.systempreferences:x"] {
            XCTAssertNil(traits(text).link, text)
        }
    }

    func testTextWithSpacesOrSeveralLinesIsNotALink() {
        XCTAssertNil(traits("see naver.com for more").link)
        XCTAssertNil(traits("naver.com\ngithub.com").link)
    }

    // MARK: Email

    func testEmailAddresses() {
        XCTAssertEqual(traits("user@example.com").email, "user@example.com")
        XCTAssertEqual(traits("mailto:kim@naver.com").email, "kim@naver.com", "mailto: is dropped")
        XCTAssertEqual(traits("first.last+tag@sub.example.co.kr").email, "first.last+tag@sub.example.co.kr")
        XCTAssertNil(traits("user@example.com").link, "an address is not also a link")
        XCTAssertNil(traits("write to user@example.com").email)
        XCTAssertNil(traits("user@localhost").email)
    }

    // MARK: Numbers and sums

    func testNumbers() {
        for text in ["42", "1,234.5", "-5", "3.14", "2.5e3", "15%"] { XCTAssertTrue(traits(text).isNumber, text) }
        for text in ["12 apples", "1.2.3", "3 + 4"] { XCTAssertFalse(traits(text).isNumber, text) }
    }

    func testSums() {
        for text in ["3 + 4 × 2", "(1+2)/3", "2^10", "100 ÷ 4", "1,000 - 250", "1/2", "10 - 3"] {
            XCTAssertTrue(traits(text).isMath, text)
            XCTAssertTrue(traits(text).isCalculatorCandidate, text)
        }
        for text in ["42", "-5", "hello 3 world", "1, 2, 3", "(42)"] { XCTAssertFalse(traits(text).isMath, text) }
    }

    func testDatesPhoneNumbersAndRangesAreNotSums() {
        // A Korean mobile number or a date must not show "= -6902".
        for text in ["2024-10-31", "010-1234-5678", "10/31/2024", "978-3-16-148410-0", "10-20"] {
            XCTAssertFalse(traits(text).isMath, text)
            XCTAssertFalse(traits(text).isCalculatorCandidate, text)
        }
    }

    func testConversionsAndFunctionsAskTheCalculator() {
        for text in ["10 km to mi", "72°F", "$100", "100 USD to KRW", "sqrt(16)", "15% of 200"] {
            XCTAssertTrue(traits(text).isCalculatorCandidate, text)
        }
        for text in ["2 days ago", "The year 2024 was long", "42"] {
            XCTAssertFalse(traits(text).isCalculatorCandidate, text)
        }
    }

    // MARK: Structured text

    func testJSON() {
        XCTAssertTrue(traits(#"{"a": 1, "b": [1, 2]}"#).isJSON)
        XCTAssertTrue(traits("[1, 2]").isJSON)
        XCTAssertTrue(traits("  {\n  \"nested\": {}\n}\n").isJSON, "white space around it is fine")
        XCTAssertFalse(traits("[x]").isJSON, "a Markdown checkbox is not JSON")
        XCTAssertFalse(traits(#"{"a": }"#).isJSON)
        XCTAssertFalse(traits("{a: 1}").isJSON, "keys need quotes")
        XCTAssertFalse(traits("42").isJSON, "a bare number is not offered as JSON")
    }

    func testPercentEscapesAndBase64() {
        XCTAssertTrue(traits("hello%20world%EC%95%88").hasPercentEscapes)
        XCTAssertFalse(traits("100% sure").hasPercentEscapes)
        XCTAssertEqual(traits("SGVsbG8gd29ybGQ=").base64Decoded, "Hello world")
        XCTAssertEqual(traits("7JWI64WV7ZWY7IS47JqU").base64Decoded, "안녕하세요")
        XCTAssertEqual(traits("aGVsbG8gd29ybGQh").base64Decoded, "hello world!", "no padding is fine")
        XCTAssertNil(traits("Username").base64Decoded, "a plain word is not Base64")
        XCTAssertNil(traits("hello world").base64Decoded)
    }

    // MARK: Lines, scripts and counts

    func testMultilineAndTripleClickSelections() {
        let two = traits("line one\nline two")
        XCTAssertTrue(two.isMultiline)
        XCTAssertEqual(two.lines, 2)
        let triple = traits("triple\n")
        XCTAssertFalse(triple.isMultiline, "the line break a triple click adds is not a second line")
        XCTAssertEqual(triple.characters, 6)
        XCTAssertEqual(traits("a\r\nb").lines, 2)
    }

    func testKoreanAndOtherCJKText() {
        let korean = traits("안녕하세요 반갑습니다")
        XCTAssertTrue(korean.hasHangul)
        XCTAssertTrue(korean.hasCJK)
        XCTAssertTrue(korean.hasLetters)
        XCTAssertFalse(korean.hasCasedLetters, "Hangul has no case: Change Case does not apply")
        XCTAssertEqual(korean.characters, 11, "syllables count as one character each")
        XCTAssertEqual(korean.words, 2)

        let japanese = traits("日本語のテキスト")
        XCTAssertTrue(japanese.hasCJK)
        XCTAssertFalse(japanese.hasHangul)
        XCTAssertGreaterThan(japanese.words, 1, "the system splits Japanese into words")

        let mixed = traits("Hello, 세계!")
        XCTAssertTrue(mixed.hasHangul)
        XCTAssertTrue(mixed.hasCasedLetters)
        XCTAssertEqual(mixed.words, 2)
    }

    func testCountsUseGraphemes() {
        let emoji = traits("👍🏽 ok")
        XCTAssertEqual(emoji.characters, 4, "a skin-tone emoji is one character")
        XCTAssertEqual(traits("").characters, 0)
        XCTAssertEqual(traits("").words, 0)
        XCTAssertEqual(traits("").lines, 0)
    }

    func testVeryLongTextIsCountedButNotParsed() {
        let long = String(repeating: "word ", count: 250_000)
        let found = traits(long)
        XCTAssertEqual(found.words, 250_000)
        XCTAssertNil(found.link)
        XCTAssertFalse(found.isJSON)
    }
}
