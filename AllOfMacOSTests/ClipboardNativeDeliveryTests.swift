import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardNativeDeliveryTests: XCTestCase {
    func testFrontmostDestinationStillRequiresShelfKeyFocusToBeReleased() async {
        var keyFocusHeld = true
        var sends = 0
        var waits = 0
        let outcome = await ClipboardPasteDelivery.deliver(version: 4, environment: .init(
            relinquishFocus: { keyFocusHeld = false }, targetIsAlive: { true }, targetIsFrontmost: { true },
            activateTarget: { XCTFail("Already active destination must not be reactivated"); return false },
            clipboardVersion: { 4 }, send: { XCTAssertFalse(keyFocusHeld); sends += 1; return true }),
            wait: { waits += 1 })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(waits, 0, "No animation-length or modifier-release delay on the normal path")
    }

    func testChangedClipboardDuringActivationNeverSendsPaste() async {
        var version = 4
        var active = false
        var sends = 0
        let outcome = await ClipboardPasteDelivery.deliver(version: 4, environment: .init(
            relinquishFocus: {}, targetIsAlive: { true }, targetIsFrontmost: { active },
            activateTarget: { true }, clipboardVersion: { version }, send: { sends += 1; return true }),
            wait: { version = 5; active = true })
        XCTAssertEqual(outcome, .clipboardChanged)
        XCTAssertEqual(sends, 0)
    }

    func testCancellationDuringActivationNeverSendsPaste() async {
        let waiting = expectation(description: "waiting for activation")
        let task = Task {
            await ClipboardPasteDelivery.deliver(version: 1, environment: .init(
                relinquishFocus: {}, targetIsAlive: { true }, targetIsFrontmost: { false },
                activateTarget: { true }, clipboardVersion: { 1 }, send: { XCTFail("Cancelled"); return true }),
                wait: { waiting.fulfill(); try await Task.sleep(for: .seconds(10)) })
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    private func store() async throws -> (ClipboardStore, NSPasteboard, URL, UserDefaults, String) {
        let suite = "aom-native-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: .init(suite))
        let store = ClipboardStore(directory: directory, pasteboard: board, defaults: defaults)
        await store.ready()
        return (store, board, directory, defaults, suite)
    }

    func testAsyncWriteCannotOverwriteANewerCopy() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); board.clearContents(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let entry = try XCTUnwrap(store.createTextItem("Selected old item"))
        let started = expectation(description: "background composition")
        store.prepareWriteOverride = { entries, plain, separator in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill(); _ = gate.wait(timeout: .now() + 5)
            return try ClipboardWritePayload.make(entries, plainText: plain, separator: separator)
        }
        let task = Task { try await store.writeAsync(entryIDs: [entry.id], playSound: false) }
        await fulfillment(of: [started], timeout: 2)
        board.clearContents(); board.setString("A newer copy", forType: .string)
        gate.signal()
        do { _ = try await task.value; XCTFail("New copy must invalidate the prepared output") } catch {}
        XCTAssertEqual(board.string(forType: .string), "A newer copy")
        await store.flush()
    }

    func testEditedItemInvalidatesAnOutputStillBeingPrepared() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); board.clearContents(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let entry = try XCTUnwrap(store.createTextItem("Old version"))
        board.clearContents(); board.setString("Existing clipboard", forType: .string)
        let started = expectation(description: "preparing old version")
        store.prepareWriteOverride = { entries, plain, separator in
            started.fulfill(); _ = gate.wait(timeout: .now() + 5)
            return try ClipboardWritePayload.make(entries, plainText: plain, separator: separator)
        }
        let task = Task { try await store.writeAsync(entryIDs: [entry.id], playSound: false) }
        await fulfillment(of: [started], timeout: 2)
        store.editText(entryID: entry.id, text: "New version")
        gate.signal()
        do { _ = try await task.value; XCTFail("Old version must be discarded") } catch {}
        XCTAssertEqual(board.string(forType: .string), "Existing clipboard")
        await store.flush()
    }

    func testSearchDeletionRestoresNeighborSelection() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        defer { board.clearContents(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        for value in ["match first", "match second", "match third"] { _ = store.createTextItem(value) }
        let state = ClipboardPanelState(); state.query = "match"
        _ = state.displayedResults(in: store); await state.finishPendingSearch()
        let initial = state.displayedResults(in: store)
        store.delete(entryIDs: [initial[1].id])
        state.clearSelection(); state.selectNeighbor(at: 1, in: store)
        XCTAssertTrue(state.isSearchPending)
        await state.finishPendingSearch()
        XCTAssertEqual(state.focusedID, initial[2].id)
        XCTAssertEqual(state.selected, [initial[2].id])
        XCTAssertEqual(state.keyboardScrollTarget, initial[2].id)
        await store.flush()
    }

    func testLargeHistorySearchReturnsBeforeScanningText() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        defer { board.clearContents(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "한국어 clipboard history ", count: 40_000)
        for _ in 0..<8 { XCTAssertNotNil(store.createTextItem(text)) }
        let state = ClipboardPanelState(); state.query = "no-such-needle"
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(state.displayedResults(in: store).isEmpty)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 0.1)
        await state.finishPendingSearch()
        XCTAssertTrue(state.displayedResults(in: store).isEmpty)
        XCTAssertFalse(state.isSearchPending)
        print("AOM large-history search dispatch: \(elapsed) seconds")
        await store.flush()
    }

    func testRealSlowPromisedProviderDoesNotBlockInputLoop() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        let provider = Process()
        defer {
            if provider.isRunning { provider.terminate(); provider.waitUntilExit() }
            board.clearContents(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("provider-ready")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/clipboard-promised-provider.swift")
        provider.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        provider.arguments = [script.path, board.name.rawValue, ready.path]
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run()
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Separate provider must start")
        let start = ProcessInfo.processInfo.systemUptime
        store.poll(sourceName: "Fixture", sourceBundleID: "test.provider")
        let duration = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(duration, 0.1, "Provider sleeps 350 ms in its own process; poll must return before it")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(store.entries.isEmpty, "Input loop resumed while the provider is still working")
        await store.finishPendingCaptures()
        XCTAssertEqual(store.entries.first?.text, "AOM promised-provider fixture")
        print("AOM slow promised provider: main poll \(duration) seconds")
        await store.flush()
    }

    func testSearchDiscardsOldQueryWithoutBlockingMainActor() async throws {
        let (store, board, directory, defaults, suite) = try await store()
        defer { board.clearContents(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(store.createTextItem("alpha"))
        let second = try XCTUnwrap(store.createTextItem("beta"))
        let state = ClipboardPanelState()
        state.query = "alpha"
        XCTAssertTrue(state.displayedResults(in: store).isEmpty)
        XCTAssertTrue(state.isSearchPending)
        state.query = "beta"
        _ = state.displayedResults(in: store)
        await state.finishPendingSearch()
        XCTAssertEqual(state.displayedResults(in: store).map(\.id), [second.id])
        XCTAssertFalse(state.isSearchPending)
        state.query = "alpha"
        _ = state.displayedResults(in: store)
        await state.finishPendingSearch()
        XCTAssertEqual(state.displayedResults(in: store).map(\.id), [first.id])
        await store.flush()
    }
}
