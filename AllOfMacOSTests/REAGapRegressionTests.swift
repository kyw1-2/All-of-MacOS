import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class REAGapRegressionTests: XCTestCase {
    func testClosedAudioRowsKeepIdentityAndSettingsAfterListReordering() throws {
        let suite = "AOM-REA-Audio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = AppAudioState(pid: -1, name: "B", bundleID: "test.b", gain: 1, muted: false, tapped: false)
        let moved = AppAudioState(pid: -2, name: "B", bundleID: "test.b", gain: 1, muted: false, tapped: false)
        let inserted = AppAudioState(pid: -1, name: "A", bundleID: "test.a", gain: 1, muted: false, tapped: false)
        XCTAssertEqual(old.id, moved.id)
        XCTAssertNotEqual(old.id, inserted.id)
        XCTAssertEqual(AppAudioPreferences.toggleMute(bundleID: old.bundleID, defaults: defaults), true)
        XCTAssertTrue(AppAudioPreferences.setGain(0.35, bundleID: old.bundleID, defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: "AOMAudioMute_test.b"))
        XCTAssertEqual(defaults.double(forKey: "AOMAudioGain_test.b"), 0.35, accuracy: 0.000001)
        XCTAssertNil(defaults.object(forKey: "AOMAudioMute_test.a"))
        XCTAssertNil(defaults.object(forKey: "AOMAudioGain_test.a"))
        XCTAssertFalse(AppAudioPreferences.setGain(.nan, bundleID: old.bundleID, defaults: defaults))
        XCTAssertNil(AppAudioPreferences.toggleMute(bundleID: "", defaults: defaults))
    }

    func testRepeatedUnquotedFilterCommitsEarlierOccurrence() {
        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: "from:Safari from:Safari"), ["from:Safari"])
        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: "from:Safari"), [])
        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: "from:Safari "), ["from:Safari"])
    }

    func testPreparedClipboardSearchPreservesBoardExclusionsAndTextMatches() {
        let work = ClipboardPinboard(name: "Work Notes", color: "blue")
        let privateBoard = ClipboardPinboard(name: "Private", color: "red")
        let boards = [work, privateBoard]
        let entries = [
            ClipboardEntry(title: "Memo", text: "Needle", pinboardIDs: [work.id], items: []),
            ClipboardEntry(title: "Memo", text: "Needle draft", pinboardIDs: [work.id], items: []),
            ClipboardEntry(title: "Memo", text: "Needle", pinboardIDs: [privateBoard.id], items: []),
            ClipboardEntry(title: "Memo", text: "Needle", kind: .image, pinboardIDs: [work.id], items: [])
        ]
        let query = "needle board:work -draft type:text -board:private"
        let prepared = ClipboardSearchQuery(query, boards: boards)
        let regular = ClipboardSearchQuery(query)
        XCTAssertEqual(entries.map { prepared.matches($0, boards: boards) }, [true, false, false, false])
        XCTAssertEqual(entries.map { prepared.matches($0, boards: boards) }, entries.map { regular.matches($0, boards: boards) })
        XCTAssertFalse(ClipboardSearchQuery("board:missing", boards: boards).matches(entries[0], boards: boards))
        XCTAssertTrue(ClipboardSearchQuery("-board:missing", boards: boards).matches(entries[0], boards: boards))
    }

    func testTenThousandClipboardEntriesUsePreparedBoardNames() {
        let boards = (0..<100).map { ClipboardPinboard(name: "Board \($0)", color: "blue") }
        let entries = (0..<10_000).map { index in
            ClipboardEntry(title: "Clip", text: "needle \(index)", pinboardIDs: [boards[index % 100].id], items: [])
        }
        let query = ClipboardSearchQuery("needle board:\"Board 99\" type:text", boards: boards)
        let start = ProcessInfo.processInfo.systemUptime
        let matches = entries.filter { query.matches($0, boards: boards) }
        XCTAssertEqual(matches.count, 100)
        print("REA_BENCH clipboard_10k_seconds=\(ProcessInfo.processInfo.systemUptime - start)")
    }

    func testOlderCaptureWriteCannotEvictNewerRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-REA-Drag-\(UUID().uuidString)")
        var pending: [Int: CheckedContinuation<URL, Error>] = [:]
        var urls: [Int: URL] = [:]
        var count = 0
        defer {
            for continuation in pending.values { continuation.resume(throwing: CocoaError(.userCancelled)) }
            try? FileManager.default.removeItem(at: directory)
        }
        let files = CaptureDragFiles(directory: directory) { _, folder in
            let index = count; count += 1
            let url = folder.appendingPathComponent("capture.png")
            try Data([UInt8(index)]).write(to: url)
            urls[index] = url
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let entry = CaptureHistoryEntry(image: image, kind: .area, capturedAt: Date(), windowTitle: nil, fileURL: nil)
        files.prefetch(entry)
        for _ in 0..<100 where pending[0] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(pending[0])
        entry.replaceImage(image, scale: 1)
        files.prefetch(entry)
        for _ in 0..<100 where pending[1] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let newURL = try XCTUnwrap(urls[1])
        let newWrite = try XCTUnwrap(pending.removeValue(forKey: 1))
        newWrite.resume(returning: newURL)
        for _ in 0..<100 where files.readyFile(for: entry) == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(files.readyFile(for: entry), newURL)
        let oldURL = try XCTUnwrap(urls[0])
        let oldWrite = try XCTUnwrap(pending.removeValue(forKey: 0))
        oldWrite.resume(returning: oldURL)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: oldURL.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(files.readyFile(for: entry), newURL)
        XCTAssertEqual(try Data(contentsOf: newURL), Data([1]))
        XCTAssertNil(entry.fileURL)
    }

    func testWildcardMatchesWholeTextWithBoundedRepeatedStars() {
        XCTAssertFalse(WorkflowBranchCondition.wildcardMatches(String(repeating: "*a", count: 80) + "b", String(repeating: "a", count: 1000)))
        XCTAssertFalse(WorkflowBranchCondition.wildcardMatches("a*", String(repeating: "a", count: 1024) + "b"))
        XCTAssertTrue(WorkflowBranchCondition.wildcardMatches("Report-*.PDF", "report-2026.pdf"))
        XCTAssertTrue(WorkflowBranchCondition.wildcardMatches("a?c", "a\nc"))
        XCTAssertTrue(WorkflowBranchCondition.wildcardMatches("?", "👨‍👩‍👧"))
        XCTAssertTrue(WorkflowBranchCondition.wildcardMatches("[a].*", "[a].txt"))
        XCTAssertFalse(WorkflowBranchCondition.wildcardMatches("[a].*", "a.txt"))
        XCTAssertTrue(WorkflowBranchCondition.wildcardMatches("*", ""))
        XCTAssertFalse(WorkflowBranchCondition.wildcardMatches("?", ""))
        XCTAssertFalse(WorkflowBranchCondition.wildcardMatches(String(repeating: "*", count: 257), ""))
    }

    func testKeystrokeLookupKeepsOlderLongBadgeAndLastDuplicate() {
        let events = [AOMKeystrokeEvent(time: 1, label: "Long", duration: 10),
                      AOMKeystrokeEvent(time: 2, label: "Short", duration: 0.1),
                      AOMKeystrokeEvent(time: 2, label: "Last", duration: 0.2)]
        XCTAssertEqual(AOMStudioTimeline.activeKeystroke(at: 2, events: events)?.label, "Last")
        XCTAssertEqual(AOMStudioTimeline.activeKeystroke(at: 3, events: events)?.label, "Long")
        XCTAssertNil(AOMStudioTimeline.activeKeystroke(at: 11, events: events))
        XCTAssertNil(AOMStudioTimeline.activeKeystroke(at: .nan, events: events))
        let many = (0..<60_000).map { AOMKeystrokeEvent(time: Double($0) * 0.1, label: "Key", duration: Double($0 % 10 + 1)) }
        for time in stride(from: -1.0, through: 6010.0, by: 47.3) {
            XCTAssertEqual(AOMStudioTimeline.activeKeystroke(at: time, events: many),
                           many.last { time >= $0.time && time < $0.time + $0.duration })
        }
    }

    private typealias Focus = AOMStudioTimeline.Focus
    func testZoomNeighborScanMatchesReferenceWithUnsortedDuplicateAndInvalidEdits() {
        var frames: [AOMStudioZoomKeyframe] = []
        frames.reserveCapacity(163)
        for index in 0..<160 {
            let frameTime = Double((index * 37) % 80)
            let magnification = Double(index % 8)
            let focusX = Double(index % 12) / 10.0
            let focusY = Double(index % 15) / 10.0
            frames.append(AOMStudioZoomKeyframe(time: frameTime,
                                                magnification: magnification,
                                                focusX: focusX, focusY: focusY))
        }
        frames += [AOMStudioZoomKeyframe(time: .nan, magnification: 2),
                   AOMStudioZoomKeyframe(time: 9, magnification: .infinity),
                   AOMStudioZoomKeyframe(time: -1, magnification: 2)]
        for time in stride(from: -1.0, through: 90.0, by: 0.125) {
            XCTAssertEqual(AOMStudioTimeline.sampledFocus(at: time, keyframes: frames),
                           Self.referenceFocus(at: time, keyframes: frames))
        }
        var checksum = 0.0
        let before = ProcessInfo.processInfo.systemUptime
        for index in 0..<10_000 { checksum += Self.referenceFocus(at: Double(index % 800) / 10, keyframes: frames).magnification }
        let referenceSeconds = ProcessInfo.processInfo.systemUptime - before
        let after = ProcessInfo.processInfo.systemUptime
        for index in 0..<10_000 { checksum -= AOMStudioTimeline.sampledFocus(at: Double(index % 800) / 10, keyframes: frames).magnification }
        let currentSeconds = ProcessInfo.processInfo.systemUptime - after
        XCTAssertEqual(checksum, 0, accuracy: 0.00001)
        print("REA_BENCH zoom_reference_seconds=\(referenceSeconds) zoom_current_seconds=\(currentSeconds)")
    }

    private static func referenceFocus(at time: Double,
                             keyframes: [AOMStudioZoomKeyframe]) -> Focus {
        let origin = Focus(magnification: 1, x: 0.5, y: 0.5)
        guard time.isFinite else { return origin }
        // Last edit at a given time wins; duplicate timestamps never create a
        // zero-length interpolation interval or a nondeterministic jump.
        var unique: [Double: AOMStudioZoomKeyframe] = [:]
        for frame in keyframes where frame.time.isFinite && frame.time >= 0 &&
            frame.time < 86_400 && frame.magnification.isFinite &&
            frame.focusX.isFinite && frame.focusY.isFinite {
            unique[frame.time] = frame
        }
        var previousTime = 0.0
        var previous = origin
        for frame in unique.values.sorted(by: { $0.time < $1.time }) {
            let focus = Focus(magnification: min(4, max(1, frame.magnification)),
                              x: min(1, max(0, frame.focusX)),
                              y: min(1, max(0, frame.focusY)))
            if time <= frame.time {
                let span = frame.time - previousTime
                if span <= 0 { return focus }
                let position = min(1, max(0, (time - previousTime) / span))
                let smooth = position * position * (3 - 2 * position)
                return Focus(magnification: previous.magnification +
                    (focus.magnification - previous.magnification) * smooth,
                             x: previous.x + (focus.x - previous.x) * smooth,
                             y: previous.y + (focus.y - previous.y) * smooth)
            }
            previousTime = frame.time
            previous = focus
        }
        return previous
    }

}
