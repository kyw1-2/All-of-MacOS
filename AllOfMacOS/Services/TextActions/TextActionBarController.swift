import AppKit
import SwiftUI

/// What the bar's SwiftUI view draws. The controller owns it; the page's
/// live preview owns one of its own.
@MainActor
final class TextActionBarModel: ObservableObject {
    @Published var items: [TextActionBarItem] = []
    @Published private(set) var pages: [Range<Int>] = []
    @Published private(set) var page = 0
    /// A transform whose rewrites the bar shows in place of the actions.
    @Published private(set) var submenu: TextActionBarItem?
    /// A short confirmation ("Copied") shown before the bar leaves.
    @Published var confirmation: String?
    @Published var showsNames = false

    /// Runs an item: the item, the rewrite (for transforms) and whether ⌥ was held.
    var perform: (TextActionBarItem, TextTransformVariant?, Bool) -> Void = { _, _, _ in }
    /// The bar changed width (a page, a submenu, a confirmation).
    var layoutChanged: () -> Void = {}

    var visibleItems: [TextActionBarItem] {
        guard pages.indices.contains(page) else { return items }
        return Array(items[pages[page]])
    }
    var hasPreviousPage: Bool { page > 0 }
    var hasNextPage: Bool { page < pages.count - 1 }

    func set(_ items: [TextActionBarItem], showsNames: Bool, maxWidth: CGFloat) {
        self.items = items
        self.showsNames = showsNames
        submenu = nil
        confirmation = nil
        page = 0
        pages = TextActionBarPaging.pages(widths: items.map { Self.width(of: $0, showsNames: showsNames) },
                                          maxWidth: maxWidth, chevron: TextActionBarMetrics.chevronWidth)
    }

    func nextPage() {
        guard hasNextPage else { return }
        page += 1
        layoutChanged()
    }

    func previousPage() {
        guard hasPreviousPage else { return }
        page -= 1
        layoutChanged()
    }

    func open(_ item: TextActionBarItem) {
        submenu = item
        layoutChanged()
    }

    func closeSubmenu() {
        submenu = nil
        layoutChanged()
    }

    /// The width an item takes on the bar, for paging. It follows the
    /// view's layout: an icon button, an icon and a name, or a text chip.
    static func width(of item: TextActionBarItem, showsNames: Bool) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        func text(_ string: String) -> CGFloat { ceil((string as NSString).size(withAttributes: [.font: font]).width) }
        let separator: CGFloat = 1
        switch item.kind {
        case .result, .chip:
            return text(item.title) + TextActionBarMetrics.itemPadding * 2 + separator
        case .action, .menu, .transform:
            let icon = TextActionBarMetrics.iconButton
            return (showsNames ? icon + AOMSpace.x1 + text(item.title) + TextActionBarMetrics.itemPadding : icon) + separator
        }
    }
}

/// The bar's sizes, shared by the view and the paging.
enum TextActionBarMetrics {
    /// One regular control high, plus the capsule's inset.
    static let height: CGFloat = AOMIcon.hitArea + AOMSpace.x1
    static let iconButton: CGFloat = AOMIcon.hitArea + AOMSpace.x0_5
    static let itemPadding: CGFloat = AOMSpace.x2
    static let chevronWidth: CGFloat = AOMIcon.hitArea
    /// Wider bars page, like the iOS edit menu.
    static let maxWidth: CGFloat = 560
}

/// The panel never becomes key or main: clicking the bar leaves the other
/// app active and its selection in place.
final class TextActionBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click (the panel is never key) and reports the pointer
/// entering and leaving, in any app state.
final class TextActionBarHostingView: NSHostingView<TextActionBarView> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// Shows the bar in its own non-activating panel and hides it by the rules
/// of `TextActionBarLifecycle`. Its monitors exist only while it is visible.
@MainActor
final class TextActionBarController {
    let model = TextActionBarModel()
    private(set) var selection: TextSelection?
    private(set) var context = TextActionContext()
    /// Runs an item the person clicked.
    var onPerform: ((TextActionBarItem, TextTransformVariant?, Bool) -> Void)?
    var onDismiss: ((TextActionDismissReason) -> Void)?

    /// Native selection popovers (notably ChatGPT's "Ask ChatGPT") use the
    /// menu window layer. A status-bar-level panel appears behind them.
    /// This nonactivating bar exists only during a valid text selection.
    static let selectionPanelLevel: NSWindow.Level = .popUpMenu

    private var panel: TextActionBarPanel?
    private var hosting: TextActionBarHostingView?
    private var lifecycle = TextActionBarLifecycle(hideDelay: 4)
    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var wakeTimer: Timer?
    private var confirmWork: DispatchWorkItem?
    private var anchor: CGRect = .zero
    private var pointer: CGPoint?
    private var position: TextActionBarPosition = .above
    private var showToken = 0

    var isVisible: Bool { lifecycle.phase == .shown }

    init() {
        model.perform = { [weak self] item, variant, alternate in self?.onPerform?(item, variant, alternate) }
        model.layoutChanged = { [weak self] in self?.layout() }
    }

    func show(_ items: [TextActionBarItem], for selection: TextSelection, context: TextActionContext,
              anchor: CGRect, pointer: CGPoint?, settings: TextActionsSettings) {
        guard NSApp != nil, !items.isEmpty else { return }
        if isVisible { hidePanel(.newSelection, animated: false) }
        self.selection = selection
        self.context = context
        self.anchor = anchor
        self.pointer = pointer
        position = settings.position
        lifecycle.hideDelay = settings.hideDelay
        confirmWork?.cancel()
        model.set(items, showsNames: settings.showsNames, maxWidth: TextActionBarMetrics.maxWidth)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        showToken &+= 1
        layout()
        let reduceMotion = AOMMotion.systemReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        installMonitors()
        apply(lifecycle.handle(.shown(at: ProcessInfo.processInfo.systemUptime)))
    }

    /// Flashes a confirmation in the bar, then hides it.
    func confirm(_ text: String) {
        guard isVisible else { return }
        model.confirmation = text
        layout()
        confirmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.handle(.actionFinished(keepsBar: false)) }
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func dismiss(_ reason: TextActionDismissReason) {
        guard isVisible else { return }
        switch reason {
        case .paused: handle(.paused)
        case .secureInput: handle(.secureInput)
        case .newSelection: handle(.newSelection)
        case .action: handle(.actionFinished(keepsBar: false))
        default: hidePanel(reason, animated: true)
        }
    }

    // MARK: Layout

    /// Sizes and places the panel now, and once more on the next turn: SwiftUI
    /// applies a model change (a page, a submenu, a confirmation) a moment
    /// later, and the bar must stay centred at its new width.
    private func layout() {
        place()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func place() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screens = NSScreen.screens.map { TextActionScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let origin = TextActionBarPlacement.origin(for: size, anchor: anchor, pointer: pointer, screens: screens, position: position)
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> TextActionBarPanel {
        let panel = TextActionBarPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: TextActionBarMetrics.height),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = Self.selectionPanelLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityTitle("Text Actions")
        let hosting = TextActionBarHostingView(rootView: TextActionBarView(model: model))
        hosting.onHover = { [weak self] inside in
            guard let self else { return }
            self.handle(inside ? .pointerEntered : .pointerExited(at: ProcessInfo.processInfo.systemUptime))
        }
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    // MARK: Dismissal

    private func handle(_ event: TextActionBarLifecycle.Event) {
        if event == .pointerEntered { wakeTimer?.invalidate(); wakeTimer = nil }
        apply(lifecycle.handle(event))
    }

    private func apply(_ effect: TextActionBarLifecycle.Effect?) {
        switch effect {
        case .hide(let reason)?: hidePanel(reason, animated: reason != .newSelection)
        case .wake(let time)?: scheduleWake(at: time)
        case nil: break
        }
    }

    private func scheduleWake(at time: TimeInterval) {
        wakeTimer?.invalidate()
        let delay = max(0.05, time - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.tick(at: ProcessInfo.processInfo.systemUptime)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    private func hidePanel(_ reason: TextActionDismissReason, animated: Bool) {
        if lifecycle.phase == .shown {
            // Keep the state machine in step when the hide did not come from it.
            _ = lifecycle.handle(.newSelection)
        }
        wakeTimer?.invalidate()
        wakeTimer = nil
        confirmWork?.cancel()
        confirmWork = nil
        removeMonitors()
        selection = nil
        onDismiss?(reason)
        guard let panel, panel.isVisible else { return }
        let token = showToken
        if !animated || AOMMotion.systemReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A bar shown again meanwhile stays.
                guard let self, self.showToken == token, self.lifecycle.phase == .hidden else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.mouseDown(insideBar: false)) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TextActionPasteboard.syntheticTag else { return }
            let escape = event.keyCode == 53
            MainActor.assumeIsolated { self?.handle(.keyDown(escape: escape)) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
            MainActor.assumeIsolated { self?.handle(.scrolled) }
        }) { monitors.append(monitor) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid != self.selection?.pid else { return }
                self.handle(.appSwitched)
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
