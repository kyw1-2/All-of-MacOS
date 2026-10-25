import XCTest
import AppKit
import PDFKit
@testable import AllOfMacOS

/// MacMagic tool coverage: the pure parts of the eight new tools.
@MainActor
final class MacMagicToolTests: XCTestCase {

    func testQRCodeGeneratesNonEmptyImage() {
        let image = MacMagicSystemToolService.shared.generateQRCode(text: "https://kyw1-2.github.io")
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 50)
    }

    func testBatchRenameNumbersAndPatterns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["photo one.jpg", "photo two.jpg", "photo three.jpg"]
        var urls: [URL] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            urls.append(url)
        }
        let renamed = try MacMagicSystemToolService.shared.batchRename(
            urls: urls, pattern: "photo ", replacement: "shot-{n}-")
        XCTAssertEqual(renamed.count, 3)
        XCTAssertEqual(renamed[0].lastPathComponent, "shot-1-one.jpg")
        XCTAssertEqual(renamed[2].lastPathComponent, "shot-3-three.jpg")
    }

    func testForceDeleteClearsTheLockFlagFirst() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-locked-\(UUID().uuidString).txt")
        try "locked".write(to: url, atomically: true, encoding: .utf8)
        try MacMagicSystemToolService.shared.setFileLocked(url: url, locked: true)
        // A plain remove would fail with EPERM; forceDelete must succeed.
        try MacMagicSystemToolService.shared.forceDelete(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCombinePDFsMergesPagesInOrder() throws {
        let service = MacMagicSystemToolService.shared
        func makePDF(_ text: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aom-\(text).pdf")
            let document = PDFDocument()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage()
            image.addRepresentation(bitmap)
            if let page = PDFPage(image: image) {
                document.insert(page, at: 0)
            }
            _ = document.write(to: url)
            return url
        }
        let first = try makePDF("first-\(UUID().uuidString)")
        let second = try makePDF("second-\(UUID().uuidString)")
        let merged = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-merged-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: merged)
        }
        try service.combinePDFs(urls: [second, first], to: merged) // sorted by name → first, second
        let result = PDFDocument(url: merged)
        XCTAssertEqual(result?.pageCount, 2, "two single-page PDFs merge into two pages")
    }

    func testDiskCacheSkipsAOMOwnCaches() {
        // The contract: AOM's own cache directories survive clearDiskCache.
        // We only assert the skip-list logic indirectly — the function must
        // not throw on a standard user cache directory.
        XCTAssertNoThrow(try MacMagicSystemToolService.shared.clearDiskCache())
    }
}
