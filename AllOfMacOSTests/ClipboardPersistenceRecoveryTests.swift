import AppKit
import XCTest
@testable import AllOfMacOS

/// Phase-1 remediation regressions.
///
/// - F-02: a user-made duplicate must not absorb a later copy of its source.
/// - F-06: a failed archive read must never be overwritten, and both the
///   transient-Keychain and unreadable-archive paths must recover.
@MainActor
final class ClipboardPersistenceRecoveryTests: XCTestCase {

    private struct Harness {
        let token: String
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let store: ClipboardStore
    }

    private func makeStore(token: String, directory: URL) -> Harness {
        let board = NSPasteboard(name: .init("AOM-phase1-\(token)"))
        let defaults = UserDefaults(suiteName: "AOM-phase1-\(token)")!
        let store = ClipboardStore(directory: directory, pasteboard: board, defaults: defaults)
        return Harness(token: token, directory: directory, board: board, defaults: defaults, store: store)
    }

    private func makeHarness(_ token: String = UUID().uuidString) -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-phase1-\(token)")
        return makeStore(token: token, directory: directory)
    }

    private func cleanUp(_ harness: Harness) {
        harness.board.clearContents()
        harness.defaults.removePersistentDomain(forName: "AOM-phase1-\(harness.token)")
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private func copy(_ text: String, into harness: Harness) {
        harness.board.clearContents()
        XCTAssertTrue(harness.board.setString(text, forType: .string))
        harness.store.poll(sourceName: "Test", sourceBundleID: "test.phase1")
    }

    // MARK: - F-02

    func testDuplicateDoesNotStealDeduplicationFromOriginal() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()

        copy("hello", into: harness)
        await harness.store.finishPendingCaptures()
        let original = try XCTUnwrap(harness.store.entries.first)

        let duplicate = try XCTUnwrap(harness.store.duplicate(entryID: original.id))
        XCTAssertEqual(duplicate.duplicatedFrom, original.id)
        XCTAssertEqual(harness.store.entries.first?.id, duplicate.id, "the duplicate is inserted newest-first")
        await harness.store.finishPendingCaptures()

        copy("hello", into: harness)
        await harness.store.finishPendingCaptures()

        XCTAssertEqual(harness.store.entries.count, 2, "the duplicate is a distinct entry")
        XCTAssertEqual(harness.store.entries.first?.id, original.id,
                       "a fresh copy of the original content must be credited to the original, not its Copy")
        XCTAssertEqual(harness.store.entries.first?.sourceBundleID, "test.phase1")
        await harness.store.flush()
    }

    // MARK: - F-06

    func testStorageFailureClassification() {
        XCTAssertTrue(ClipboardStore.isTransientStorageFailure(ClipboardArchiveEncryption.Failure.keychain(-25308)))
        XCTAssertFalse(ClipboardStore.isTransientStorageFailure(ClipboardArchiveEncryption.Failure.invalidKey))
        XCTAssertFalse(ClipboardStore.isTransientStorageFailure(ClipboardArchiveEncryption.Failure.missingKey))
        XCTAssertFalse(ClipboardStore.isTransientStorageFailure(ClipboardStore.StoreError.invalidArchive))
    }

    func testTransientKeychainFailureRetriesAndRecovers() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        // The load task cannot run before the next suspension, so the override
        // is installed before `ready()` awaits it.
        store.loadFailureOverride = ClipboardArchiveEncryption.Failure.keychain(-25308)
        await store.ready()
        XCTAssertEqual(store.storageStatus, .transientFailure)
        XCTAssertNotNil(store.storageWarning)

        _ = store.createTextItem("during outage")
        await store.flush()
        let file = harness.directory.appendingPathComponent("history-v1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "nothing is written while the Keychain is unavailable")

        await store.recoverStorage()
        XCTAssertEqual(store.storageStatus, .ok)
        XCTAssertNil(store.storageWarning)
        XCTAssertTrue(store.entries.contains { $0.text == "during outage" },
                      "items captured during the outage are saved once the Keychain returns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnreadableArchiveIsPreservedUntilExplicitRecovery() async throws {
        let token = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-phase1-\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history-v1.json")
        let corrupt = Data("this is not a clipboard archive".utf8)
        try corrupt.write(to: file)

        let harness = makeStore(token: token, directory: directory)
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        XCTAssertEqual(store.storageStatus, .unreadableArchive)
        XCTAssertNotNil(store.storageWarning)

        _ = store.createTextItem("new item")
        await store.flush()
        XCTAssertEqual(try Data(contentsOf: file), corrupt,
                       "an unreadable archive must not be overwritten by a later save")

        await store.recoverStorage()
        XCTAssertEqual(store.storageStatus, .ok)
        XCTAssertNil(store.storageWarning)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history-v1.json.unreadable-") }
        XCTAssertEqual(backups.count, 1, "the unreadable bytes are kept under a new name")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backups[0])), corrupt)
        XCTAssertNotEqual(try Data(contentsOf: file), corrupt, "a fresh archive is written after recovery")

        let reopened = ClipboardStore(directory: directory,
                                      pasteboard: NSPasteboard(name: .init("AOM-phase1-reload-\(token)")),
                                      defaults: UserDefaults(suiteName: "AOM-phase1-reload-\(token)")!)
        await reopened.ready()
        XCTAssertTrue(reopened.entries.contains { $0.text == "new item" })
    }
}
