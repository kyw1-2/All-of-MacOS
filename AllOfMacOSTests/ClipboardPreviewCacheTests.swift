import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardPreviewCacheTests: XCTestCase {
    func testLargeTextStatisticsPreserveCRLFAndTrailingLineSemantics() async {
        let repetitions = 50_000
        let text = String(repeating: "한국어 alpha\r\n둘 셋\n", count: repetitions)
        let entry = ClipboardEntry(title: "Large text", text: text, items: [])

        let content = await ClipboardPreviewCache.shared.content(for: entry)

        XCTAssertEqual(content.characterCount, 14 * repetitions,
                       "Swift counts CRLF as one grapheme cluster")
        XCTAssertEqual(content.summary,
            "\((14 * repetitions).formatted()) characters · \((4 * repetitions).formatted()) words · \((3 * repetitions + 1).formatted()) lines")
        XCTAssertNil(content.image)
    }

    func testEmptyTextHasZeroStatistics() async {
        let entry = ClipboardEntry(title: "Empty", text: "", items: [])
        let content = await ClipboardPreviewCache.shared.content(for: entry)
        XCTAssertEqual(content.characterCount, 0)
        XCTAssertEqual(content.summary, "0 characters · 0 words · 0 lines")
    }

    func testSameVersionReusesDerivedContent() async {
        let entry = ClipboardEntry(title: "Text", text: "one two", items: [])
        let first = await ClipboardPreviewCache.shared.content(for: entry)
        let second = await ClipboardPreviewCache.shared.content(for: entry)
        XCTAssertTrue(first === second)
    }

    func testRichTextPreviewPreservesBoldFormatting() async throws {
        let text = "Bold 한글 text"
        let rich = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let entry = ClipboardEntry(title: "Rich text", text: text,
            items: [[NSPasteboard.PasteboardType.rtf.rawValue: rtf]])

        let content = await ClipboardPreviewCache.shared.content(for: entry)
        let prepared = try XCTUnwrap(content.attributedText)
        let font = try XCTUnwrap(prepared.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(prepared.string, text)
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testPlainTextPreviewUsesDefaultFontAndBlackText() async throws {
        let entry = ClipboardEntry(title: "Plain text", text: "Plain 한글", items: [])
        let content = await ClipboardPreviewCache.shared.content(for: entry)
        let prepared = try XCTUnwrap(content.attributedText)
        let font = try XCTUnwrap(prepared.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(prepared.string, "Plain 한글")
        XCTAssertEqual(font.pointSize, 14)
        XCTAssertEqual(prepared.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .black)
    }

    func testMismatchedRichTextFallsBackToCompleteEntryText() async throws {
        let firstItem = NSAttributedString(string: "first", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try firstItem.data(from: NSRange(location: 0, length: firstItem.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let entry = ClipboardEntry(title: "Multiple items", text: "first\nsecond",
            items: [[NSPasteboard.PasteboardType.rtf.rawValue: rtf],
                    [NSPasteboard.PasteboardType.string.rawValue: Data("second".utf8)]])
        let content = await ClipboardPreviewCache.shared.content(for: entry)
        XCTAssertEqual(content.attributedText?.string, "first\nsecond")
    }

    func testNewContentVersionUpdatesTextSummaryForSameEntryID() async {
        var entry = ClipboardEntry(title: "Text", text: "first", items: [])
        let first = await ClipboardPreviewCache.shared.content(for: entry)
        let id = entry.id
        entry.text = "new text\n"
        entry.contentRevision = UUID()

        let updated = await ClipboardPreviewCache.shared.content(for: entry)

        XCTAssertEqual(entry.id, id)
        XCTAssertFalse(first === updated)
        XCTAssertEqual(updated.characterCount, 9)
        XCTAssertEqual(updated.summary, "9 characters · 2 words · 2 lines")
    }

    func testNewContentVersionUpdatesImageAndOriginalDimensions() async throws {
        var entry = ClipboardEntry(title: "Image", kind: .image,
            items: [[NSPasteboard.PasteboardType.png.rawValue: try png(width: 32, height: 16)]])
        let first = await ClipboardPreviewCache.shared.content(for: entry)
        entry.items = [[NSPasteboard.PasteboardType.png.rawValue: try png(width: 16, height: 32)]]
        entry.contentRevision = UUID()

        let updated = await ClipboardPreviewCache.shared.content(for: entry)

        XCTAssertEqual(first.summary, "32 × 16 pixels")
        XCTAssertEqual(first.image?.width, 32)
        XCTAssertEqual(first.image?.height, 16)
        XCTAssertFalse(first === updated)
        XCTAssertEqual(updated.summary, "16 × 32 pixels")
        XCTAssertEqual(updated.image?.width, 16)
        XCTAssertEqual(updated.image?.height, 32)
        XCTAssertNil(updated.characterCount)
    }

    func testImageIsBoundedWhileSummaryUsesOriginalDimensions() async throws {
        let entry = ClipboardEntry(title: "Large image", kind: .image,
            items: [[NSPasteboard.PasteboardType.png.rawValue: try png(width: 2_400, height: 1_400)]])
        let content = await ClipboardPreviewCache.shared.content(for: entry)
        let image = try XCTUnwrap(content.image)

        XCTAssertEqual(content.summary, "2400 × 1400 pixels")
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1_200)
        XCTAssertEqual(image.width, 1_200)
        XCTAssertEqual(image.height, 700)
    }

    func testFileSummaryOnlyUsesReferencesAndUnknownImageFallsBack() async {
        let file = ClipboardEntry(title: "File", kind: .file,
            items: [[NSPasteboard.PasteboardType.fileURL.rawValue:
                Data("file:///aom-test-nonexistent-file.txt".utf8)]])
        let fileContent = await ClipboardPreviewCache.shared.content(for: file)
        XCTAssertEqual(fileContent.summary, "1 file(s)")
        XCTAssertNil(fileContent.image)

        let invalidImage = ClipboardEntry(title: "Invalid", kind: .image,
            items: [[NSPasteboard.PasteboardType.png.rawValue: Data([0, 1, 2])]])
        let imageContent = await ClipboardPreviewCache.shared.content(for: invalidImage)
        XCTAssertEqual(imageContent.summary, "Image")
        XCTAssertNil(imageContent.image)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
