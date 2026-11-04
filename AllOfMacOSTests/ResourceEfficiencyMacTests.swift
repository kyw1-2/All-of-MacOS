import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AllOfMacOS

@MainActor
final class ResourceEfficiencyMacTests: XCTestCase {
    func testArmedWatcherStillReceivesAtomicReplacementImmediately() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target")
        try Data([1]).write(to: file)
        let changed = expectation(description: "kernel event before the 30-second sanity poll")
        var fulfilled = false
        let watcher = ResilientFileWatcher(path: file.path) {
            if (try? Data(contentsOf: file)) == Data([2]), !fulfilled {
                fulfilled = true
                changed.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(watcher.pollingInterval, 30)
        try Data([2]).write(to: file, options: .atomic)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(watcher.pollingInterval, 30)
    }

    func testMissingParentRecoversThenSlowsPollingAndStopsCleanly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("missing")
        let file = parent.appendingPathComponent("target")
        let changed = expectation(description: "missing parent recovered")
        var fulfilled = false
        let watcher = ResilientFileWatcher(path: file.path) {
            if !fulfilled, FileManager.default.fileExists(atPath: file.path) {
                fulfilled = true
                changed.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(watcher.pollingInterval, 1)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(watcher.pollingInterval, 30)
        watcher.stop()
        XCTAssertNil(watcher.pollingInterval)
    }

    func testStudioCacheRetainsHotImageAcrossCapacityAndReloadsInvalidatedPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var paths: [String] = []
        for index in 0..<5 {
            let url = directory.appendingPathComponent("\(index).png")
            try writePNG(to: url)
            paths.append(url.path)
        }
        defer { for path in paths { AOMStudioBackgroundImages.invalidate(path) } }
        let hot = try XCTUnwrap(AOMStudioBackgroundImages.image(atPath: paths[0]))
        for path in paths.dropFirst() {
            XCTAssertNotNil(AOMStudioBackgroundImages.image(atPath: path))
            XCTAssertTrue(AOMStudioBackgroundImages.image(atPath: paths[0]) === hot)
        }
        AOMStudioBackgroundImages.invalidate(paths[0])
        let reloaded = try XCTUnwrap(AOMStudioBackgroundImages.image(atPath: paths[0]))
        XCTAssertFalse(reloaded === hot)
        XCTAssertEqual(reloaded.extent, hot.extent)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                             bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
