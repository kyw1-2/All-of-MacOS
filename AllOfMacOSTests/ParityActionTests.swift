import XCTest
import AppKit
import Network
@testable import AllOfMacOS

/// 3.1.0 parity actions. Only pure planners and encoders are exercised; nothing
/// here posts input, changes a device or touches the general pasteboard.
final class ParityActionTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: Text transforms

    func testCaseTransforms() {
        XCTAssertEqual(TextTransform.uppercase.apply("Hello", locale: posix), "HELLO")
        XCTAssertEqual(TextTransform.lowercase.apply("HeLLo", locale: posix), "hello")
        XCTAssertEqual(TextTransform.titleCase.apply("hello world", locale: posix), "Hello World")
        XCTAssertEqual(TextTransform.sentenceCase.apply("HELLO WORLD. SECOND line\nthird", locale: posix),
                       "Hello world. Second line\nThird")
    }

    func testWhitespaceTransforms() {
        XCTAssertEqual(TextTransform.trimWhitespace.apply("  hi \n"), "hi")
        XCTAssertEqual(TextTransform.collapseSpaces.apply("a  \t b\n  c"), "a b\n c")
        XCTAssertEqual(TextTransform.removeLineBreaks.apply("one\n two \r\n\nthree"), "one two three")
    }

    func testNamingStyles() {
        XCTAssertEqual(TextTransform.camelCase.apply("Hello world-foo_bar", locale: posix), "helloWorldFooBar")
        XCTAssertEqual(TextTransform.snakeCase.apply("fileName value2X", locale: posix), "file_name_value2_x")
        XCTAssertEqual(TextTransform.kebabCase.apply("Hello World", locale: posix), "hello-world")
        XCTAssertEqual(TextTransform.words("fileName"), ["file", "Name"])
        // Nothing to name: the text is left alone rather than erased.
        XCTAssertEqual(TextTransform.snakeCase.apply("!!!"), "!!!")
        XCTAssertEqual(TextTransform.camelCase.apply(""), "")
    }

    func testURLAndLineTransforms() {
        XCTAssertEqual(TextTransform.urlEncode.apply("a b&c/한"), "a%20b%26c%2F%ED%95%9C")
        XCTAssertEqual(TextTransform.urlDecode.apply("a%20b"), "a b")
        XCTAssertEqual(TextTransform.sortLines.apply("b\na\nc\n"), "a\nb\nc\n")
        XCTAssertEqual(TextTransform.sortLines.apply("item10\nitem2"), "item2\nitem10")
        XCTAssertEqual(TextTransform.reverseLines.apply("1\n2\n3"), "3\n2\n1")
        XCTAssertEqual(TextTransform.removeDuplicateLines.apply("a\nb\na\r\nb"), "a\nb")
        XCTAssertEqual(TextTransform.plainText.apply("same"), "same")
        XCTAssertEqual(Set(TextTransform.allCases.map(\.title)).count, TextTransform.allCases.count)
    }

    func testSearchTemplates() {
        XCTAssertEqual(TextActionSupport.searchURL(template: TextActionSupport.defaultSearchURL, query: " swift actors ")?.absoluteString,
                       "https://www.google.com/search?q=swift%20actors")
        XCTAssertNil(TextActionSupport.searchURL(template: TextActionSupport.defaultSearchURL, query: "  "))
        XCTAssertTrue(TextActionSupport.isValidSearchTemplate("myapp://search/{query}"))
        XCTAssertFalse(TextActionSupport.isValidSearchTemplate("https://example.com/search"))
        XCTAssertFalse(TextActionSupport.isValidSearchTemplate("{query}"))
        XCTAssertFalse(TextActionSupport.isValidSearchTemplate("https://example.com/?q={query} x"))
        for preset in TextActionSupport.searchPresets { XCTAssertTrue(TextActionSupport.isValidSearchTemplate(preset.url), preset.name) }
        XCTAssertEqual(TextActionSupport.variableValue(String(repeating: "x", count: 600)).count, 512)
    }

    // MARK: Menus, apps and windows

    func testMenuPathParsingAndMatching() {
        XCTAssertEqual(MenuPath.components("File > Export › PDF…"), ["File", "Export", "PDF…"])
        XCTAssertEqual(MenuPath.components(" > "), [])
        XCTAssertTrue(MenuPath.matches("Save As…", "save as"))
        XCTAssertTrue(MenuPath.matches("Save As...", "Save As…"))
        XCTAssertTrue(MenuPath.matches("Export", "Exp*"))
        XCTAssertFalse(MenuPath.matches("Export", "Exp"))
        XCTAssertTrue(MenuPath.matches("Café", "cafe"))
        XCTAssertFalse(MenuPath.matches("Anything", ""))
    }

    func testRecentRingKeepsOrderAndSkipsCurrent() {
        var ring = RecentRing<Int>(capacity: 3)
        [1, 2, 3].forEach { ring.note($0) }
        XCTAssertEqual(ring.items, [3, 2, 1])
        XCTAssertEqual(ring.previous(excluding: 3), 2)
        ring.note(2)
        XCTAssertEqual(ring.items, [2, 3, 1])
        XCTAssertEqual(ring.previous(excluding: 2, isAlive: { $0 != 3 }), 1)
        ring.note(4)
        XCTAssertEqual(ring.items, [4, 2, 3])
        ring.remove(2)
        XCTAssertEqual(ring.previous(excluding: 4), 3)
        XCTAssertNil(RecentRing<Int>().previous(excluding: nil))
    }

    func testOwnerUnderPointerIgnoresOwnWindowsAndStopsAtPanels() {
        let windows = [
            OnScreenWindow(pid: 1, layer: 0, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), alpha: 1),  // AOM itself
            OnScreenWindow(pid: 9, layer: 0, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), alpha: 0),  // invisible
            OnScreenWindow(pid: 5, layer: 20, bounds: CGRect(x: 0, y: 900, width: 2000, height: 100), alpha: 1), // Dock-like panel
            OnScreenWindow(pid: 7, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 900), alpha: 1)
        ]
        XCTAssertEqual(OnScreenWindow.owner(at: CGPoint(x: 200, y: 200), in: windows, excluding: 1), 7)
        XCTAssertNil(OnScreenWindow.owner(at: CGPoint(x: 200, y: 950), in: windows, excluding: 1))
        XCTAssertNil(OnScreenWindow.owner(at: CGPoint(x: 1500, y: 200), in: windows, excluding: 1))
    }

    func testCarriedWindowKeepsItsRelativePlace() {
        let moved = WindowGeometry.carried(CGRect(x: 100, y: 100, width: 400, height: 300),
                                           from: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                           to: CGRect(x: 1000, y: 0, width: 2000, height: 1200))
        XCTAssertEqual(moved, CGRect(x: 1267, y: 180, width: 400, height: 300))
        let shrunk = WindowGeometry.carried(CGRect(x: 0, y: 0, width: 1500, height: 900),
                                            from: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                            to: CGRect(x: -800, y: 0, width: 800, height: 600))
        XCTAssertEqual(shrunk, CGRect(x: -800, y: 0, width: 800, height: 600))
        let filled = WindowGeometry.carried(CGRect(x: 0, y: 0, width: 1000, height: 800),
                                            from: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                            to: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        XCTAssertEqual(filled, CGRect(x: 100, y: 100, width: 1000, height: 800))
    }

    func testSideBySideCoversTheVisibleArea() {
        let halves = WindowGeometry.sideBySide(in: CGRect(x: 0, y: 25, width: 1441, height: 875))
        XCTAssertEqual(halves.left, CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(halves.right, CGRect(x: 720, y: 25, width: 721, height: 875))
    }

    func testWindowTitleMatching() {
        XCTAssertTrue(WindowGeometry.titleMatches("Inbox – Mail", query: "inbox"))
        XCTAssertTrue(WindowGeometry.titleMatches("Inbox – Mail", query: "*mail"))
        XCTAssertFalse(WindowGeometry.titleMatches("Inbox – Mail", query: "inbox?"))
        XCTAssertFalse(WindowGeometry.titleMatches("Inbox", query: "  "))
        XCTAssertFalse(WindowGeometry.titleMatches("", query: "x"))
    }

    // MARK: System

    func testInputSourceSelectionPlan() {
        let abc = InputSources.Source(id: "com.apple.keylayout.ABC", name: "ABC")
        let korean = InputSources.Source(id: "com.apple.inputmethod.Korean.2SetKorean", name: "2-Set Korean")
        let sources = [abc, korean]
        XCTAssertEqual(InputSources.target(for: nil, in: sources, current: abc.id), korean)
        XCTAssertEqual(InputSources.target(for: "", in: sources, current: korean.id), abc)
        XCTAssertEqual(InputSources.target(for: nil, in: sources, current: "unknown"), abc)
        XCTAssertEqual(InputSources.target(for: "2-set korean", in: sources, current: nil), korean)
        XCTAssertEqual(InputSources.target(for: abc.id, in: sources, current: nil), abc)
        XCTAssertNil(InputSources.target(for: "missing", in: sources, current: nil))
        XCTAssertNil(InputSources.target(for: nil, in: [], current: nil))
    }

    func testMirroringPlan() {
        let on = DisplayMirroring.plan(displays: [1, 2, 3], main: 1, anyMirrored: false)
        XCTAssertEqual(on.map(\.0), [2, 3]); XCTAssertEqual(on.map(\.1), [1, 1])
        let off = DisplayMirroring.plan(displays: [1, 2, 3], main: 1, anyMirrored: true)
        XCTAssertEqual(off.map(\.1), [kCGNullDirectDisplay, kCGNullDirectDisplay])
    }

    // MARK: OCR

    func testScreenTextLocationAndMapping() throws {
        let lines = [TextLayoutLine(text: "Nothing here", box: CGRect(x: 0, y: 0, width: 100, height: 20)),
                     TextLayoutLine(text: "Hello World", box: CGRect(x: 100, y: 50, width: 220, height: 20))]
        let box = try XCTUnwrap(ScreenTextSearch.locate("world", in: lines))
        XCTAssertEqual(box.minX, 220, accuracy: 0.001)
        XCTAssertEqual(box.width, 100, accuracy: 0.001)
        XCTAssertEqual(box.minY, 50)
        XCTAssertNil(ScreenTextSearch.locate("absent", in: lines))
        XCTAssertNil(ScreenTextSearch.locate(" ", in: lines))
        let point = ScreenTextSearch.globalPoint(CGPoint(x: 200, y: 100), imageSize: CGSize(width: 2000, height: 1000),
                                                 globalRect: CGRect(x: 1440, y: 0, width: 1000, height: 500))
        XCTAssertEqual(point, CGPoint(x: 1540, y: 50))
    }

    // MARK: MIDI and OSC

    func testMIDIBytesAndUniversalPackets() {
        XCTAssertEqual(MIDIMessage.bytes(.noteOn, channel: 1, number: 60, value: 100), [0x90, 60, 100])
        XCTAssertEqual(MIDIMessage.bytes(.noteOff, channel: 2, number: 60, value: 0), [0x81, 60, 0])
        XCTAssertEqual(MIDIMessage.bytes(.controlChange, channel: 16, number: 7, value: 127), [0xBF, 7, 127])
        XCTAssertEqual(MIDIMessage.bytes(.programChange, channel: 16, number: 5, value: 99), [0xCF, 5])
        // Out-of-range input is clamped, never wrapped into another channel.
        XCTAssertEqual(MIDIMessage.bytes(.noteOn, channel: 40, number: 300, value: -5), [0x9F, 127, 0])
        XCTAssertEqual(MIDIMessage.universalPacket([0x90, 0x3C, 0x64]), 0x2090_3C64)
        XCTAssertEqual(MIDIMessage.universalPacket([0xCF, 0x05]), 0x20CF_0500)
    }

    func testOSCArgumentParsing() {
        XCTAssertEqual(OSCMessage.arguments(from: #"1 0.5 "two words" true FALSE -3 1e3 text"#),
                       [.int(1), .float(0.5), .string("two words"), .bool(true), .bool(false), .int(-3), .float(1000), .string("text")])
        XCTAssertEqual(OSCMessage.arguments(from: #""" "a\"b""#), [.string(""), .string(#"a"b"#)])
        XCTAssertEqual(OSCMessage.arguments(from: "   "), [])
    }

    func testOSCEncodingMatchesTheSpecLayout() throws {
        let data = try XCTUnwrap(OSCMessage.encode(address: "/a", arguments: [.int(1), .float(0.5), .string("hi"), .bool(true)]))
        XCTAssertEqual(Array(data), [0x2F, 0x61, 0, 0,
                                     0x2C, 0x69, 0x66, 0x73, 0x54, 0, 0, 0,
                                     0, 0, 0, 1,
                                     0x3F, 0, 0, 0,
                                     0x68, 0x69, 0, 0])
        let aligned = try XCTUnwrap(OSCMessage.encode(address: "/abc", arguments: []))
        XCTAssertEqual(Array(aligned), [0x2F, 0x61, 0x62, 0x63, 0, 0, 0, 0, 0x2C, 0, 0, 0])
        XCTAssertNil(OSCMessage.encode(address: "no-slash", arguments: []))
        XCTAssertFalse(OSCMessage.isValidAddress("/with space"))
        XCTAssertTrue(OSCMessage.isValidAddress("/scene/1/go"))
    }

    func testColorHex() {
        XCTAssertEqual(ColorHex.string(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), "#FF8000")
        XCTAssertEqual(ColorHex.string(NSColor(white: 1, alpha: 1)), "#FFFFFF")
    }

    /// CleanShot's Smart Highlighter marks each matched word, not the line.
    func testSmartHighlighterBoxesEveryOccurrence() {
        let text = "Total: 42 · total due"
        var ranges: [String] = []
        let boxes = AnnotationSmartTextMatcher.wordBoxes(of: "TOTAL", in: text) { range in
            ranges.append(String(text[range]))
            let offset = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
            return CGRect(x: offset, y: 0, width: 5, height: 1)
        }
        XCTAssertEqual(ranges, ["Total", "total"])
        XCTAssertEqual(boxes.map(\.minX), [0, 12])
        XCTAssertTrue(AnnotationSmartTextMatcher.wordBoxes(of: "absent", in: text) { _ in .zero }.isEmpty)
    }

    /// Real UDP delivery on the loopback interface only.
    func testOSCMessageArrivesOverLoopback() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = expectation(description: "datagram")
        var payload = Data()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                payload = data ?? Data(); received.fulfill()
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let message = try XCTUnwrap(OSCMessage.encode(address: "/aom/test", arguments: [.int(7), .string("ok")]))
        let sent = expectation(description: "sent")
        var ok = false
        OSCMessage.send(message, host: "127.0.0.1", port: Int(port)) { ok = $0; sent.fulfill() }
        wait(for: [sent, received], timeout: 5)
        XCTAssertTrue(ok)
        XCTAssertEqual(payload, message)
    }

    // MARK: Catalogue and validation

    func testEveryParityActionHasAFormDefaultsAndValidDefaults() {
        for type in ParityActions.handled {
            XCTAssertTrue(ActionParameterForm.handles(type), "\(type.rawValue) has no editor form")
            XCTAssertFalse(type.description.isEmpty)
            let action = TriggerAction(actionType: type, parameters: type.defaultParameters)
            XCTAssertNil(ActionParameterValidation.problem(for: action), type.rawValue)
            XCTAssertNil(ActionTree.problem([action]), type.rawValue)
        }
        XCTAssertTrue(ActionParameterForm.handles(.toggleDoNotDisturb))
        XCTAssertFalse(ActionType.toggleDoNotDisturb.description.contains("Not implemented"))
    }

    func testWindowParityActionsFindTheirOwnWindows() {
        for type in [ActionType.activateWindowByTitle, .minimizeAppWindows, .gatherWindowsToPointerDisplay, .tileFrontWindowsSideBySide] {
            XCTAssertEqual(type.category, .windowManagement)
            XCTAssertFalse(type.needsFocusedWindow, type.rawValue)
        }
        XCTAssertEqual(ActionType.restartRecording.category, .screenCapture)
    }

    /// Paste: merging several items keeps HTML-only and RTFD formatting.
    func testMultiPasteMergesHTMLAndRTFD() throws {
        func entry(_ item: [String: Data]) -> ClipboardEntry {
            ClipboardEntry.captured(items: [item], sourceName: nil, sourceBundleID: nil, at: Date())
        }
        let string = NSPasteboard.PasteboardType.string.rawValue
        let web = entry([string: Data("Bold".utf8), ClipboardWritePayload.htmlType: Data("<b>Bold</b>".utf8)])
        let plain = entry([string: Data("a < b".utf8)])
        let merged = try ClipboardWritePayload.make([web, plain], plainText: false, separator: "\n")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(String(decoding: try XCTUnwrap(merged[0][ClipboardWritePayload.htmlType]), as: UTF8.self), "<b>Bold</b><br>a &lt; b")
        XCTAssertEqual(String(decoding: try XCTUnwrap(merged[0][string]), as: UTF8.self), "Bold\na < b")

        let rich = NSAttributedString(string: "Pic", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtfd = try XCTUnwrap(rich.rtfd(from: NSRange(location: 0, length: rich.length)))
        let picture = entry([string: Data("Pic".utf8), NSPasteboard.PasteboardType.rtfd.rawValue: rtfd])
        let both = try ClipboardWritePayload.make([picture, plain], plainText: false, separator: "\n")
        XCTAssertNotNil(both[0][ClipboardWritePayload.rtfdType])
        XCTAssertNotNil(both[0][NSPasteboard.PasteboardType.rtf.rawValue])
        XCTAssertNil(both[0][ClipboardWritePayload.htmlType], "no HTML source, no HTML flavour")
        XCTAssertTrue(ClipboardWritePayload.sameText("Pic\u{FFFC}\n", "Pic"))
        XCTAssertFalse(ClipboardWritePayload.sameText("Other", "Pic"))
    }

    /// The AOM menu bar mark: a template image per state, each drawn and distinct.
    func testMenuBarMarkRendersEveryStateAsADistinctTemplate() throws {
        var coverages: [Int] = []
        var signatures = Set<Data>()
        for state in AOMMenuBarIcon.State.allCases {
            let image = AOMMenuBarIcon.image(state)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 20, height: 16))
            XCTAssertFalse(state.accessibilityDescription.isEmpty)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 32, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            AOMMenuBarIcon.draw(state, in: NSRect(x: 0, y: 0, width: 40, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            var covered = 0
            for x in 0..<40 { for y in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { covered += 1 } }
            coverages.append(covered)
            signatures.insert(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        }
        // Visible ink, but a light glyph like the system's own (well under half the canvas).
        XCTAssertTrue(coverages.allSatisfy { $0 > 120 && $0 < 640 }, "\(coverages)")
        XCTAssertEqual(signatures.count, AOMMenuBarIcon.State.allCases.count)
    }

    /// Raycast/BTT-style launcher results in the command palette.
    func testPaletteApplicationsScanAndRank() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aom-palette-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("A", isDirectory: true), second = root.appendingPathComponent("B", isDirectory: true)
        for (folder, names) in [(first, ["Safari.app", "Visual Studio Code.app", "notes.txt"]), (second, ["Safari.app", "Mail.app"])] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in names {
                if name.hasSuffix(".app") { try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
                else { try Data().write(to: folder.appendingPathComponent(name)) }
            }
        }
        let apps = PaletteApplications.scan([first, second])
        XCTAssertEqual(apps.map(\.name), ["Mail", "Safari", "Visual Studio Code"], "folders merge, duplicates and non-apps drop")
        XCTAssertEqual(apps.first { $0.name == "Safari" }?.url.deletingLastPathComponent().lastPathComponent, "A")
        XCTAssertEqual(PaletteApplications.matching("saf", in: apps).map(\.name), ["Safari"])
        XCTAssertEqual(PaletteApplications.matching("code", in: apps).map(\.name), ["Visual Studio Code"])
        XCTAssertEqual(PaletteApplications.matching("a", in: apps).map(\.name), ["Mail", "Safari", "Visual Studio Code"], "shorter names first within a rank")
        XCTAssertTrue(PaletteApplications.matching("  ", in: apps).isEmpty)
    }

    /// BTT waits: an app quitting, a file going away, the focused window changing.
    func testNewWaitConditions() {
        var window: String? = "com.apple.Safari|Inbox"
        var running: Set<String> = ["com.apple.Safari"]
        var files: Set<String> = ["/tmp/x"]
        let probe = WaitProbe(runningBundleIDs: { running }, frontmostBundleID: { nil }, fileExists: { files.contains($0) },
                              clipboardChangeCount: { 0 }, now: { 0 }, focusedWindow: { window })
        func check(_ condition: String, _ target: String = "", baseline: String? = nil) -> Bool {
            WaitFor.isSatisfied(condition: condition, target: target, baselineClipboard: 0, probe: probe, baselineWindow: baseline)
        }
        XCTAssertFalse(check("appQuit", "com.apple.Safari")); running = []
        XCTAssertTrue(check("appQuit", "com.apple.Safari"))
        XCTAssertFalse(check("fileGone", "/tmp/x")); files = []
        XCTAssertTrue(check("fileGone", "/tmp/x"))
        XCTAssertFalse(check("fileGone", ""), "an empty path never counts as gone")
        XCTAssertFalse(check("windowChange", baseline: "com.apple.Safari|Inbox"))
        window = "com.apple.Safari|Sent"
        XCTAssertTrue(check("windowChange", baseline: "com.apple.Safari|Inbox"))
        XCTAssertTrue(check("windowTitleContains", "sent"))
        XCTAssertFalse(check("windowTitleContains", "safari"), "the bundle ID is not part of the title")
        XCTAssertTrue(WaitFor.targetless.contains("windowChange"))
        for condition in ActionParameterValidation.waitConditions {
            var p = ActionType.waitFor.defaultParameters; p.waitCondition = condition
            XCTAssertNil(ActionParameterValidation.problem(for: TriggerAction(actionType: .waitFor, parameters: p)), condition)
        }
    }

    func testWhatsNewShowsOnlyAfterAnUpdate() {
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: nil, current: "3.1.0"), "first install stays quiet")
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "3.1.0", current: "3.1.0"), "relaunch stays quiet")
        XCTAssertTrue(WhatsNew.shouldShow(lastSeen: "3.0.14", current: "3.1.0"))
        XCTAssertFalse(WhatsNew.items.isEmpty)
    }

    /// The live camera bubble starts where the studio camera layer defaults to,
    /// and its final place becomes that layer's position.
    func testCameraBubbleGeometryRoundTrips() throws {
        let rect = CGRect(x: 100, y: 50, width: 1000, height: 600)   // top-left global
        let primaryTop: CGFloat = 900
        let frame = CameraBubbleGeometry.initialFrame(recording: rect, primaryTop: primaryTop)
        XCTAssertEqual(frame.width, 144)                                   // 24 % of 600
        XCTAssertEqual(frame.midX, 100 + 1000 * 0.84, accuracy: 0.001)
        XCTAssertEqual(primaryTop - frame.midY, 50 + 600 * 0.84, accuracy: 0.001)
        let placement = try XCTUnwrap(CameraBubbleGeometry.placement(panel: frame, recording: rect, primaryTop: primaryTop))
        XCTAssertEqual(placement.x, 0.84, accuracy: 0.0001)
        XCTAssertEqual(placement.y, 0.84, accuracy: 0.0001)
        XCTAssertEqual(placement.size, 0.24, accuracy: 0.0001)
        // A tiny recording keeps the whole bubble inside it.
        let small = CGRect(x: 0, y: 0, width: 120, height: 120)
        let clamped = CameraBubbleGeometry.initialFrame(recording: small, primaryTop: 500)
        XCTAssertEqual(clamped.width, 96)
        XCTAssertGreaterThanOrEqual(clamped.minX, 0); XCTAssertLessThanOrEqual(clamped.maxX, 120)
        XCTAssertNil(CameraBubbleGeometry.placement(panel: frame, recording: .zero, primaryTop: 0))
    }

    func testValidationRejectsBadValues() {
        func problem(_ type: ActionType, _ change: (inout ActionParameters) -> Void) -> String? {
            var p = type.defaultParameters; change(&p)
            return ActionParameterValidation.problem(for: TriggerAction(actionType: type, parameters: p))
        }
        XCTAssertNotNil(problem(.sendMIDI) { $0.midiChannel = 0 })
        XCTAssertNotNil(problem(.sendMIDI) { $0.midiValue = 128 })
        XCTAssertNotNil(problem(.sendMIDI) { $0.midiMessage = "sysex" })
        XCTAssertNotNil(problem(.sendOSC) { $0.oscPort = 70_000 })
        XCTAssertNotNil(problem(.sendOSC) { $0.oscAddress = "no-slash" })
        XCTAssertNotNil(problem(.transformClipboardText) { $0.textTransform = "bogus" })
        XCTAssertNotNil(problem(.chooseMenuItem) { $0.menuPath = ">>" })
        XCTAssertNotNil(problem(.searchSelectedText) { $0.url = "https://example.com" })
        XCTAssertNotNil(problem(.setWiFiPower) { $0.switchMode = "maybe" })
        XCTAssertNotNil(problem(.saveSelectedText) { $0.variableName = "bad name" })
        XCTAssertNotNil(problem(.pasteClipboardItem) { $0.clipboardItemIndex = 0 })
        XCTAssertNotNil(problem(.hapticFeedback) { $0.hapticPattern = "buzz" })
        XCTAssertNil(problem(.chooseMenuItem) { $0.menuPath = "File > Save" })
    }

    func testNewParametersDecodeFromOldPresets() throws {
        let p = try JSONDecoder().decode(ActionParameters.self, from: Data("{}".utf8))
        XCTAssertNil(p.textTransform); XCTAssertNil(p.menuPath); XCTAssertNil(p.clipboardItemIndex)
        XCTAssertNil(p.windowTitleQuery); XCTAssertNil(p.midiMessage); XCTAssertNil(p.oscHost); XCTAssertNil(p.switchMode)
        var round = ActionParameters(); round.midiNumber = 64; round.oscAddress = "/x"; round.windowTitleQuery = "Mail"
        let decoded = try JSONDecoder().decode(ActionParameters.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(decoded, round)
    }

    func testMenuPathAndTitleQueryTakeVariables() {
        var action = TriggerAction(actionType: .chooseMenuItem)
        action.parameters.menuPath = "File > {{var:item}}"
        action.parameters.windowTitleQuery = "{{var:item}}"
        let resolved = WorkflowVariables.interpolated(action) { $0 == "item" ? "Save" : nil }
        XCTAssertEqual(resolved.parameters.menuPath, "File > Save")
        XCTAssertEqual(resolved.parameters.windowTitleQuery, "Save")
    }
}
