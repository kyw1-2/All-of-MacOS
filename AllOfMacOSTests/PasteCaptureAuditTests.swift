import AppKit
import CoreImage
import XCTest
@testable import AllOfMacOS

@MainActor
final class PasteCaptureAuditTests: XCTestCase {
    func testRetentionIndefinitelyAndTenThousandLimitSurviveSaveAndReload() async throws {
        let token = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-audit-\(token)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AOM-audit-\(token)"))
        let clipboard = NSPasteboard(name: .init("AOM-audit-\(token)"))
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: "AOM-audit-\(token)")
        }
        let store = ClipboardStore(directory: directory, pasteboard: clipboard, defaults: defaults, now: { clock })
        await store.ready()
        store.settings.retentionDays = 0
        store.settings.maxEntries = 10_000
        XCTAssertEqual(store.settings.bounded.retentionDays, 0)
        XCTAssertEqual(store.settings.bounded.maxEntries, 10_000)

        clipboard.clearContents()
        XCTAssertTrue(clipboard.setString("Keep forever (until capacity)", forType: .string))
        store.poll(sourceName: "Audit", sourceBundleID: "test.audit")
        await store.flush()
        XCTAssertEqual(store.entries.count, 1)
        clock.addTimeInterval(400 * 86_400)
        // Changing preferences invokes trim, just like periodic retention.
        store.settings.maxBytes -= 1
        XCTAssertEqual(store.entries.count, 1, "Unlimited retention must not silently delete the clip after a year")
        await store.flush()

        let reopened = ClipboardStore(directory: directory,
                                     pasteboard: NSPasteboard(name: .init("AOM-audit-reloaded-\(token)")),
                                     defaults: defaults, now: { clock })
        await reopened.ready()
        XCTAssertEqual(reopened.entries.first?.text, "Keep forever (until capacity)")
        XCTAssertEqual(reopened.settings.retentionDays, 0)
        XCTAssertEqual(reopened.settings.maxEntries, 10_000)
    }

    func testCaptureHistoryRestoresImageAndMP4AfterRestartWithoutDeletingOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-history-reload-\(UUID())")
        let savedVideo = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-preserve-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: savedVideo)
        }
        try Data("an existing video".utf8).write(to: savedVideo)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try XCTUnwrap(bitmap.cgImage)
        let store = CaptureHistory(directory: folder)
        let screenshot = store.add(CaptureResult(image: image, globalRect: CGRect(x: 10, y: 20, width: 16, height: 16),
                                                  scale: 1, kind: .area), url: nil)
        let video = store.add(CaptureResult(image: image, globalRect: CGRect(x: 0, y: 0, width: 16, height: 16),
                                             scale: 1, kind: .videoRecording), url: savedVideo)
        let reopened = CaptureHistory(directory: folder)
        XCTAssertEqual(reopened.entries.map(\.id), [video.id, screenshot.id])
        XCTAssertEqual(reopened.entries.last?.image.width, 16)
        XCTAssertEqual(reopened.entries.first?.playableVideoURL, savedVideo)
        reopened.removeAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedVideo.path),
                      "Clearing history must never delete a separately saved MP4.")
        XCTAssertTrue(CaptureHistory(directory: folder).entries.isEmpty)
    }

    func testRecognizeQRCodeInScreenshot() async throws {
        let payload = "https://example.com/aom-qr-test"
        let qr = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        qr.setValue(Data(payload.utf8), forKey: "inputMessage")
        qr.setValue("H", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(qr.outputImage)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let image = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))
        let codes = try await TextRecognitionService.detectQRCodes(image)
        XCTAssertTrue(codes.contains(payload), "An on-device QR scan should return the original payload.")
    }

    func testLastAreaDisplayIDRoundTripAndReset() {
        let oldRect = CaptureSettings.lastArea
        let oldID = CaptureSettings.lastAreaDisplayID
        defer {
            CaptureSettings.lastArea = oldRect
            CaptureSettings.lastAreaDisplayID = oldID
        }
        CaptureSettings.lastArea = CGRect(x: 30, y: 40, width: 120, height: 150)
        CaptureSettings.lastAreaDisplayID = 12345
        XCTAssertEqual(CaptureSettings.lastAreaDisplayID, 12345)
        CaptureSettings.lastArea = nil
        XCTAssertNil(CaptureSettings.lastAreaDisplayID)
    }

    func testRecordingOutputPathsCannotOverwriteSameSecondMP4() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-recording-audit-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ScreenRecordingService.uniqueRecordingURL(in: folder, at: timestamp)
        XCTAssertEqual(first.pathExtension, "mp4")
        try Data("first video must survive".utf8).write(to: first)
        let second = ScreenRecordingService.uniqueRecordingURL(in: folder, at: timestamp)
        XCTAssertNotEqual(first, second)
        try Data("second video".utf8).write(to: second)
        let third = ScreenRecordingService.uniqueRecordingURL(in: folder, at: timestamp)
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(third, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first video must survive".utf8))
    }

    func testMissingCaptureFileNeverClaimsClipboardCopySuccess() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-AOM-\(UUID().uuidString).mp4")
        XCTAssertFalse(ScreenCaptureService.shared.copyFileToClipboard(missing))
    }
}
