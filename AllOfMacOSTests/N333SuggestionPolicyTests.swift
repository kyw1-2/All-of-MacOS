import AppKit
import XCTest
@testable import AllOfMacOS

/// N333-03 (re-audit 2026-10-30): a privacy change made while suggestion
/// work is pending is honoured before anything is published or logged. When
/// the destination is excluded, secure keyboard entry turns on, Intelligent
/// Clipboard is turned off or the excluded-app list changes, the request
/// still answers, with nothing, and the paste log learns nothing. A request
/// superseded by a newer one stays silent instead, as before.
///
/// Synthetic fixtures only. Every store has a private named pasteboard, its
/// own defaults suite and a temporary directory. The destination reader and
/// the secure-input probe are stubs (the seams Independent333AuditTests
/// uses). Nothing reads Accessibility, the screen, the user's clipboard or
/// the network.
@MainActor
final class N333SuggestionPolicyTests: XCTestCase {
    private struct Harness {
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let token: String
        let store: ClipboardStore
    }

    private func harness() -> Harness {
        let token = "AOMN333Policy-\(UUID().uuidString)"
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

    private var destination: ClipboardSuggestionTarget {
        ClipboardSuggestionTarget(pid: 4_242, bundleID: "test.n333.destination", appName: "Fixture")
    }

    /// `createTextItem` records All of MacOS itself as the item's source app.
    private var itemSource: String { "com.kyw.allofmacos" }

    /// Starts a request whose destination read is held at a gate, runs
    /// `change` on the main actor while it is held, releases it and returns
    /// what the request answered. The read is an email field with a window
    /// title and a label, which a refusal must not keep.
    private func answer(_ intelligence: ClipboardIntelligence, store: ClipboardStore,
                        whilePending change: () -> Void) async -> [UUID] {
        let entered = expectation(description: "destination reader entered")
        let delivered = expectation(description: "callback delivered")
        let gate = DispatchSemaphore(value: 0)
        intelligence.destinationReader = { _, bundleID, _, _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 10)
            return ClipboardDestinationContext(bundleID: bundleID, windowTitle: "Synthetic window", kind: .text,
                                               fieldHint: "email", source: .accessibility)
        }
        var ids: [UUID] = []
        intelligence.suggestionsAsync(for: destination, store: store) { ids = $0; delivered.fulfill() }
        await fulfillment(of: [entered], timeout: 10)
        change()
        gate.signal()
        await fulfillment(of: [delivered], timeout: 10)
        return ids
    }

    // MARK: - Pending suggestions

    /// (a) The audit's case. The answer is delivered, empty, and records the
    /// exclusion instead of what was read before it.
    func testExclusionAddedWhilePendingAnswersNothing() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        // Same trimmed, case-insensitive match as the start-of-request gate.
        let ids = await answer(intelligence, store: h.store) {
            h.store.settings.ignoredApps.append(" TEST.n333.Destination ")
        }
        XCTAssertFalse(ids.contains(item.id))
        XCTAssertEqual(ids, [], "an exclusion added during pending work voids its result")
        XCTAssertTrue(intelligence.lastContext.isExcluded)
        XCTAssertNil(intelligence.lastContext.windowTitle, "nothing read before the exclusion is kept")
        XCTAssertEqual(intelligence.lastContext.fieldHint, "")
    }

    /// (b) Secure keyboard entry turns on while the read is held.
    func testSecureInputTurnedOnWhilePendingAnswersNothing() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        let ids = await answer(intelligence, store: h.store) { intelligence.secureInputProbe = { true } }
        XCTAssertFalse(ids.contains(item.id))
        XCTAssertEqual(ids, [])
        XCTAssertTrue(intelligence.lastContext.isSecureInput)
        XCTAssertEqual(intelligence.lastContext.kind, .password)
        XCTAssertNil(intelligence.lastContext.windowTitle)
        XCTAssertEqual(intelligence.lastContext.fieldHint, "")
    }

    /// (c) Intelligent Clipboard is turned off while the read is held.
    func testIntelligentClipboardTurnedOffWhilePendingAnswersNothing() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        let ids = await answer(intelligence, store: h.store) { intelligence.isEnabled = false }
        XCTAssertFalse(ids.contains(item.id))
        XCTAssertEqual(ids, [])
        XCTAssertEqual(intelligence.lastContext, ClipboardDestinationContext())
    }

    /// (d) Control: with no change, or a change unrelated to privacy, the
    /// same held request publishes the suggestion and the context it read.
    func testUnchangedPolicyPublishesTheSuggestion() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        let unchanged = await answer(intelligence, store: h.store) {}
        XCTAssertEqual(unchanged, [item.id], "control: the fixture is suggested when nothing changes")
        XCTAssertEqual(intelligence.lastContext.windowTitle, "Synthetic window")
        XCTAssertFalse(intelligence.lastContext.blocksSuggestions)

        let unrelated = await answer(intelligence, store: h.store) { h.store.settings.plainText.toggle() }
        XCTAssertEqual(unrelated, [item.id], "a setting unrelated to privacy leaves the answer alone")
    }

    /// The destination stays allowed, but the app an item came from is
    /// excluded while the request ranks with the old list.
    func testSourceAppExcludedWhilePendingIsNotSuggested() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        let source = itemSource
        let ids = await answer(intelligence, store: h.store) { h.store.settings.ignoredApps.append(source) }
        XCTAssertFalse(ids.contains(item.id), "an item from an app excluded meanwhile is never offered")
        XCTAssertFalse(intelligence.lastContext.isExcluded, "the destination itself is still allowed")
    }

    /// Superseded is not refused: a request overtaken by a newer one stays
    /// silent, and the newer one answers.
    func testSupersededRequestStaysSilentAndItsSuccessorAnswers() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }

        let entered = expectation(description: "first read entered")
        let gate = DispatchSemaphore(value: 0)
        intelligence.destinationReader = { _, bundleID, _, _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 10)
            return ClipboardDestinationContext(bundleID: bundleID, kind: .text, fieldHint: "email", source: .accessibility)
        }
        var firstAnswers = 0
        intelligence.suggestionsAsync(for: destination, store: h.store) { _ in firstAnswers += 1 }
        await fulfillment(of: [entered], timeout: 10)

        // The newer request queues behind the held one on the same serial
        // queue, so the older answer reaches the main queue first.
        intelligence.destinationReader = { _, bundleID, _, _ in
            ClipboardDestinationContext(bundleID: bundleID, kind: .text, fieldHint: "email", source: .accessibility)
        }
        let answered = expectation(description: "successor answered")
        var ids: [UUID] = []
        intelligence.suggestionsAsync(for: destination, store: h.store) { ids = $0; answered.fulfill() }
        gate.signal()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(firstAnswers, 0, "the superseded request never answers; its successor does")
        XCTAssertEqual(ids, [item.id])
    }

    // MARK: - The paste log

    /// A paste whose classification is still queued when the policy changes
    /// learns nothing. With no change it is learned (control). The shared
    /// classification queue is held behind another app's destination read.
    func testPasteLogRechecksThePolicyWhenClassificationLands() async throws {
        let source = itemSource
        let scenarios: [(name: String, learned: Int, change: (Harness, ClipboardIntelligence) -> Void)] = [
            ("control", 1, { _, _ in }),
            ("destination excluded", 0, { h, _ in h.store.settings.ignoredApps.append("test.n333.destination") }),
            ("secure input turned on", 0, { _, intelligence in intelligence.secureInputProbe = { true } }),
            ("feature turned off", 0, { _, intelligence in intelligence.isEnabled = false }),
            ("item's own app excluded", 0, { h, _ in h.store.settings.ignoredApps.append(source) }),
        ]
        for scenario in scenarios {
            let h = harness(); defer { clean(h) }; await h.store.ready()
            let item = try XCTUnwrap(h.store.createTextItem("someone@example.com"))
            let intelligence = ClipboardIntelligence()
            let originalEnabled = intelligence.isEnabled
            intelligence.isEnabled = true
            defer { intelligence.isEnabled = originalEnabled }
            intelligence.secureInputProbe = { false }
            defer { intelligence.log(for: h.store).erase() }

            let entered = expectation(description: "queue held: \(scenario.name)")
            let held = expectation(description: "holding request answered: \(scenario.name)")
            let decided = expectation(description: "paste decided: \(scenario.name)")
            let gate = DispatchSemaphore(value: 0)
            intelligence.destinationReader = { _, bundleID, _, _ in
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 10)
                return ClipboardDestinationContext(bundleID: bundleID, kind: .text, source: .accessibility)
            }
            intelligence.suggestionsAsync(for: ClipboardSuggestionTarget(pid: 77, bundleID: "test.n333.holder", appName: "Holder"),
                                          store: h.store) { _ in held.fulfill() }
            await fulfillment(of: [entered], timeout: 10)
            intelligence.recordPaste(entryIDs: [item.id], target: destination, store: h.store) { decided.fulfill() }
            scenario.change(h, intelligence)
            gate.signal()
            await fulfillment(of: [held, decided], timeout: 10)

            let events = intelligence.log(for: h.store).events
            XCTAssertEqual(events.count, scenario.learned, scenario.name)
            if scenario.learned > 0 {
                XCTAssertEqual(events.first?.destinationBundleID, "test.n333.destination", scenario.name)
                XCTAssertEqual(events.first?.entryID, item.id, scenario.name)
            }
        }
    }

    // MARK: - The window look

    /// The window look (capture, OCR, model) never runs in a test: isolated
    /// runs do not ask for it. Its `stillAllowed` steps and its answer call
    /// `pendingRefusal`, the decision the first answer uses. That decision
    /// is checked directly.
    func testPendingDecisionSharedWithTheWindowLook() async throws {
        let h = harness(); defer { clean(h) }; await h.store.ready()
        let intelligence = ClipboardIntelligence()
        let originalEnabled = intelligence.isEnabled
        intelligence.isEnabled = true
        defer { intelligence.isEnabled = originalEnabled }
        intelligence.secureInputProbe = { false }
        let app = "test.n333.destination"

        let started = h.store.settings.excludedBundleIDs
        XCTAssertNil(intelligence.pendingRefusal(for: app, store: h.store, rankedWith: started), "control")

        h.store.settings.ignoredApps.append("test.n333.other")
        XCTAssertEqual(intelligence.pendingRefusal(for: app, store: h.store, rankedWith: started),
                       ClipboardDestinationContext(bundleID: app), "the list the work ranked with has changed")
        let current = h.store.settings.excludedBundleIDs
        XCTAssertNil(intelligence.pendingRefusal(for: app, store: h.store, rankedWith: current),
                     "control: work that ranked with the current list")

        intelligence.secureInputProbe = { true }
        XCTAssertEqual(intelligence.pendingRefusal(for: app, store: h.store, rankedWith: current)?.isSecureInput, true)
        intelligence.secureInputProbe = { false }

        intelligence.isEnabled = false
        XCTAssertEqual(intelligence.pendingRefusal(for: app, store: h.store, rankedWith: current), ClipboardDestinationContext())
        intelligence.isEnabled = true

        h.store.settings.ignoredApps.append(app)
        let excluded = intelligence.pendingRefusal(for: app, store: h.store, rankedWith: h.store.settings.excludedBundleIDs)
        XCTAssertEqual(excluded?.isExcluded, true)
        XCTAssertNil(excluded?.windowTitle)
    }
}
