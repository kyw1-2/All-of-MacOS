import XCTest
@testable import AllOfMacOS

/// Favourites, Finder windows and recent folders: order and de-duplication,
/// the recent-folder store, and the Workspace tile's summary.
@MainActor
final class FilesListsTests: XCTestCase {
    private var folder: URL!
    private let home = "/Users/aom-test"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-files-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFavoritesKeepTheirOrderAndShowEachFolderOnce() {
        let list = FilesFolderLists.favorites(["~/Desktop", "/Users/aom-test/Documents", "/Users/aom-test/Desktop/", "~/Downloads",
                                               "/Users/aom-test/Documents"], home: home)
        XCTAssertEqual(list, ["/Users/aom-test/Desktop", "/Users/aom-test/Documents", "/Users/aom-test/Downloads"])
    }

    func testFinderWindowsStayFrontToBackWithoutRepeats() {
        let paths = FilesFinder.parse("/Users/aom-test/Projects/\n/Users/aom-test/Downloads/\n/Users/aom-test/Projects/\nnot a path\n/\n")
        XCTAssertEqual(paths, ["/Users/aom-test/Projects", "/Users/aom-test/Downloads", "/Users/aom-test/Projects", "/"])
        XCTAssertEqual(FilesFolderLists.finderFolders(paths, home: home), ["/Users/aom-test/Projects", "/Users/aom-test/Downloads", "/"])
    }

    func testNotingAJumpMovesTheFolderToTheFrontAndKeepsTheLimit() {
        let start = Date(timeIntervalSince1970: 1_000)
        var list: [FilesRecentJump] = []
        for index in 0..<14 {
            list = FilesFolderLists.noting("/Users/aom-test/F\(index)", at: start.addingTimeInterval(Double(index)), in: list, home: home)
        }
        XCTAssertEqual(list.count, FilesFolderLists.recentJumpLimit)
        XCTAssertEqual(list.first?.path, "/Users/aom-test/F13")
        list = FilesFolderLists.noting("~/F5", at: start.addingTimeInterval(100), in: list, home: home)
        XCTAssertEqual(list.first?.path, "/Users/aom-test/F5")
        XCTAssertEqual(list.filter { $0.path == "/Users/aom-test/F5" }.count, 1)
        XCTAssertEqual(list.count, FilesFolderLists.recentJumpLimit)
    }

    func testRecentsMergeJumpsAndNewestFilesNewestFirst() {
        let base = Date(timeIntervalSince1970: 10_000)
        let jumps = [FilesRecentJump(path: "/Users/aom-test/Thesis", date: base.addingTimeInterval(10))]
        let newest = [FilesNewestFile(url: URL(fileURLWithPath: "/Users/aom-test/Downloads/Lecture/slides.pdf"), added: base.addingTimeInterval(20)),
                      FilesNewestFile(url: URL(fileURLWithPath: "/Users/aom-test/Desktop/Project-main"), added: base.addingTimeInterval(5), isFolder: true),
                      FilesNewestFile(url: URL(fileURLWithPath: "/Users/aom-test/Downloads/report.pdf"), added: base.addingTimeInterval(30))]
        let recents = FilesFolderLists.recents(jumps: jumps, newestFiles: newest, excluding: ["/Users/aom-test/Downloads"], home: home)
        XCTAssertEqual(recents.map(\.path), ["/Users/aom-test/Downloads/Lecture", "/Users/aom-test/Thesis", "/Users/aom-test/Desktop/Project-main"])
        XCTAssertEqual(recents.map(\.source), [.newestFile, .recent, .newestFile])
        XCTAssertEqual(recents[0].detail, "Has slides.pdf")
        XCTAssertNil(recents[1].detail)
        XCTAssertTrue(recents[2].detail?.hasPrefix("Added to ") == true)
    }

    func testRecentsKeepTheNewestDateOnceAndLeaveOutListedFolders() {
        let base = Date(timeIntervalSince1970: 50_000)
        let jumps = [FilesRecentJump(path: "/Users/aom-test/Shared", date: base),
                     FilesRecentJump(path: "/Users/aom-test/Desktop", date: base.addingTimeInterval(1))]
        let newest = [FilesNewestFile(url: URL(fileURLWithPath: "/Users/aom-test/Shared/new.key"), added: base.addingTimeInterval(60))]
        let recents = FilesFolderLists.recents(jumps: jumps, newestFiles: newest, excluding: ["~/Desktop"], home: home)
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.path, "/Users/aom-test/Shared")
        XCTAssertEqual(recents.first?.date, base.addingTimeInterval(60))
        XCTAssertEqual(recents.first?.detail, "Has new.key")
        let limited = FilesFolderLists.recents(jumps: (0..<20).map { FilesRecentJump(path: "/Users/aom-test/R\($0)", date: base.addingTimeInterval(Double($0))) },
                                               newestFiles: [], excluding: [], limit: 5, home: home)
        XCTAssertEqual(limited.map(\.path), (15..<20).reversed().map { "/Users/aom-test/R\($0)" })
    }

    func testRecentFolderStoreSurvivesARelaunch() throws {
        let file = folder.appendingPathComponent("recent-folders.json")
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = FilesRecentFolderStore(fileURL: file, now: { clock })
        let a = folder.appendingPathComponent("A", isDirectory: true)
        let b = folder.appendingPathComponent("B", isDirectory: true)
        store.note(a)
        clock = clock.addingTimeInterval(60)
        store.note(b)
        clock = clock.addingTimeInterval(60)
        store.note(a)
        FilesAtomicWriter.flush()
        let reloaded = FilesRecentFolderStore(fileURL: file)
        XCTAssertEqual(reloaded.jumps.map(\.path), [FilesPath.key(a.path), FilesPath.key(b.path)])
        XCTAssertEqual(reloaded.jumps.first?.date, clock)
        reloaded.remove(b.path)
        FilesAtomicWriter.flush()
        XCTAssertEqual(FilesRecentFolderStore.load(from: file).map(\.path), [FilesPath.key(a.path)])
    }

    func testSettingsKeepFavoritesInOrderWithoutDuplicates() throws {
        let suite = "AOMFilesListsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Users/aom-test/One"], forKey: FilesSettings.Key.favorites)
        let settings = FilesSettings(defaults: defaults)
        settings.addFavorite(URL(fileURLWithPath: folder.path))
        settings.addFavorite(URL(fileURLWithPath: folder.path + "/"))
        XCTAssertEqual(settings.favorites, ["/Users/aom-test/One", FilesPath.key(folder.path)])
        settings.moveFavorite(from: 1, to: 0)
        XCTAssertEqual(settings.favorites.first, FilesPath.key(folder.path))
        XCTAssertEqual(defaults.stringArray(forKey: FilesSettings.Key.favorites), settings.favorites)
        settings.removeFavorite(folder.path)
        XCTAssertEqual(settings.favorites, ["/Users/aom-test/One"])
        XCTAssertFalse(settings.dialogHelper, "The helper is off until turned on")
        XCTAssertFalse(settings.shakeOpensShelf, "Shake is off until turned on")
        settings.exclude("com.apple.Terminal")
        XCTAssertTrue(settings.isExcluded("com.apple.terminal"))
        XCTAssertTrue(FilesSettings(defaults: defaults).isExcluded("com.apple.Terminal"))
    }

    func testWorkspaceTileSummary() {
        let off = FilesModule.statusSummary(dialogHelper: false, shake: false, needsAccessibility: false, shelfCount: 0, downloadsToday: nil)
        XCTAssertFalse(off.isOn)
        XCTAssertNil(off.count)
        let shelf = FilesModule.statusSummary(dialogHelper: true, shake: false, needsAccessibility: false, shelfCount: 3, downloadsToday: 9)
        XCTAssertTrue(shelf.isOn)
        XCTAssertEqual(shelf.count, 3)
        XCTAssertEqual(shelf.unit, "items on the shelf")
        let downloads = FilesModule.statusSummary(dialogHelper: false, shake: true, needsAccessibility: false, shelfCount: 0, downloadsToday: 1)
        XCTAssertTrue(downloads.isOn)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.unit, "download today")
        let attention = FilesModule.statusSummary(dialogHelper: true, shake: false, needsAccessibility: true, shelfCount: 0, downloadsToday: nil)
        XCTAssertNotNil(attention.attention)
        XCTAssertNil(off.attention)
    }
}
