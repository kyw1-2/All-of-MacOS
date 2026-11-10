import AppKit
import Carbon

/// The overlay window: transparent, above everything (menu bar and Dock
/// included), on every Space and over full-screen apps. It ignores the
/// mouse, so a click goes to the app underneath (and ends hint mode), and it
/// takes the keyboard without activating AOM, so the front app stays front.
final class ClickHintsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityLabel("Click hints")
    }
}

/// One display's pills as small layers (no full-screen drawing). Layer
/// geometry is top-left based, like Accessibility frames.
final class ClickHintsOverlayView: NSView {
    private let canvas = CALayer()
    private var pills: [Int: CALayer] = [:]
    private let searchLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // The flip sits on a child, which `render(in:)` and the screen draw alike.
        canvas.isGeometryFlipped = true
        canvas.frame = bounds
        layer?.addSublayer(canvas)
        searchLayer.isHidden = true
        canvas.addSublayer(searchLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Not flipped: the root layer stays bottom-up like the window, and only
    // `canvas` flips (a flipped root would mirror the whole tree).

    /// Adds or updates the pill for `target` at `frame` (view points, top-left).
    func setPill(_ target: Int, frame: CGRect, image: CGImage?, scale: CGFloat, halo: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pill = pills[target] ?? {
            let layer = CALayer()
            layer.contentsGravity = .resize
            canvas.insertSublayer(layer, below: searchLayer)
            pills[target] = layer
            return layer
        }()
        pill.frame = frame
        pill.contents = image
        pill.contentsScale = scale
        if let halo {
            pill.shadowColor = halo
            pill.shadowOpacity = 1
            pill.shadowRadius = 2
            pill.shadowOffset = .zero
            pill.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: frame.height / 2,
                                     cornerHeight: frame.height / 2, transform: nil)
        } else {
            pill.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    func setVisible(_ target: Int, _ visible: Bool) {
        guard let pill = pills[target], pill.isHidden == visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.isHidden = !visible
        CATransaction.commit()
    }

    /// The search capsule; nil hides it.
    func setSearch(image: CGImage?, frame: CGRect, scale: CGFloat, halo: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        searchLayer.isHidden = image == nil
        searchLayer.contents = image
        searchLayer.contentsScale = scale
        searchLayer.frame = frame
        if let halo, image != nil {
            searchLayer.shadowColor = halo
            searchLayer.shadowOpacity = 1
            searchLayer.shadowRadius = 3
            searchLayer.shadowOffset = .zero
            searchLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: frame.height / 2,
                                            cornerHeight: frame.height / 2, transform: nil)
        } else {
            searchLayer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        CATransaction.commit()
    }

}

/// The search capsule: "Search  sav  · 3", drawn like a pill.
enum ClickHintsSearchBadge {
    static func text(query: String, matches: Int) -> String {
        let shown = query.isEmpty ? "Type a name" : query
        return "Search: \(shown)  ·  \(matches == 1 ? "1 match" : "\(matches) matches")"
    }

    static func size(_ text: String, style: ClickHintsPillStyle, scale: CGFloat) -> CGSize {
        let width = NSAttributedString(string: text, attributes: [.font: style.font]).size().width + style.padding * 3
        return CGSize(width: (width * scale).rounded(.up) / scale, height: style.height + 6)
    }

    static func image(_ text: String, style: ClickHintsPillStyle, scale: CGFloat) -> CGImage? {
        let size = size(text, style: style, scale: scale)
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.addPath(path)
        context.setFillColor(style.fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(style.accent)
        context.setLineWidth(max(1.5, style.borderWidth))
        context.strokePath()
        let string = NSAttributedString(string: text, attributes: [.font: style.font,
                                                                   .foregroundColor: NSColor(cgColor: style.text) ?? .labelColor])
        let baseline = (size.height - style.font.capHeight) / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: CGPoint(x: style.padding * 1.5, y: baseline + style.font.descender))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// One hint-mode session: the panels, the pills, the keys, and the end.
/// Its monitors and observers exist only while it is on screen.
@MainActor
final class ClickHintsSession {
    private(set) static var active: ClickHintsSession?
    static var isActive: Bool { active != nil }

    private let targets: [ClickHintsTarget]
    private let labels: [String]
    private let pid: pid_t
    private let windowFrame: CGRect?
    private var state: ClickHintsInputState
    private let style: ClickHintsPillStyle
    private var restore: (() -> Void)?

    private var displays: [ClickHintsDisplay] = []
    private var placements: [ClickHintsPlacedPill?] = []
    private var panels: [UInt32: ClickHintsPanel] = [:]
    private var views: [UInt32: ClickHintsOverlayView] = [:]
    /// Each panel's top-left corner in Accessibility coordinates.
    private var panelOrigins: [UInt32: CGPoint] = [:]
    private var keyDisplay: UInt32?
    private var searchFrame: CGRect = .zero
    private var shownState: [Int: String] = [:]
    private var imageCache: [String: CGImage] = [:]
    private var translator: ClickHintsLayoutTranslator?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var finished = false

    init(targets: [ClickHintsTarget], pid: pid_t, windowFrame: CGRect?, alphabet: ClickHintsAlphabet,
         size: ClickHintsSize, startsInSearch: Bool, restore: (() -> Void)?) {
        self.targets = targets
        self.pid = pid
        self.windowFrame = windowFrame
        self.restore = restore
        // Targets arrive in rank order: the first gets the shortest label.
        labels = ClickHintsLabels.make(count: targets.count, alphabet: alphabet)
        state = ClickHintsInputState(labels: labels, searchTexts: targets.map(\.attributes.searchText),
                                     startsInSearch: startsInSearch)
        style = ClickHintsPillStyle.current(size: size)
    }

    // MARK: Present

    func present() {
        guard !targets.isEmpty, labels.count == targets.count else { finish(); return }
        displays = ClickHintsDisplay.current()
        guard let primaryTop = NSScreen.screens.first?.frame.maxY, !displays.isEmpty else { finish(); return }
        let sizes = labels.map { ClickHintsPillRenderer.size(for: $0, style: style) }
        placements = ClickHintsPlacement.place(anchors: targets.map(\.visibleFrame), sizes: sizes, displays: displays)

        // The search capsule sits at the top centre of the window.
        let window = windowFrame ?? targets[0].visibleFrame
        let center = CGPoint(x: window.midX, y: window.midY)
        let keyOwner = ClickHintsPlacement.display(for: CGRect(origin: center, size: CGSize(width: 1, height: 1)), in: displays)
        keyDisplay = keyOwner?.id
        if let keyOwner {
            let badge = ClickHintsSearchBadge.size(ClickHintsSearchBadge.text(query: "", matches: targets.count), style: style, scale: 2)
            let wide = CGSize(width: max(badge.width, 260), height: badge.height)
            searchFrame = ClickHintsPlacement.fit(CGRect(x: window.midX - wide.width / 2, y: window.minY + 34,
                                                         width: wide.width, height: wide.height),
                                                  in: keyOwner.frame, scale: keyOwner.scale)
        }

        // One panel per display that has pills, as small as its pills allow.
        var bounds: [UInt32: CGRect] = [:]
        for placed in placements.compactMap({ $0 }) {
            bounds[placed.displayID] = (bounds[placed.displayID] ?? .null).union(placed.frame)
        }
        if let keyDisplay { bounds[keyDisplay] = (bounds[keyDisplay] ?? .null).union(searchFrame) }
        for display in displays {
            guard let rect = bounds[display.id], !rect.isNull else { continue }
            let area = rect.insetBy(dx: -6, dy: -6).intersection(display.frame)
            let appKitFrame = NSRect(x: area.minX, y: primaryTop - area.maxY, width: area.width, height: area.height)
            let panel = ClickHintsPanel(frame: appKitFrame)
            let view = ClickHintsOverlayView(frame: NSRect(origin: .zero, size: appKitFrame.size))
            panel.contentView = view
            panels[display.id] = panel
            views[display.id] = view
            panelOrigins[display.id] = area.origin
        }
        if keyDisplay == nil || panels[keyDisplay!] == nil { keyDisplay = panels.keys.sorted().first }

        translator = ClickHintsLayoutTranslator()
        redraw()
        for (id, panel) in panels where id != keyDisplay { panel.orderFrontRegardless() }
        if let keyDisplay, let panel = panels[keyDisplay] { panel.makeKeyAndOrderFront(nil) }
        Self.active = self
        installMonitors()
        announce()
    }

    // MARK: Draw

    private func scale(of display: UInt32) -> CGFloat {
        displays.first { $0.id == display }?.scale ?? 2
    }

    private func image(label: String, typed: Int, highlighted: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(label)|\(typed)|\(highlighted)|\(scale)"
        if let cached = imageCache[key] { return cached }
        let made = ClickHintsPillRenderer.image(label: label, typed: typed, highlighted: highlighted, style: style, scale: scale)
        imageCache[key] = made
        return made
    }

    private func redraw() {
        let visible = Set(state.matches)
        let typed = state.mode == .labels ? state.typed.count : 0
        let highlighted = state.highlightedTarget
        for index in targets.indices {
            guard let placed = placements[index], let view = views[placed.displayID],
                  let origin = panelOrigins[placed.displayID] else { continue }
            let isVisible = visible.contains(index)
            if isVisible {
                let isHighlighted = highlighted == index
                let signature = "\(typed)|\(isHighlighted)"
                if shownState[index] != signature {
                    let scale = scale(of: placed.displayID)
                    let frame = placed.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                    view.setPill(index, frame: frame, image: image(label: labels[index], typed: typed, highlighted: isHighlighted, scale: scale),
                                 scale: scale, halo: style.halo)
                    shownState[index] = signature
                }
            }
            view.setVisible(index, isVisible)
        }
        if let keyDisplay, let view = views[keyDisplay], let origin = panelOrigins[keyDisplay] {
            if state.mode == .search {
                let scale = scale(of: keyDisplay)
                let text = ClickHintsSearchBadge.text(query: state.query, matches: state.matches.count)
                let size = ClickHintsSearchBadge.size(text, style: style, scale: scale)
                var frame = CGRect(x: searchFrame.midX - size.width / 2, y: searchFrame.minY, width: size.width, height: size.height)
                frame = frame.offsetBy(dx: -origin.x, dy: -origin.y)
                view.setSearch(image: ClickHintsSearchBadge.image(text, style: style, scale: scale), frame: frame,
                               scale: scale, halo: style.halo)
            } else {
                view.setSearch(image: nil, frame: .zero, scale: 1, halo: nil)
            }
        }
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags
        let key = ClickHintsKeyboard.key(keyCode: event.keyCode, shift: flags.contains(.shift)) { [translator] code in
            translator?.character(for: code) ?? event.charactersIgnoringModifiers?.first
        }
        // A held letter must not type a label twice.
        if event.isARepeat, case .character = key { return }
        switch state.handle(key, modifiers: ClickHintsModifiers(flags)) {
        case .unchanged:
            break
        case .updated:
            redraw()
        case .rejected:
            NSSound.beep()
        case .cancel:
            finish()
        case .act(let index, let kind):
            act(on: targets[index], kind: kind)
        }
    }

    private func act(on target: ClickHintsTarget, kind: ClickHintsClickKind) {
        let restore = self.restore
        self.restore = nil
        // The overlay is gone before anything happens.
        finish()
        guard !IsSecureEventInputEnabled(), !ScreenLock.isLocked else {
            ClickHintsModule.finishRestore(restore)
            return
        }
        // Let the front app's window take the keyboard back first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ClickHintsPerformer.perform(target, kind: kind) { outcome in
                if case .failed(let reason) = outcome {
                    GestureHUD.shared.show(title: "Couldn't \(kind.title)", detail: "\(reason). Try again, or use the mouse this time.")
                }
                ClickHintsModule.finishRestore(restore)
            }
        }
    }

    // MARK: End

    /// Takes the overlay down, removes every monitor and observer, and puts
    /// back what the session changed. Safe to call more than once.
    func finish() {
        guard !finished else { return }
        finished = true
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        views.removeAll()
        imageCache.removeAll()
        translator = nil
        if Self.active === self { Self.active = nil }
        ClickHintsModule.finishRestore(restore)
        restore = nil
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self, !self.finished else { return event }
            self.handle(event)
            return nil
        }) { monitors.append(keys) }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            self?.finish()
            return event
        }) { monitors.append(local) }

        let workspace = NSWorkspace.shared.notificationCenter
        let pid = self.pid
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                           queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != pid else { return }
            MainActor.assumeIsolated { self?.finish() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }))
        if let keyDisplay, let panel = panels[keyDisplay] {
            observers.append((center, center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                         queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }))
        }
    }

    private func announce() {
        guard let keyDisplay, let panel = panels[keyDisplay] else { return }
        let count = targets.count
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "\(count == 1 ? "1 click hint" : "\(count) click hints"). Type a hint to click, Escape to cancel.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

}
