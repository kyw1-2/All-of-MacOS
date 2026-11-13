import AppKit
import SwiftUI

/// Top-level navigation hubs for All of MacOS.
enum AOMMainTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case gestures = "Gestures & Automation"
    case snapping = "Window Snapping"
    case capture = "Capture & Studio"
    case clipboard = "Clipboard Memory"
    case audio = "Audio"
    case tools = "System Tools"
    case insights = "Statistics"
    // 3.4 productivity pages (after Insights so ⌘1…⌘8 and the preview tab
    // numbers of the earlier pages stay as they were).
    case folderRules = "Folder Rules"
    case textActions = "Text Actions"
    case files = "Files"
    case focus = "Focus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Workspace"
        case .gestures: return "Automation"
        case .snapping: return "Window Tiling"
        case .capture: return "Capture"
        case .clipboard: return "Clipboard"
        case .audio: return "Audio"
        case .tools: return "System Tools"
        case .insights: return "Insights"
        case .folderRules: return "Folder Rules"
        case .textActions: return "Text Actions"
        case .files: return "Files"
        case .focus: return "Focus"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return "Everything at a glance"
        case .gestures: return "Trackpad, keyboard, mouse & workflow automation"
        case .snapping: return "Tiling, trackpad snap, zones & display layouts"
        case .capture: return "Screenshots, recording, annotation & OCR"
        case .clipboard: return "Encrypted pasteboard history, pinboards & search"
        case .audio: return "Per-app volume, the equalizer & output devices"
        case .tools: return "Finder, network, PDF, media & cleanup utilities"
        case .insights: return "How often each input fires and what it runs"
        case .folderRules: return "Rules that tidy Downloads, Desktop and other folders"
        case .textActions: return "A bar of actions over the text you select"
        case .files: return "Open and Save dialog shortcuts, a drop shelf and recent files"
        case .focus: return "Focus sessions, hiding distractions and quitting idle apps"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .gestures: return "hand.tap.fill"
        case .snapping: return "rectangle.split.2x2.fill"
        case .capture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard.fill"
        case .audio: return "waveform"
        case .tools: return "wrench.and.screwdriver.fill"
        case .insights: return "chart.xyaxis.line"
        case .folderRules: return "folder.badge.gearshape"
        case .textActions: return "character.cursor.ibeam"
        case .files: return "folder.fill"
        case .focus: return "timer"
        }
    }

    /// Outline symbol for the sidebar (the system tints it with the accent).
    var sidebarSymbol: String {
        switch self {
        case .home: return "house"
        case .gestures: return "bolt"
        case .snapping: return "rectangle.split.2x2"
        case .capture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .audio: return "waveform"
        case .tools: return "wrench.and.screwdriver"
        case .insights: return "chart.bar.xaxis"
        case .folderRules: return "folder.badge.gearshape"
        case .textActions: return "character.cursor.ibeam"
        case .files: return "folder"
        case .focus: return "timer"
        }
    }

    /// System Settings–style tile colour for the sidebar and page heroes.
    var accentColor: Color {
        switch self {
        case .home: return .blue
        case .gestures: return .cyan
        case .snapping: return .indigo
        case .capture: return .orange
        case .clipboard: return .purple
        case .audio: return .pink
        case .tools: return .teal
        case .insights: return .green
        case .folderRules: return .mint
        case .textActions: return .orange
        case .files: return .blue
        case .focus: return .red
        }
    }

    /// ⌘1…⌘9 in the View menu and sidebar for the first nine pages; later
    /// pages have none (a two-digit key equivalent does not exist).
    var shortcutKey: KeyEquivalent? {
        guard let index = AOMMainTab.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}

/// App-owned scroll views keep their native scrolling behavior without tracks.
/// Observe AppKit's resets as SwiftUI updates Lists, Forms and text editors.
/// No global preferences, method swizzling or wheel event interception.
///
/// Performance: `NSWindow.didUpdateNotification` fires after *every* event
/// (mouse move, hover, scroll, key). Walking whole view trees on each one made
/// hover and scrolling in floating panels stall, so a refresh now covers only
/// the window that posted, at most a few times per second, and skips
/// non-activating panels — those own their scroll chrome via
/// `NativeScrollChrome` already.
@MainActor
final class AOMScrollChromePolicy {
    static let shared = AOMScrollChromePolicy()
    private var notificationTokens: [NSObjectProtocol] = []
    private let surfaces = NSMapTable<NSScrollView, Surface>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var pendingWindows: [ObjectIdentifier: (window: NSWindow, due: CFTimeInterval)] = [:]
    private var lastRefresh: [ObjectIdentifier: CFTimeInterval] = [:]
    private var flushScheduled = false
    static let minimumInterval: CFTimeInterval = 1.0

    func start() {
        guard notificationTokens.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    if name == NSWindow.didBecomeKeyNotification { self.followUpdates(of: window) }
                    self.scheduleRefresh(window)
                }
            })
        }
        if let key = NSApp.keyWindow { followUpdates(of: key) }
        for window in NSApp.windows where Self.isManaged(window) { refresh(window) }
    }

    /// Per-event updates only matter for the window being used; background
    /// windows refresh when they become key again. 3.4.44: `didUpdate` is
    /// observed for the managed key window alone instead of every window, so
    /// events in panels and HUDs no longer run this block at all.
    private var updateToken: NSObjectProtocol?
    private weak var updateWindow: NSWindow?

    private func followUpdates(of window: NSWindow) {
        let target: NSWindow? = Self.isManaged(window) ? window : nil
        guard target !== updateWindow || (target != nil && updateToken == nil) else { return }
        if let updateToken { NotificationCenter.default.removeObserver(updateToken) }
        updateToken = nil
        updateWindow = target
        guard let target else { return }
        updateToken = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: target,
                                                             queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.isKeyWindow else { return }
                self?.scheduleRefresh(window)
            }
        }
    }

    /// Titled app windows only. Floating, non-activating panels (clipboard
    /// shelf, Quick Access, HUDs) and system file dialogs keep their own setup.
    static func isManaged(_ window: NSWindow) -> Bool {
        guard window.isVisible, !(window is NSSavePanel) else { return false }
        if window.styleMask.contains(.nonactivatingPanel) { return false }
        return window.styleMask.contains(.titled)
    }

    private func scheduleRefresh(_ window: NSWindow) {
        guard Self.isManaged(window) else { return }
        let key = ObjectIdentifier(window)
        guard pendingWindows[key] == nil else { return }
        let now = CACurrentMediaTime()
        let due = max(now, (lastRefresh[key] ?? 0) + Self.minimumInterval)
        pendingWindows[key] = (window, due)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now)) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let now = CACurrentMediaTime()
        var nextDue: CFTimeInterval?
        for (key, item) in pendingWindows {
            if item.due <= now + 0.005 {
                pendingWindows[key] = nil
                lastRefresh[key] = now
                refresh(item.window)
            } else {
                nextDue = min(nextDue ?? item.due, item.due)
            }
        }
        if let nextDue {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, nextDue - now)) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    private func refresh(_ window: NSWindow) {
        guard Self.isManaged(window), let content = window.contentView else { return }
        attach(in: content)
    }

    func attach(in view: NSView) {
        if let scroll = view as? NSScrollView, surfaces.object(forKey: scroll) == nil {
            surfaces.setObject(Surface(scroll), forKey: scroll)
        }
        for child in view.subviews { attach(in: child) }
    }

    @MainActor
    private final class Surface {
        private weak var scroll: NSScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var applying = false

        init(_ scroll: NSScrollView) {
            self.scroll = scroll
            observations = [
                scroll.observe(\.hasVerticalScroller, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                },
                scroll.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                },
                scroll.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            ]
            apply()
        }

        private func apply() {
            guard !applying, let scroll else { return }
            applying = true
            defer { applying = false }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        }
    }
}
