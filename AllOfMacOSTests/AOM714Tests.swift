import XCTest
@testable import AllOfMacOS

/// 7.14: Codex's review of 7.13.0 (S1–S3, cache lifetimes) and the main
/// window's new hero headers.
final class AOM714Tests: XCTestCase {
    // S3: a huge "modified:" can't overflow the summary's Int().
    func testSavedSearchDurationIsBounded() {
        XCTAssertNil(PaletteFileQuery.duration("1e308y"))
        XCTAssertNil(PaletteFileQuery.duration("101y"))
        XCTAssertEqual(PaletteFileQuery.duration("7d"), 7 * 86_400)
        XCTAssertEqual(PaletteFileQuery.durationText(.infinity), "100y")
        XCTAssertEqual(PaletteFileQuery.durationText(1e300), "100y")
        XCTAssertEqual(PaletteFileQuery.durationText(7 * 86_400), "1w")
    }

    // S1: a file whose old place is taken is pointed at where it really is.
    func testShelfRestorePointsAtTheTrashWhenTheOldPlaceIsTaken() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AOM714-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a.png")
        let trashed = folder.appendingPathComponent("trash-a.png")
        try Data("original".utf8).write(to: trashed)
        try Data("newcomer".utf8).write(to: original)
        let item = FilesShelfItem(path: FilesPath.key(original.path), added: Date(), received: true)
        let move = FilesTransfer.Move(from: original, to: trashed, identity: FolderRulesSafety.identity(trashed))
        let putBack = FilesTransfer(done: [], failures: [.init(url: trashed, reason: "a file with that name is already there")])
        let kept = FilesShelfPanelController.itemsToRestore([(0, item)], trashed: [move], putBack: putBack)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.item.path, FilesPath.key(trashed.path), "the row opens the original, not the newcomer")
    }

    // F10: Folder Rules stopping leaves no page text behind.
    func testPDFCacheIsEmptyAfterClearing() {
        FolderRulePDFText.clearCache()
        XCTAssertEqual(FolderRulePDFText.cachedCount, 0)
    }

    // Mock-up M02: Favorites keep order, skip Workspace, unknown and repeated pages, at most six.
    func testSidebarFavoritesDecode() {
        XCTAssertEqual(AOMSidebarFavorites.decode("Audio,Home,Nope,Audio,Files"), [.audio, .files])
        let all = AOMMainTab.allCases.filter { $0 != .home }
        XCTAssertEqual(AOMSidebarFavorites.decode(AOMSidebarFavorites.encode(all)).count, AOMSidebarFavorites.limit)
        XCTAssertEqual(AOMSidebarFavorites.encode([.clipboard, .audio]), "Clipboard Memory,Audio")
    }
}
