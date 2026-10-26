import XCTest
import AppKit
import PDFKit
import Darwin
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

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testDiskCacheSkipsAOMOwnCaches() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = folder.appendingPathComponent("com.kyw.AllOfMacOS")
        let other = folder.appendingPathComponent("other-cache")
        try Data(repeating: 1, count: 8192).write(to: own)
        try Data(repeating: 2, count: 8192).write(to: other)
        let freed = try MacMagicSystemToolService.shared.clearDiskCache(in: folder)
        XCTAssertGreaterThan(freed, 0, "Top-level cache files count toward reclaimed space")
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testDSStoreCleanupIncludesHiddenSubdirectories() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for directory in [folder, nested] {
            try Data().write(to: directory.appendingPathComponent(".DS_Store"))
            try Data().write(to: directory.appendingPathComponent("keep.txt"))
        }
        let count = try await MacMagicSystemToolService.shared.eraseDSStoreFiles(in: folder)
        XCTAssertEqual(count, 2)
        for directory in [folder, nested] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".DS_Store").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep.txt").path))
        }
    }

    func testUnlockPreservesHiddenAndBackupFlags() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("flags")
        try Data().write(to: file)
        defer {
            _ = chflags(file.path, 0)
            try? FileManager.default.removeItem(at: folder)
        }
        let unrelated = UInt32(UF_HIDDEN | UF_NODUMP)
        XCTAssertEqual(chflags(file.path, unrelated), 0)
        let service = MacMagicSystemToolService.shared
        try service.setFileLocked(url: file, locked: true)
        try service.setFileLocked(url: file, locked: false)
        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_flags, unrelated)
        try service.setFileHidden(url: file, hidden: false)
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_flags, UInt32(UF_NODUMP))
    }

    func testRenamePreservesLiteralReplacementAndExtensionlessNames() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("original")
        try Data([1]).write(to: file)
        let result = try MacMagicSystemToolService.shared.batchRename(
            urls: [file], pattern: "original", replacement: "$1-{n}")
        XCTAssertEqual(result.first?.lastPathComponent, "$1-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result[0].path))
    }

    func testRenameRejectsCollisionAndPathTraversal() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("first.txt")
        let occupied = folder.appendingPathComponent("second.txt")
        try Data([1]).write(to: file)
        try Data([2]).write(to: occupied)
        let service = MacMagicSystemToolService.shared
        XCTAssertThrowsError(try service.batchRename(urls: [file], pattern: "first", replacement: "second"))
        XCTAssertThrowsError(try service.batchRename(urls: [file], pattern: "first", replacement: "../escape"))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
        XCTAssertEqual(try Data(contentsOf: occupied), Data([2]))
        XCTAssertEqual(try service.batchRename(urls: [file], pattern: "absent", replacement: "x"), [file])
    }

    func testWebPConversionWritesRealWebPAndPreservesExistingOutput() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let source = folder.appendingPathComponent("image.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let output = try MacMagicSystemToolService.shared.convertImage(url: source, to: .webp)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes.dropFirst(8).prefix(4), as: UTF8.self), "WEBP")
        XCTAssertThrowsError(try MacMagicSystemToolService.shared.convertImage(url: source, to: .webp))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
}
