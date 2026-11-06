import AppKit

/// Notices the end of a selection in other apps with light global monitors:
/// left mouse down and up (a drag, a double or triple click, a ⇧-click),
/// and, when that trigger is on, ⇧ with the arrow keys. No drag events are
/// watched (the distance comes from the two clicks), nothing is installed
/// while every trigger is off, and AOM's own windows are never seen (global
/// monitors skip the app's own events).
@MainActor
final class TextSelectionMonitor {
    struct Gesture: Equatable {
        enum Kind: Equatable { case drag, doubleClick, tripleClick, shiftClick, keyboard }
        var kind: Kind
        /// Where the pointer was (AppKit coordinates); nil for the keyboard.
        var pointer: CGPoint?
    }

    struct Options: Equatable {
        var drag = false
        var clicks = false
        var keyboard = false
        /// How long the arrow keys rest before a keyboard selection counts.
        var keyboardDelay: TimeInterval = 0.5
    }

    /// A mouse moving this far between down and up dragged.
    static let dragThreshold: CGFloat = 4

    /// Distinguish a completed double-click from the beginning of a
    /// triple-click selection. The double-click may still get a third click, so wait
    /// for a short quiet interval after the second release before probing AX.
    nonisolated static func settledDelay(kind: Gesture.Kind, userDelay: TimeInterval) -> TimeInterval {
        switch kind {
        case .doubleClick: return max(userDelay, 0.42)
        default: return userDelay
        }
    }
    /// Arrows, Home, End, Page Up and Page Down.
    static let selectionKeys: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]

    var onMouseDown: ((CGPoint, Int) -> Void)?
    var onGesture: ((Gesture) -> Void)?

    private(set) var options = Options()
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var downPoint: CGPoint?
    private var downDragCount = 0
    private var keyboardWork: DispatchWorkItem?

    var isMonitoring: Bool { mouseMonitor != nil || keyMonitor != nil }

    func update(_ options: Options) {
        self.options = options
        let wantsMouse = options.drag || options.clicks
        if wantsMouse, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
            }
        } else if !wantsMouse, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            downPoint = nil
        }
        if options.keyboard, keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
            }
        } else if !options.keyboard, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
            keyboardWork?.cancel()
            keyboardWork = nil
        }
    }

    func stop() { update(Options()) }

    private static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextActionPasteboard.syntheticTag
    }

    private func handleMouse(_ event: NSEvent) {
        guard !Self.isSynthetic(event) else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            downPoint = point
            downDragCount = NSPasteboard(name: .drag).changeCount
            onMouseDown?(point, event.clickCount)
        case .leftMouseUp:
            guard let start = downPoint else { return }
            downPoint = nil
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let kind = Self.gesture(clickCount: event.clickCount, distance: hypot(point.x - start.x, point.y - start.y),
                                          flags: flags, dragged: NSPasteboard(name: .drag).changeCount != downDragCount,
                                          options: options) else { return }
            onGesture?(Gesture(kind: kind, pointer: point))
        default:
            break
        }
    }

    /// Which selection a mouse-up ended, if any. ⌘-click opens links and
    /// ⌃-click is a right click; a drag and drop (files, moved text) writes
    /// the drag pasteboard; a plain click selects nothing.
    static func gesture(clickCount: Int, distance: CGFloat, flags: NSEvent.ModifierFlags, dragged: Bool,
                        options: Options) -> Gesture.Kind? {
        guard !flags.contains(.command), !flags.contains(.control), !dragged else { return nil }
        if clickCount >= 3 { return options.clicks ? .tripleClick : nil }
        if clickCount == 2 { return options.clicks ? .doubleClick : nil }
        if distance >= dragThreshold { return options.drag ? .drag : nil }
        if flags.contains(.shift) { return options.drag ? .shiftClick : nil }
        return nil
    }

    /// The selection at mouse down is compared with the one at mouse up for
    /// drags (a window or scroll-bar drag changes nothing) and for double and
    /// triple clicks (a double click on a title bar zooms the window). A
    /// ⇧-click always changes the selection, and the keyboard has no mouse down.
    static func comparesWithMouseDown(_ kind: Gesture.Kind) -> Bool {
        switch kind {
        case .drag, .doubleClick, .tripleClick: return true
        case .shiftClick, .keyboard: return false
        }
    }

    /// The second and third clicks of a multi-click keep the first click's
    /// reading: by then the app may already have selected the word.
    static func startsNewAnchor(clickCount: Int) -> Bool { clickCount <= 1 }

    private func handleKey(_ event: NSEvent) {
        guard !Self.isSynthetic(event) else { return }
        keyboardWork?.cancel()
        keyboardWork = nil
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift), !flags.contains(.control), Self.selectionKeys.contains(event.keyCode) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onGesture?(Gesture(kind: .keyboard, pointer: nil)) }
        }
        keyboardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + options.keyboardDelay, execute: work)
    }
}
