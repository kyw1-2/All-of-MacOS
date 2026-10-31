import XCTest
@testable import AllOfMacOS

/// Recent downloads and screenshots: sorting, what is skipped, where
/// screenshots are saved and how they are recognised. Temporary folders and an
/// in-memory preference store; the real com.apple.screencapture is never read.
@MainActor
final class FilesRecentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-files-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testNewestFirstThenByName() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func file(_ name: String, _ offset: TimeInterval) -> FilesRecentFile {
            FilesRecentFile(url: URL(fileURLWithPath: "/d/\(name)"), added: base.addingTimeInterval(offset), size: 1, isFolder: false)
        }
        let sorted = FilesRecentScanner.sorted([file("b.pdf", 10), file("old.zip", -500), file("a.pdf", 10), file("new.dmg", 60),
                                                file("file10.txt", 0), file("file9.txt", 0)])
        XCTAssertEqual(sorted.map(\.url.lastPathComponent), ["new.dmg", "a.pdf", "b.pdf", "file9.txt", "file10.txt", "old.zip"])
    }

    func testListingSkipsHiddenAndUnfinishedDownloadsAndKeepsTheLimit() throws {
        for name in ["report.pdf", "photo.heic", ".DS_Store", "movie.mp4.crdownload", "big.iso.download", "part.zip.part", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Unzipped"), withIntermediateDirectories: true)
        let all = FilesRecentScanner.newest(in: folder, limit: 20)
        XCTAssertEqual(Set(all.map(\.url.lastPathComponent)), ["report.pdf", "photo.heic", "notes.txt", "Unzipped"])
        XCTAssertEqual(all.first { $0.url.lastPathComponent == "Unzipped" }?.isFolder, true)
        XCTAssertNil(all.first { $0.url.lastPathComponent == "Unzipped" }?.size)
        XCTAssertEqual(all.first { $0.url.lastPathComponent == "report.pdf" }?.size, 1)
        XCTAssertEqual(FilesRecentScanner.newest(in: folder, limit: 2).count, 2)
        XCTAssertNil(FilesRecentScanner.read(folder.appendingPathComponent("missing"), limit: 5))
        XCTAssertEqual(FilesRecentScanner.newest(in: folder.appendingPathComponent("missing"), limit: 5), [])
    }

    func testScreenshotFolderComesFromTheScreenshotSetting() throws {
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let shots = home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let absolute = MemoryPreferenceStore(["com.apple.screencapture/location": shots.path])
        XCTAssertEqual(FilesRecentScanner.screenshotFolder(store: absolute, home: home).path, shots.standardizedFileURL.path)
        let tilde = MemoryPreferenceStore(["com.apple.screencapture/location": "~/Pictures/Screenshots/"])
        XCTAssertEqual(FilesRecentScanner.screenshotFolder(store: tilde, home: home).path, shots.standardizedFileURL.path)
    }

    func testScreenshotFolderFallsBackToTheDesktop() {
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true).path
        XCTAssertEqual(FilesRecentScanner.screenshotFolder(store: MemoryPreferenceStore(), home: home).path, desktop)
        for value: Any in ["", "   ", "relative/folder", folder.appendingPathComponent("gone").path, 42] {
            let store = MemoryPreferenceStore(["com.apple.screencapture/location": value])
            XCTAssertEqual(FilesRecentScanner.screenshotFolder(store: store, home: home).path, desktop, "\(value)")
        }
        let file = folder.appendingPathComponent("not-a-folder.png")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(FilesRecentScanner.screenshotFolder(store: MemoryPreferenceStore(["com.apple.screencapture/location": file.path]),
                                                          home: home).path, desktop)
    }

    func testScreenshotsAreRecognisedByTheirMarkThenTheirName() {
        let named = URL(fileURLWithPath: "/s/Screenshot 2026-10-31 at 14.02.11.png")
        let korean = URL(fileURLWithPath: "/s/스크린샷 2026-10-31 오후 2.02.11.png")
        let photo = URL(fileURLWithPath: "/s/IMG_2041.png")
        XCTAssertTrue(FilesRecentScanner.isScreenshot(photo, metadata: { _ in true }), "the Spotlight mark decides")
        XCTAssertFalse(FilesRecentScanner.isScreenshot(named, metadata: { _ in false }), "the Spotlight mark decides")
        XCTAssertTrue(FilesRecentScanner.isScreenshot(named, metadata: { _ in nil }))
        XCTAssertTrue(FilesRecentScanner.isScreenshot(korean, metadata: { _ in nil }))
        XCTAssertTrue(FilesRecentScanner.isScreenshot(URL(fileURLWithPath: "/s/Screen Recording 2026-10-30 at 18.03.55.mov"), metadata: { _ in nil }))
        XCTAssertFalse(FilesRecentScanner.isScreenshot(photo, metadata: { _ in nil }))
        XCTAssertTrue(FilesRecentScanner.isInProgressDownload(URL(fileURLWithPath: "/d/a.zip.crdownload")))
        XCTAssertFalse(FilesRecentScanner.isInProgressDownload(URL(fileURLWithPath: "/d/a.zip")))
    }
}
