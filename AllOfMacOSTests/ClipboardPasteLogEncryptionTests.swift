import XCTest
@testable import AllOfMacOS

/// F-05: the paste log must serialise a burst of records so the newest events
/// win, make `erase()` final against an in-flight write, and keep the log
/// encrypted at rest without ever falling back to plaintext.
@MainActor
final class ClipboardPasteLogEncryptionTests: XCTestCase {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aom-pastelog-f05-\(UUID().uuidString)")
    }

    /// Reversible, non-JSON cipher so the encrypted path is deterministic and
    /// does not depend on the login Keychain.
    private var testCipher: PasteLogCipher {
        PasteLogCipher(isEncrypted: true,
                       seal: { Data($0.map { $0 ^ 0xA5 }) },
                       open: { Data($0.map { $0 ^ 0xA5 }) })
    }

    private func event(_ index: Int) -> ClipboardPasteEvent {
        ClipboardPasteEvent(entryID: UUID(), itemClass: .link,
                            sourceBundleID: "src.\(index)", destinationBundleID: "dst",
                            destinationKind: .search, date: Date(timeIntervalSince1970: Double(index)))
    }

    func testRapidRecordsKeepNewestAndEraseIsFinal() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0)
        let events = (0..<64).map { event($0) }
        for e in events { log.record(e) } // no await between records
        await log.flush()

        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events, events,
                       "a burst must persist in order, newest last")

        // An erase that races a still-pending debounce must win.
        for index in 64..<80 { log.record(event(index)) }
        log.erase()
        await log.flush()
        XCTAssertTrue(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events.isEmpty,
                      "erase must not be resurrected by an in-flight write")
    }

    /// Regression for the F-05 revision guard: every `scheduleSave()` must claim
    /// a fresh revision (`writeRevision.next()`) so a superseded debounce is
    /// discarded at write time. A long debounce keeps the scheduled snapshots
    /// pending, so `flush()` must still persist the newest snapshot rather than
    /// be discarded as stale by the revision check.
    func testFlushAfterPendingScheduleStillWritesNewestSnapshot() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 60_000_000_000)
        let expected = [event(0), event(1)]
        log.record(expected[0])
        log.record(expected[1])
        await log.flush()

        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events,
                       expected,
                       "flush must persist the newest snapshot even when a debounce was pending")
    }

    func testEncryptedAtRestAndReadBack() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0)
        let events = (0..<3).map { event($0) }
        for e in events { log.record(e) }
        await log.flush()

        let encryptedURL = dir.appendingPathComponent("paste-events-v2.encrypted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("paste-events.json").path),
                       "the encrypted log must not leave a plaintext sibling")

        let raw = try Data(contentsOf: encryptedURL)
        XCTAssertNil(try? JSONDecoder().decode([ClipboardPasteEvent].self, from: raw),
                     "the on-disk log must not be readable plaintext JSON")
        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events, events)
    }

    func testLegacyPlaintextLogIsMigratedWithoutLoss() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = (0..<2).map { event($0) }
        try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("paste-events.json"))

        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0)
        XCTAssertEqual(log.events, legacy, "old plaintext data must still be read")
        await log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("paste-events.json").path),
                       "the plaintext log is retired after a successful encrypted write")
        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events, legacy)
    }

    func testKeychainFailureNeverFallsBackToPlaintext() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = PasteLogCipher(isEncrypted: true,
                                     seal: { _ in throw ClipboardArchiveEncryption.Failure.keychain(-25308) },
                                     open: { $0 })
        let log = ClipboardPasteLog(directory: dir, cipher: failing, saveDelay: 0)
        log.record(event(1))
        await log.flush()
        XCTAssertNotNil(log.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("paste-events.json").path),
                       "a Keychain failure must not write plaintext")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("paste-events-v2.encrypted").path))
    }

    func testRealKeychainCipherRoundTrips() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try ClipboardArchiveEncryption.encrypt(Data("probe".utf8)) }
        catch { throw XCTSkip("Keychain unavailable in this environment: \(error)") }
        let log = ClipboardPasteLog(directory: dir, cipher: .keychain, saveDelay: 0)
        let expected = event(9)
        log.record(expected)
        await log.flush()
        let raw = try Data(contentsOf: dir.appendingPathComponent("paste-events-v2.encrypted"))
        XCTAssertNil(try? JSONDecoder().decode([ClipboardPasteEvent].self, from: raw))
        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: .keychain, saveDelay: 0).events, [expected])
    }

    /// Regression for the F-05 compile break: `mergeLegacyIfPresent` builds a
    /// `Set(events)`, so `ClipboardPasteEvent` must be `Hashable`. Equality and
    /// hashing must agree with the existing synthesized `Equatable`.
    func testPasteEventIsHashableAndDeduplicatesByValue() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 42)
        let a = ClipboardPasteEvent(entryID: id, itemClass: .link, sourceBundleID: "src",
                                    destinationBundleID: "dst", destinationKind: .search, date: date)
        let b = ClipboardPasteEvent(entryID: id, itemClass: .link, sourceBundleID: "src",
                                    destinationBundleID: "dst", destinationKind: .search, date: date)
        var changed = b
        changed.destinationKind = .chat

        XCTAssertEqual(a, b, "equal values must stay equal after adding Hashable")
        XCTAssertEqual(a.hashValue, b.hashValue, "equal values must hash equally")
        XCTAssertEqual(Set([a, b]).count, 1, "value-equal paste events must collapse in a Set")
        XCTAssertNotEqual(a, changed)
        XCTAssertEqual(Set([a, changed]).count, 2)
    }

    /// Regression for the exact `Set(events)` site: merging a legacy plaintext
    /// log must not duplicate an event already present in the encrypted log.
    func testLegacyMergeDoesNotDuplicateKnownEvents() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let known = event(1)
        let duplicate = known // value-equal to the encrypted-log entry
        let extra = event(2)
        let sealed = try testCipher.seal(JSONEncoder().encode([known]))
        try sealed.write(to: dir.appendingPathComponent("paste-events-v2.encrypted"))
        try JSONEncoder().encode([duplicate, extra]).write(to: dir.appendingPathComponent("paste-events.json"))

        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0)
        XCTAssertEqual(log.events, [known, extra],
                       "the legacy merge must drop events already known by value")
        await log.flush()
        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events, [known, extra],
                       "the deduplicated merge must survive a reload")
    }

    /// F-05 revision regression: a persist queued by an older snapshot must not
    /// overwrite a newer one that lands first. The first snapshot is parked at
    /// the `willPersist` seam, a newer snapshot is flushed, then the stale
    /// snapshot is released; its revision must make it discard itself.
    func testStaleQueuedSnapshotCannotOverwriteNewerOne() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = PasteLogWriteGate()
        let log = ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0,
                                    willPersist: { await gate.holdFirst() },
                                    didPersist: { await gate.noteSettled() })
        let first = event(1)
        let second = event(2)

        log.record(first)
        await gate.waitUntilHeld()    // [first] is parked before it reaches the queue

        log.record(second)
        await log.flush()             // [first, second] lands while [first] is parked

        await gate.release()          // let the parked [first] reach the queue
        await gate.waitForSettled(2)  // and finish (discarded as stale)

        XCTAssertEqual(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events,
                       [first, second],
                       "a stale snapshot released after a newer write must be discarded")

        log.erase()
        await log.flush()
        XCTAssertTrue(ClipboardPasteLog(directory: dir, cipher: testCipher, saveDelay: 0).events.isEmpty,
                      "erase must stay terminal after the stale write settled")
    }
}

/// Deterministic F-05 race seam. Parks the first paste-log write before it is
/// handed to the serial queue and reports how many writes have settled.
private actor PasteLogWriteGate {
    private var held = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var settled = 0
    private var settledWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The first call parks until `release()`; later calls return immediately.
    func holdFirst() async {
        guard !held else { return }
        held = true
        heldWaiter?.resume()
        heldWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func noteSettled() {
        settled += 1
        let ready = settledWaiters.filter { settled >= $0.target }
        settledWaiters.removeAll { settled >= $0.target }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSettled(_ target: Int) async {
        if settled >= target { return }
        await withCheckedContinuation { settledWaiters.append((target, $0)) }
    }
}
