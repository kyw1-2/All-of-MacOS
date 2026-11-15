import Foundation
import SwiftUI

/// The selected main-window page, on its own publisher.
///
/// `AppState.selectedMainTab` forwards here, so a page change re-renders only
/// the views that observe this object (the page host, the sidebar, the title
/// and Back/Forward) instead of everything that observes AppState, including
/// the App's scene graph.
@MainActor
final class AOMNavigation: ObservableObject {
    static let shared = AOMNavigation(history: .shared, persistsLastPage: MainWindow.persistsLastPage)

    /// Recorded and persisted here, before any view renders the change, so
    /// Back/Forward read the new history in the same update and recording
    /// needs no second render pass.
    @Published var selected: AOMMainTab = .home {
        didSet {
            guard selected != oldValue else { return }
            history?.record(from: oldValue, to: selected)
            // In the same transaction as the selection, so the leaves that
            // observe these flip in the render that shows the new page.
            activities[oldValue]?.setActive(false)
            activities[selected]?.setActive(true)
            if persistsLastPage { UserDefaults.standard.set(selected.rawValue, forKey: MainWindow.lastPageKey) }
        }
    }

    /// Pages the main window has built at least once (the page host adds
    /// them); `AOMPageSwitchBench` reports whether a switch built its page.
    var createdPages: Set<AOMMainTab> = []

    private var activities: [AOMMainTab: AOMPageActivity] = [:]

    /// The page's activity flag, created on the first request (the page host
    /// asks once, when it builds the page) and the same object afterwards.
    func activity(for tab: AOMMainTab) -> AOMPageActivity {
        if let existing = activities[tab] { return existing }
        let activity = AOMPageActivity(isActive: tab == selected)
        activities[tab] = activity
        return activity
    }

    private let history: AOMNavigationHistory?
    private let persistsLastPage: Bool

    /// Tests pass their own history (or none) and never persist.
    init(history: AOMNavigationHistory?, persistsLastPage: Bool) {
        self.history = history
        self.persistsLastPage = persistsLastPage
    }
}

// MARK: - Page activity

/// Whether a main-window page is the selected one. Each page gets its own
/// object once and keeps it, so a page change never gives a page subtree a
/// new environment; only the small views that observe the object re-render.
/// Changed on the main thread only (by `AOMNavigation`).
final class AOMPageActivity: ObservableObject, @unchecked Sendable {
    /// Everything outside the main window's page host: Settings, sheets,
    /// panels, previews and tests behave as an always-selected page.
    static let alwaysActive = AOMPageActivity(isActive: true)

    @Published private(set) var isActive: Bool

    init(isActive: Bool) { self.isActive = isActive }

    /// Publishes only when the value changes.
    func setActive(_ value: Bool) {
        guard value != isActive, self !== Self.alwaysActive else { return }
        isActive = value
    }
}

private struct AOMPageActivityKey: EnvironmentKey {
    static let defaultValue = AOMPageActivity.alwaysActive
}

extension EnvironmentValues {
    /// The page's activity flag: read it in closures (`isActive`) without
    /// observing it, or observe it in a small leaf view.
    var aomPageActivity: AOMPageActivity {
        get { self[AOMPageActivityKey.self] }
        set { self[AOMPageActivityKey.self] = newValue }
    }
}
