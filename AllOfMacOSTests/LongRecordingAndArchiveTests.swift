import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import AllOfMacOS

/// Audit 2026-10-28 F06 (65-minute recordings), plus the archive hardening
/// done with it (unreadable archives, the recording error log). Everything runs on synthetic samples in
/// temporary folders: no screen is recorded and no user file is read.
@MainActor
final class LongRecordingAndArchiveTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders.removeAll()
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AOMAuditF06F07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    /// What the recorder does: one sample every 50 ms of recording time.
    private func record(minutes: Double, hidden: ClosedRange<Double>? = nil,
                        x: (Double) -> Double = { _ in 0.5 }) -> AOMCursorSampler {
        var sampler = AOMCursorSampler()
        let count = Int(minutes * 60 / 0.05)
        for index in 0..<count {
            let time = Double(index) * 0.05
            let visible = !(hidden?.contains(time) ?? false)
            sampler.append(AOMCursorPoint(time: time, x: x(time), y: 0.5, visible: visible))
        }
        return sampler
    }

    // MARK: F06

    func testA65MinuteTrackStaysBoundedAndCoversTheWholeTake() {
        let total = 65.0 * 60
        let sampler = record(minutes: 65, x: { $0 / total })
        let track = AOMCursorTrack(points: sampler.points)
        XCTAssertLessThanOrEqual(sampler.points.count, AOMCursorSampler.capacity)
        XCTAssertTrue(track.isValid)
        XCTAssertGreaterThan(sampler.points.last!.time, total - 0.2, "the last minutes are sampled too")
        // The audit's CursorProbe: 3.3.0 returned nil here (60,000 × 50 ms = 50 min).
        XCTAssertNotNil(track.smoothedPosition(at: 3001))
        XCTAssertNotNil(track.smoothedPosition(at: total - 1))
        let late = track.smoothedPosition(at: 3500)
        XCTAssertEqual(Double(late?.x ?? -1), 3500 / total, accuracy: 0.002, "thinned samples still interpolate the path")
        XCTAssertEqual(sampler.spacing, 0.1, accuracy: 1e-9, "one thinning pass: 100 ms resolution")
    }

    func testHiddenIntervalsKeepTheirEdgesAfterThinning() {
        let sampler = record(minutes: 65, hidden: 1000.0...1010.0)
        let track = AOMCursorTrack(points: sampler.points)
        XCTAssertNil(track.smoothedPosition(at: 1005), "the pointer stays hidden while it was outside the area")
        XCTAssertNotNil(track.smoothedPosition(at: 999.5))
        XCTAssertNotNil(track.smoothedPosition(at: 1011))
    }

    func testAFourHourTrackWithHeavyInputFitsTheSidecar() throws {
        let sampler = record(minutes: 240)
        XCTAssertLessThanOrEqual(sampler.points.count, AOMCursorSampler.capacity)
        XCTAssertGreaterThan(sampler.points.last!.time, 240 * 60 - 1)
        // The most input a track may hold: 60,000 clicks and 60,000 keystrokes.
        let clicks = (0..<60_000).map { AOMClickEvent(time: Double($0) * 0.2, x: 0.3, y: 0.4) }
        let keys = (0..<60_000).map { AOMKeystrokeEvent(time: Double($0) * 0.2, label: "⌘⇧K") }
        let track = AOMCursorTrack(points: sampler.points, clicks: clicks, keystrokes: keys)
        let movie = try temporaryFolder().appendingPathComponent("Screen Recording.mp4")
        try track.write(for: movie)
        let size = try XCTUnwrap(try AOMCursorTrack.sidecarURL(for: movie).resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 8_000_000, "above the old 8 MB bound, which rejected this take")
        XCTAssertLessThanOrEqual(size, AOMCursorTrack.maximumBytes)
        let read = try XCTUnwrap(AOMCursorTrack.read(for: movie))
        XCTAssertEqual(read.points.count, sampler.points.count)
        XCTAssertEqual(read.clicks?.count, 60_000)
        XCTAssertEqual(read.keystrokes?.count, 60_000)
    }

    /// The recorder's timer delivers samples 48–55 ms apart, not every 50 ms.
    /// A first version of the sampler dropped about a fifth of them.
    func testTimerJitterNeitherDropsSamplesNorCoarsensTheTrack() {
        var seed: UInt64 = 0x2026_1028
        func jittered() -> Double {          // deterministic 48…55 ms
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.048 + Double((seed >> 33) % 1000) / 1000 * 0.007
        }
        var sampler = AOMCursorSampler()
        var time = 0.0, fed = 0
        while time < 10 * 60 { sampler.append(AOMCursorPoint(time: time, x: 0.5, y: 0.5)); fed += 1; time += jittered() }
        XCTAssertEqual(sampler.points.count, fed, "before thinning every sample is kept")
        while time < 65 * 60 { sampler.append(AOMCursorPoint(time: time, x: 0.5, y: 0.5)); fed += 1; time += jittered() }
        XCTAssertLessThanOrEqual(sampler.points.count, AOMCursorSampler.capacity)
        let tail = sampler.points.filter { $0.time > 60 * 60 }
        let mean = (tail.last!.time - tail.first!.time) / Double(tail.count - 1)
        XCTAssertEqual(mean, sampler.spacing, accuracy: 0.02, "after thinning the spacing averages the target, not 1.5× it")
    }

    func testAFlickeringPointerCannotGrowTheTrackWithoutBound() {
        var sampler = AOMCursorSampler()
        for index in 0..<200_000 {
            sampler.append(AOMCursorPoint(time: Double(index) * 0.05, x: 0.5, y: 0.5, visible: index % 2 == 0))
        }
        XCTAssertLessThan(sampler.points.count, AOMCursorSampler.capacity)
        XCTAssertTrue(AOMCursorTrack(points: sampler.points).isValid)
    }

    func testAnOversizedTrackSaysSoInsteadOfClaimingAFullDisk() {
        let message = AOMCursorTrack.Failure.tooLarge(bytes: 30_000_000).localizedDescription
        XCTAssertTrue(message.contains("30 MB"), message)
        XCTAssertFalse(message.lowercased().contains("space"), message)
    }

    // MARK: Unreadable archives (3.3.1 hardening)

    private func writePNG(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAnUnreadableCaptureManifestIsKeptAndTheHistoryRebuilt() throws {
        let folder = try temporaryFolder()
        let ids = [UUID(), UUID()]
        for id in ids { try writePNG(folder.appendingPathComponent(id.uuidString).appendingPathExtension("png")) }
        let garbage = Data("[{\"id\": \"truncated".utf8)
        try garbage.write(to: folder.appendingPathComponent("history-v1.json"))

        let history = CaptureHistory(directory: folder, residentByteBudget: 1_000_000)
        XCTAssertEqual(Set(history.entries.map(\.id)), Set(ids), "both captures come back from their PNGs")
        let preserved = try XCTUnwrap(history.preservedManifestURL)
        XCTAssertEqual(try Data(contentsOf: preserved), garbage, "the unreadable bytes are kept, not overwritten")

        // Pins were in the lost manifest, so every recovered capture is kept
        // pinned: a retention pass (e.g. the next capture) must delete none.
        XCTAssertTrue(history.entries.allSatisfy(\.isPinned))
        let savedCapacity = CaptureSettings.historyCapacity
        CaptureSettings.historyCapacity = 0
        defer { CaptureSettings.historyCapacity = savedCapacity }
        history.applyRetention()
        XCTAssertEqual(Set(history.entries.map(\.id)), Set(ids), "retention keeps every recovered capture")

        // A second open waits for the first one's manifest write and reads it.
        let reopened = CaptureHistory(directory: folder, residentByteBudget: 1_000_000)
        XCTAssertEqual(Set(reopened.entries.map(\.id)), Set(ids))
        XCTAssertNil(reopened.preservedManifestURL, "the rebuilt manifest is readable")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString).appendingPathExtension("png").path),
                          "the recovered image is still on disk")
        }
    }

    func testTheRecordingErrorArchiveIsBoundedAndKeepsOnlyFileNames() throws {
        let folder = try temporaryFolder()
        let movie = URL(fileURLWithPath: "/Users/someone/Movies/Private Client/Screen Recording 2026-10-28.mp4")
        for index in 0..<(RecordingEventLog.maximumLines + 10) {
            RecordingEventLog.record("interrupted", file: movie, detail: "writer failed \(index)", directory: folder)
        }
        let entries = RecordingEventLog.entries(directory: folder)
        XCTAssertEqual(entries.count, RecordingEventLog.maximumLines)
        XCTAssertEqual(entries.last?["detail"], "writer failed \(RecordingEventLog.maximumLines + 9)", "newest kept")
        XCTAssertEqual(entries.first?["file"], "Screen Recording 2026-10-28.mp4")
        let raw = try String(contentsOf: folder.appendingPathComponent(RecordingEventLog.fileName), encoding: .utf8)
        XCTAssertFalse(raw.contains("Private Client"), "no folder names are archived")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(RecordingEventLog.fileName).path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o077, 0, "owner-only")
    }

    // MARK: Honest results — a cut-short take is not "Recording Saved"

    func testATakeThatMacOSCutShortIsNotAnnouncedAsSaved() {
        let stopped = ScreenRecordingService.stopOutcome(interruption: "macOS stopped the screen capture: permission revoked.",
                                                         warnings: [], file: "Take.mp4")
        XCTAssertEqual(stopped.title, "Recording Stopped Early")
        XCTAssertTrue(stopped.detail.contains("permission revoked"))
        XCTAssertEqual(stopped.event, "stopped-early")
        let partial = ScreenRecordingService.stopOutcome(interruption: nil,
                                                         warnings: ["Layer export failed.", "Camera fragments were retained."],
                                                         file: "Take.mp4")
        XCTAssertEqual(partial.title, "Recording Saved with Warning")
        XCTAssertTrue(partial.detail.contains("Layer export failed.") && partial.detail.contains("Camera fragments"),
                      "a later warning no longer overwrites an earlier one")
        XCTAssertEqual(ScreenRecordingService.stopOutcome(interruption: nil, warnings: [], file: "Take.mp4").title, "Recording Saved")
    }
}
