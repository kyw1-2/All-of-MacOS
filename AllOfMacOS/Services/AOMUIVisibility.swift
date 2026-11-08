import AppKit
import Combine

/// Whether AOM has anything on screen at all.
///
/// 3.4.32 audit: a `TimelineView(.animation)` and the `repeatForever`
/// animations in `GesturePreviewView` were gated on `scenePhase == .active`
/// only. A SwiftUI `WindowGroup` keeps its scene active after the window is
/// ordered out or closed, so the preview kept asking for a 30 fps frame clock
/// with no window to draw into: the app sat at ~44 % CPU (and dragged
/// WindowServer to ~47 %) purely from AttributeGraph updates and layer commits.
/// Gating those animations on real window visibility, not scene phase, brings
/// an idle app back to a few percent.
@MainActor
final class AOMUIVisibility: ObservableObject {
    static let shared = AOMUIVisibility()

    /// True while at least one AOM window is on screen and not minimised.
    @Published private(set) var anyWindowVisible = true

    /// A panel that is ordered out or fully transparent does not count as
    /// something to animate for.
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private static let watchedNames: [Notification.Name] = [
        // AppKit has no "did become visible"; ordering a window back on screen
        // is reported as an occlusion change and, once drawn, as an expose.
        NSWindow.didExposeNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.willCloseNotification,
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification,
    ]

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in Self.watchedNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AOMUIVisibility.shared.recompute() }
            })
        }
        recompute()
    }

    func stop() {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        started = false
    }

    /// Pure visibility rule, so the decision is testable without a window server.
    static func isVisible(windowIsVisible: Bool, isMiniaturized: Bool, occlusionVisible: Bool) -> Bool {
        windowIsVisible && !isMiniaturized && occlusionVisible
    }

    /// `NSStatusBarWindow` is private, so match it by name.
    static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).contains("StatusBarWindow")
    }

    func recompute() {
        let visible = NSApp.windows.contains { window in
            // The status item owns a window that stays "visible" for the life
            // of the app; it draws nothing that animates.
            guard !Self.isStatusBarWindow(window) else { return false }
            return Self.isVisible(windowIsVisible: window.isVisible,
                                  isMiniaturized: window.isMiniaturized,
                                  occlusionVisible: window.occlusionState.contains(.visible))
        }
        if anyWindowVisible != visible { anyWindowVisible = visible }
    }
}
