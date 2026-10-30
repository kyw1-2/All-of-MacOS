import AppKit
import XCTest
@testable import AllOfMacOS

/// Independent audit regressions. Production sources are a byte-identical
/// copy of 1e4553d; no network, real clipboard, Accessibility, audio I/O or
/// physical input. Failure means the desired protection is absent.
@MainActor
final class Independent333AuditTests: XCTestCase {
    private struct Harness {
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let token: String
        let store: ClipboardStore
    }
    private func harness() -> Harness {
        let token = "AOMIndependent333-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let defaults = UserDefaults(suiteName: token)!
        return Harness(directory: directory, board: board, defaults: defaults, token: token,
                       store: ClipboardStore(directory: directory, pasteboard: board, defaults: defaults))
    }
    private func clean(_ h: Harness) {
        h.board.releaseGlobally()
        h.defaults.removePersistentDomain(forName: h.token)
        try? FileManager.default.removeItem(at: h.directory)
    }
    func testMCPMustRefuseJSONPassword() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let value = #"{"password": "fixture-simple-value"}"#
        let entry = try XCTUnwrap(h.store.createTextItem(value))
        let result = try? ClipboardMCPHandler.call("read_item", ["id": entry.id.uuidString], store: h.store)
        print("AUDIT JSON read_item returned full synthetic content:", result?["content"] as? String == value)
        XCTAssertNil(result, "JSON password should be withheld from an authorized MCP reader")
    }
    func testMCPMustExcludeJSONSecretFromContentSearch() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        _ = try XCTUnwrap(h.store.createTextItem(#"{"client_secret": "fixture-search-marker"}"#))
        let result = try ClipboardMCPHandler.call("search", ["query": "fixture-search-marker"], store: h.store)
        let total = result["total"] as? Int
        print("AUDIT JSON secret content search total:", total ?? -1)
        XCTAssertEqual(total, 0, "Secret content should not be discoverable through search")
    }
    func testExistingProviderSecretStillBlocked() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let entry = try XCTUnwrap(h.store.createTextItem("api_key=sk-SYNTHETIC0000000000000000"))
        XCTAssertThrowsError(try ClipboardMCPHandler.call("read_item", ["id": entry.id.uuidString], store: h.store))
    }
    func testAsyncSuggestionsRecheckExclusionBeforePublishing() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        _ = h.store.createTextItem("someone@example.com")
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }
        let entered = expectation(description: "destination reader entered")
        let completed = expectation(description: "callback delivered")
        let gate = DispatchSemaphore(value: 0)
        intelligence.destinationReader = { _, bundleID, _, _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 10)
            return ClipboardDestinationContext(bundleID: bundleID, kind: .text, fieldHint: "email", source: .accessibility)
        }
        var ids: [UUID] = []
        intelligence.suggestionsAsync(for: ClipboardSuggestionTarget(pid: 4242, bundleID: "test.audit.destination", appName: "Fixture"), store: h.store) {
            ids = $0; completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 10)
        h.store.settings.ignoredApps = ["test.audit.destination"]
        gate.signal()
        await fulfillment(of: [completed], timeout: 10)
        print("AUDIT suggestions after exclusion:", ids.count)
        XCTAssertTrue(ids.isEmpty, "An exclusion added during pending work should invalidate its result")
    }
    func testFailedContinuousWriteMustRetrySameValue() {
        var work: [() -> Void] = []
        var calls = 0
        let sink = ContinuousValueSink(minimumInterval: 0, schedule: { _, task in work.append(task) }, apply: { _, _ in
            calls += 1
            return calls > 1
        })
        sink.submit(0.5, to: .systemVolume); work.removeFirst()()
        sink.submit(0.5, to: .systemVolume); work.removeFirst()()
        print("AUDIT failed-write attempts after repeat:", calls)
        XCTAssertEqual(calls, 2, "A failed write must not count as the last successfully written level")
    }
    func testSuccessfulContinuousWriteDeduplicates() {
        var work: [() -> Void] = []
        var calls = 0
        let sink = ContinuousValueSink(minimumInterval: 0, schedule: { _, task in work.append(task) }, apply: { _, _ in calls += 1; return true })
        sink.submit(0.5, to: .systemVolume); work.removeFirst()()
        sink.submit(0.5, to: .systemVolume); work.removeFirst()()
        XCTAssertEqual(calls, 1)
    }
}
