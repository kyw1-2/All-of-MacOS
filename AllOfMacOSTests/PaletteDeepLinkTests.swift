import AppKit
import XCTest
@testable import AllOfMacOS

/// Copy Link to Current Item: Markdown, HTML and RTF formatting with their
/// escaping, Mail's message:// links, where each app's item is read and how
/// the script answers are parsed. Writes go to a private pasteboard; no
/// Apple events are sent.
final class PaletteDeepLinkTests: XCTestCase {
    private let swift = PaletteLink(title: "Swift.org", url: URL(string: "https://www.swift.org/")!)

    func testMarkdown() {
        XCTAssertEqual(PaletteLinkFormat.markdown(swift), "[Swift.org](https://www.swift.org/)")
        let tricky = PaletteLink(title: "Arrays [part 2] \\ notes\nmore",
                                 url: URL(string: "https://en.wikipedia.org/wiki/Function_(mathematics)")!)
        XCTAssertEqual(PaletteLinkFormat.markdown(tricky),
                       "[Arrays \\[part 2\\] \\\\ notes more](https://en.wikipedia.org/wiki/Function_%28mathematics%29)",
                       "brackets and backslashes are escaped, parentheses can't end the link early")
        XCTAssertEqual(PaletteLinkFormat.markdown([swift, swift]).components(separatedBy: "\n").count, 2)
    }

    func testFileLinksStayPercentEncoded() {
        let file = PaletteLink(title: "Report draft.pages", url: URL(fileURLWithPath: "/Users/Shared/Report draft.pages"))
        XCTAssertEqual(PaletteLinkFormat.markdown(file), "[Report draft.pages](file:///Users/Shared/Report%20draft.pages)")
        XCTAssertEqual(PaletteLinkFormat.plain([file]), "file:///Users/Shared/Report%20draft.pages")
    }

    func testHTMLEscaping() {
        let link = PaletteLink(title: "Tom & Jerry <\"best\"> 'ep'", url: URL(string: "https://example.com/?a=1&b=2")!)
        XCTAssertEqual(PaletteLinkFormat.html([link]),
                       "<a href=\"https://example.com/?a=1&amp;b=2\">Tom &amp; Jerry &lt;&quot;best&quot;&gt; &#39;ep&#39;</a>")
        XCTAssertEqual(PaletteLinkFormat.html([swift, swift]).components(separatedBy: "<br>").count, 2)
    }

    func testRTFEscapesAndReadsBackAsALink() throws {
        let link = PaletteLink(title: "시립대 {portal} \\ 안내", url: URL(string: "https://portal.uos.ac.kr/?q=%22x%22")!)
        let data = PaletteLinkFormat.rtf([link])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\\rtf1"))
        XCTAssertTrue(text.contains("HYPERLINK \"https://portal.uos.ac.kr/?q=%22x%22\""))
        XCTAssertTrue(text.contains("\\{portal\\}"), "braces are escaped")
        XCTAssertFalse(text.unicodeScalars.contains { !$0.isASCII }, "Korean is written as \\u escapes")
        let parsed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                            documentAttributes: nil)
        XCTAssertEqual(parsed.string, "시립대 {portal} \\ 안내", "the RTF reads back to the same title")
        let attribute = parsed.attribute(.link, at: 0, effectiveRange: nil)
        let url = (attribute as? URL) ?? (attribute as? String).flatMap(URL.init(string:))
        XCTAssertEqual(url?.host, "portal.uos.ac.kr")
    }

    func testMailMessageURL() {
        XCTAssertEqual(PaletteLinkFormat.mailMessageURL(messageID: "<CAF+abc=1@mail.gmail.com>")?.absoluteString,
                       "message://%3CCAF+abc=1@mail.gmail.com%3E")
        XCTAssertEqual(PaletteLinkFormat.mailMessageURL(messageID: "id with space/slash@x")?.absoluteString,
                       "message://%3Cid%20with%20space%2Fslash@x%3E")
        XCTAssertNil(PaletteLinkFormat.mailMessageURL(messageID: " <> "))
    }

    func testRichPasteboardHasEveryFlavour() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aom-test-deeplink-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(PaletteLinkFormat.write([swift], style: .rich, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "[Swift.org](https://www.swift.org/)")
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://www.swift.org/")
        XCTAssertEqual(pasteboard.string(forType: .html), "<a href=\"https://www.swift.org/\">Swift.org</a>")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")), "Swift.org")

        XCTAssertTrue(PaletteLinkFormat.write([swift], style: .markdown, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "[Swift.org](https://www.swift.org/)")
        XCTAssertNil(pasteboard.string(forType: .html), "Copy as Markdown is plain text only")
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertTrue(PaletteLinkFormat.write([swift], style: .plainURL, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "https://www.swift.org/")
        XCTAssertFalse(PaletteLinkFormat.write([], style: .rich, to: pasteboard))
    }

    func testSourceByFrontApp() {
        XCTAssertEqual(PaletteLinkSource.source(for: "com.apple.Safari"), .browser(bundleID: "com.apple.Safari", safari: true))
        XCTAssertEqual(PaletteLinkSource.source(for: "com.google.Chrome"), .browser(bundleID: "com.google.Chrome", safari: false))
        XCTAssertEqual(PaletteLinkSource.source(for: "com.naver.Whale"), .browser(bundleID: "com.naver.Whale", safari: false))
        XCTAssertEqual(PaletteLinkSource.source(for: "com.apple.finder"), .finder)
        XCTAssertEqual(PaletteLinkSource.source(for: "com.apple.mail"), .mail)
        XCTAssertEqual(PaletteLinkSource.source(for: "com.apple.TextEdit"), .documentOrApp)
        XCTAssertEqual(PaletteLinkSource.source(for: nil), .documentOrApp)
        XCTAssertNil(PaletteLinkSource.documentOrApp.script)
        XCTAssertTrue(PaletteLinkSource.source(for: "com.apple.Safari").script?.contains("current tab of front window") == true)
        XCTAssertTrue(PaletteLinkSource.source(for: "com.google.Chrome").script?.contains("active tab of front window") == true)
    }

    func testParsingScriptAnswers() {
        let browser = PaletteLinkSource.browser(bundleID: "com.apple.Safari", safari: true)
        XCTAssertEqual(browser.links(fromScriptOutput: "Swift.org\u{1F}https://www.swift.org/\n"), [swift])
        XCTAssertEqual(browser.links(fromScriptOutput: "\u{1F}https://example.com/x\n").first?.title, "example.com",
                       "an untitled tab is named by its host")
        XCTAssertTrue(browser.links(fromScriptOutput: "").isEmpty)
        XCTAssertTrue(browser.links(fromScriptOutput: "no separator").isEmpty)

        let finder = PaletteLinkSource.finder.links(fromScriptOutput: "/Users/Shared/A b.txt\n/Users/Shared/Folder/\n")
        XCTAssertEqual(finder.map(\.url.path), ["/Users/Shared/A b.txt", "/Users/Shared/Folder"])
        XCTAssertTrue(finder.allSatisfy(\.url.isFileURL))

        let mail = PaletteLinkSource.mail.links(fromScriptOutput: "Re: 과제 제출\u{1F}abc@uos.ac.kr\n\u{1F}x@y\n")
        XCTAssertEqual(mail.map(\.title), ["Re: 과제 제출", "Message"])
        XCTAssertEqual(mail.first?.url.absoluteString, "message://%3Cabc@uos.ac.kr%3E")
    }
}
