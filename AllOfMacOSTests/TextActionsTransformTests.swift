import XCTest
@testable import AllOfMacOS

/// Text Actions transforms: case styles, Format JSON, URL and Base64
/// coding, and the Markdown wraps.
final class TextActionsTransformTests: XCTestCase {
    private func apply(_ variant: TextTransformVariant, _ text: String, clipboard: URL? = nil) -> String? {
        TextActionTransforms.apply(variant, to: text, clipboardURL: clipboard)
    }

    func testCaseStyles() {
        let text = "hello world fileName"
        XCTAssertEqual(apply(.changeCase(.upper), text), "HELLO WORLD FILENAME")
        XCTAssertEqual(apply(.changeCase(.lower), "Hello WORLD"), "hello world")
        XCTAssertEqual(apply(.changeCase(.title), "hello WORLD"), "Hello World")
        XCTAssertEqual(apply(.changeCase(.camel), text), "helloWorldFileName", "a lower-to-upper change splits words")
        XCTAssertEqual(apply(.changeCase(.snake), text), "hello_world_file_name")
        XCTAssertEqual(apply(.changeCase(.kebab), text), "hello-world-file-name")
        XCTAssertEqual(apply(.changeCase(.camel), "Hello world-wide web"), "helloWorldWideWeb")
        XCTAssertEqual(apply(.changeCase(.upper), "안녕 abc"), "안녕 ABC", "Hangul stays as it is")
        XCTAssertEqual(TextCaseStyle.allCases.map(\.title), ["UPPER", "lower", "Title", "camelCase", "snake_case", "kebab-case"])
    }

    func testFormatJSONKeepsOrderNumbersAndEscapes() {
        let compact = #"{"b":1,"a":[1,2.50,{}],"s":"x,y:{z}\"q","e":[],"u":"\u00e9"}"#
        XCTAssertEqual(apply(.formatJSON, compact), """
        {
          "b": 1,
          "a": [
            1,
            2.50,
            {}
          ],
          "s": "x,y:{z}\\"q",
          "e": [],
          "u": "\\u00e9"
        }
        """)
        XCTAssertEqual(apply(.formatJSON, "[ ]"), "[]")
        XCTAssertEqual(apply(.formatJSON, #"{"a":"\\","b":"\"}"}"#), "{\n  \"a\": \"\\\\\",\n  \"b\": \"\\\"}\"\n}",
                       "escaped quotes and backslashes do not end a string")
        XCTAssertNil(apply(.formatJSON, #"{"a": }"#), "invalid JSON is left alone")
        XCTAssertNil(apply(.formatJSON, "not json"))
    }

    func testFormatJSONIsStable() throws {
        let once = try XCTUnwrap(apply(.formatJSON, #"{"k":[1,{"x":null}]}"#))
        XCTAssertEqual(apply(.formatJSON, once), once, "formatting formatted JSON changes nothing")
    }

    func testURLCoding() {
        XCTAssertEqual(apply(.urlEncode, "a b/한?&"), "a%20b%2F%ED%95%9C%3F%26")
        XCTAssertEqual(apply(.urlDecode, "a%20b%2F%ED%95%9C"), "a b/한")
        XCTAssertNil(apply(.urlDecode, "100%"), "a broken escape cannot be decoded")
    }

    func testBase64() {
        XCTAssertEqual(apply(.base64Encode, "안녕"), "7JWI64WV")
        XCTAssertEqual(apply(.base64Encode, "Hello world"), "SGVsbG8gd29ybGQ=")
        XCTAssertEqual(apply(.base64Decode, "SGVsbG8gd29ybGQ="), "Hello world")
        XCTAssertEqual(apply(.base64Decode, "SGVs bG8g\nd29y bGQ="), "Hello world", "white space inside is ignored")
        XCTAssertEqual(apply(.base64Decode, "aGk_dGhlcmUh"), "hi?there!", "the URL-safe alphabet decodes too")
        XCTAssertNil(apply(.base64Decode, "not base64!"))
    }

    func testMarkdownKeepsWhiteSpaceOutsideTheMarkers() {
        XCTAssertEqual(apply(.markdown(.bold), " word "), " **word** ")
        XCTAssertEqual(apply(.markdown(.italic), "word\n"), "*word*\n")
        XCTAssertEqual(apply(.markdown(.code), "let x = 1"), "`let x = 1`")
        XCTAssertEqual(apply(.markdown(.bold), "   "), "   ", "nothing to wrap")
    }

    func testMarkdownCode() {
        XCTAssertEqual(apply(.markdown(.code), "a`b"), "``a`b``", "a backtick inside needs a longer fence")
        XCTAssertEqual(apply(.markdown(.code), "`x`"), "`` `x` ``", "a backtick at either end needs a space")
        XCTAssertEqual(apply(.markdown(.code), "line 1\nline 2"), "```\nline 1\nline 2\n```", "several lines become a block")
        XCTAssertEqual(apply(.markdown(.code), "a\n```\nb"), "````\na\n```\nb\n````")
    }

    func testMarkdownLinks() {
        let clipboard = URL(string: "https://example.com/page")
        XCTAssertEqual(apply(.markdown(.link), "the docs", clipboard: clipboard), "[the docs](https://example.com/page)",
                       "the address on the clipboard")
        XCTAssertEqual(apply(.markdown(.link), "https://naver.com"), "[https://naver.com](https://naver.com)",
                       "a selected address links to itself")
        XCTAssertEqual(apply(.markdown(.link), "plain"), "[plain]()", "no address yet")
        XCTAssertEqual(apply(.markdown(.link), "a]b", clipboard: clipboard), "[a\\]b](https://example.com/page)")
    }
}
