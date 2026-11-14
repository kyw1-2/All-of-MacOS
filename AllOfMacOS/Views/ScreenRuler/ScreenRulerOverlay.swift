import AppKit
import QuartzCore

/// The colours, font and line weight one measuring session draws with.
struct ScreenRulerStyle {
    let guide: CGColor
    let fill: CGColor
    let labelText: CGColor
    /// A contrasting edge behind every mark (Increase Contrast).
    let halo: CGColor?
    let increasedContrast: Bool
    let labelFont: NSFont
    let noticeFont: NSFont

    init(options: ScreenRulerOptions, increasedContrast: Bool) {
        let color = AOMRGBAColor(red: options.guideColor.red, green: options.guideColor.green,
                                 blue: options.guideColor.blue, alpha: 1)
        let darkText = Self.prefersDarkText(on: color)
        guide = color.cgColor
        fill = AOMRGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.14).cgColor
        labelText = darkText ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        halo = increasedContrast ? (darkText ? CGColor(gray: 0, alpha: 0.7) : CGColor(gray: 1, alpha: 0.85)) : nil
        self.increasedContrast = increasedContrast
        labelFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        noticeFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    /// White label text unless it falls below 4.5:1 on the guide colour and
    /// black reads better (WCAG relative luminance).
    static func prefersDarkText(on color: AOMRGBAColor) -> Bool {
        func linear(_ value: Double) -> Double {
            let c = min(1, max(0, value))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        let onWhite = 1.05 / (luminance + 0.05)
        let onBlack = (luminance + 0.05) / 0.05
        return onWhite < 4.5 && onBlack > onWhite
    }
}

/// Runs one measuring session: a still of every display in a borderless
/// panel above everything, the ruler drawn over it, and the keys.
///
/// The panels show the capture the session measures, so what the user sees
/// is exactly what is measured (AOM's own windows were left out of it). The
/// panels take every click, so nothing underneath is clicked or activated;
/// AOM is activated only to receive the keys, and the app that was in front
/// gets the keyboard back when the session ends.
@MainActor
final class ScreenRulerOverlayController {
    private(set) static var active: ScreenRulerOverlayController?
    private var session: ScreenRulerSession
    private let images: [CGDirectDisplayID: CGImage]
    private var panels: [ScreenRulerPanel] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previousFrontmost: SelectionOverlayFocusPolicy.Snapshot?
    private var hidCursor = false
    private var didFinish = false
    private var shiftDown = false
    private var lastPointer: CGPoint?
    private var primaryHeight: CGFloat = 0
    private var style: ScreenRulerStyle
    private var notice: (text: String, displayID: CGDirectDisplayID)?
    private var noticeWork: DispatchWorkItem?
    private var shownLiveDisplayID: CGDirectDisplayID?
    private var shownAreaDisplayIDs: Set<CGDirectDisplayID> = []

    init(frames: [ScreenRulerFrame], options: ScreenRulerOptions) {
        session = ScreenRulerSession(snapshots: frames.map(\.snapshot), options: options)
        var images: [CGDirectDisplayID: CGImage] = [:]
        for frame in frames { images[frame.snapshot.display.id] = frame.image }
        self.images = images
        style = ScreenRulerStyle(options: options,
                                 increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    // MARK: - Session

    func present() throws {
        guard Self.active == nil else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ScreenRulerError.noDisplays }
        // Every screen needs its own still; a display that came or went since
        // the capture would be measured from the wrong pixels.
        guard screens.allSatisfy({ images[$0.displayID] != nil && session.snapshot(for: $0.displayID) != nil }),
              screens.count == session.snapshots.count else { throw ScreenRulerError.displaysChanged }
        Self.active = self
        primaryHeight = screens[0].frame.height

        for screen in screens {
            guard let snapshot = session.snapshot(for: screen.displayID), let image = images[screen.displayID] else { continue }
            let panel = ScreenRulerPanel(screen: screen, display: snapshot.display, backdrop: image,
                                         style: style, hidesCursor: session.options.hidesCursor, controller: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        // Activation only routes the keys here; anything of AOM's that it
        // brings back on screen (a closed main window) is put away again.
        capturePreviousFrontmost()
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        AOMOverlayActivation.activateForOverlay()
        let pointer = currentPointer()
        if let keyPanel = panels.first(where: { $0.rulerDisplay.contains(pointer) }) ?? panels.first {
            keyPanel.makeKey()
            keyPanel.makeFirstResponder(keyPanel.rulerView)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            let ours = Set(self.panels.map(ObjectIdentifier.init))
            for window in NSApp.windows where window.isVisible && !ours.contains(ObjectIdentifier(window))
                && !visibleBefore.contains(ObjectIdentifier(window)) {
                window.orderOut(nil)
            }
        }

        installMonitors()
        if session.options.hidesCursor {
            // The cursor can only be hidden by the active app: hide it now, or
            // as soon as the activation above lands.
            if NSApp.isActive {
                hideCursor()
            } else {
                // `hideCursor()` runs once; the observer goes with the others in `finish()`.
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.hideCursor() }
                    })
            }
        } else {
            NSCursor.crosshair.set()
        }
        pointerMoved()
        render(.all)
        showNotice("Drag to measure an area · ⇧ keep · ⌘C copy · Space pt/px · Esc exit", seconds: 4)
        announce("Screen ruler. Move the pointer to measure, drag to measure an area. Escape exits.")
    }

    /// Ends the session: panels, monitors and the cursor go back to normal,
    /// the captured pixels are released, and the app that was in front gets
    /// the keyboard back.
    func finish() {
        guard !didFinish else { return }
        didFinish = true
        session.exit()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        workspaceObservers = []
        noticeWork?.cancel()
        let closing = panels
        panels = []
        for panel in closing {
            panel.orderOut(nil)
            panel.rulerView.controller = nil
        }
        if hidCursor {
            NSCursor.unhide()
            hidCursor = false
        }
        NSCursor.arrow.set()
        if Self.active === self { Self.active = nil }
        restorePreviousFrontmostIfNeeded()
    }

    private func hideCursor() {
        guard !didFinish, !hidCursor else { return }
        NSCursor.hide()
        hidCursor = true
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.handleFlagsChanged(event)
                return event
            }
            return self.handleKeyDown(event) ? nil : event
        }
        // If macOS kept another app active, Esc still ends the session.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.finish() }
        }
        let center = NotificationCenter.default
        // The stills no longer match the screen after any of these.
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
    }

    // MARK: - Input

    /// The pointer in global top-left points, wherever the event landed:
    /// mouse-moved events can reach the key panel while the pointer is over
    /// another display's panel.
    private func currentPointer() -> CGPoint {
        ScreenRulerGeometry.globalPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: primaryHeight)
    }

    func pointerMoved() {
        guard !didFinish, session.phase == .hovering else { return }
        let point = currentPointer()
        guard point != lastPointer else { return }
        lastPointer = point
        session.move(to: point)
        if !session.options.hidesCursor { NSCursor.crosshair.set() }
        render(.live)
    }

    func mouseDown(_ event: NSEvent) {
        guard !didFinish else { return }
        session.press(at: currentPointer())
        render([.live, .area])
    }

    func mouseDragged(_ event: NSEvent) {
        guard !didFinish, session.phase == .dragging else { return }
        let point = currentPointer()
        guard point != lastPointer else { return }
        lastPointer = point
        session.move(to: point)
        render(.area)
    }

    func mouseUp(_ event: NSEvent) {
        guard !didFinish, session.phase == .dragging else { return }
        let point = currentPointer()
        lastPointer = point
        session.release(at: point, keepsAsDrawn: event.modifierFlags.contains(.option))
        render([.live, .area])
        if let area = session.area { announce(ScreenRulerFormat.spoken(.area(area), unit: session.unit)) }
    }

    /// Esc, Space, ⌘C, ⌫ and the arrows. Every key is used while measuring
    /// (see the end), so this returns false only after the session ended.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !didFinish else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 53: // Esc
            finish()
            return true
        case 49 where modifiers.isEmpty: // Space
            session.toggleUnit()
            render(.all)
            announce(session.unit.title)
            return true
        case 51, 117: // ⌫, ⌦: the newest kept measurement
            if session.removeLastHeld() { render(.held) }
            return true
        case 123, 124, 125, 126: // ← → ↓ ↑: one pixel, ten with ⌥
            let step = modifiers.contains(.option) ? 10 : 1
            let (dx, dy): (Int, Int)
            switch event.keyCode {
            case 123: (dx, dy) = (-step, 0)
            case 124: (dx, dy) = (step, 0)
            case 125: (dx, dy) = (0, step)
            default: (dx, dy) = (0, -step)
            }
            nudge(dx: dx, dy: dy)
            return true
        default:
            break
        }
        // ⌘C by key position, so it works with any input source (ANSI C = 8).
        if modifiers == .command, event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy()
            return true
        }
        // Every other key is swallowed while measuring: AOM is only in front
        // to hear these keys, so ⌘Q or ⌘W must not reach its menus (and a
        // stray key must not beep).
        return true
    }

    /// ⇧ going down keeps the measurement in focus on screen.
    func handleFlagsChanged(_ event: NSEvent) {
        guard !didFinish else { return }
        let down = event.modifierFlags.contains(.shift)
        defer { shiftDown = down }
        guard down, !shiftDown, let kept = session.hold() else { return }
        render(.held)
        announce("Kept. " + ScreenRulerFormat.spoken(kept, unit: session.unit))
    }

    private func nudge(dx: Int, dy: Int) {
        guard let target = session.nudgedPointer(dx: dx, dy: dy) else { return }
        // Moving the real pointer keeps the next mouse move from jumping back.
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPointer = target
        session.move(to: target)
        render(session.phase == .dragging ? .area : .live)
    }

    private func copy() {
        guard let text = session.copyText() else {
            showNotice("Nothing to copy yet", seconds: 1.5)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            showNotice("Could not copy to the clipboard", seconds: 2)
            return
        }
        showNotice("Copied \(text)", seconds: 1.6)
        announce("Copied \(text)")
    }

    // MARK: - Drawing

    struct Parts: OptionSet {
        let rawValue: Int
        static let live = Parts(rawValue: 1)
        static let area = Parts(rawValue: 2)
        static let held = Parts(rawValue: 4)
        static let notice = Parts(rawValue: 8)
        static let all: Parts = [.live, .area, .held, .notice]
    }

    private func render(_ parts: Parts) {
        guard !didFinish else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let unit = session.unit
        let both = session.options.showsBothUnits
        let contrast = style.increasedContrast

        if parts.contains(.live) {
            let live = session.phase == .hovering ? session.live : nil
            let color = session.options.showsColor ? session.pointerColorHex : nil
            for panel in panels {
                let id = panel.rulerDisplay.id
                guard let live, live.display.id == id else {
                    // Only the display that showed the crosshair needs clearing.
                    if shownLiveDisplayID == id { panel.rulerView.setLive(nil, color: nil, pointer: nil) }
                    continue
                }
                let pointer = session.pointer.map { panel.rulerDisplay.localPoint(fromGlobal: $0) }
                panel.rulerView.setLive(ScreenRulerLayout.marks(for: live, unit: unit, showsBoth: both,
                                                                increasedContrast: contrast),
                                        color: color, pointer: pointer)
            }
            shownLiveDisplayID = live?.display.id
        }
        if parts.contains(.area) {
            var shown: Set<CGDirectDisplayID> = []
            for panel in panels {
                let id = panel.rulerDisplay.id
                var marks: ScreenRulerMarks?
                if let drag = session.dragArea, drag.display.id == id {
                    marks = ScreenRulerLayout.marks(for: drag, dragging: true, unit: unit, showsBoth: both)
                } else if let area = session.area, area.display.id == id {
                    marks = ScreenRulerLayout.marks(for: area, dragging: false, unit: unit, showsBoth: both)
                }
                if marks != nil { shown.insert(id) }
                if marks != nil || shownAreaDisplayIDs.contains(id) { panel.rulerView.setArea(marks) }
            }
            shownAreaDisplayIDs = shown
        }
        if parts.contains(.held) {
            for panel in panels {
                let marks = session.held.filter { $0.display.id == panel.rulerDisplay.id }
                    .map { ScreenRulerLayout.marks(for: $0, unit: unit, showsBoth: both, increasedContrast: contrast) }
                panel.rulerView.setHeld(marks)
            }
        }
        if parts.contains(.notice) {
            for panel in panels {
                panel.rulerView.setNotice(notice?.displayID == panel.rulerDisplay.id ? notice?.text : nil)
            }
        }
    }

    /// A short message at the bottom of the display under the pointer.
    private func showNotice(_ text: String, seconds: Double) {
        let pointer = session.pointer ?? currentPointer()
        guard let index = session.snapshotIndex(containing: pointer) else { return }
        notice = (text, session.snapshots[index].display.id)
        render(.notice)
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.didFinish else { return }
                self.notice = nil
                self.render(.notice)
            }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func announce(_ text: String) {
        guard let element = panels.first(where: \.isKeyWindow) ?? panels.first else { return }
        element.rulerView.setAccessibilityValue(text)
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Focus

    private func capturePreviousFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            previousFrontmost = nil
            return
        }
        previousFrontmost = SelectionOverlayFocusPolicy.Snapshot(processIdentifier: front.processIdentifier,
                                                                 bundleIdentifier: front.bundleIdentifier)
    }

    /// Gives the keyboard back to the app the session took it from, unless
    /// the user has moved on to another app since.
    private func restorePreviousFrontmostIfNeeded() {
        guard let previous = previousFrontmost else { return }
        previousFrontmost = nil
        let current = NSWorkspace.shared.frontmostApplication.map {
            SelectionOverlayFocusPolicy.Snapshot(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
        }
        guard SelectionOverlayFocusPolicy.shouldRestore(previous: previous, current: current,
                                                        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: previous.processIdentifier),
              !app.isTerminated else { return }
        _ = app.activate(options: [])
    }
}

// MARK: - Panel

/// One display's borderless panel above everything (menu bar and Dock
/// included). It takes every click, so the windows underneath are never
/// clicked or activated.
final class ScreenRulerPanel: NSPanel {
    let rulerDisplay: ScreenRulerDisplay
    let rulerView: ScreenRulerOverlayView

    @MainActor
    init(screen: NSScreen, display: ScreenRulerDisplay, backdrop: CGImage, style: ScreenRulerStyle,
         hidesCursor: Bool, controller: ScreenRulerOverlayController?) {
        let view = ScreenRulerOverlayView(display: display, backdrop: backdrop, style: style, hidesCursor: hidesCursor)
        view.controller = controller
        rulerDisplay = display
        rulerView = view
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        // The still covers the whole display, so the panel is opaque.
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        setAccessibilityLabel("Screen ruler")
        contentView = rulerView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

/// Draws one display's still and the ruler with Core Animation layers: a
/// pointer move only moves a few small layers and changes two labels, so
/// the ruler keeps up with a 120 Hz pointer on a Retina display.
final class ScreenRulerOverlayView: NSView {
    weak var controller: ScreenRulerOverlayController?
    let rulerDisplay: ScreenRulerDisplay
    private let style: ScreenRulerStyle
    private let hidesCursor: Bool
    private let rootLayer = CALayer()
    /// Holds everything the ruler draws, with a top-left origin like the
    /// ruler's math. The flip lives on this child layer (not the root), so it
    /// is applied against a real superlayer on screen and in `render(in:)` alike.
    private let canvasLayer = CALayer()
    private let backdropLayer = CALayer()
    private let heldContainer = CALayer()
    private var heldLayers: [ScreenRulerMarksLayer] = []
    private let areaLayer = ScreenRulerMarksLayer()
    private let liveLayer = ScreenRulerMarksLayer()
    private let chipLayer = ScreenRulerChipLayer()
    private let noticeLayer = ScreenRulerPillLayer()
    private var tracking: NSTrackingArea?

    init(display: ScreenRulerDisplay, backdrop: CGImage?, style: ScreenRulerStyle, hidesCursor: Bool) {
        rulerDisplay = display
        self.style = style
        self.hidesCursor = hidesCursor
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
        // Layer-hosting: the view owns this tree.
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.actions = ScreenRulerLayers.noActions
        layer = rootLayer
        wantsLayer = true
        rootLayer.contentsScale = display.scale
        canvasLayer.isGeometryFlipped = true
        canvasLayer.frame = bounds
        canvasLayer.actions = ScreenRulerLayers.noActions
        rootLayer.addSublayer(canvasLayer)

        backdropLayer.contents = backdrop
        backdropLayer.contentsGravity = .resize
        backdropLayer.contentsScale = display.scale
        // One captured pixel per display pixel: never smoothed.
        backdropLayer.magnificationFilter = .nearest
        backdropLayer.minificationFilter = .nearest
        backdropLayer.frame = bounds
        backdropLayer.actions = ScreenRulerLayers.noActions
        heldContainer.actions = ScreenRulerLayers.noActions
        heldContainer.frame = bounds
        for layer in [backdropLayer, heldContainer, areaLayer, liveLayer, chipLayer, noticeLayer] {
            canvasLayer.addSublayer(layer)
        }
        for layer in [areaLayer, liveLayer] {
            layer.frame = bounds
            layer.isHidden = true
        }
        chipLayer.isHidden = true
        noticeLayer.isHidden = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screen ruler")
        setAccessibilityHelp("Move the pointer to measure the space around it. Drag to measure an area. Shift keeps a measurement, Command C copies it, Space switches points and pixels, arrow keys move the pointer by one pixel, Escape exits.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    // Not flipped: events are read from NSEvent.mouseLocation, and the
    // drawing's top-left origin comes from `canvasLayer`.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        if !hidesCursor { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !hidesCursor { NSCursor.crosshair.set() }
    }

    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    // Right-click exits on release, so the release never reaches the app below.
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { controller?.finish() }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func keyDown(with event: NSEvent) { _ = controller?.handleKeyDown(event) }
    override func flagsChanged(with event: NSEvent) { controller?.handleFlagsChanged(event) }

    // MARK: Drawing

    func setLive(_ marks: ScreenRulerMarks?, color: String?, pointer: CGPoint?) {
        liveLayer.update(marks, style: style, scale: rulerDisplay.scale, bounds: bounds)
        guard let color, let pointer else {
            chipLayer.isHidden = true
            return
        }
        chipLayer.update(hex: color, style: style, scale: rulerDisplay.scale)
        chipLayer.frame = ScreenRulerLayers.chipFrame(size: chipLayer.preferredSize, pointer: pointer, in: bounds)
        chipLayer.isHidden = false
    }

    func setArea(_ marks: ScreenRulerMarks?) {
        areaLayer.update(marks, style: style, scale: rulerDisplay.scale, bounds: bounds)
    }

    func setHeld(_ marks: [ScreenRulerMarks]) {
        while heldLayers.count < marks.count {
            let layer = ScreenRulerMarksLayer()
            layer.frame = bounds
            heldContainer.addSublayer(layer)
            heldLayers.append(layer)
        }
        while heldLayers.count > marks.count {
            heldLayers.removeLast().removeFromSuperlayer()
        }
        for (layer, mark) in zip(heldLayers, marks) {
            layer.update(mark, style: style, scale: rulerDisplay.scale, bounds: bounds)
        }
    }

    func setNotice(_ text: String?) {
        guard let text else {
            noticeLayer.isHidden = true
            return
        }
        let size = noticeLayer.configure(text: text, font: style.noticeFont, foreground: CGColor(gray: 1, alpha: 1),
                                         background: CGColor(gray: 0.1, alpha: 0.88),
                                         border: style.increasedContrast ? CGColor(gray: 1, alpha: 0.9) : nil,
                                         scale: rulerDisplay.scale, padding: CGSize(width: 12, height: 6))
        noticeLayer.cornerRadius = size.height / 2
        let origin = CGPoint(x: ScreenRulerLayout.snapped((bounds.width - size.width) / 2, scale: rulerDisplay.scale),
                             y: ScreenRulerLayout.snapped(bounds.maxY - size.height - 48, scale: rulerDisplay.scale))
        noticeLayer.frame = CGRect(origin: origin, size: size)
        noticeLayer.isHidden = false
    }
}

// MARK: - Layers

enum ScreenRulerLayers {
    /// No implicit animation on any property the ruler changes.
    static let noActions: [String: CAAction] = {
        var actions: [String: CAAction] = [:]
        for key in ["position", "bounds", "frame", "contents", "hidden", "opacity", "path", "string",
                    "backgroundColor", "borderColor", "borderWidth", "foregroundColor", "fillColor",
                    "strokeColor", "lineDashPattern", "lineWidth", "sublayers", "onOrderIn", "onOrderOut",
                    "cornerRadius", "fontSize", "font"] {
            actions[key] = NSNull()
        }
        return actions
    }()

    /// The colour chip sits below and to the right of the pointer, flipping
    /// left or up near the display's edges.
    static func chipFrame(size: CGSize, pointer: CGPoint, in bounds: CGRect) -> CGRect {
        let offset: CGFloat = 16
        var origin = CGPoint(x: pointer.x + offset, y: pointer.y + offset)
        if origin.x + size.width > bounds.maxX { origin.x = pointer.x - offset - size.width }
        if origin.y + size.height > bounds.maxY { origin.y = pointer.y - offset - size.height }
        origin.x = min(max(bounds.minX, origin.x), bounds.maxX - size.width)
        origin.y = min(max(bounds.minY, origin.y), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

/// A rounded label with one line of text.
final class ScreenRulerPillLayer: CALayer {
    private let textLayer = CATextLayer()
    private var shownText: String?

    override init() {
        super.init()
        actions = ScreenRulerLayers.noActions
        textLayer.actions = ScreenRulerLayers.noActions
        textLayer.alignmentMode = .center
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        addSublayer(textLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    /// Sets the text and colours and returns the pill's size (the caller
    /// places it). `leading` reserves room before the text (the colour
    /// chip's swatch); the text is centred vertically in `minHeight`.
    func configure(text: String, font: NSFont, foreground: CGColor, background: CGColor, border: CGColor?,
                   scale: CGFloat, padding: CGSize = CGSize(width: 5, height: 2),
                   leading: CGFloat = 0, minHeight: CGFloat = 0) -> CGSize {
        if shownText != text {
            textLayer.string = text
            shownText = text
        }
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = foreground
        textLayer.contentsScale = scale
        contentsScale = scale
        backgroundColor = background
        borderColor = border
        borderWidth = border == nil ? 0 : 1
        cornerRadius = 4
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        let height = max(minHeight, textSize.height + padding.height * 2)
        textLayer.frame = CGRect(x: padding.width + leading, y: ((height - textSize.height) / 2).rounded(),
                                 width: textSize.width, height: textSize.height)
        return CGSize(width: textSize.width + padding.width * 2 + leading, height: height)
    }
}

/// The hex colour under the pointer: a swatch and "#RRGGBB".
final class ScreenRulerChipLayer: CALayer {
    private let swatch = CALayer()
    private let pill = ScreenRulerPillLayer()
    private(set) var preferredSize: CGSize = .zero

    override init() {
        super.init()
        actions = ScreenRulerLayers.noActions
        swatch.actions = ScreenRulerLayers.noActions
        swatch.cornerRadius = 3
        swatch.borderWidth = 1
        addSublayer(pill)
        addSublayer(swatch)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    func update(hex: String, style: ScreenRulerStyle, scale: CGFloat) {
        let swatchSide = ceil(style.labelFont.pointSize + 3)
        let inset: CGFloat = 6
        let gap: CGFloat = 6
        // The swatch sits at the pill's leading edge, the text after it.
        let size = pill.configure(text: hex, font: style.labelFont, foreground: CGColor(gray: 1, alpha: 1),
                                  background: CGColor(gray: 0.1, alpha: 0.88),
                                  border: style.increasedContrast ? CGColor(gray: 1, alpha: 0.9) : nil,
                                  scale: scale, padding: CGSize(width: inset, height: 3),
                                  leading: swatchSide + gap, minHeight: swatchSide + 6)
        pill.frame = CGRect(origin: .zero, size: size)
        swatch.frame = CGRect(x: inset, y: ((size.height - swatchSide) / 2).rounded(), width: swatchSide, height: swatchSide)
        swatch.backgroundColor = AOMRGBAColor(hex: hex)?.cgColor
        swatch.borderColor = CGColor(gray: 1, alpha: 0.8)
        swatch.contentsScale = scale
        preferredSize = size
    }
}

/// One measurement's marks: line rectangles (with an optional halo), a box
/// and labels. Layers are reused between updates.
final class ScreenRulerMarksLayer: CALayer {
    private let haloContainer = CALayer()
    private let lineContainer = CALayer()
    private let boxHalo = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private let labelContainer = CALayer()
    private var halos: [CALayer] = []
    private var lines: [CALayer] = []
    private var labels: [ScreenRulerPillLayer] = []

    override init() {
        super.init()
        actions = ScreenRulerLayers.noActions
        for layer in [boxHalo, boxLayer, haloContainer, lineContainer, labelContainer] {
            layer.actions = ScreenRulerLayers.noActions
            addSublayer(layer)
        }
        boxLayer.isHidden = true
        boxHalo.isHidden = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    func update(_ marks: ScreenRulerMarks?, style: ScreenRulerStyle, scale: CGFloat, bounds: CGRect) {
        guard let marks else {
            isHidden = true
            return
        }
        isHidden = false
        frame = bounds
        for container in [haloContainer, lineContainer, labelContainer] { container.frame = bounds }
        let pixel = 1 / scale

        // Lines and their halos.
        func pool(_ layers: inout [CALayer], in container: CALayer, count: Int) {
            while layers.count < count {
                let layer = CALayer()
                layer.actions = ScreenRulerLayers.noActions
                container.addSublayer(layer)
                layers.append(layer)
            }
            for (index, layer) in layers.enumerated() { layer.isHidden = index >= count }
        }
        pool(&lines, in: lineContainer, count: marks.lines.count)
        for (layer, rect) in zip(lines, marks.lines) {
            layer.frame = rect
            layer.backgroundColor = style.guide
        }
        pool(&halos, in: haloContainer, count: style.halo == nil ? 0 : marks.lines.count)
        if let halo = style.halo {
            for (layer, rect) in zip(halos, marks.lines) {
                layer.frame = rect.insetBy(dx: -pixel, dy: -pixel)
                layer.backgroundColor = halo
            }
        }

        // The box: stroked just inside the measured pixels.
        if let box = marks.box, box.width > 0, box.height > 0 {
            let width = CGFloat(ScreenRulerLayout.linePixels(increasedContrast: style.increasedContrast)) * pixel
            let local = CGRect(origin: .zero, size: box.size)
            let path = CGPath(rect: local.insetBy(dx: min(width / 2, local.width / 2), dy: min(width / 2, local.height / 2)),
                              transform: nil)
            boxLayer.frame = box
            boxLayer.path = path
            // Paths are rasterized: at the display's scale, or they blur on Retina.
            boxLayer.contentsScale = scale
            boxLayer.lineWidth = width
            boxLayer.strokeColor = style.guide
            boxLayer.fillColor = style.fill
            boxLayer.lineDashPattern = marks.dashed ? [NSNumber(value: Double(4)), NSNumber(value: Double(3))] : nil
            boxLayer.isHidden = false
            if let halo = style.halo {
                boxHalo.frame = box
                boxHalo.path = path
                boxHalo.contentsScale = scale
                boxHalo.lineWidth = width + 2 * pixel
                boxHalo.strokeColor = halo
                boxHalo.fillColor = nil
                boxHalo.isHidden = false
            } else {
                boxHalo.isHidden = true
            }
        } else {
            boxLayer.isHidden = true
            boxHalo.isHidden = true
        }

        // Labels.
        while labels.count < marks.labels.count {
            let layer = ScreenRulerPillLayer()
            labelContainer.addSublayer(layer)
            labels.append(layer)
        }
        for (index, layer) in labels.enumerated() { layer.isHidden = index >= marks.labels.count }
        for (layer, label) in zip(labels, marks.labels) {
            let size = layer.configure(text: label.text, font: style.labelFont, foreground: style.labelText,
                                       background: style.guide, border: style.halo, scale: scale)
            let frame = ScreenRulerLayout.labelFrame(size: size, for: label, in: bounds)
            layer.frame = CGRect(x: ScreenRulerLayout.snapped(frame.minX, scale: scale),
                                 y: ScreenRulerLayout.snapped(frame.minY, scale: scale),
                                 width: frame.width, height: frame.height)
        }
    }
}
