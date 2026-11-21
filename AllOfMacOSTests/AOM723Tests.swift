import AVFoundation
import XCTest
@testable import AllOfMacOS

/// 7.2.3: the integrated audit's P1/P2 file and record bugs that 7.2.2 left
/// — B01 (Shelf Undo moves only the file it moved), B06 (Convert Video
/// reports a failed export), B08 (an unreadable focus log is kept), B09
/// (AI chat writes in order) and B10 (a partial Shelf action keeps Undo).
final class AOM723Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // Resolved, so /var and /private/var don't make two keys for one path.
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AOM723-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Locked folders and files from the tests below are opened up first.
        if let all = FileManager.default.enumerator(atPath: folder.path) {
            for case let path as String in all { chmod(folder.appendingPathComponent(path).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func subfolder(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in directory: URL? = nil, _ text: String = "x") throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: B01 — Shelf Undo moves only the file it moved

    func testShelfUndoLeavesADifferentFileThatTookTheName() async throws {
        let source = try subfolder("Source"), destination = try subfolder("Destination")
        let a = try touch("A.txt", in: source, "original")
        let result = await FilesFileActions.transfer([a], to: destination, move: true)
        let moved = try XCTUnwrap(result.done.first)
        XCTAssertNotNil(moved.identity, "the move records the file's device and inode")

        // The audit's steps: A is put away, and another file named A takes its place.
        try FileManager.default.moveItem(at: moved.to, to: folder.appendingPathComponent("kept A.txt"))
        try "someone else's".write(to: moved.to, atomically: false, encoding: .utf8)

        let back = await FilesFileActions.moveBack(result.done)
        XCTAssertTrue(back.done.isEmpty, "\(back)")
        XCTAssertEqual(back.failures.count, 1)
        XCTAssertTrue(back.failures.first?.reason.contains("different file") == true, "\(back.failures)")
        XCTAssertEqual(text(moved.to), "someone else's", "the other file stays where it is")
        XCTAssertFalse(exists(a), "nothing took A's old place")
    }

    func testShelfUndoStillMovesTheSameFileBack() async throws {
        let source = try subfolder("Source"), destination = try subfolder("Destination")
        let a = try touch("A.txt", in: source, "original")
        let result = await FilesFileActions.transfer([a], to: destination, move: true)
        let moved = try XCTUnwrap(result.done.first)
        // Edited in place: the same file, so Undo still takes it back.
        let handle = try FileHandle(forWritingTo: moved.to)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" + edit".utf8))
        try handle.close()

        let back = await FilesFileActions.moveBack(result.done)
        XCTAssertEqual(back.done.count, 1, "\(back.failures)")
        XCTAssertEqual(text(a), "original + edit")
        XCTAssertFalse(exists(moved.to))
    }

    // MARK: B10 — a partial Shelf action keeps Undo for what worked

    @MainActor
    func testShelfMoveThatPartlyFailsKeepsUndoForTheFilesThatMoved() async throws {
        let source = try subfolder("Source"), destination = try subfolder("Destination")
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let controller = FilesShelfPanelController(store: store)
        let a = try touch("a.txt", in: source), b = try touch("b.txt", in: source)
        let items = store.add([a, b])
        try FileManager.default.removeItem(at: b)   // b can't move

        controller.runTransfer(items, to: destination, move: true)
        try await waitUntil("the move") { controller.model.progress == nil && controller.model.message != nil }
        let message = try XCTUnwrap(controller.model.message)
        XCTAssertEqual(message.tone, .danger)
        XCTAssertTrue(message.text.hasPrefix("Moved 1 of 2 items to Destination."), message.text)
        XCTAssertTrue(message.text.contains("“b.txt”"), message.text)
        XCTAssertEqual(message.undoTitle, "Undo", "before 7.2.3 a failure dropped the Undo of a.txt")
        XCTAssertEqual(store.items(Set([items[0].id])).first?.path,
                       FilesPath.key(destination.appendingPathComponent("a.txt").path))

        controller.model.undo?()
        try await waitUntil("the undo") { controller.model.message?.text == "Moved 1 item back" }
        XCTAssertTrue(exists(a))
        XCTAssertEqual(store.items(Set([items[0].id])).first?.path, FilesPath.key(a.path))
    }

    @MainActor
    func testShelfUndoThatCantMoveBackSaysWhereTheFileIs() async throws {
        let source = try subfolder("Source"), destination = try subfolder("Destination")
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let controller = FilesShelfPanelController(store: store)
        let a = try touch("a.txt", in: source, "moved")
        let items = store.add([a])
        controller.runTransfer(items, to: destination, move: true)
        try await waitUntil("the move") { controller.model.message?.undoTitle == "Undo" }

        _ = try touch("a.txt", in: source, "new")   // a's old place is taken
        controller.model.undo?()
        try await waitUntil("the undo") { controller.model.message?.tone == .danger }
        let text = try XCTUnwrap(controller.model.message?.text)
        XCTAssertTrue(text.contains("is back in its old folder"), text)
        XCTAssertTrue(text.hasSuffix("It's still in Destination"), text)
        XCTAssertEqual(store.items.first?.path, FilesPath.key(destination.appendingPathComponent("a.txt").path),
                       "the shelf item still names the file where it is")
    }

    @MainActor
    func testTransferMessages() {
        let moved = FilesTransfer.Move(from: URL(fileURLWithPath: "/a/x"), to: URL(fileURLWithPath: "/b/x"))
        let failed = FilesTransfer.Failure(url: URL(fileURLWithPath: "/a/y"), reason: "it no longer exists")
        XCTAssertEqual(FilesShelfPanelController.transferMessage(FilesTransfer(done: [moved]), move: true, total: 1, folderName: "B").text,
                       "Moved 1 item to B")
        let partial = FilesShelfPanelController.transferMessage(FilesTransfer(done: [moved], failures: [failed, failed]),
                                                                move: false, total: 3, folderName: "B")
        XCTAssertEqual(partial.text, "Copied 1 of 3 items to B. Couldn't copy “y” (and 1 more) because it no longer exists")
        XCTAssertEqual(partial.tone, .danger)
        XCTAssertEqual(FilesShelfPanelController.transferMessage(FilesTransfer(failures: [failed]), move: true, total: 1, folderName: "B").text,
                       "Couldn't move “y” because it no longer exists")
    }

    /// Undo of a removal brings received files out of the Trash. One that
    /// can't come back is named where it is; the rest come back as before.
    func testShelfUndoOfARemovalKeepsTrackOfFilesLeftInTheTrash() async throws {
        let received = try subfolder("Received"), trash = try subfolder("Trash")
        let r1 = try touch("r1.png", in: received), r2 = try touch("r2.png", in: received)
        let items = [r1, r2].map { FilesShelfItem(path: FilesPath.key($0.path), added: Date(), received: true) }
        let removed = items.enumerated().map { (index: $0.offset, item: $0.element) }
        // A stand-in Trash: the tests never touch the real one.
        var trashed: [FilesTransfer.Move] = []
        for url in [r1, r2] {
            let place = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: place)
            trashed.append(.init(from: url, to: place, identity: FolderRulesSafety.identity(place)))
        }
        _ = try touch("r2.png", in: received, "a new r2")

        let back = await FilesFileActions.moveBack(trashed)
        XCTAssertEqual(back.done.count, 1)
        XCTAssertEqual(back.failures.count, 1)
        let restored = FilesShelfPanelController.itemsToRestore(removed, trashed: trashed, putBack: back)
        XCTAssertEqual(restored.map(\.item.path), [FilesPath.key(r1.path), FilesPath.key(trash.appendingPathComponent("r2.png").path)],
                       "r2's item names the file in the Trash, not the new r2")
        XCTAssertEqual(restored.map(\.item.id), items.map(\.id))

        try FileManager.default.removeItem(at: trash.appendingPathComponent("r2.png"))
        XCTAssertEqual(FilesShelfPanelController.itemsToRestore(removed, trashed: trashed, putBack: back).map(\.item.id), [items[0].id],
                       "an item whose file is gone stays off")
    }

    // MARK: B06 — Convert Video reports a failed export

    /// A real ten-frame H.264 movie.
    private func makeMovie(_ name: String) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testConvertVideoToAFolderItCantWriteFails() async throws {
        let movie = try await makeMovie("clip.mov")
        let locked = try subfolder("Locked")
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        let destination = locked.appendingPathComponent("clip.mp4")
        do {
            try await MacMagicSystemToolService.shared.convertVideo(url: movie, to: destination)
            XCTFail("an export that wrote nothing was reported as converted")
        } catch {}
        XCTAssertFalse(exists(destination))
    }

    func testConvertVideoReplacesTheFileTheSavePanelAgreedToReplace() async throws {
        let movie = try await makeMovie("clip.mov")
        let destination = try touch("clip.mp4", "an older file")
        try await MacMagicSystemToolService.shared.convertVideo(url: movie, to: destination)
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "before 7.2.3 the export failed on the existing file and the old one stayed")
        XCTAssertNotEqual(text(destination), "an older file")
    }

    func testConvertVideoOfAFileThatIsNoVideoFailsAndLeavesNothing() async throws {
        let fake = try touch("fake.mov", "not a movie")
        let destination = folder.appendingPathComponent("fake.mp4")
        do {
            try await MacMagicSystemToolService.shared.convertVideo(url: fake, to: destination)
            XCTFail("a file with no video was reported as converted")
        } catch {}
        XCTAssertFalse(exists(destination))
    }

    // MARK: B08 — an unreadable focus log is kept, never replaced

    private let entry = FocusLogEntry(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_500),
                                      plannedMinutes: 25, focusedSeconds: 1500, completed: true)

    @MainActor
    func testUnreadableFocusLogIsSetAsideNotReplaced() throws {
        let directory = try subfolder("Focus")
        let damaged = Data(#"{"version":1,"entries":[{"id":"#.utf8)
        try damaged.write(to: directory.appendingPathComponent(FocusLogStore.fileName))

        let log = FocusLogStore(directory: directory)
        XCTAssertTrue(log.entries.isEmpty)
        let problem = try XCTUnwrap(log.problem)
        XCTAssertFalse(problem.blocksSaving)
        XCTAssertTrue(problem.file.lastPathComponent.hasPrefix("sessions.unreadable-"), problem.file.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: problem.file), damaged)

        log.append(entry, now: entry.end)
        FocusStorage.flush()
        XCTAssertEqual(try Data(contentsOf: problem.file), damaged, "the next session save leaves the old bytes alone")
        let reopened = FocusLogStore(directory: directory)
        XCTAssertEqual(reopened.entries, [entry])
        XCTAssertNil(reopened.problem)
    }

    @MainActor
    func testFocusLogThatCantBeReadIsNeverSavedOver() throws {
        let directory = try subfolder("Focus")
        let file = directory.appendingPathComponent(FocusLogStore.fileName)
        let original = Data(#"{"version":1,"entries":[]}"#.utf8)
        try original.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o000), 0)

        let log = FocusLogStore(directory: directory)
        XCTAssertEqual(log.problem?.blocksSaving, true)
        log.append(entry, now: entry.end)
        FocusStorage.flush()
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testUnreadableFocusListsAndActivityAreSetAsideToo() throws {
        let directory = try subfolder("Focus")
        let damaged = Data("not json".utf8)
        try damaged.write(to: directory.appendingPathComponent(FocusListsStore.fileName))
        try damaged.write(to: directory.appendingPathComponent(FocusActivityStore.fileName))

        let lists = FocusListsStore(directory: directory)
        let activity = FocusActivityStore(directory: directory)
        let listsCopy = try XCTUnwrap(lists.problem?.file), activityCopy = try XCTUnwrap(activity.problem?.file)
        lists.addDistraction(FocusAppRef(bundleID: "com.example.chat", name: "Chat"))
        activity.clear()
        FocusStorage.flush()
        XCTAssertEqual(try Data(contentsOf: listsCopy), damaged)
        XCTAssertEqual(try Data(contentsOf: activityCopy), damaged)
        XCTAssertEqual(FocusListsStore(directory: directory).lists.distractingApps.map(\.bundleID), ["com.example.chat"])
    }

    // MARK: B09 — AI chat writes in order, the newest state last

    private func record(_ title: String, size: Int = 1) -> AOMAIChatHistory.Record {
        AOMAIChatHistory.Record(id: UUID(), title: title, date: Date(), model: nil,
                                messages: [.init(role: "user", text: title),
                                           .init(role: "assistant", text: String(repeating: "answer ", count: size))])
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    @MainActor
    func testDeletedChatStaysDeletedWhenAnEarlierSaveIsSlow() throws {
        let url = folder.appendingPathComponent("AI/chats.json")
        let history = AOMAIChatHistory(url: url)
        let writer = try XCTUnwrap(history.writer)
        let keep = record("keep"), doomed = record("doomed", size: 50_000), later = record("later")
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let calls = Calls()
        writer.beforeWrite = { generation in
            calls.add(generation)
            if generation == 2 { started.signal(); gate.wait() }
        }

        history.save(keep)                 // 1
        history.save(doomed)               // 2: the big list, held mid-write
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        history.delete(doomed.id)          // 3: superseded before it starts
        history.save(later)                // 4: the newest state
        gate.signal()
        history.flush()

        XCTAssertEqual(AOMAIChatHistory(url: url).records.map(\.id), [later.id, keep.id],
                       "before 7.2.3 the held save could finish last and bring the deleted chat back")
        XCTAssertFalse(calls.all.contains(3), "a write superseded before it started is skipped: \(calls.all)")
        XCTAssertEqual(calls.all.last, 4)
    }

    @MainActor
    func testChatHistoryDeleteIsTheLastWrite() throws {
        let url = folder.appendingPathComponent("AI/chats.json")
        let history = AOMAIChatHistory(url: url)
        let chats = (0..<20).map { record("chat \($0)", size: 2_000) }
        for chat in chats { history.save(chat) }
        history.delete(chats[19].id)
        history.flush()
        let reopened = AOMAIChatHistory(url: url)
        XCTAssertEqual(reopened.records.count, 19)
        XCTAssertFalse(reopened.records.contains { $0.id == chats[19].id })
    }
}
