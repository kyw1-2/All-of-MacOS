import AppKit
import XCTest
@testable import AllOfMacOS

/// 1.2.1: clipboard shelf responsiveness and instant Capture Text.
@MainActor
final class AOM121PerformanceTests: XCTestCase {
    private func render(_ text: String, pointSize: CGFloat = 28, width: CGFloat = 900) -> CGImage {
        let lines = text.components(separatedBy: "\n")
        let height = CGFloat(lines.count) * pointSize * 1.8 + 40
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize),
                                                             .foregroundColor: NSColor.black]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 20, y: 20 + CGFloat(index) * pointSize * 1.8), withAttributes: attributes)
            }
            return true
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    private func options(_ languages: [String]) -> TextRecognitionOptions {
        var options = TextRecognitionOptions()
        options.languages = languages
        return options
    }

    // MARK: Capture Text

    func testEnglishCaptureUsesSinglePass() async throws {
        let result = try await TextRecognitionService.recognize(render("Instant text capture works offline."),
                                                                options: options(["en-US", "ko-KR"]))
        XCTAssertTrue(result.text.contains("Instant text capture"), result.text)
        XCTAssertEqual(result.passCount, 1, "Plain Latin text must not run the multi-pass pipeline")
    }

    func testKoreanUnderEnglishFirstSystemStaysFast() async throws {
        // This Mac's order is English first, Korean second.
        let result = try await TextRecognitionService.recognize(render("한국어 문자 인식 속도 테스트\nOCR 2026 결과"),
                                                                options: options(["en-US", "ko-KR"]))
        XCTAssertTrue(result.text.contains("문자 인식"), result.text)
        XCTAssertLessThanOrEqual(result.passCount, 2, "Korean + Latin needs at most one re-read")
        XCTAssertFalse(result.usedLiveText)
    }

    func testFastPathCanBeTurnedOff() async throws {
        var slow = options(["en-US", "ko-KR"])
        slow.prefersSpeed = false
        let result = try await TextRecognitionService.recognize(render("Voting pipeline still available"), options: slow)
        XCTAssertGreaterThan(result.passCount, 1)
    }

    func testFastLanguagesAreBounded() {
        let priority = TextCaptureLanguages.priorityList(selected: ["ko-KR"], automatic: false)
        let fast = TextRecognitionEngine.fastLanguages(priority)
        XCTAssertEqual(fast.first, "ko-KR")
        XCTAssertTrue(fast.contains("en-US"))
        XCTAssertLessThanOrEqual(fast.count, 4)
    }

    func testFastRecognitionSettingDefaultsOnAndPersists() {
        let defaults = UserDefaults(suiteName: "AOM121-\(UUID().uuidString)")!
        let settings = TextCaptureSettings(defaults: defaults)
        XCTAssertTrue(settings.prefersFastRecognition)
        settings.prefersFastRecognition = false
        XCTAssertFalse(TextRecognitionOptions.fromSettings(settings).prefersSpeed)
    }

    // MARK: Clipboard

    func testSearchQueryStillMatchesEveryField() {
        var entry = ClipboardEntry(title: "Meeting", text: "Design review at 10:30", sourceName: "Notes",
                                   sourceBundleID: "com.apple.Notes", items: [])
        entry.recognizedText = "영수증 합계"
        XCTAssertTrue(ClipboardSearchQuery("meeting").matches(entry, boards: []))
        XCTAssertTrue(ClipboardSearchQuery("review").matches(entry, boards: []))
        XCTAssertTrue(ClipboardSearchQuery("notes").matches(entry, boards: []))
        XCTAssertTrue(ClipboardSearchQuery("합계").matches(entry, boards: []))
        XCTAssertFalse(ClipboardSearchQuery("-review").matches(entry, boards: []))
        XCTAssertFalse(ClipboardSearchQuery("apple").matches(entry, boards: []), "Bundle IDs are not searched")
        XCTAssertTrue(ClipboardSearchQuery("").matches(entry, boards: []))
        XCTAssertTrue(ClipboardSearchQuery("after:2000-01-01").matches(entry, boards: []))
    }

    func testIntelligenceDigestIsCheapButSensitiveToEdits() {
        let long = String(repeating: "abc ", count: 500_000)
        let entry = ClipboardEntry(title: "Log", text: long, items: [])
        var edited = entry
        edited.text = long + "x"
        XCTAssertEqual(ClipboardIntelligence.digest(entry), ClipboardIntelligence.digest(entry))
        XCTAssertNotEqual(ClipboardIntelligence.digest(entry), ClipboardIntelligence.digest(edited))
        let start = Date()
        for _ in 0..<200 { _ = ClipboardIntelligence.digest(entry) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "Digest must not hash the whole clip")
    }

    func testHugeClipsSkipExpensiveClassification() {
        let start = Date()
        let value = ClipboardItemClassifier.classify(text: String(repeating: "token=value ", count: 20_000))
        XCTAssertEqual(value, .unclassified)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(ClipboardItemClassifier.classify(text: String(repeating: "x", count: 70_000) + "-----BEGIN RSA PRIVATE KEY-----"), .secret)
    }

    func testScrollPolicyLeavesFloatingPanelsAlone() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertFalse(AOMScrollChromePolicy.isManaged(panel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        XCTAssertTrue(AOMScrollChromePolicy.isManaged(window))
    }

    func testDeepLinkOpensClipboardShelf() {
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://open-clipboard")!), .openClipboard)
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://open-clipboard?x=1")!))
    }
}

@MainActor
final class ShortcutConflictTests: XCTestCase {
    func testDetectsPasteOwningTheShelfShortcut() throws {
        let data = Data(#"{"keyCode":9,"internalModifiers":1179648}"#.utf8)
        let decoded = try XCTUnwrap(ShortcutConflicts.decode(data))
        XCTAssertEqual(decoded.keyCode, 9)
        XCTAssertTrue(decoded.modifiers.contains([.command, .shift]))
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        // No Paste process in the list: no conflict even with matching prefs.
        XCTAssertNil(ShortcutConflicts.clipboardHistoryConflict(
            shortcut: KeyboardShortcut(keyCode: 9, modifiers: [.command, .shift]), running: [finder], preference: { _, _ in data }))
        XCTAssertNil(ShortcutConflicts.decode(Data("{}".utf8)))
    }
}
