import AppKit
import Combine
import SwiftUI

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
    nonisolated static func isVisible(windowIsVisible: Bool, isMiniaturized: Bool, occlusionVisible: Bool) -> Bool {
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

/// Owns refresh demand for the actual hosting window, not all AOM panels.
/// SwiftUI can keep a page mounted after orderOut, so onDisappear alone is
/// insufficient. No timer is needed to discover visibility changes.
struct AOMWindowVisibilityReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.stop() }

    final class WindowView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reported = false
        private var pending: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidHide() { super.viewDidHide(); scheduleUpdate() }
        override func viewDidUnhide() { super.viewDidUnhide(); scheduleUpdate() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            if let window {
                let center = NotificationCenter.default
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    })
                }
                observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate(closing: true) }
                })
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    })
                }
            }
            scheduleUpdate()
        }

        private func scheduleUpdate(closing: Bool = false) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let visible = !closing && !NSApp.isHidden && !self.isHiddenOrHasHiddenAncestor && self.window.map {
                    AOMUIVisibility.isVisible(windowIsVisible: $0.isVisible,
                        isMiniaturized: $0.isMiniaturized, occlusionVisible: $0.occlusionState.contains(.visible))
                } == true
                self.report(visible)
            }
            pending = work
            // Keep model publications out of SwiftUI's view update transaction.
            DispatchQueue.main.async(execute: work)
        }

        private func report(_ visible: Bool) {
            guard reported != visible else { return }
            reported = visible
            changed?(visible)
        }

        private func removeObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        func stop() {
            pending?.cancel(); pending = nil
            removeObservers()
            if reported {
                reported = false
                let callback = changed
                DispatchQueue.main.async { callback?(false) }
            }
        }

        deinit {
            pending?.cancel()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

extension View {
    func aomOnWindowVisibilityChange(_ changed: @escaping (Bool) -> Void) -> some View {
        background(AOMWindowVisibilityReader(changed: changed).frame(width: 0, height: 0))
    }
}
