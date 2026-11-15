import XCTest
import Combine
import SwiftUI
@testable import AllOfMacOS

@MainActor
final class AOMNavigationTests: XCTestCase {
    func testShowStatisticsFollowsAndSelectsInsights() {
        let navigation = AOMNavigation(history: nil, persistsLastPage: false)
        let state = AppState(navigation: navigation)
        XCTAssertEqual(state.selectedMainTab, .home)
        XCTAssertFalse(state.showStatistics)

        state.showStatistics = true
        XCTAssertEqual(navigation.selected, .insights)
        XCTAssertTrue(state.showStatistics)

        state.showStatistics = false
        XCTAssertEqual(navigation.selected, .gestures)
        XCTAssertFalse(state.showStatistics)

        state.selectedMainTab = .insights
        XCTAssertTrue(state.showStatistics)
        state.selectedMainTab = .audio
        XCTAssertFalse(state.showStatistics)

        // Turning it off elsewhere leaves the page alone.
        state.showStatistics = false
        XCTAssertEqual(navigation.selected, .audio)
    }

    func testPageChangePublishesOnNavigationNotAppState() {
        let navigation = AOMNavigation(history: nil, persistsLastPage: false)
        let state = AppState(navigation: navigation)
        var appStateChanges = 0
        var navigationChanges = 0
        let a = state.objectWillChange.sink { appStateChanges += 1 }
        let b = navigation.objectWillChange.sink { navigationChanges += 1 }
        defer { a.cancel(); b.cancel() }

        state.selectedMainTab = .capture
        state.showStatistics = true
        XCTAssertEqual(navigationChanges, 2)
        XCTAssertEqual(appStateChanges, 0)

        // Selecting the page already selected publishes nothing.
        state.selectedMainTab = .insights
        XCTAssertEqual(navigationChanges, 2)
    }

    func testNavigationRecordsHistoryBeforeViewsRender() {
        let history = AOMNavigationHistory()
        let navigation = AOMNavigation(history: history, persistsLastPage: false)
        navigation.selected = .audio
        XCTAssertEqual(history.backTarget, .home)
        navigation.selected = .files
        XCTAssertEqual(history.backStack, [.home, .audio])

        let state = AppState(navigation: navigation)
        history.goBack(state)
        XCTAssertEqual(navigation.selected, .audio)
        XCTAssertEqual(history.backStack, [.home])
        XCTAssertEqual(history.forwardTarget, .files)
        history.goForward(state)
        XCTAssertEqual(navigation.selected, .files)
        XCTAssertEqual(history.backStack, [.home, .audio])
        XCTAssertFalse(history.canGoForward)

        // Launch restore is not a visit.
        history.skipRecording(.focus)
        navigation.selected = .focus
        XCTAssertEqual(history.backStack, [.home, .audio])
    }

    func testHistoryPublishesOnlyWhenAvailabilityChanges() {
        let history = AOMNavigationHistory()
        var changes = 0
        let subscription = history.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        history.record(from: .home, to: .gestures)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(history.canGoBack)

        // Ordinary page changes leave both buttons as they are.
        for (old, new) in [(AOMMainTab.gestures, AOMMainTab.audio), (.audio, .files), (.files, .focus)] {
            history.record(from: old, to: new)
        }
        XCTAssertEqual(changes, 1)

        _ = history.back(from: .focus)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(history.canGoForward)
        history.record(from: .files, to: .files)
        XCTAssertEqual(changes, 2)

        // A new visit clears Forward.
        history.record(from: .files, to: .home)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(changes, 3)
    }

    func testHistoryKeepsAtMostTheLimit() {
        let history = AOMNavigationHistory()
        let tabs = AOMMainTab.allCases
        for index in 0..<(AOMNavigationHistory.limit + 10) {
            history.record(from: tabs[index % tabs.count], to: tabs[(index + 1) % tabs.count])
        }
        XCTAssertEqual(history.backStack.count, AOMNavigationHistory.limit)
    }

    func testSelectionFlipsExactlyTheTwoAffectedPageActivities() {
        let navigation = AOMNavigation(history: nil, persistsLastPage: false)
        let home = navigation.activity(for: .home)
        let audio = navigation.activity(for: .audio)
        let files = navigation.activity(for: .files)
        XCTAssertTrue(home.isActive)
        XCTAssertFalse(audio.isActive)
        XCTAssertTrue(navigation.activity(for: .home) === home, "one object per page")

        var counts: [AOMMainTab: Int] = [:]
        let subscriptions = [(AOMMainTab.home, home), (.audio, audio), (.files, files)].map { tab, activity in
            activity.objectWillChange.sink { counts[tab, default: 0] += 1 }
        }
        defer { subscriptions.forEach { $0.cancel() } }

        navigation.selected = .audio
        XCTAssertEqual(counts, [.home: 1, .audio: 1])
        XCTAssertFalse(home.isActive)
        XCTAssertTrue(audio.isActive)
        XCTAssertFalse(files.isActive)

        navigation.selected = .files
        XCTAssertEqual(counts, [.home: 1, .audio: 2, .files: 1])
        // A page with no activity object yet is created in the right state.
        XCTAssertFalse(navigation.activity(for: .focus).isActive)
        XCTAssertTrue(navigation.activity(for: .files).isActive)
    }

    func testPageActivityPublishesOnlyOnChange() {
        let activity = AOMPageActivity(isActive: true)
        var changes = 0
        let subscription = activity.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        activity.setActive(true)
        XCTAssertEqual(changes, 0)
        activity.setActive(false)
        activity.setActive(false)
        XCTAssertEqual(changes, 1)
        activity.setActive(true)
        XCTAssertEqual(changes, 2)
        // Outside the page host everything stays selected.
        AOMPageActivity.alwaysActive.setActive(false)
        XCTAssertTrue(AOMPageActivity.alwaysActive.isActive)
    }

    func testPageObservationFollowsItsPageActivity() {
        final class Source: ObservableObject { @Published var value = 0 }
        let source = Source()
        let activity = AOMPageActivity(isActive: true)
        let observation = AOMPageObservation([source.aomChanges])
        observation.follow(activity)
        var changes = 0
        let subscription = observation.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        activity.setActive(false)
        source.value = 1
        XCTAssertEqual(changes, 0)
        // Selecting the page forwards the missed change at once.
        activity.setActive(true)
        XCTAssertEqual(changes, 1)
    }

    func testRefreshClockSaysWhenARefreshIsDue() {
        let clock = AOMRefreshClock()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(clock.remaining(of: 30, now: start), 0)
        clock.mark(start)
        XCTAssertEqual(clock.remaining(of: 30, now: start.addingTimeInterval(10)), 20, accuracy: 0.001)
        XCTAssertEqual(clock.remaining(of: 30, now: start.addingTimeInterval(31)), 0)
    }

    func testHiddenPagesUseOneModifierChainWithDifferentValues() {
        XCTAssertEqual(AOMPageHiding.opacity.opacity(active: false), 0)
        XCTAssertEqual(AOMPageHiding.opacity.offset(active: false), 0)
        XCTAssertEqual(AOMPageHiding.offset.opacity(active: false), 1)
        XCTAssertEqual(AOMPageHiding.offset.offset(active: false), AOMPageHiding.offscreenDistance)
        for hiding in [AOMPageHiding.opacity, .offset] {
            XCTAssertEqual(hiding.opacity(active: true), 1)
            XCTAssertEqual(hiding.offset(active: true), 0)
        }
    }

    func testVisitedPagesAppendOnceAndNeverMove() {
        typealias Host = AOMPageHost<EmptyView>
        var visited = Host.visiting(.home, after: [])
        XCTAssertEqual(visited, [.home])
        visited = Host.visiting(.audio, after: visited)
        visited = Host.visiting(.files, after: visited)
        XCTAssertEqual(visited, [.home, .audio, .files])
        // Revisiting keeps every page where it was.
        XCTAssertEqual(Host.visiting(.home, after: visited), visited)
        XCTAssertEqual(Host.visiting(.audio, after: visited), visited)
        XCTAssertEqual(Host.visiting(.focus, after: visited), [.home, .audio, .files, .focus])
    }

    func testPageObservationHoldsChangesWhileHidden() {
        final class Source: ObservableObject { @Published var value = 0 }
        let source = Source()
        let observation = AOMPageObservation([source.aomChanges])
        var changes = 0
        let subscription = observation.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        source.value = 1
        XCTAssertEqual(changes, 1)
        observation.setActive(false)
        source.value = 2
        source.value = 3
        XCTAssertEqual(changes, 1)
        observation.setActive(true)
        XCTAssertEqual(changes, 2)
        // Nothing missed: selecting again publishes nothing.
        observation.setActive(false)
        observation.setActive(true)
        XCTAssertEqual(changes, 2)
    }

    func testPausedPageScheduleStopsAfterOneEntry() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let paused = Array(AOMPageSchedule(interval: 30, paused: true).entries(from: start, mode: .normal))
        XCTAssertEqual(paused, [start])
        let running = Array(AOMPageSchedule(interval: 30, paused: false).entries(from: start, mode: .normal).prefix(3))
        XCTAssertEqual(running, [start, start.addingTimeInterval(30), start.addingTimeInterval(60)])
    }
}
