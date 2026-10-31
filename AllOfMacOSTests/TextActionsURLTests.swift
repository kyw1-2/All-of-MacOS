import XCTest
@testable import AllOfMacOS

/// Text Actions: the addresses Search, Search GitHub, Translate, Look Up and
/// New Email open, with their encoding (Korean included). Nothing is opened.
final class TextActionsURLTests: XCTestCase {
    func testEverySearchEngineEncodesKorean() throws {
        let expected: [TextSearchEngine: String] = [
            .google: "https://www.google.com/search?q=%EC%95%88%EB%85%95%20%EC%84%B8%EA%B3%84",
            .naver: "https://search.naver.com/search.naver?query=%EC%95%88%EB%85%95%20%EC%84%B8%EA%B3%84",
            .bing: "https://www.bing.com/search?q=%EC%95%88%EB%85%95%20%EC%84%B8%EA%B3%84",
            .duckDuckGo: "https://duckduckgo.com/?q=%EC%95%88%EB%85%95%20%EC%84%B8%EA%B3%84",
            .perplexity: "https://www.perplexity.ai/search?q=%EC%95%88%EB%85%95%20%EC%84%B8%EA%B3%84"
        ]
        for (engine, url) in expected {
            XCTAssertEqual(TextActionURLs.search("안녕 세계", engine: engine, customTemplate: "")?.absoluteString, url, engine.title)
        }
        XCTAssertEqual(Set(expected.keys).union([.custom]), Set(TextSearchEngine.allCases), "every engine is covered")
    }

    func testReservedCharactersAreEncoded() {
        XCTAssertEqual(TextActionURLs.search("swift async/await & more?", engine: .google, customTemplate: "")?.absoluteString,
                       "https://www.google.com/search?q=swift%20async%2Fawait%20%26%20more%3F")
        XCTAssertEqual(TextActionURLs.search("a+b=c#d", engine: .naver, customTemplate: "")?.absoluteString,
                       "https://search.naver.com/search.naver?query=a%2Bb%3Dc%23d")
    }

    func testWhiteSpaceIsFoldedAndLongQueriesAreCutAtAWord() {
        XCTAssertEqual(TextActionURLs.query("  a\n b \t  c ", limit: 500), "a b c")
        let long = String(repeating: "word ", count: 200)
        let cut = TextActionURLs.query(long, limit: TextActionURLs.searchLimit)
        XCTAssertLessThanOrEqual(cut.count, TextActionURLs.searchLimit)
        XCTAssertTrue(cut.hasSuffix("word"), "cut between words")
        XCTAssertNil(TextActionURLs.search("   ", engine: .google, customTemplate: ""), "nothing to search")
    }

    func testCustomTemplates() {
        XCTAssertTrue(TextActionURLs.isValidTemplate("https://example.com/find?q={query}"))
        XCTAssertTrue(TextActionURLs.isValidTemplate("dash://{query}"), "an app scheme the person typed is allowed")
        XCTAssertFalse(TextActionURLs.isValidTemplate("https://example.com/find?q="), "needs {query}")
        XCTAssertFalse(TextActionURLs.isValidTemplate("https://example.com/ find?q={query}"), "no spaces")
        XCTAssertFalse(TextActionURLs.isValidTemplate("{query}"), "needs a scheme")
        XCTAssertEqual(TextActionURLs.search("x y", engine: .custom, customTemplate: "dash://{query}")?.absoluteString, "dash://x%20y")
        XCTAssertNil(TextActionURLs.search("x", engine: .custom, customTemplate: ""))
        XCTAssertNil(TextActionURLs.search("x", engine: .custom, customTemplate: "https://example.com/"))
    }

    func testGitHubSearch() {
        XCTAssertEqual(TextActionURLs.gitHubSearch("swift-format")?.absoluteString, "https://github.com/search?q=swift-format")
        XCTAssertEqual(TextActionURLs.gitHubSearch("NSPanel nonactivating")?.absoluteString,
                       "https://github.com/search?q=NSPanel%20nonactivating")
    }

    func testTranslatorsCarryTheLanguagesAndTheText() {
        XCTAssertEqual(TextActionURLs.translate("Hello world", translator: .papago, from: "auto", to: "ko")?.absoluteString,
                       "https://papago.naver.com/?sk=auto&tk=ko&st=Hello%20world")
        XCTAssertEqual(TextActionURLs.translate("안녕하세요\n반갑습니다", translator: .google, from: "ko", to: "en")?.absoluteString,
                       "https://translate.google.com/?sl=ko&tl=en&text=%EC%95%88%EB%85%95%ED%95%98%EC%84%B8%EC%9A%94%0A%EB%B0%98%EA%B0%91%EC%8A%B5%EB%8B%88%EB%8B%A4&op=translate",
                       "line breaks are kept as %0A")
        XCTAssertEqual(TextActionURLs.translate("x", translator: .papago, from: "auto", to: "zh-TW")?.absoluteString,
                       "https://papago.naver.com/?sk=auto&tk=zh-TW&st=x")
        XCTAssertNil(TextActionURLs.translate("x", translator: .google, from: "auto", to: "auto"), "the target is a language")
        XCTAssertNil(TextActionURLs.translate("x", translator: .google, from: "xx", to: "en"))
        XCTAssertNil(TextActionURLs.translate("  ", translator: .google, from: "auto", to: "en"))
    }

    func testLongTranslationsStayWithinTheLinkLimits() throws {
        let korean = String(repeating: "가나다라 ", count: 900)   // 4,500 characters, 9 encoded per syllable
        let sent = TextActionURLs.translationText(korean)
        XCTAssertLessThan(sent.count, korean.count)
        XCTAssertLessThanOrEqual(try XCTUnwrap(TextActionURLs.encoded(sent)).count, TextActionURLs.translateEncodedLimit)
        XCTAssertTrue(sent.hasSuffix("가나다라"), "cut at a word")
        let english = String(repeating: "This is a sentence. ", count: 200) // 4,000 characters
        let cut = TextActionURLs.translationText(english)
        XCTAssertLessThanOrEqual(cut.count, TextActionURLs.translateLimit)
        XCTAssertTrue(cut.hasSuffix("."), "cut at a sentence")
        XCTAssertEqual(TextActionURLs.translationText("  short  "), "short")
    }

    func testTextAlreadyInTheTargetLanguageGoesToEnglishOrBack() {
        XCTAssertEqual(TextActionURLs.targetLanguage(for: "안녕하세요 반갑습니다", from: "auto", to: "ko", preferred: ["en-KR", "ko-KR"]), "en")
        XCTAssertEqual(TextActionURLs.targetLanguage(for: "Hello there, how are you doing today?", from: "auto", to: "en",
                                                     preferred: ["en-KR", "ko-KR"]), "ko", "from English to the person's other language")
        XCTAssertEqual(TextActionURLs.targetLanguage(for: "Hello there, how are you doing today?", from: "auto", to: "en",
                                                     preferred: ["en-US"]), "en", "nobody to switch to")
        XCTAssertEqual(TextActionURLs.targetLanguage(for: "Hello there, how are you doing today?", from: "auto", to: "ko",
                                                     preferred: ["ko-KR"]), "ko")
        XCTAssertEqual(TextActionURLs.targetLanguage(for: "안녕하세요", from: "ko", to: "ko", preferred: ["ko-KR"]), "ko",
                       "a chosen source language is left alone")
        XCTAssertEqual(TextActionURLs.dominantLanguage(of: "Swift 프로그래밍 언어"), "ko", "Korean with an English term is Korean")
    }

    func testLookUpAndMail() {
        XCTAssertEqual(TextActionURLs.lookUp("serendipity")?.absoluteString, "dict://serendipity")
        XCTAssertEqual(TextActionURLs.lookUp(" 사과 ")?.absoluteString, "dict://%EC%82%AC%EA%B3%BC")
        XCTAssertEqual(TextActionURLs.lookUp("ice cream")?.absoluteString, "dict://ice%20cream")
        XCTAssertNil(TextActionURLs.lookUp(""))
        XCTAssertEqual(TextActionURLs.mail(to: "kim@naver.com")?.absoluteString, "mailto:kim@naver.com")
        XCTAssertNil(TextActionURLs.mail(to: "not an address"))
    }

    func testCountChipWords() {
        XCTAssertEqual(TextActionCountFormat.chip(characters: 1, words: 1), "1 char · 1 word")
        XCTAssertEqual(TextActionCountFormat.chip(characters: 128, words: 21), "128 chars · 21 words")
        XCTAssertEqual(TextActionCountFormat.spoken(characters: 12, words: 3, lines: 2), "12 characters, 3 words, 2 lines")
    }
}
