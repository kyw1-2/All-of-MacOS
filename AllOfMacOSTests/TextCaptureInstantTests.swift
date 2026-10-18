import AppKit
import XCTest
@testable import AllOfMacOS

final class TextCaptureInstantTests: XCTestCase {
    @MainActor
    private func render(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 1100, height: 180, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1100, height: 180))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 20, y: 35), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    func testPrimaryLanguageSelectsTextSniperEngine() {
        for code in ["ko-KR", "ja-JP", "zh-Hans", "zh-Hant", "yue-Hant"] {
            XCTAssertTrue(TextCaptureInstant.prefersLiveText(engine: .automatic, primaryLanguage: code))
            XCTAssertFalse(TextCaptureInstant.prefersLiveText(engine: .vision, primaryLanguage: code))
        }
        XCTAssertFalse(TextCaptureInstant.prefersLiveText(engine: .automatic, primaryLanguage: "en-US"))
        XCTAssertTrue(TextCaptureInstant.prefersLiveText(engine: .liveText, primaryLanguage: "en-US"))
    }

    @MainActor
    func testKoreanCaptureUsesOnlyLiveTextAndPreservesSpacing() async throws {
        var options = TextRecognitionOptions()
        options.languages = ["ko-KR", "en-US"]
        let start = Date()
        let result = try await TextCaptureInstant.recognize(render("한국어 문자 인식 속도 테스트\nOCR 2026 결과"), options: options)
        print("[instant Korean] ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        XCTAssertTrue(result.text.contains("문자 인식"), result.text)
        XCTAssertTrue(result.text.contains("OCR 2026"), result.text)
        XCTAssertTrue(result.usedLiveText)
        XCTAssertEqual(result.passCount, 0, "Copying a Live Text transcript must not wait for Vision geometry")
        XCTAssertEqual(result.upscale, 1)
        XCTAssertFalse(result.inverted)
    }

    @MainActor
    func testEnglishCaptureUsesOneVisionPass() async throws {
        var options = TextRecognitionOptions()
        options.languages = ["en-US"]
        let result = try await TextCaptureInstant.recognize(render("Instant text capture works offline."), options: options)
        XCTAssertTrue(result.text.contains("Instant text capture"), result.text)
        XCTAssertFalse(result.usedLiveText)
        XCTAssertEqual(result.passCount, 1)
    }

    @MainActor
    func testCaptureLatencyComparison() async throws {
        let image = render("한국어 문자 인식 속도 테스트\nOCR 2026 결과")
        var options = TextRecognitionOptions()
        options.languages = ["ko-KR", "en-US"]
        let oldStart = Date()
        let previous = try await TextRecognitionEngine.recognize(image, options: options)
        let previousMS = Int(Date().timeIntervalSince(oldStart) * 1000)
        let start = Date()
        let result = try await TextCaptureInstant.recognize(image, options: options)
        print("[capture comparison] previous_ms=\(previousMS) instant_ms=\(Int(Date().timeIntervalSince(start) * 1000)) previous_passes=\(previous.passCount) instant_passes=\(result.passCount)")
        XCTAssertTrue(result.text.contains("문자 인식"))
    }

    func testDeadlineReturnsWithoutWaitingForNonCooperativeOperation() async {
        let start = Date()
        let result = await TextAnalysisDeadline<Int>.run(seconds: 0.02) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { continuation.resume(returning: 42) }
            }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        // Let the late completion exercise the exactly-once guard.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    func testDeadlineSuccessAndCancellation() async {
        let result = await TextAnalysisDeadline<Int>.run(seconds: 1) { 42 }
        XCTAssertEqual(result, 42)
        let task = Task {
            await TextAnalysisDeadline<Int>.run(seconds: 10) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return 99
            }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }
}
