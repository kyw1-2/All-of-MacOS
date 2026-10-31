import XCTest
@testable import AllOfMacOS

/// The Drop Shelf's store (a relaunch keeps the items) and its file actions
/// in temporary folders: names never overwrite, Move To moves and moves back,
/// Compress makes a ZIP next to the first file. No Trash, no real folders.
@MainActor
final class FilesShelfTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-files-shelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, in subfolder: String = "Source", contents: String = "x") throws -> URL {
        let directory = folder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testShelfItemsSurviveARelaunchInOrder() throws {
        let storeFile = folder.appendingPathComponent("shelf.json")
        let clock = Date(timeIntervalSince1970: 1_750_000_000)
        let store = FilesShelfStore(fileURL: storeFile, now: { clock })
        let a = try file("a.pdf"), b = try file("b report.png"), c = try file("과제.hwp")
        store.add([a, b])
        store.add([c], received: true)
        XCTAssertEqual(store.items.map(\.url.lastPathComponent), ["과제.hwp", "a.pdf", "b report.png"])
        FilesAtomicWriter.flush()

        let reloaded = FilesShelfStore(fileURL: storeFile)
        XCTAssertEqual(reloaded.items, store.items)
        XCTAssertEqual(reloaded.items.map(\.received), [true, false, false])
        XCTAssertEqual(reloaded.items.first?.added, clock)
        XCTAssertTrue(reloaded.items.allSatisfy(\.exists))
        // The shelf stores paths: the files themselves never moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testTheSameFileIsOnTheShelfOnce() throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let a = try file("a.txt")
        let first = store.add([a])
        let again = store.add([a, URL(fileURLWithPath: a.path + "/../a.txt"), a])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(again.map(\.id), [first[0].id, first[0].id, first[0].id])
        XCTAssertTrue(store.add([URL(string: "https://example.com")!]).isEmpty)
    }

    func testRemoveAndUndoPutItemsBackWhereTheyWere() throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let urls = try ["1.txt", "2.txt", "3.txt", "4.txt"].map { try file($0) }
        store.add(urls)
        let order = store.items.map(\.id)
        let removed = store.remove([order[1], order[3]])
        XCTAssertEqual(store.items.map(\.id), [order[0], order[2]])
        store.restore(removed)
        XCTAssertEqual(store.items.map(\.id), order)
        let all = store.clear()
        XCTAssertTrue(store.items.isEmpty)
        store.restore(all)
        XCTAssertEqual(store.items.map(\.id), order)
    }

    func testRelocatingAnItemIsSaved() throws {
        let storeFile = folder.appendingPathComponent("shelf.json")
        let store = FilesShelfStore(fileURL: storeFile)
        let a = try file("a.txt")
        let item = try XCTUnwrap(store.add([a]).first)
        let moved = folder.appendingPathComponent("Elsewhere/a.txt")
        store.relocate(item.id, to: moved)
        FilesAtomicWriter.flush()
        XCTAssertEqual(FilesShelfStore.load(from: storeFile).first?.path, FilesPath.key(moved.path))
    }

    func testAMissingOrDamagedShelfFileLoadsEmpty() throws {
        XCTAssertTrue(FilesShelfStore.load(from: folder.appendingPathComponent("none.json")).isEmpty)
        let damaged = folder.appendingPathComponent("damaged.json")
        try Data("{ not json".utf8).write(to: damaged)
        XCTAssertTrue(FilesShelfStore(fileURL: damaged).items.isEmpty)
    }

    func testNamesNeverOverwrite() {
        let taken: Set<String> = ["/t/Report.pdf", "/t/Report 2.pdf", "/t/Folder", "/t/Archive.zip"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        let base = URL(fileURLWithPath: "/t", isDirectory: true)
        XCTAssertEqual(FilesNaming.uniqueDestination(for: "Report.pdf", in: base, exists: exists).lastPathComponent, "Report 3.pdf")
        XCTAssertEqual(FilesNaming.uniqueDestination(for: "Folder", in: base, exists: exists).lastPathComponent, "Folder 2")
        XCTAssertEqual(FilesNaming.uniqueDestination(for: "New.txt", in: base, exists: exists).lastPathComponent, "New.txt")
        XCTAssertEqual(FilesNaming.uniqueDestination(for: "archive.tar.gz", in: base, exists: { $0.lastPathComponent == "archive.tar.gz" }).lastPathComponent,
                       "archive.tar 2.gz")
        XCTAssertEqual(FilesNaming.archiveName(for: [URL(fileURLWithPath: "/t/Report.pdf")]), "Report.pdf.zip")
        XCTAssertEqual(FilesNaming.archiveName(for: [URL(fileURLWithPath: "/t/a"), URL(fileURLWithPath: "/t/b")]), "Archive.zip")
    }

    func testCopyToKeepsTheOriginalAndNeverOverwrites() async throws {
        let a = try file("a.txt", contents: "new")
        let destination = folder.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("a.txt"))
        let result = await FilesFileActions.transfer([a], to: destination, move: false)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.done.first?.to.lastPathComponent, "a 2.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testMoveToMovesAndUndoMovesBack() async throws {
        let a = try file("a.txt")
        let missing = folder.appendingPathComponent("Source/gone.txt")
        let destination = folder.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = await FilesFileActions.transfer([a, missing], to: destination, move: true)
        XCTAssertEqual(result.done.count, 1)
        XCTAssertEqual(result.failures.first?.url, missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        let back = await FilesFileActions.moveBack(result.done)
        XCTAssertTrue(back.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testCompressMakesAZipNextToTheFirstFileWithoutOverwriting() async throws {
        let a = try file("a.txt", contents: "alpha")
        let b = try file("b.txt", contents: "beta")
        try Data("existing".utf8).write(to: a.deletingLastPathComponent().appendingPathComponent("Archive.zip"))
        let archive = try await FilesFileActions.compress([a, b], handle: FilesProcess.Handle())
        XCTAssertEqual(archive.lastPathComponent, "Archive 2.zip")
        XCTAssertEqual(archive.deletingLastPathComponent().standardizedFileURL, a.deletingLastPathComponent().standardizedFileURL)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)
        XCTAssertGreaterThan(size.intValue, 100)
        let single = try await FilesFileActions.compress([a], handle: FilesProcess.Handle())
        XCTAssertEqual(single.lastPathComponent, "a.txt.zip")
        let listing = FilesProcess.run("/usr/bin/zipinfo", ["-1", archive.path], timeout: 20)
        // ditto keeps extended attributes in __MACOSX entries, like the Finder.
        let entries = listing.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX") }
        XCTAssertEqual(Set(entries), ["a.txt", "b.txt"])
    }
}
