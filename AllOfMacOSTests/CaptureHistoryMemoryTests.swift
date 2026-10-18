import XCTest
import CoreGraphics
@testable import AllOfMacOS

/// F-01: capture history must bound *resident decoded bytes*, not only the
/// entry count, while pins stay durable and full-resolution pixels remain
/// retrievable on demand from the managed PNG.
@MainActor
final class CaptureHistoryMemoryTests: XCTestCase {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-caphistory-f01-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeImage(size: Int, red: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func result(_ image: CGImage, at date: Date = Date()) -> CaptureResult {
        CaptureResult(image: image, globalRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                      scale: 1, kind: .area, capturedAt: date)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func assertSamePixels(_ lhs: CGImage, _ rhs: CGImage,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let a = pixels(lhs), b = pixels(rhs)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        var maxDelta = 0
        for (x, y) in zip(a, b) { maxDelta = max(maxDelta, abs(Int(x) - Int(y))) }
        XCTAssertLessThanOrEqual(maxDelta, 1,
                                 "rehydrated pixels must match the captured pixels", file: file, line: line)
    }

    private func managedPNG(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    func testResidentByteBudgetEvictsAndRehydratesFullResolution() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 64
        let perImage = size * size * 4
        let budget = perImage * 4
        let history = CaptureHistory(directory: dir, residentByteBudget: budget)

        let images = (0..<6).map { makeImage(size: size, red: CGFloat($0) / 5) }
        let entries = zip(images, 0..<6).map { history.add(result($0.0), url: nil) }
        await history.flushPendingCacheWrites()

        XCTAssertEqual(history.entries.count, 6, "the byte budget must not drop entries")
        XCTAssertLessThanOrEqual(history.residentPixelBytes, budget,
                                 "the resident set must fit the byte budget")
        XCTAssertTrue(history.entries.contains { !$0.isResident },
                      "decoded bitmaps over budget must be evicted")

        let evicted = try XCTUnwrap(history.entries.first { !$0.isResident })
        let index = try XCTUnwrap(entries.firstIndex { $0.id == evicted.id })
        let rehydrated = evicted.image
        XCTAssertEqual(rehydrated.width, size)
        XCTAssertEqual(rehydrated.height, size)
        assertSamePixels(rehydrated, images[index])
    }

    func testCountBoundStillApplies() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = CaptureSettings.historyCapacity
        CaptureSettings.historyCapacity = 3
        defer { CaptureSettings.historyCapacity = previous }

        let history = CaptureHistory(directory: dir, residentByteBudget: Int.max)
        for index in 0..<6 { _ = history.add(result(makeImage(size: 8, red: CGFloat(index) / 6)), url: nil) }
        await history.flushPendingCacheWrites()
        XCTAssertEqual(history.entries.count, 3, "the existing count bound must still apply")
    }

    func testPinnedEntriesSurviveBudgetAndKeepTheirCacheFile() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 64
        let history = CaptureHistory(directory: dir, residentByteBudget: size * size * 4)

        let pinnedImage = makeImage(size: size, red: 0.1)
        // Older than the other captures (so it is the first eviction candidate)
        // but still inside the 30-day retention window.
        let pinned = history.add(result(pinnedImage, at: Date().addingTimeInterval(-3_600)), url: nil)
        history.togglePin(pinned)
        for index in 1..<5 {
            _ = history.add(result(makeImage(size: size, red: CGFloat(index) / 5)), url: nil)
        }
        await history.flushPendingCacheWrites()

        XCTAssertTrue(history.entries.contains { $0.id == pinned.id },
                      "a pinned entry is never removed by the byte budget")
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedPNG(pinned.id, in: dir).path),
                      "the managed PNG of a pinned entry must never be deleted")
        XCTAssertEqual(pinned.image.width, size)
        assertSamePixels(pinned.image, pinnedImage)
    }

    func testLoadDoesNotDecodeEveryCachedPNGOnStartup() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = CaptureHistory(directory: dir)
        _ = first.add(result(makeImage(size: 64, red: 0.3)), url: nil)
        _ = first.add(result(makeImage(size: 64, red: 0.6)), url: nil)
        await first.flushPendingCacheWrites()

        let reopened = CaptureHistory(directory: dir)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.residentPixelBytes, 0,
                       "startup must not decode full-resolution bitmaps")
        XCTAssertEqual(reopened.entries.first?.pixelSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(reopened.entries.first?.image.width, 64,
                       "full fidelity must still be available on demand")
    }

    func testReplaceImageStaysResidentUntilNewCacheLands() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = CaptureHistory(directory: dir, residentByteBudget: Int.max)
        let original = makeImage(size: 64, red: 0.2)
        let entry = history.add(result(original), url: nil)
        await history.flushPendingCacheWrites()
        XCTAssertTrue(entry.canEvictResidentImage)

        let edited = makeImage(size: 48, red: 0.9)
        history.replaceImage(of: entry, with: edited, scale: 1)
        XCTAssertFalse(entry.canEvictResidentImage,
                       "the stale PNG must not be rehydrated before the replacement lands")
        XCTAssertEqual(entry.pixelSize, CGSize(width: 48, height: 48))
        assertSamePixels(entry.image, edited)
        XCTAssertNil(entry.fileURL, "an in-place edit must detach the saved file")

        await history.flushPendingCacheWrites()
        XCTAssertTrue(entry.canEvictResidentImage,
                      "the replacement PNG becomes the rehydration source once written")

        let reopened = try XCTUnwrap(CaptureHistory(directory: dir, residentByteBudget: 1).entries.first)
        XCTAssertEqual(reopened.pixelSize, CGSize(width: 48, height: 48))
        assertSamePixels(reopened.image, edited)
    }

    func testFreshCaptureStaysResidentUntilItsManagedPNGLands() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A budget that cannot even hold this one capture: it may only be
        // enforced once the managed PNG exists, so the unsaved pixels are safe.
        let history = CaptureHistory(directory: dir, residentByteBudget: 1)
        let entry = history.add(result(makeImage(size: 64, red: 0.4)), url: nil)

        XCTAssertTrue(entry.isResident,
                      "a fresh capture must stay resident while its PNG write is in flight")
        XCTAssertFalse(entry.canEvictResidentImage)
        XCTAssertEqual(entry.image.width, 64)

        await history.flushPendingCacheWrites()
        XCTAssertFalse(entry.isResident, "once cached, the byte budget may evict the bitmap")
        XCTAssertEqual(history.entries.count, 1, "eviction must never drop the entry")
        XCTAssertEqual(entry.image.width, 64, "full fidelity must remain retrievable")
    }
}
