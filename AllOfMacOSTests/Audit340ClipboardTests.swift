import AppKit
import XCTest
@testable import AllOfMacOS

/// 3.4.0 audit: the clipboard's pasteboard poller while history is off or
/// paused, and suggestions already on screen when the privacy policy changes
/// (the N333-03 follow-up). Every store has a private named pasteboard, its
/// own defaults suite and a temporary folder; the destination reader and the
/// secure-input probe are stubs, so nothing reads Accessibility, the screen,
/// the user's clipboard or the network.
@MainActor
final class Audit340ClipboardTests: XCTestCase {
    private struct Harness {
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let token: String
        let store: ClipboardStore
    }

    private func harness() -> Harness {
        let token = "Audit340Clipboard-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let defaults = UserDefaults(suiteName: token)!
        return Harness(directory: directory, board: board, defaults: defaults, token: token,
                       store: ClipboardStore(directory: directory, pasteboard: board, defaults: defaults))
    }

    private func clean(_ h: Harness) {
        h.store.stop()
        h.board.releaseGlobally()
        h.defaults.removePersistentDomain(forName: h.token)
        try? FileManager.default.removeItem(at: h.directory)
    }

    // MARK: The poller

    func testThePollerSlowsDownWhileHistoryIsOffOrPaused() async {
        let h = harness(); defer { clean(h) }
        await h.store.ready()
        h.store.start()
        XCTAssertEqual(h.store.pollingInterval, 0.075)
        h.store.settings.enabled = false
        XCTAssertEqual(h.store.pollingInterval, 60, "history off: one wake a minute, for the retention trim")
        h.store.settings.enabled = true
        XCTAssertEqual(h.store.pollingInterval, 0.075)
        h.store.pause()
        XCTAssertEqual(h.store.pollingInterval, 60, "paused")
        h.store.resume()
        XCTAssertEqual(h.store.pollingInterval, 0.075)
        h.store.stop()
        XCTAssertNil(h.store.pollingInterval)
        h.store.settings.enabled = false
        XCTAssertNil(h.store.pollingInterval, "a stopped store stays stopped")
    }

    /// Resuming still ignores what was copied while paused.
    func testResumingAfterASlowPauseIngestsNothingCopiedMeanwhile() async throws {
        let h = harness(); defer { clean(h) }
        await h.store.ready()
        h.store.start()
        h.store.pause()
        h.board.clearContents()
        h.board.setString("copied while paused", forType: .string)
        h.store.resume()
        h.store.poll()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(h.store.entries.contains { $0.text == "copied while paused" })
    }

    // MARK: Suggestions already on screen

    private var destination: ClipboardSuggestionTarget {
        ClipboardSuggestionTarget(pid: 4_242, bundleID: "test.audit340.destination", appName: "Fixture")
    }

    /// Publishes suggestions for the fixture and returns every answer the
    /// caller receives from then on.
    private final class Answers { var all: [[UUID]] = [] }

    private func showSuggestions(_ intelligence: ClipboardIntelligence, store: ClipboardStore) async -> Answers {
        intelligence.secureInputProbe = { false }
        intelligence.destinationReader = { _, bundleID, _, _ in
            ClipboardDestinationContext(bundleID: bundleID, windowTitle: "Synthetic window", kind: .text,
                                        fieldHint: "email", source: .accessibility)
        }
        let answers = Answers()
        let first = expectation(description: "published")
        intelligence.suggestionsAsync(for: destination, store: store) { ids in
            answers.all.append(ids)
            if answers.all.count == 1 { first.fulfill() }
        }
        await fulfillment(of: [first], timeout: 10)
        return answers
    }

    func testSuggestionsOnScreenAreWithdrawnWhenTheDestinationIsExcluded() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let original = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = original }

        let answers = await showSuggestions(intelligence, store: h.store)
        XCTAssertEqual(answers.all, [[item.id]], "control: the fixture is suggested")
        h.store.settings.ignoredApps.append(" TEST.audit340.Destination ")
        try await Task.sleep(nanoseconds: 150_000_000) // the store's change is checked on the next turn
        XCTAssertEqual(answers.all.last, [], "the suggestion on screen is withdrawn")
        XCTAssertTrue(intelligence.lastContext.isExcluded)
        XCTAssertNil(intelligence.lastContext.windowTitle, "nothing read before the exclusion is kept")
    }

    func testSuggestionsOnScreenAreWithdrawnWhenIntelligentClipboardIsTurnedOff() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let original = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = original }

        let answers = await showSuggestions(intelligence, store: h.store)
        XCTAssertEqual(answers.all, [[item.id]])
        intelligence.isEnabled = false
        XCTAssertEqual(answers.all.last, [], "withdrawn when the feature goes")
        XCTAssertEqual(intelligence.lastContext, ClipboardDestinationContext())
        intelligence.isEnabled = true
        XCTAssertEqual(answers.all.count, 2, "turning it on again publishes nothing by itself")
    }

    /// An app excluded that an item came from: the item may not stay offered.
    func testSuggestionsOnScreenAreWithdrawnWhenTheirSourceAppIsExcluded() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let original = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = original }

        let answers = await showSuggestions(intelligence, store: h.store)
        XCTAssertEqual(answers.all, [[item.id]])
        h.store.settings.ignoredApps.append("com.kyw.allofmacos") // createTextItem's source
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(answers.all.last, [])
        XCTAssertFalse(intelligence.lastContext.isExcluded, "the destination itself is still allowed")
    }

    func testAChangeUnrelatedToPrivacyLeavesTheSuggestionsAlone() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let original = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = original }

        let answers = await showSuggestions(intelligence, store: h.store)
        h.store.settings.plainText.toggle()
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(answers.all, [[item.id]], "nothing withdrawn, nothing republished")
    }
}
