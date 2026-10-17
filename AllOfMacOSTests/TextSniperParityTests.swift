import XCTest
import AppKit
@testable import AllOfMacOS

/// TextSniper-parity OCR: recognition across scripts on synthetic renders,
/// plus the pure post-processing, settings and language-order logic.
///
/// Recognition assertions compare whitespace-free, case-folded text and check
/// distinctive substrings only, so they survive OS model updates.
final class TextSniperParityTests: XCTestCase {

    // MARK: - Rendering helpers

    private func render(_ text: String, pointSize: CGFloat = 28, dark: Bool = false,
                        width: Int = 960, font: NSFont? = nil) -> CGImage {
        let lines = text.components(separatedBy: "\n")
        let lineHeight = pointSize * 1.5
        let height = Int(CGFloat(lines.count) * lineHeight + pointSize * 1.2)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(dark ? CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: pointSize),
            .foregroundColor: dark ? NSColor.white : NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            let y = CGFloat(height) - pointSize * 0.6 - CGFloat(index + 1) * lineHeight
            (line as NSString).draw(at: NSPoint(x: pointSize * 0.6, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func compact(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }

    private func recognize(_ image: CGImage, keepsLineBreaks: Bool = true,
                           languages: [String] = ["en-US", "ko-KR", "ja-JP", "zh-Hans"],
                           engine: TextRecognitionEngineMode = .automatic) async throws -> TextRecognitionResult {
        var options = TextRecognitionOptions()
        options.languages = languages
        options.keepsLineBreaks = keepsLineBreaks
        options.engine = engine
        return try await TextRecognitionService.recognize(image, options: options)
    }

    private func assertContains(_ text: String, _ needles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let haystack = compact(text)
        for needle in needles {
            XCTAssertTrue(haystack.contains(compact(needle)), "Expected “\(needle)” in “\(text)”", file: file, line: line)
        }
    }

    // MARK: - Recognition

    func testEnglishRecognitionKeepsLines() async throws {
        let image = render("The quick brown fox jumps over the lazy dog.\nInvoice number 2026-1017 is due Friday.")
        let result = try await recognize(image)
        print("[OCR en]", result.text, "passes:", result.passCount, "live:", result.usedLiveText)
        assertContains(result.text, ["quick brown fox", "lazy dog", "Invoice", "2026"])
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, 2, result.text)
    }

    func testKoreanRecognition() async throws {
        let image = render("한국어 문자 인식 테스트입니다.\n가나다라 마바사 아자차카")
        let result = try await recognize(image)
        print("[OCR ko]", result.text, "passes:", result.passCount, "live:", result.usedLiveText)
        assertContains(result.text, ["한국어", "문자", "인식", "테스트"])
        XCTAssertTrue(result.text.contains("문자 인식"), "Hangul word spacing must be preserved: \(result.text)")
    }

    func testJapaneseRecognition() async throws {
        let image = render("日本語の文字認識テストです。\nひらがなとカタカナ")
        let result = try await recognize(image)
        print("[OCR ja]", result.text, "passes:", result.passCount, "live:", result.usedLiveText)
        assertContains(result.text, ["日本語", "認識", "ひらがな", "カタカナ"])
    }

    func testChineseRecognition() async throws {
        let image = render("中文文字识别测试。\n简体中文句子")
        let result = try await recognize(image)
        print("[OCR zh]", result.text, "passes:", result.passCount, "live:", result.usedLiveText)
        assertContains(result.text, ["中文", "识别", "测试"])
    }

    func testMixedScriptRecognition() async throws {
        let image = render("Hello 안녕하세요 世界 こんにちは\nAOM 텍스트 OCR 2026")
        let result = try await recognize(image)
        print("[OCR mix]", result.text, "passes:", result.passCount, "live:", result.usedLiveText)
        assertContains(result.text, ["Hello", "안녕하세요", "こんにちは", "AOM", "텍스트", "OCR", "2026"])
    }

    func testDarkModeWhiteOnBlack() async throws {
        let image = render("White on black terminal output\n어두운 배경의 흰 글씨", dark: true)
        let result = try await recognize(image)
        print("[OCR dark]", result.text, "inverted:", result.inverted)
        XCTAssertTrue(result.inverted, "A dark capture gets an inverted pass")
        assertContains(result.text, ["White on black", "terminal", "어두운", "배경"])
    }

    func testTinyTextIsUpscaled() async throws {
        let image = render("Tiny text sample 12345", pointSize: 7, width: 170)
        let result = try await recognize(image)
        print("[OCR tiny]", result.text, "upscale:", result.upscale)
        XCTAssertGreaterThan(result.upscale, 1, "Small text must be upscaled before recognition")
        assertContains(result.text, ["Tiny", "text", "12345"])
    }

    func testJoinLinesModeReflowsParagraph() async throws {
        let image = render("Optical character recognition turns\npixels into editable text on device.")
        let result = try await recognize(image, keepsLineBreaks: false)
        print("[OCR reflow]", result.text)
        XCTAssertFalse(result.text.contains("\n"), result.text)
        assertContains(result.text, ["turns pixels"])
    }

    func testLegacyAPIStillWorks() async throws {
        let image = render("Legacy API call 42")
        let text = try await TextRecognitionService.recognize(image, keepsLineBreaks: true)
        assertContains(text, ["Legacy", "42"])
        let layout = try await TextRecognitionService.recognizeWithLayout(image)
        XCTAssertFalse(layout.isEmpty)
        for item in layout {
            XCTAssertTrue((0...1.0001).contains(item.box.minX) && (0...1.0001).contains(item.box.maxY), "\(item.box)")
        }
        let boxes = try await TextRecognitionService.boxes(matching: "legacy", in: image)
        XCTAssertEqual(boxes.count, 1)
    }

    func testBarcodeAndQRDetection() async throws {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue("https://example.com/aom".data(using: .utf8), forKey: "inputMessage")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40)))
        let image = CIContext().createCGImage(padded, from: padded.extent)!
        let codes = try await TextRecognitionService.detectBarcodes(image)
        XCTAssertEqual(codes.map(\.payload), ["https://example.com/aom"])
        let qrOnly = try await TextRecognitionService.detectQRCodes(image)
        XCTAssertEqual(qrOnly, ["https://example.com/aom"])
    }

    func testTwoColumnLayoutReadsColumnByColumn() async throws {
        // Pure layout: two prose columns, each three lines filling its width.
        func seg(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 300) -> TextLayoutLine {
            TextLayoutLine(text: t, box: CGRect(x: x, y: y, width: w, height: 20))
        }
        let segments = [
            seg("Left one", 10, 10), seg("Right one", 400, 10),
            seg("Left two", 10, 40), seg("Right two", 400, 40),
            seg("Left three", 10, 70), seg("Right three", 400, 70),
        ]
        let text = TextLayoutAssembler.assemble(segments, options: .init(keepsLineBreaks: true))
        XCTAssertEqual(text, "Left one\nLeft two\nLeft three\nRight one\nRight two\nRight three")
        // Short ragged cells are a table: keep rows, separate cells with tabs.
        let table = [seg("Name", 10, 10, 60), seg("Value", 400, 10, 60),
                     seg("Apples", 10, 40, 70), seg("3", 400, 40, 12),
                     seg("Pears", 10, 70, 60), seg("12", 400, 70, 24)]
        XCTAssertEqual(TextLayoutAssembler.assemble(table, options: .init(keepsLineBreaks: true)),
                       "Name\tValue\nApples\t3\nPears\t12")
    }

    // MARK: - Pure post-processing

    func testParagraphReflowWithGeometry() {
        func line(_ t: String, _ y: CGFloat, width: CGFloat = 600, x: CGFloat = 0, h: CGFloat = 20) -> TextLayoutLine {
            TextLayoutLine(text: t, box: CGRect(x: x, y: y, width: width, height: h))
        }
        let lines = [
            line("Heading", 0, width: 120, h: 30),
            line("The first paragraph wraps onto", 50),
            line("a second line and ends here.", 76, width: 380),
            line("A new paragraph starts after a gap", 130),
            line("and continues.", 156, width: 200),
        ]
        let text = TextLayoutAssembler.assemble(lines, options: .init(keepsLineBreaks: false, detectsColumns: false))
        XCTAssertEqual(text, """
            Heading
            The first paragraph wraps onto a second line and ends here.
            A new paragraph starts after a gap and continues.
            """)
    }

    func testHyphenationJoining() {
        XCTAssertTrue(TextHyphenation.isHyphenBreak("recog-", next: "nition works"))
        XCTAssertFalse(TextHyphenation.isHyphenBreak("A list -", next: "item"))
        XCTAssertFalse(TextHyphenation.isHyphenBreak("Year 2026-", next: "next"))
        XCTAssertFalse(TextHyphenation.isHyphenBreak("North-", next: "East"), "Capitalised continuation is a real compound")
        XCTAssertEqual(TextHyphenation.joinPreservingLines(["Optical recog-", "nition works", "well"]),
                       ["Optical recognition", "works", "well"])
        XCTAssertEqual(TextHyphenation.joinPreservingLines(["infor-", "mation"]), ["information"])
        XCTAssertEqual(TextPostProcessor.reflow(["Optical recog-", "nition works", "well."], joinsHyphenatedWords: true),
                       "Optical recognition works well.")
        XCTAssertEqual(TextPostProcessor.reflow(["Optical recog-", "nition"], joinsHyphenatedWords: false),
                       "Optical recog- nition")
    }

    func testCJKSpacingRules() {
        // Chinese / Japanese lines join without spaces; Korean keeps word spacing.
        XCTAssertEqual(TextSpacing.lineJoinSeparator("中文文字", "识别测试"), "")
        XCTAssertEqual(TextSpacing.lineJoinSeparator("日本語の", "テスト"), "")
        XCTAssertEqual(TextSpacing.lineJoinSeparator("한국어 문자", "인식 테스트"), " ")
        XCTAssertEqual(TextSpacing.lineJoinSeparator("hello", "world"), " ")
        XCTAssertEqual(TextSpacing.lineJoinSeparator("使用", "OCR"), "")
        XCTAssertEqual(TextSpacing.normalizeCJKSpacing("東 京 タ ワ ー"), "東京タワー")
        XCTAssertEqual(TextSpacing.normalizeCJKSpacing("你好 ， 世界 。"), "你好，世界。")
        XCTAssertEqual(TextSpacing.normalizeCJKSpacing("한국어 문자 인식"), "한국어 문자 인식")
        XCTAssertEqual(TextSpacing.normalizeCJKSpacing("Hello 世界"), "Hello 世界")
        XCTAssertEqual(TextPostProcessor.reflow(["中文文字", "识别测试。"], joinsHyphenatedWords: true), "中文文字识别测试。")
        XCTAssertEqual(TextPostProcessor.reflow(["한국어 문자", "인식 테스트"], joinsHyphenatedWords: true), "한국어 문자 인식 테스트")
    }

    func testListItemsAndBlankLinesStayOnTheirOwnLines() {
        XCTAssertTrue(TextPostProcessor.isListItem("• Bullet"))
        XCTAssertTrue(TextPostProcessor.isListItem("2. Second"))
        XCTAssertTrue(TextPostProcessor.isListItem("- dash item"))
        XCTAssertFalse(TextPostProcessor.isListItem("-5 degrees"))
        XCTAssertFalse(TextPostProcessor.isListItem("3.14 is pi"))
        XCTAssertEqual(TextPostProcessor.reflow(["Shopping:", "• Milk", "• Eggs", "", "Done and", "dusted"],
                                                joinsHyphenatedWords: true),
                       "Shopping:\n• Milk\n• Eggs\nDone and dusted")
    }

    func testScriptClassificationAndLinks() {
        XCTAssertEqual(TextScriptClassifier.dominantScript("안녕하세요 world"), .hangul)
        XCTAssertEqual(TextScriptClassifier.dominantScript("こんにちは"), .kana)
        XCTAssertEqual(TextScriptClassifier.dominantScript("世界和平"), .han)
        XCTAssertEqual(TextScriptClassifier.dominantScript("Привет"), .cyrillic)
        XCTAssertNil(TextScriptClassifier.dominantScript("123 !?"))
        let links = TextPostProcessor.links(in: "See https://example.com/a and mail me@example.org, again https://example.com/a")
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/a", "mailto:me@example.org"])
    }

    func testFusionVotesAcrossScriptPasses() {
        // Synthetic passes over "Hello 안녕하세요 世界": the Korean pass misreads
        // the Han word, the Japanese pass hallucinates Han over the Hangul.
        func obs(_ tokens: [(String, CGFloat, CGFloat)], conf: Float) -> OCRPassObservation {
            let text = tokens.map(\.0).joined(separator: " ")
            let toks = tokens.enumerated().map { i, t in
                OCRToken(text: t.0, box: CGRect(x: t.1, y: 10, width: t.2 - t.1, height: 30), leadingSpace: i > 0)
            }
            return OCRPassObservation(text: text, box: CGRect(x: tokens[0].1, y: 10, width: tokens.last!.2 - tokens[0].1, height: 30),
                                      confidence: conf, tokens: toks)
        }
        let hangul = OCRPass(label: "hangul", group: .hangul,
                             observations: [obs([("Hello", 0, 80), ("안녕하세요", 90, 210), ("반뜻", 220, 280)], conf: 0.5)])
        let japanese = OCRPass(label: "japanese", group: .japanese,
                               observations: [obs([("Hello", 0, 80), ("州品", 95, 200), ("世界", 220, 280)], conf: 0.5)])
        let chinese = OCRPass(label: "zh", group: .chineseSimplified,
                              observations: [obs([("Hello", 0, 80), ("世界", 222, 281)], conf: 1.0)])
        // Without a re-read, Han over Hangul is disputed …
        let disputes = TextRecognitionFusion.disputedRegions([hangul, japanese, chinese])
        XCTAssertTrue(disputes.contains { $0.minX < 100 && $0.maxX > 190 }, "\(disputes)")
        // … and a Live Text re-read of that region settles it.
        let hint = (region: CGRect(x: 90, y: 10, width: 120, height: 30), text: "안녕하세요")
        let lines = TextRecognitionFusion.fuse([hangul, japanese, chinese], regionHints: [hint])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "Hello 안녕하세요 世界")
        // Script plausibility: a Korean pass emitting Katakana is down-weighted.
        XCTAssertLessThan(TextRecognitionFusion.scriptWeight("フトレトト", group: .hangul), 0.5)
        XCTAssertGreaterThan(TextRecognitionFusion.scriptWeight("안녕", group: .hangul), 1.0)
        XCTAssertEqual(TextRecognitionFusion.scriptWeight("anything", group: nil), 1)
    }

    func testTokenizerSplitsScriptRunsAndKeepsPunctuation() {
        let text = "世界こんにちは 테스트입니다. 2026년 OCR"
        let tokens = TextRecognitionFusion.tokenRanges(text).map { String(text[$0]) }
        XCTAssertEqual(tokens, ["世界", "こんにちは", "테스트입니다.", "2026년", "OCR"])
        // Unreliable CJK sub-range boxes are re-estimated inside the line.
        let ranges = TextRecognitionFusion.tokenRanges("Hello 世界こんにちは")
        let line = CGRect(x: 0, y: 0, width: 300, height: 30)
        let boxes = TextRecognitionFusion.layoutTokens(
            text: "Hello 世界こんにちは", ranges: ranges,
            measured: [CGRect(x: 0, y: 0, width: 70, height: 30),
                       CGRect(x: 70, y: 0, width: 230, height: 30),
                       CGRect(x: 70, y: 0, width: 230, height: 30)], lineBox: line)
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(boxes[0].maxX, 70, accuracy: 0.5)
        XCTAssertLessThan(boxes[1].maxX, boxes[2].minX + 1, "Re-estimated CJK runs must not overlap")
        XCTAssertEqual(boxes[2].maxX, 300, accuracy: 0.5)
    }

    func testComposeOutputAndAdditiveClipboard() {
        XCTAssertEqual(TextCaptureController.composeOutput(text: "Visit https://a.example", barcodes: ["https://a.example"]),
                       "Visit https://a.example")
        XCTAssertEqual(TextCaptureController.composeOutput(text: "Ticket", barcodes: ["ABC-123"]), "Ticket\nABC-123")
        XCTAssertEqual(TextCaptureController.composeOutput(text: "  ", barcodes: ["ABC-123"]), "ABC-123")
        XCTAssertEqual(TextCaptureController.clipboardText(for: "new", existing: "old", additive: true).text, "old\nnew")
        XCTAssertEqual(TextCaptureController.clipboardText(for: "new", existing: "old\n", additive: true).text, "old\nnew")
        XCTAssertEqual(TextCaptureController.clipboardText(for: "new", existing: "old", additive: false).text, "new")
        XCTAssertFalse(TextCaptureController.clipboardText(for: "new", existing: nil, additive: true).appended)
    }

    @MainActor
    func testClipboardImageExtraction() {
        let board = NSPasteboard(name: NSPasteboard.Name("AOMTextCaptureTest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertNil(TextCaptureController.clipboardImage(from: board))
        let cg = render("Clipboard image")
        board.clearContents()
        board.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        let image = TextCaptureController.clipboardImage(from: board)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, cg.width)
    }

    // MARK: - Settings and languages

    func testSettingsPersistence() {
        let suite = "AOMTextCaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TextCaptureSettings(defaults: defaults)
        XCTAssertTrue(settings.usesAutomaticLanguages)
        XCTAssertTrue(settings.keepsLineBreaks)
        XCTAssertFalse(settings.additiveClipboard)
        XCTAssertTrue(settings.usesLanguageCorrection, "TextSniper always enables language correction")
        XCTAssertEqual(settings.engine, .automatic)

        settings.usesAutomaticLanguages = false
        settings.selectedLanguages = ["ko-KR", "en-US", "ko-KR", "ja-JP"]
        settings.keepsLineBreaks = false
        settings.additiveClipboard = true
        settings.joinsHyphenatedWords = false
        settings.detectsLinks = false
        settings.readsBarcodes = false
        settings.playsSound = false
        settings.showsResultHUD = false
        settings.speaksResult = true
        settings.customWordsText = "AOM, TextSniper\nKiro"
        settings.engine = .liveText
        settings.hudDuration = 99

        let reloaded = TextCaptureSettings(defaults: defaults)
        XCTAssertFalse(reloaded.usesAutomaticLanguages)
        XCTAssertEqual(reloaded.selectedLanguages, ["ko-KR", "en-US", "ja-JP"])
        XCTAssertFalse(reloaded.keepsLineBreaks)
        XCTAssertTrue(reloaded.additiveClipboard)
        XCTAssertFalse(reloaded.joinsHyphenatedWords)
        XCTAssertFalse(reloaded.detectsLinks)
        XCTAssertFalse(reloaded.readsBarcodes)
        XCTAssertFalse(reloaded.playsSound)
        XCTAssertFalse(reloaded.showsResultHUD)
        XCTAssertTrue(reloaded.speaksResult)
        XCTAssertEqual(reloaded.customWords, ["AOM", "TextSniper", "Kiro"])
        XCTAssertEqual(reloaded.engine, .liveText)
        XCTAssertEqual(reloaded.hudDuration, 30, "Duration is clamped")
        XCTAssertEqual(defaults.object(forKey: "AOMOCRKeepsLineBreaks") as? Bool, false,
                       "Keep Line Breaks shares the pre-existing CaptureSettings key")

        reloaded.moveLanguage("ja-JP", by: -2)
        XCTAssertEqual(reloaded.selectedLanguages, ["ja-JP", "ko-KR", "en-US"])
        reloaded.removeLanguage("ko-KR")
        reloaded.addLanguage("zh-Hant")
        XCTAssertEqual(TextCaptureSettings(defaults: defaults).selectedLanguages, ["ja-JP", "en-US", "zh-Hant"])
        let options = TextRecognitionOptions.fromSettings(reloaded)
        XCTAssertEqual(Array(options.languages.prefix(3)), ["ja-JP", "en-US", "zh-Hant"])
        XCTAssertFalse(options.keepsLineBreaks)
        XCTAssertTrue(TextRecognitionOptions.fromSettings(reloaded, keepsLineBreaks: true).keepsLineBreaks)
    }

    func testLanguageListOrdering() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "ko-KR", "ja-JP", "pt-BR", "no-NO"]
        // Explicit order first, then English fallback, then the rest in Vision order.
        XCTAssertEqual(TextCaptureLanguages.priorityList(selected: ["ko-KR", "ja-JP"], automatic: false,
                                                         preferred: ["fr-FR"], supported: supported),
                       ["ko-KR", "ja-JP", "en-US", "fr-FR", "zh-Hans", "zh-Hant", "pt-BR", "no-NO"])
        // Automatic follows the system languages, mapped onto Vision codes.
        XCTAssertEqual(TextCaptureLanguages.priorityList(selected: ["ja-JP"], automatic: true,
                                                         preferred: ["ko-KR", "zh-Hant-TW", "en-GB"], supported: supported),
                       ["ko-KR", "zh-Hant", "en-US", "fr-FR", "zh-Hans", "ja-JP", "pt-BR", "no-NO"])
        XCTAssertEqual(TextCaptureLanguages.bestMatch(for: "zh-HK", in: supported), "zh-Hant")
        XCTAssertEqual(TextCaptureLanguages.bestMatch(for: "zh", in: supported), "zh-Hans")
        XCTAssertEqual(TextCaptureLanguages.bestMatch(for: "pt-PT", in: supported), "pt-BR")
        XCTAssertEqual(TextCaptureLanguages.bestMatch(for: "nb", in: supported), "no-NO")
        XCTAssertNil(TextCaptureLanguages.bestMatch(for: "xx-YY", in: supported))
        // Every supported language has a localised display name, and the picker is sorted by it.
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(TextCaptureLanguages.displayName(for: "ko-KR", locale: english), "Korean (South Korea)")
        XCTAssertTrue(TextCaptureLanguages.displayName(for: "ko-KR", locale: Locale(identifier: "ko_KR")).hasPrefix("한국어"))
        let picker = TextCaptureLanguages.pickerOrder(supported, locale: english)
        XCTAssertEqual(picker.map { TextCaptureLanguages.displayName(for: $0, locale: english) },
                       picker.map { TextCaptureLanguages.displayName(for: $0, locale: english) }
                           .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(TextCaptureLanguages.supported.contains("ko-KR"))
        // Script-group passes put the group's language first.
        XCTAssertEqual(TextCaptureLanguages.passLanguages(for: .hangul, priority: ["en-US", "ko-KR", "ja-JP"]),
                       ["ko-KR", "en-US", "ja-JP"])
        XCTAssertEqual(TextCaptureLanguages.passLanguages(for: .chineseTraditional, priority: ["en-US"]).first, "zh-Hant")
        XCTAssertEqual(TextScriptGroup.groups(forScripts: [.han: 3], priority: ["ja-JP"]), [.japanese])
        XCTAssertEqual(TextScriptGroup.groups(forScripts: [.han: 3, .hangul: 2], priority: []), [.hangul, .chineseSimplified])
    }

    @MainActor
    func testTextCaptureShortcutsPersistAndMatch() {
        let suite = "AOMTextCaptureShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = TextCaptureShortcuts(defaults: defaults)
        XCTAssertEqual(shortcuts.shortcut(for: .captureTextToggledLineBreaks),
                       KeyboardShortcut(keyCode: 19, modifiers: [.command, .shift, .option]))
        XCTAssertNil(shortcuts.shortcut(for: .readQRCode), "TextSniper ships QR unassigned")
        let custom = KeyboardShortcut(keyCode: 12, modifiers: [.control, .option, .command])
        shortcuts.setShortcut(custom, for: .readQRCode)
        shortcuts.setShortcut(nil, for: .captureTextToggledLineBreaks)
        let reloaded = TextCaptureShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .readQRCode), custom)
        XCTAssertNil(reloaded.shortcut(for: .captureTextToggledLineBreaks), "Cleared shortcut stays cleared")
        XCTAssertEqual(reloaded.matchingAction(keyCode: 12, modifiers: [.control, .option, .command, .capsLock]), .readQRCode)
        XCTAssertNil(reloaded.matchingAction(keyCode: 12, modifiers: [.command]))
        // The CleanShot table keeps owning ⇧⌘2 for Capture Text.
        let capture = CaptureShortcuts(defaults: UserDefaults(suiteName: suite + "-capture")!)
        XCTAssertEqual(capture.matchingAction(keyCode: 19, modifiers: [.command, .shift]), .ocr)
        XCTAssertNil(capture.matchingAction(keyCode: 19, modifiers: [.command, .shift, .option]),
                     "The toggled-line-break default must not collide with a CleanShot default")
        UserDefaults().removePersistentDomain(forName: suite + "-capture")
    }

    @MainActor
    func testResultHUDPlacementStaysOnScreen() {
        guard let screen = NSScreen.screens.first else { return }
        let size = NSSize(width: 380, height: 160)
        let primaryHeight = screen.frame.height
        // Selection near the top of the primary display: HUD goes below it.
        let anchor = CGRect(x: screen.frame.midX - 100, y: 100, width: 200, height: 80)
        let origin = TextCaptureHUDController.origin(for: size, anchor: anchor)
        XCTAssertLessThan(origin.y + size.height, primaryHeight - anchor.maxY + 1)
        XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1)
            .contains(NSRect(origin: origin, size: size)))
        // No anchor: bottom centre of the screen under the pointer.
        let fallback = TextCaptureHUDController.origin(for: size, anchor: nil, mouse: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        XCTAssertEqual(fallback.x + size.width / 2, screen.visibleFrame.midX, accuracy: 1)
    }

    func testVoiceSelectionFollowsDetectedLanguage() {
        let voices = ["en-US", "ko-KR", "ja-JP", "zh-CN", "zh-TW", "en-GB"]
        XCTAssertEqual(TextCaptureSpeech.voiceLanguage(for: "ko", available: voices, preferred: []), "ko-KR")
        XCTAssertEqual(TextCaptureSpeech.voiceLanguage(for: "zh-Hant", available: voices, preferred: []), "zh-TW")
        XCTAssertEqual(TextCaptureSpeech.voiceLanguage(for: "zh-Hans", available: voices, preferred: []), "zh-CN")
        XCTAssertEqual(TextCaptureSpeech.voiceLanguage(for: "en", available: voices, preferred: ["en-GB"]), "en-GB")
        XCTAssertNil(TextCaptureSpeech.voiceLanguage(for: "xx", available: voices, preferred: []))
        XCTAssertEqual(TextRecognitionEngine.dominantLanguage("이것은 한국어 문장입니다"), "ko")
    }

    func testCaptureMenuKeepsCleanShotTopLevelAndAddsTextEntries() {
        XCTAssertEqual(CaptureMenuCommand.captureText.title(), "Capture Text (OCR)")
        XCTAssertEqual(CaptureMenuCommand.captureText.shortcutAction, .ocr)
        XCTAssertEqual(TextCaptureShortcutAction.allCases.map(\.displayName),
                       ["Capture Text (Toggle Line Breaks)", "Capture Text from Clipboard Image", "Read QR / Barcode"])
    }
}
