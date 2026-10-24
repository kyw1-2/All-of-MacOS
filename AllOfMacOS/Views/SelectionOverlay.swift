import AppKit
import SwiftUI

extension NSScreen {
    /// The `CGDirectDisplayID` backing this screen.
    ///
    /// AppKit only exposes it inside `deviceDescription`, and the key is not a
    /// public constant, so the lookup lives here rather than being repeated.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// This screen's frame in global top-left-origin (ScreenCaptureKit) points.
    var sckFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// The dimmed full-screen overlay the user drags a capture rectangle on.
///
/// It covers every display at once with one window per screen, so a selection
/// can start on one display and the crosshair still reads correctly. A single
/// window spanning the union of all screens would be simpler, but macOS will not
/// let a window draw across displays with different backing scales without
/// resampling, which makes the dim layer visibly soft on one of them.
///
/// In All-In-One (`integrated`) mode a finished drag becomes a *pending*
/// selection: it can be moved (drag inside, arrow keys), sized via the W × H
/// fields, and is captured with Return or by choosing a mode (A F W S T O R).
@MainActor
final class SelectionOverlayController {
    private(set) static var activeController: SelectionOverlayController?
    static var isActive: Bool { activeController != nil }
    static func cancelActive() {
        activeController?.finish(nil)
    }

    private var windows: [SelectionWindow] = []
    private let state = SelectionState()
    private var localKeyMonitor: Any?
    var selectedMode: IntegratedCaptureMode { state.captureMode }
    var selectedWindowID: CGWindowID? { state.hoveredWindow?.windowID }
    private let completion: (CGRect?) -> Void
    private var didFinish = false
    private var globalKeyMonitor: Any?
    /// The app that was frontmost when the overlay took activation, if any.
    ///
    /// Stored as a pid + bundle id rather than an `NSRunningApplication` so a
    /// terminated app is never kept alive and is not reactivated.
    private var previousFrontmost: SelectionOverlayFocusPolicy.Snapshot?

    init(integrated: Bool = false, startInWindowMode: Bool = false,
         completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        state.integrated = integrated
        if startInWindowMode {
            state.mode = .window
            state.captureMode = .window
        }
    }

    func present() {
        Self.activeController = self
        // The display query overlaps the user's drag instead of following it.
        ScreenCaptureService.shared.prewarm()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { finish(nil); return }

        state.activate = { [weak self] mode in self?.activate(mode) }
        state.commitPending = { [weak self] in self?.commitPending() }
        state.activeDisplayID = (screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screens[0]).displayID
        state.desktopBounds = screens.map(\.sckFrame).reduce(CGRect.null) { $0.union($1) }
        if CaptureSettings.snapsSelection { state.snapGuides = Self.snapGuides(screens: screens) }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated {
                    self?.finish(nil)
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }

        // A still backdrop is captured before the dimming goes up. It is shown
        // when Freeze Screen is on and feeds the pixel magnifier.
        let needsBackdrop = CaptureSettings.freezeScreen || CaptureSettings.showsMagnifier
        let backdrops = needsBackdrop ? Self.freezeBackdrops(for: screens) : [:]

        for (index, screen) in screens.enumerated() {
            let window = SelectionWindow(screen: screen, backdrop: backdrops[screen.displayID],
                                         showsBackdrop: CaptureSettings.freezeScreen, state: state)
            window.onCommit = { [weak self] rect in self?.finish(rect) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            windows.append(window)
            window.present(initiallyActive: index == 0)
        }
        // Remember who owned the keyboard before the overlay takes it, so a
        // cancelled selection can hand it back. Captured before `activate`.
        capturePreviousFrontmost()
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        CaptureCoordinator.textLog.info("selection overlay presented")
    }

    /// Edges of other apps' visible windows plus every display frame.
    private static func snapGuides(screens: [NSScreen]) -> SelectionGeometry.SnapGuides {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = info.compactMap { window -> CGRect? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 50, rect.height >= 50 else { return nil }
            return rect
        }
        return SelectionGeometry.SnapGuides(rects: windows + screens.map(\.sckFrame))
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            state.commandDown = event.modifierFlags.contains(.command)
            state.shiftDown = event.modifierFlags.contains(.shift)
            state.optionDown = event.modifierFlags.contains(.option)
            return event
        }
        // The inline ratio list owns arrows / Return / Esc while it is open.
        if state.ratioMenuOpen, !(NSApp.keyWindow?.firstResponder is NSText) {
            switch event.keyCode {
            case 53: state.ratioMenuOpen = false; return nil
            case 125: state.moveRatioHighlight(by: 1); return nil
            case 126: state.moveRatioHighlight(by: -1); return nil
            case 36, 76: state.chooseHighlightedRatio(); return nil
            default: break
            }
        }
        if event.keyCode == 53 { finish(nil); return nil }
        // Typing into the W × H fields must not switch modes.
        if NSApp.keyWindow?.firstResponder is NSText { return event }
        guard !state.isDragging else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        // ⌘R opens the aspect-ratio list (Space/Return are taken by the overlay).
        if state.integrated, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "r" {
            state.toggleRatioMenu()
            return nil
        }
        guard modifiers.isEmpty else { return event }

        if event.keyCode == 49 { // Space: window ↔ area
            activate(state.captureMode == .window ? .area : .window)
            return nil
        }
        if state.integrated {
            if let mode = IntegratedCaptureMode.forKey(event.charactersIgnoringModifiers ?? "") {
                activate(mode)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                commitPending()
                return nil
            }
            if let pending = state.pendingRect,
               let moved = AllInOneSelection.nudged(pending, keyCode: event.keyCode,
                                                    large: event.modifierFlags.contains(.shift),
                                                    within: displayFrame(containing: pending)) {
                state.pendingRect = moved
                return nil
            }
        }
        return event
    }

    /// Mode buttons and single-letter keys share this path. With a pending
    /// selection an area-based mode captures immediately (CleanShot AIO).
    private func activate(_ mode: IntegratedCaptureMode) {
        switch mode {
        case .fullscreen:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
            guard let screen else { return }
            state.captureMode = .fullscreen
            finish(screen.sckFrame)
        case .window:
            state.captureMode = .window
            state.mode = .window
            state.pendingRect = nil
        default:
            state.captureMode = mode
            state.mode = .area
            if let pending = state.pendingRect { finish(pending) }
        }
    }

    private func commitPending() {
        guard let pending = state.pendingRect else { return }
        if state.captureMode == .window || state.captureMode == .fullscreen { state.captureMode = .area }
        finish(pending)
    }

    private func displayFrame(containing rect: CGRect) -> CGRect {
        let frames = NSScreen.screens.map(\.sckFrame)
        return frames.max { $0.intersection(rect).width * $0.intersection(rect).height <
                            $1.intersection(rect).width * $1.intersection(rect).height } ?? rect
    }

    private func finish(_ rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor); localKeyMonitor = nil }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
        state.activate = nil
        state.commitPending = nil
        NSCursor.arrow.set()
        // Tear the overlays down before handing the rect back: the capture that
        // follows must not photograph the selection UI itself.
        let toClose = windows
        windows = []
        for window in toClose { window.orderOut(nil) }
        if rect == nil {
            // Hand activation back to the app the overlay took it from. This
            // runs after the windows are ordered out so the previous app is not
            // asked to become active while a screen-saver-level panel still
            // covers it. It is a no-op when the user has since switched apps.
            restorePreviousFrontmostIfNeeded()
            // Cancellation does not start a capture. Notify immediately instead
            // of leaving Escape waiting on an already-busy main queue.
            completion(nil)
        } else {
            // A successful capture must not pull focus back: the capture target
            // (or whatever the user is doing now) keeps the keyboard.
            previousFrontmost = nil
            // A successful capture requires one runloop turn for the selection
            // windows to disappear before ScreenCaptureKit reads any pixels.
            DispatchQueue.main.async { [completion] in
                completion(rect)
            }
        }
    }

    /// Snapshots the frontmost app before `NSApp.activate` takes over.
    ///
    /// If AOM is already frontmost there is nothing to restore, so the snapshot
    /// stays `nil` and no duplicate activation is attempted later.
    private func capturePreviousFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            previousFrontmost = nil
            return
        }
        previousFrontmost = SelectionOverlayFocusPolicy.Snapshot(
            processIdentifier: front.processIdentifier,
            bundleIdentifier: front.bundleIdentifier)
    }

    /// Reactivates the app the overlay took activation from, if it is still the
    /// right thing to do. Consumes the snapshot so it runs at most once.
    private func restorePreviousFrontmostIfNeeded() {
        guard let previous = previousFrontmost else { return }
        previousFrontmost = nil
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let current = NSWorkspace.shared.frontmostApplication.map {
            SelectionOverlayFocusPolicy.Snapshot(processIdentifier: $0.processIdentifier,
                                                 bundleIdentifier: $0.bundleIdentifier)
        }
        guard SelectionOverlayFocusPolicy.shouldRestore(previous: previous, current: current,
                                                        ownProcessIdentifier: ownPID) else { return }
        // Prefer the exact process; fall back to another instance of the same
        // bundle only if the original has quit. A terminated process is never
        // activated: `NSRunningApplication(processIdentifier:)` already returns
        // nil for a dead pid, and `isTerminated` covers an app that is exiting.
        let app = NSRunningApplication(processIdentifier: previous.processIdentifier)
            ?? previous.bundleIdentifier.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                    .first { !$0.isTerminated }
            }
        guard let app, !app.isTerminated else { return }
        _ = app.activate(options: [])
    }

    /// A still image of each display, used as the overlay's backdrop.
    ///
    /// This runs before the dim windows exist, so the image contains the desktop
    /// and not the overlay. A failure here degrades to a live backdrop rather
    /// than blocking the capture.
    private static func freezeBackdrops(for screens: [NSScreen]) -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in screens {
            guard let image = CGDisplayCreateImage(screen.displayID) else { continue }
            result[screen.displayID] = image
        }
        return result
    }
}

/// Pure decision logic for returning keyboard focus after a cancelled
/// selection. Kept free of AppKit objects so it can be unit-tested
/// deterministically; the controller supplies the live snapshots.
enum SelectionOverlayFocusPolicy {
    /// A frontmost application, identified by process and bundle.
    struct Snapshot: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    /// Whether a cancelled overlay should reactivate `previous`.
    ///
    /// Restore only when the overlay actually took activation from another app,
    /// the user has not switched away in the meantime (AOM is still frontmost),
    /// and we are not already back on the previous app — the last case would be
    /// a duplicate activation.
    static func shouldRestore(previous: Snapshot?, current: Snapshot?,
                              ownProcessIdentifier: pid_t) -> Bool {
        guard let previous else { return false }
        guard previous.processIdentifier != ownProcessIdentifier else { return false }
        guard let current else { return false }
        return current.processIdentifier == ownProcessIdentifier
    }
}

/// Pure helpers for the All-In-One selection, kept AppKit-free for tests.
enum AllInOneSelection {
    /// Arrow-key nudge (1 pt, 10 pt with Shift), clamped inside `bounds`.
    /// Returns nil for keys that are not arrows.
    static func nudged(_ rect: CGRect, keyCode: UInt16, large: Bool, within bounds: CGRect) -> CGRect? {
        let step: CGFloat = large ? 10 : 1
        var moved = rect
        switch keyCode {
        case 123: moved.origin.x -= step   // ←
        case 124: moved.origin.x += step   // →
        case 125: moved.origin.y += step   // ↓ (top-left origin)
        case 126: moved.origin.y -= step   // ↑
        default: return nil
        }
        return clamped(moved, within: bounds)
    }

    /// Keeps the rectangle's size where possible and its origin inside `bounds`.
    static func clamped(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        let width = min(max(1, rect.width), bounds.width)
        let height = min(max(1, rect.height), bounds.height)
        let x = min(max(bounds.minX, rect.minX), bounds.maxX - width)
        let y = min(max(bounds.minY, rect.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Applies W × H pixel values typed into the toolbar, anchored at the origin.
    static func resized(_ rect: CGRect, pixelWidth: Int?, pixelHeight: Int?,
                        scale: CGFloat, within bounds: CGRect) -> CGRect {
        let s = max(1, scale)
        var result = rect
        if let pixelWidth, pixelWidth > 0 { result.size.width = CGFloat(pixelWidth) / s }
        if let pixelHeight, pixelHeight > 0 { result.size.height = CGFloat(pixelHeight) / s }
        return clamped(result, within: bounds)
    }
}

/// One display's worth of selection overlay.
private final class SelectionWindow: NSPanel {
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// Named `hostScreen` rather than `screen` because `NSPanel` already has a
    /// `screen` property that means something else.
    private let hostScreen: NSScreen
    private let state: SelectionState

    init(screen: NSScreen, backdrop: CGImage?, showsBackdrop: Bool, state: SelectionState) {
        self.state = state
        self.hostScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Presenting over a full-screen app or a game is the common case for a
        // screenshot, so this must not be suppressed by app activation rules.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setAccessibilityLabel("Capture selection")

        let view = SelectionView(state: state, screen: hostScreen, backdrop: backdrop,
                                 showsBackdrop: showsBackdrop,
                                 onCommit: { [weak self] rect in self?.onCommit?(rect) },
                                 onCancel: { [weak self] in self?.onCancel?() })
        contentView = FirstMouseHostingView(rootView: view)
    }

    /// The overlay appears over another app without activating AOM. The very
    /// first press must start the drag instead of only focusing the panel.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    // The overlay is a tool, not a document window: it must be able to take key
    // focus to receive Escape and arrow keys.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func present(initiallyActive: Bool) {
        setFrame(hostScreen.frame, display: true)
        orderFrontRegardless()
    }
}

/// All-In-One toolbar modes, in CleanShot's order with its single-letter keys.
enum IntegratedCaptureMode: String, CaseIterable {
    case area = "Area"
    case fullscreen = "Fullscreen"
    case window = "Window"
    case scrolling = "Scrolling"
    case timer = "Self-Timer"
    case text = "Text"
    case recording = "Record"

    var icon: String {
        switch self {
        case .area: return "viewfinder"
        case .fullscreen: return "display"
        case .window: return "macwindow"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .timer: return "timer"
        case .text: return "text.viewfinder"
        case .recording: return "record.circle"
        }
    }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .fullscreen: return "Capture Fullscreen"
        case .window: return "Capture Window"
        case .scrolling: return "Scrolling Capture"
        case .timer: return "Self-Timer"
        case .text: return "Capture Text"
        case .recording: return "Record Screen"
        }
    }

    var keyLabel: String {
        switch self {
        case .area: return "A"
        case .fullscreen: return "F"
        case .window: return "Space/W"
        case .scrolling: return "S"
        case .timer: return "T"
        case .text: return "O"
        case .recording: return "R"
        }
    }

    /// Tooltip text, e.g. "Capture Window (Space/W)".
    var tooltip: String { "\(title) (\(keyLabel))" }

    static func forKey(_ characters: String) -> IntegratedCaptureMode? {
        switch characters.lowercased() {
        case "a": return .area
        case "f": return .fullscreen
        case "w": return .window
        case "s": return .scrolling
        case "t": return .timer
        case "o": return .text
        case "r": return .recording
        default: return nil
        }
    }

    /// Modes that act on a dragged rectangle.
    var usesArea: Bool { self != .fullscreen && self != .window }
}

/// CleanShot X style selection modes: drag rectangle area or press Space to select a window.
enum SelectionOverlayMode {
    case area
    case window
}

struct WindowCandidate: Equatable {
    let windowID: CGWindowID
    let sckRect: CGRect      // Global rect in ScreenCaptureKit coordinates
    let localRect: CGRect    // View-local rect on this screen
    let appName: String
    let title: String
}

/// Shared drag state for all overlay windows.
private final class SelectionState: ObservableObject {
    @Published var captureMode: IntegratedCaptureMode = .area
    var integrated = false
    @Published var mode: SelectionOverlayMode = .area
    @Published var hoveredWindow: WindowCandidate?
    @Published var anchor: CGPoint?
    @Published var current: CGPoint?
    @Published var isDragging = false
    /// All-In-One: a finished drag awaiting a mode / Return (global SCK points).
    @Published var pendingRect: CGRect?
    @Published var commandDown = false
    @Published var shiftDown = false
    @Published var optionDown = false
    /// All-In-One aspect-ratio lock, remembered across sessions.
    @Published var aspectRatio: SelectionAspectRatio = SelectionAspectRatioStore.load()
    /// The inline ratio list under the toolbar (an NSMenu would open below the
    /// screen-saver-level overlay, so the list is drawn in the overlay itself).
    @Published var ratioMenuOpen = false
    @Published var ratioHighlight = 0
    /// Set while a pending-selection handle is being dragged.
    @Published var activeHandle: SelectionHandle?
    /// The display whose window shows the All-In-One toolbar.
    @Published var activeDisplayID: CGDirectDisplayID = 0
    var activate: ((IntegratedCaptureMode) -> Void)?
    var commitPending: (() -> Void)?
    /// Union of every display, in global top-left points.
    var desktopBounds: CGRect = .infinite
    /// Window and display edges an area selection snaps to (empty = off).
    var snapGuides = SelectionGeometry.SnapGuides()

    /// Snapping applies to free-form drags only: never with a ratio lock, from
    /// the centre (⌥) or while ⌃ is held.
    func snapping(_ point: CGPoint) -> CGPoint {
        guard aspectRatio.value == nil, !optionDown,
              !NSEvent.modifierFlags.contains(.control) else { return point }
        return SelectionGeometry.snapped(point, to: snapGuides)
    }

    /// Freeform, presets, then the custom entry (current custom ratio or 16:9 seed).
    var ratioChoices: [SelectionAspectRatio] { [.freeform] + SelectionAspectRatio.presets }

    /// The rectangle the user has drawn so far, normalized so a drag in any
    /// direction produces a positive-size rect. The ratio lock and ⌥ (from
    /// centre) apply while dragging.
    var rect: CGRect? {
        guard let anchor, let current else { return nil }
        return SelectionGeometry.dragRect(anchor: anchor, current: current, ratio: aspectRatio.value,
                                          fromCenter: optionDown, bounds: desktopBounds)
    }

    func toggleRatioMenu() {
        ratioMenuOpen.toggle()
        if ratioMenuOpen {
            ratioHighlight = ratioChoices.firstIndex(of: aspectRatio) ?? ratioChoices.count
        }
    }

    func moveRatioHighlight(by delta: Int) {
        // The last row (index == choices.count) is "Custom…".
        ratioHighlight = min(max(0, ratioHighlight + delta), ratioChoices.count)
    }

    func chooseHighlightedRatio() {
        if ratioHighlight < ratioChoices.count {
            choose(ratio: ratioChoices[ratioHighlight])
        } else {
            showsCustomRatio = true
        }
    }

    @Published var showsCustomRatio = false

    /// Locks the ratio, remembers it, and reshapes a pending selection.
    func choose(ratio: SelectionAspectRatio) {
        aspectRatio = ratio
        SelectionAspectRatioStore.save(ratio)
        ratioMenuOpen = false
        showsCustomRatio = false
        if let pending = pendingRect {
            let bounds = NSScreen.screens.map(\.sckFrame)
                .filter { $0.intersects(pending) }
                .reduce(CGRect.null) { $0.union($1) }
            pendingRect = SelectionGeometry.applying(ratio: ratio.value, to: pending,
                                                     within: bounds.isNull ? desktopBounds : bounds)
        }
    }
}

/// Draws the dim layer, the live selection rectangle, its dimensions, and the
/// crosshair guides, plus CleanShot X-style window highlight when Space is pressed.
private struct SelectionView: View {
    @ObservedObject var state: SelectionState
    let screen: NSScreen
    let backdrop: CGImage?
    let showsBackdrop: Bool
    let onCommit: (CGRect) -> Void
    let onCancel: () -> Void

    /// Tracks the pointer for the crosshair, magnifier, and window detection.
    @State private var pointer: CGPoint = .zero
    @State private var pointerInside = false
    /// Set when a drag started inside the pending selection (move, not redraw).
    @State private var moveOrigin: CGRect?
    /// The pending selection when a handle drag started.
    @State private var resizeOrigin: CGRect?

    private var selectionRect: CGRect? { state.rect.map { localRect(for: $0) } }
    private var pendingLocal: CGRect? {
        guard let pending = state.pendingRect, pending.intersects(screen.sckFrame) else { return nil }
        return localRect(for: pending)
    }
    private var hoveredTarget: WindowCandidate? {
        guard let target = state.hoveredWindow else { return nil }
        return WindowCandidate(windowID: target.windowID, sckRect: target.sckRect, localRect: localRect(for: target.sckRect), appName: target.appName, title: target.title)
    }
    private var showsToolbar: Bool { state.integrated && state.activeDisplayID == screen.displayID }
    private var showsCrosshair: Bool {
        state.mode == .area && !state.isDragging && pendingLocal == nil && pointerInside
            && CaptureSettings.crosshairMode.showsCrosshair(commandPressed: state.commandDown)
    }
    private var showsMagnifier: Bool {
        state.mode == .area && pointerInside && moveOrigin == nil
            && (CaptureSettings.showsMagnifier || state.shiftDown)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                canvas(size: geometry.size)

                // Controls sit above the gesture layer so clicks and typing in
                // the toolbar never start a new selection.
                if showsToolbar {
                    let position = toolbarPosition(in: geometry.size)
                    AllInOneToolbar(state: state, screen: screen, opensUpward: position.y > geometry.size.height / 2,
                                    onCancel: onCancel)
                        .fixedSize()
                        .position(position)
                } else if !state.integrated {
                    instructionBadge
                }
            }
        }
    }

    private func canvas(size: CGSize) -> some View {
            ZStack(alignment: .top) {
                backdropLayer(size: size)
                dimLayer(size: size)

                // CleanShot X: Window selection highlight when Space is pressed
                if state.mode == .window, let target = hoveredTarget {
                    windowHighlight(target: target)
                }

                // Area drag selection / All-In-One pending selection
                if state.mode == .area, let rect = activeRect {
                    border(rect: rect, showsHandles: state.integrated && !(state.isDragging && moveOrigin == nil)
                                                     && pendingLocal != nil)
                }
                if state.mode == .area, state.isDragging, moveOrigin == nil, let rect = selectionRect {
                    dimensionLabel(rect: rect)
                }
                if state.mode == .area, state.activeHandle != nil, let rect = pendingLocal {
                    dimensionLabel(rect: rect)
                }

                // Crosshairs & cursor UI
                if showsCrosshair {
                    crosshair(size: size)
                } else if state.mode == .window && pointerInside {
                    windowCursor(size: size)
                }

                if showsMagnifier {
                    MagnifierView(image: backdrop, pointer: pointer, screen: screen)
                        .position(magnifierPosition(in: size))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(state.mode == .area ? dragGesture : nil)
            .onTapGesture {
                if state.mode == .window, let target = hoveredTarget {
                    onCommit(target.sckRect)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    pointer = point
                    pointerInside = true
                    if state.activeDisplayID != screen.displayID, state.pendingRect == nil {
                        state.activeDisplayID = screen.displayID
                    }
                    if state.mode == .window {
                        detectWindowUnderPointer(localPoint: point)
                    } else {
                        updateCursor(at: point)
                    }
                case .ended:
                    pointerInside = false
                }
            }
            .onChange(of: state.mode) { _, mode in
                let mouse = NSEvent.mouseLocation
                if mode == .window, screen.frame.contains(mouse) {
                    let point = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
                    detectWindowUnderPointer(localPoint: point)
                }
            }
    }

    /// The rectangle currently drawn: the live drag, else the pending selection.
    private var activeRect: CGRect? {
        if state.isDragging, moveOrigin == nil, let rect = selectionRect { return rect }
        return pendingLocal
    }

    // MARK: - Layers

    @ViewBuilder
    private func backdropLayer(size: CGSize) -> some View {
        if showsBackdrop, let backdrop {
            Image(decorative: backdrop, scale: screen.backingScaleFactor)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .ignoresSafeArea()
        }
    }

    private func dimLayer(size: CGSize) -> some View {
        Group {
            if state.mode == .area, let rect = activeRect {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            } else if state.mode == .window, let target = hoveredTarget {
                // Cut out the hovered window from the dimming layer
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRoundedRect(in: target.localRect, cornerSize: CGSize(width: 8, height: 8),
                                        style: .continuous)
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
            } else {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - CleanShot X Window Selection UI

    @ViewBuilder
    private func windowHighlight(target: WindowCandidate) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: target.localRect.width, height: target.localRect.height)
                .position(x: target.localRect.midX, y: target.localRect.midY)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2.5)
                .frame(width: target.localRect.width, height: target.localRect.height)
                .position(x: target.localRect.midX, y: target.localRect.midY)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)

            // Window Information Pill (App Name, Window Title, Dimensions)
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(target.appName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                if !target.title.isEmpty {
                    Text("•")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(target.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                }

                Text("\(Int(target.sckRect.width)) × \(Int(target.sckRect.height))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .position(
                x: target.localRect.midX,
                y: max(30, target.localRect.minY - 18)
            )
        }
        .allowsHitTesting(false)
    }

    private func windowCursor(size: CGSize) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "camera.fill")
                .font(.system(size: 13, weight: .bold))
            Text("Click to capture")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor, in: Capsule())
        .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)
        .position(x: min(pointer.x + 65, size.width - 70), y: min(pointer.y + 24, size.height - 20))
        .allowsHitTesting(false)
    }

    private func border(rect: CGRect, showsHandles: Bool) -> some View {
        ZStack {
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)

            if showsHandles {
                // Eight resize handles (corners + edge midpoints) on the pending
                // All-In-One selection. Hit testing lives in the canvas gesture
                // (`SelectionHandle.hit`) so a handle drag never starts a new area.
                ForEach(SelectionHandle.allCases, id: \.self) { handle in
                    let point = handle.position(in: rect)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(width: handle.isCorner ? 9 : 8, height: handle.isCorner ? 9 : 8)
                        .scaleEffect(state.activeHandle == handle ? 1.3 : 1)
                        .shadow(color: Color.black.opacity(0.6), radius: 1)
                        .position(point)
                        .accessibilityLabel(handle.accessibilityName)
                        .accessibilityHint("Drag to resize. Shift keeps the ratio, Option resizes from the center.")
                }
            } else {
                // Corner marks while a new area is being dragged.
                ForEach([-1.0, 1.0], id: \.self) { hX in
                    ForEach([-1.0, 1.0], id: \.self) { hY in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.black.opacity(0.6), radius: 1)
                            .position(
                                x: rect.midX + hX * (rect.width / 2),
                                y: rect.midY + hY * (rect.height / 2)
                            )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var instructionBadge: some View {
        HStack(spacing: 7) {
            if state.mode == .window {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Click a window to capture it.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Space for area · Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Drag to select capture area.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Space to select a window · Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 3)
        .padding(.top, 24)
        .allowsHitTesting(false)
    }

    /// W × H readout that follows the cursor while dragging.
    private func dimensionLabel(rect: CGRect) -> some View {
        let pixels = pixelSize(for: rect)
        return Text("\(Int(pixels.width)) × \(Int(pixels.height))")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            .position(cursorLabelPosition())
            .allowsHitTesting(false)
    }

    private func crosshair(size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: pointer.x, y: 0))
                path.addLine(to: CGPoint(x: pointer.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: pointer.y))
                path.addLine(to: CGPoint(x: size.width, y: pointer.y))
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)

            // A small coordinate readout beside the cursor
            Text("\(Int((pointer.x * screen.backingScaleFactor).rounded())), \(Int((pointer.y * screen.backingScaleFactor).rounded()))")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .position(x: pointer.x + 52, y: pointer.y + 16)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if state.ratioMenuOpen { state.ratioMenuOpen = false }
                if state.anchor == nil && moveOrigin == nil && resizeOrigin == nil {
                    if state.integrated, let pending = state.pendingRect,
                       let handle = SelectionHandle.hit(value.startLocation, in: localRect(for: pending)) {
                        // A handle on the pending selection resizes it.
                        resizeOrigin = pending
                        state.activeHandle = handle
                    } else if state.integrated, let pending = state.pendingRect,
                       localRect(for: pending).contains(value.startLocation) {
                        // In All-In-One, dragging inside the pending selection moves it.
                        moveOrigin = pending
                        NSCursor.closedHand.set()
                    } else {
                        state.anchor = state.snapping(globalRect(for: CGRect(origin: value.startLocation, size: .zero)).origin)
                    }
                }
                if let origin = resizeOrigin, let handle = state.activeHandle {
                    let flags = NSEvent.modifierFlags
                    // A ratio lock always applies; ⇧ keeps the current ratio otherwise.
                    let ratio = state.aspectRatio.value
                        ?? (flags.contains(.shift) && origin.height > 0 ? origin.width / origin.height : nil)
                    let point = globalRect(for: CGRect(origin: value.location, size: .zero)).origin
                    state.pendingRect = SelectionGeometry.resize(origin, handle: handle, to: point, ratio: ratio,
                                                                 fromCenter: flags.contains(.option),
                                                                 bounds: clampBounds(for: origin))
                    pointer = value.location
                    handle.cursor.set()
                    return
                }
                if let origin = moveOrigin {
                    let moved = origin.offsetBy(dx: value.translation.width, dy: value.translation.height)
                    state.pendingRect = AllInOneSelection.clamped(moved, within: screen.sckFrame)
                    return
                }
                let mouse = NSEvent.mouseLocation
                state.optionDown = NSEvent.modifierFlags.contains(.option)
                state.current = state.snapping(CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y))
                state.isDragging = true
                pointer = value.location
            }
            .onEnded { _ in
                if resizeOrigin != nil {
                    resizeOrigin = nil
                    state.activeHandle = nil
                    return
                }
                if moveOrigin != nil {
                    moveOrigin = nil
                    NSCursor.openHand.set()
                    return
                }
                let committed = state.rect
                state.isDragging = false
                state.anchor = nil
                state.current = nil
                guard let rect = committed, rect.width >= 2, rect.height >= 2 else { return }
                if state.integrated {
                    // CleanShot AIO keeps the area; a mode or Return captures it.
                    state.pendingRect = rect
                    state.activeDisplayID = screen.displayID
                } else {
                    onCommit(rect)
                }
            }
    }

    /// Resizing stays on the display(s) the selection already occupies.
    private func clampBounds(for rect: CGRect) -> CGRect {
        let frames = NSScreen.screens.map(\.sckFrame).filter { $0.intersects(rect) }
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? screen.sckFrame : union
    }

    /// Resize / move / crosshair cursor for the pointer over the pending selection.
    private func updateCursor(at point: CGPoint) {
        guard state.integrated, state.mode == .area, !state.isDragging, state.activeHandle == nil,
              moveOrigin == nil else { return }
        guard let pending = pendingLocal else { return }
        if let handle = SelectionHandle.hit(point, in: pending) {
            handle.cursor.set()
        } else if pending.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Window Detection (CleanShot X style)

    private func detectWindowUnderPointer(localPoint: CGPoint) {
        let globalPt = globalRect(for: CGRect(origin: localPoint, size: .zero)).origin
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            state.hoveredWindow = nil
            return
        }

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ownPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard rect.width >= 50, rect.height >= 50 else { continue }

            if rect.contains(globalPt) {
                let wid = (info[kCGWindowNumber as String] as? CGWindowID) ?? 0
                let appName = (info[kCGWindowOwnerName as String] as? String) ?? "Application"
                let title = (info[kCGWindowName as String] as? String) ?? ""
                let local = localRect(for: rect)

                state.hoveredWindow = WindowCandidate(
                    windowID: wid,
                    sckRect: rect,
                    localRect: local,
                    appName: appName,
                    title: title
                )
                return
            }
        }
        state.hoveredWindow = nil
    }

    private func localRect(for sck: CGRect) -> CGRect {
        let frame = screen.sckFrame
        return CGRect(x: sck.minX - frame.minX, y: sck.minY - frame.minY, width: sck.width, height: sck.height)
    }

    // MARK: - Geometry

    /// Converts a view-local rect to a global top-left-origin rect in points
    /// matching ScreenCaptureKit / SCDisplay coordinates.
    private func globalRect(for local: CGRect) -> CGRect {
        let frame = screen.sckFrame
        return CGRect(x: frame.minX + local.minX, y: frame.minY + local.minY,
                      width: local.width, height: local.height)
    }

    /// Converts a local rect's size into device pixels.
    private func pixelSize(for rect: CGRect) -> CGSize {
        let global = globalRect(for: rect)
        let scale = NSScreen.screens.filter { $0.sckFrame.intersects(global) }
            .map(\.backingScaleFactor).max() ?? screen.backingScaleFactor
        return CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    private func cursorLabelPosition() -> CGPoint {
        // Bottom-right of the cursor, flipped to stay on screen near the edges.
        let size = screen.frame.size
        let x = pointer.x + 58 > size.width - 8 ? pointer.x - 50 : pointer.x + 50
        let y = pointer.y + 30 > size.height - 8 ? pointer.y - 22 : pointer.y + 26
        return CGPoint(x: x, y: y)
    }

    private func toolbarPosition(in size: CGSize) -> CGPoint {
        let clampX: (CGFloat) -> CGFloat = { min(max($0, 260), size.width - 260) }
        if let rect = pendingLocal {
            // Below the selection when there is room, else above, else inside.
            if rect.maxY + 72 < size.height { return CGPoint(x: clampX(rect.midX), y: rect.maxY + 40) }
            if rect.minY - 72 > 0 { return CGPoint(x: clampX(rect.midX), y: rect.minY - 40) }
            return CGPoint(x: clampX(rect.midX), y: rect.maxY - 48)
        }
        return CGPoint(x: size.width / 2, y: size.height - 120)
    }

    private func magnifierPosition(in size: CGSize) -> CGPoint {
        // Keep the loupe away from the edges it would otherwise hang off.
        let x = pointer.x + 200 > size.width ? pointer.x - 100 : pointer.x + 100
        let y = pointer.y + 200 > size.height ? pointer.y - 100 : pointer.y + 100
        return CGPoint(x: min(max(x, 80), size.width - 80), y: min(max(y, 90), size.height - 90))
    }
}

/// CleanShot-style All-In-One control bar: seven mode buttons, W × H fields
/// for the pending selection, a hint line and cancel.
private struct AllInOneToolbar: View {
    @ObservedObject var state: SelectionState
    let screen: NSScreen
    var opensUpward = false
    let onCancel: () -> Void
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var focusedField: SizeField?
    private enum SizeField { case width, height }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(IntegratedCaptureMode.allCases.enumerated()), id: \.element) { index, mode in
                    if index == 1 || index == 3 || index == 6 { separator }
                    modeButton(mode)
                }
                separator
                sizeFields
                ratioButton
                separator
                ToolbarIconButton(symbol: "xmark", label: "Cancel", help: "Cancel (Esc)", selected: false,
                                  action: onCancel)
            }
            .padding(6)
            .aomFloatingSurface(.bar, radius: 14)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            // Overlaid so opening the list never moves the toolbar itself.
            .overlay(alignment: opensUpward ? .bottomTrailing : .topTrailing) {
                if state.ratioMenuOpen {
                    SelectionRatioList(state: state)
                        .offset(x: -44, y: opensUpward ? -50 : 50)
                }
            }

            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.66), in: Capsule())
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .controlSize(.regular)
        .onAppear(perform: syncFields)
        .onChange(of: state.pendingRect) { _, _ in if focusedField == nil { syncFields() } }
    }

    private var hint: String {
        if state.captureMode == .window { return "Click a window to capture it. Press Space for area." }
        if state.pendingRect != nil {
            return "Press Return or choose a mode to capture. Drag inside to move, handles to resize (⇧ ratio, ⌥ center)."
        }
        switch state.captureMode {
        case .recording: return "Drag to select the area to record."
        case .scrolling: return "Drag to select the area to scroll-capture."
        case .text: return "Drag to select the text to recognize."
        case .timer: return "Drag to select capture area. The timer starts after you confirm."
        default: return "Drag to select capture area."
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func modeButton(_ mode: IntegratedCaptureMode) -> some View {
        ToolbarIconButton(symbol: mode.icon, label: mode.title, help: mode.tooltip,
                          selected: state.captureMode == mode) {
            state.activate?(mode)
        }
    }

    private var scale: CGFloat { screen.backingScaleFactor }

    private var sizeFields: some View {
        HStack(spacing: 4) {
            TextField("W", text: $widthText)
                .focused($focusedField, equals: .width)
                .accessibilityLabel("Selection width in pixels")
                .help("Width in pixels")
            Text("×").foregroundStyle(.secondary)
            TextField("H", text: $heightText)
                .focused($focusedField, equals: .height)
                .accessibilityLabel("Selection height in pixels")
                .help("Height in pixels")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13).monospacedDigit())
        .multilineTextAlignment(.center)
        .frame(width: 136)
        .disabled(state.pendingRect == nil)
        .onSubmit(applyFields)
        .onChange(of: focusedField) { old, _ in if old != nil { applyFields() } }
    }

    private func syncFields() {
        guard let rect = state.pendingRect else { widthText = ""; heightText = ""; return }
        widthText = "\(Int((rect.width * scale).rounded()))"
        heightText = "\(Int((rect.height * scale).rounded()))"
    }

    /// Ratio lock button beside W × H (CleanShot `OneSizeControl` ratio button).
    private var ratioButton: some View {
        let locked = !state.aspectRatio.isFreeform
        return Button { state.toggleRatioMenu() } label: {
            HStack(spacing: 3) {
                Image(systemName: locked ? "lock.fill" : "aspectratio")
                    .font(.system(size: 11, weight: .semibold))
                Text(locked ? state.aspectRatio.title : "Ratio")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(locked ? Color.white : Color.primary)
            .padding(.horizontal, 7).frame(height: 26)
            .background(locked ? Color.accentColor : Color.white.opacity(state.ratioMenuOpen ? 0.16 : 0.08),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .help("Aspect ratio (⌘R): \(state.aspectRatio.menuTitle)")
        .accessibilityLabel("Aspect ratio")
        .accessibilityValue(state.aspectRatio.menuTitle)
        .accessibilityHint("Opens the ratio list. Shortcut Command-R.")
    }

    private func applyFields() {
        guard let rect = state.pendingRect else { return }
        let currentPixels = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let typedW = Int(widthText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let typedH = Int(heightText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let size = SelectionGeometry.lockedSize(width: typedW, height: typedH, current: currentPixels,
                                                ratio: state.aspectRatio.value)
        state.pendingRect = AllInOneSelection.resized(
            rect, pixelWidth: size.width > 0 ? Int(size.width) : nil,
            pixelHeight: size.height > 0 ? Int(size.height) : nil,
            scale: scale, within: screen.sckFrame)
        syncFields()
    }
}

/// The inline aspect-ratio list (Freeform, presets, Custom…). Rows are buttons;
/// ↑/↓ + Return and Esc work through the overlay's key monitor.
private struct SelectionRatioList: View {
    @ObservedObject var state: SelectionState
    @State private var customWidth = ""
    @State private var customHeight = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(state.ratioChoices.enumerated()), id: \.element) { index, ratio in
                row(title: ratio.title, selected: state.aspectRatio == ratio, highlighted: state.ratioHighlight == index) {
                    state.choose(ratio: ratio)
                }
                if index == 0 { Divider().padding(.vertical, 2) }
            }
            Divider().padding(.vertical, 2)
            row(title: state.aspectRatio.isCustom ? "Custom (\(state.aspectRatio.title))…" : "Custom…",
                selected: state.aspectRatio.isCustom,
                highlighted: state.ratioHighlight == state.ratioChoices.count) {
                state.showsCustomRatio.toggle()
            }
            if state.showsCustomRatio {
                HStack(spacing: 4) {
                    TextField("W", text: $customWidth)
                        .accessibilityLabel("Custom ratio width")
                    Text(":").foregroundStyle(.secondary)
                    TextField("H", text: $customHeight)
                        .accessibilityLabel("Custom ratio height")
                    Button("Set") { applyCustom() }
                        .disabled(customRatio == nil)
                        .help("Lock the selection to this custom ratio")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 168)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .onSubmit(applyCustom)
                .onAppear {
                    let seed = state.aspectRatio.isFreeform ? SelectionAspectRatio(width: 16, height: 9) : state.aspectRatio
                    customWidth = "\(Int(seed.width))"
                    customHeight = "\(Int(seed.height))"
                }
            }
        }
        .padding(6)
        .frame(width: 184)
        .aomFloatingSurface(.bar, radius: 12)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aspect ratio list")
    }

    private var customRatio: SelectionAspectRatio? {
        guard let w = Double(customWidth.trimmingCharacters(in: .whitespaces)),
              let h = Double(customHeight.trimmingCharacters(in: .whitespaces)) else { return nil }
        return SelectionAspectRatio.custom(width: w, height: h)
    }

    private func applyCustom() {
        guard let ratio = customRatio else { return }
        state.choose(ratio: ratio)
    }

    private func row(title: String, selected: Bool, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(selected ? 1 : 0)
                Text(title).font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .padding(.horizontal, 6).frame(height: 22)
            .background(highlighted ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let label: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : hovering ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Pixel loupe next to the pointer (Show Magnifier setting, or hold Shift).
private struct MagnifierView: View {
    let image: CGImage?
    let pointer: CGPoint
    let screen: NSScreen

    private let side: CGFloat = 120
    /// Odd so the centre pixel is well defined.
    private let pixelCount = 15

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let crop = croppedPixels {
                    Image(decorative: crop, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: side, height: side)
                } else {
                    Color.black.opacity(0.85)
                }
                // Centre pixel outline marks the exact pixel under the pointer.
                let cell = side / CGFloat(pixelCount)
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: cell, height: cell)
                    .shadow(color: .black.opacity(0.8), radius: 0.5)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))

            Text("\(Int((pointer.x * screen.backingScaleFactor).rounded())), \(Int((pointer.y * screen.backingScaleFactor).rounded()))")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.8), in: Capsule())
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityHidden(true)
    }

    /// `pixelCount × pixelCount` device pixels centred on the pointer, clamped
    /// to the display so the loupe never stretches a partial crop.
    private var croppedPixels: CGImage? {
        guard let image else { return nil }
        let scale = CGFloat(image.width) / max(1, screen.frame.width)
        let count = CGFloat(pixelCount)
        let px = (pointer.x * scale).rounded(.down) - (count - 1) / 2
        let py = (pointer.y * scale).rounded(.down) - (count - 1) / 2
        let x = min(max(0, px), CGFloat(image.width) - count)
        let y = min(max(0, py), CGFloat(image.height) - count)
        return image.cropping(to: CGRect(x: x, y: y, width: count, height: count))
    }
}
