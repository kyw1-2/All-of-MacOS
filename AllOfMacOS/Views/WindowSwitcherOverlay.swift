import AppKit
import SwiftUI
import ScreenCaptureKit

/// AltTab / Contexts-style window switcher: every window — on screen,
/// minimized, of hidden apps and, where its app's Window menu lists it, in
/// other Spaces — as a grid of cached ScreenCaptureKit thumbnails.
///
/// Keys: Tab and ⇧Tab (with the held trigger, e.g. ⌥Tab) or the arrows move,
/// ↩ or a click switches, Esc clears the search and then cancels; typing
/// filters by app and window title (fuzzy, Hangul initials too); ⌘W closes,
/// ⌘M minimizes, ⌘H hides and ⌘Q quits the selected window's app; ⌘G groups
/// windows by app. When the switcher opened while a modifier was held,
/// releasing every modifier switches — unless you typed a search, which
/// keeps it open until ↩.
@MainActor
final class WindowSwitcherController: NSObject, ObservableObject {
    static let shared = WindowSwitcherController()
    static let groupByAppKey = "AOMPaletteSwitcherGroupByApp"

    struct Item: Identifiable {
        let id: CGWindowID
        let title: String
        let appName: String
        let icon: NSImage?
        let axWindow: AXUIElement?
        let pid: pid_t
        var thumbnail: CGImage?
        var state: SwitcherWindowState = .normal
        var bundleID: String? = nil
        var windowMenuItem: AXUIElement? = nil
    }

    /// Every window of this opening, most recently used first. Internal for
    /// the controller tests (@testable).
    @Published var items: [Item] = [] { didSet { clampSelection() } }
    /// Index into `visibleItems`. Internal setter for the controller tests.
    @Published var selectedIndex = 0
    /// The type-to-filter text.
    @Published var query = "" { didSet { if query != oldValue { selectedIndex = 0; searchMode = searchMode || !query.isEmpty } } }
    @Published var groupsByApp = UserDefaults.standard.bool(forKey: WindowSwitcherController.groupByAppKey)
    /// A one-line note in the footer ("Can't close a window in another Space").
    @Published private(set) var note: String?
    @Published private(set) var screenRecordingAllowed = true

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var initialModifiers = NSEvent.ModifierFlags(arrayLiteral: [])
    private var sawHeldModifier = false
    /// Typing a search keeps the switcher open when the trigger is released.
    private var searchMode = false
    /// One increment per show(): the async window query checks it after every
    /// await so a superseded or cancelled session can never build a panel.
    private var session = 0
    private var isPresenting = false
    private var observers: [NSObjectProtocol] = []
    private var thumbnailTask: Task<Void, Never>?
    /// Columns of the grid this opening (arrow keys move by rows).
    private(set) var columns = 1

    var isShowing: Bool { panel?.isVisible == true }

    /// What the grid shows: the search applied, then grouping.
    var visibleItems: [Item] {
        let filtered = SwitcherFilter.filtered(items, query: query, appName: \.appName, title: \.title)
        return groupsByApp && query.isEmpty ? SwitcherFilter.groupedByApp(filtered, key: \.pid) : filtered
    }

    func show() {
        guard panel == nil, !isPresenting else { return }
        isPresenting = true
        session += 1
        let currentSession = session
        previousApp = NSWorkspace.shared.frontmostApplication
        initialModifiers = NSEvent.modifierFlags.intersection([.command, .control, .option])
        sawHeldModifier = false
        searchMode = false
        query = ""
        note = nil
        let own = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier, hidden: $0.isHidden) }
        let recent = AppActivationHistory.shared.recentPIDs()
        let frontmost = previousApp?.processIdentifier
        Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                Self.readEntries(running: running, recent: recent)
            }.value
            guard let self, currentSession == self.session else { return }
            self.present(entries: entries, frontmost: frontmost)
            self.isPresenting = false
        }
    }

    /// The window list, off the main thread: the window server's windows
    /// plus Accessibility (titles, minimized windows, the Window menu for
    /// windows in other Spaces), bounded to 0.8 s in all.
    nonisolated private static func readEntries(running: [(pid: pid_t, name: String, bundleID: String?, hidden: Bool)],
                                                recent: [pid_t]) -> [SwitcherEntry] {
        let server = SwitcherWindowReader.serverWindows()
        let limit = AXDeadline(perRequest: 0.15, budget: 0.8)
        var apps: [pid_t: SwitcherApp] = [:]
        let candidates = server.filter {
            $0.layer == 0 && $0.frame.width >= SwitcherWindowList.minimumSize.width
                && $0.frame.height >= SwitcherWindowList.minimumSize.height
        }
        // Apps by recency first, so a short budget is spent where it matters.
        let order = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for app in running.sorted(by: { (order[$0.pid] ?? Int.max) < (order[$1.pid] ?? Int.max) }) {
            let offScreenTitled = candidates.contains { $0.pid == app.pid && !$0.isOnScreen && !$0.title.isEmpty }
            apps[app.pid] = SwitcherWindowReader.app(pid: app.pid, name: app.name, bundleID: app.bundleID,
                                                     isHidden: app.hidden, readWindowMenu: offScreenTitled && !app.hidden,
                                                     limit: limit)
        }
        return SwitcherWindowList.build(server: candidates, apps: apps, recentApps: recent)
    }

    private func present(entries: [SwitcherEntry], frontmost: pid_t?) {
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        let icons = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.icon) },
                               uniquingKeysWith: { first, _ in first })
        items = entries.prefix(60).map { entry in
            Item(id: entry.windowID, title: entry.title, appName: entry.appName, icon: icons[entry.pid] ?? nil,
                 axWindow: entry.axWindow, pid: entry.pid,
                 thumbnail: SwitcherThumbnailCache.shared.image(for: entry.windowID),
                 state: entry.state, bundleID: entry.bundleID, windowMenuItem: entry.windowMenuItem)
        }
        selectedIndex = SwitcherFilter.initialSelection(count: visibleItems.count,
                                                        firstIsFrontmost: visibleItems.first?.pid == frontmost)
        buildPanel()
        loadThumbnails()
    }

    private func buildPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let count = max(1, items.count)
        let maxColumns = max(1, Int((visible.width * 0.85 - SwitcherMetrics.padding * 2 + SwitcherMetrics.gap)
                                     / (SwitcherMetrics.cardWidth + SwitcherMetrics.gap)))
        columns = min(count, min(SwitcherMetrics.maximumColumns, maxColumns))
        let rows = min(SwitcherMetrics.maximumRows, Int(ceil(Double(count) / Double(columns))))
        let gridWidth = CGFloat(columns) * SwitcherMetrics.cardWidth + CGFloat(columns - 1) * SwitcherMetrics.gap
        let width = max(SwitcherMetrics.minimumWidth, gridWidth + SwitcherMetrics.padding * 2)
        let gridHeight = CGFloat(rows) * SwitcherMetrics.cardHeight + CGFloat(max(0, rows - 1)) * SwitcherMetrics.gap
        let height = min(visible.height * 0.85, SwitcherMetrics.chromeHeight + max(gridHeight, SwitcherMetrics.emptyHeight))
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: WindowSwitcherView(controller: self))
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                       display: false)
        self.panel = panel
        // The overlay must own the keyboard: without activating the app, key
        // events keep flowing to the previously active app and the local
        // monitor never sees the cycling keys. Activation must not resurrect
        // AOM's own closed windows (the main window popping up on every
        // switch): anything newly visible is ordered straight back out.
        let visibleBefore = Set(NSApp.windows.filter { $0.isVisible && $0 !== panel })
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            for window in NSApp.windows where window.isVisible && window !== self.panel
                && !visibleBefore.contains(window) {
                window.orderOut(nil)
            }
        }
        installMonitors()
    }

    /// Fresh pictures, one window at a time (light on an 8 GB Mac), front
    /// windows first. Needs Screen Recording; without it cards show icons.
    private func loadThumbnails() {
        thumbnailTask?.cancel()
        guard screenRecordingAllowed, !PresetManager.isUIPreview else { return }
        let wanted = items.map(\.id)
        thumbnailTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            for id in wanted {
                guard !Task.isCancelled, let window = byID[id] else { continue }
                guard let image = try? await SwitcherThumbnailCache.capture(window) else { continue }
                SwitcherThumbnailCache.shared.store(image, for: id)
                guard let self, !Task.isCancelled, let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                self.items[index].thumbnail = image
            }
        }
    }

    // MARK: Selection

    func moveSelection(_ offset: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = SwitcherFilter.move(selectedIndex, by: offset, count: count, columns: columns, vertical: false)
    }

    private func moveRow(_ offset: Int) {
        selectedIndex = SwitcherFilter.move(selectedIndex, by: offset, count: visibleItems.count, columns: columns, vertical: true)
    }

    private func clampSelection() {
        let count = visibleItems.count
        if selectedIndex >= count { selectedIndex = max(0, count - 1) }
    }

    var selectedItem: Item? {
        let visible = visibleItems
        return visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil
    }

    func confirm() { activateAndClose() }

    /// A click must activate the card it landed on, not whatever the keyboard
    /// had selected. Falls back to cancel when the window vanished mid-click.
    func selectAndConfirm(id: CGWindowID) {
        guard let index = visibleItems.firstIndex(where: { $0.id == id }) else { cancel(); return }
        selectedIndex = index
        confirm()
    }

    func cancel() {
        closePanel()
        previousApp?.activate(options: [])
    }

    /// Test seam: activates the chosen target. The default un-minimizes,
    /// unhides or switches Space as needed, then raises the window.
    var activateTarget: (@MainActor (Item) -> Void) = { item in
        guard !PresetManager.isUIPreview else { return }
        let entry = SwitcherEntry(windowID: item.id, pid: item.pid, appName: item.appName, bundleID: item.bundleID,
                                  title: item.title, state: item.state, axWindow: item.axWindow,
                                  windowMenuItem: item.windowMenuItem, frame: .zero)
        SwitcherWindowActions.bringForward(entry, app: NSRunningApplication(processIdentifier: item.pid))
    }

    private func activateAndClose() {
        guard let item = selectedItem else { closePanel(); return }
        closePanel()
        activateTarget(item)
    }

    private func closePanel() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
        items = []
        query = ""
        note = nil
    }

    // MARK: Window commands

    private func closeSelectedWindow() {
        guard let item = selectedItem else { return }
        guard let window = item.axWindow else {
            note = "Switch to “\(item.title.isEmpty ? item.appName : item.title)” to close it: it's in another Space."
            return
        }
        SwitcherWindowActions.close(window) { [weak self] closed in
            guard let self else { return }
            if closed { self.items.removeAll { $0.id == item.id } } else { self.note = "\(item.appName) didn't close the window." }
        }
    }

    private func toggleMinimizeSelected() {
        guard let item = selectedItem, let window = item.axWindow else {
            note = "This window can't be minimized from here."
            return
        }
        let minimize = item.state != .minimized
        SwitcherWindowActions.setMinimized(window, minimize) { [weak self] done in
            guard let self, done, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].state = minimize ? .minimized : .normal
        }
    }

    private func hideSelectedApp() {
        guard let item = selectedItem, let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if app.hide() {
            for index in items.indices where items[index].pid == item.pid && items[index].state == .normal {
                items[index].state = .hidden
            }
        }
    }

    /// Asks the app to quit, as ⌘Q in the app would: it still asks about
    /// unsaved documents. Its windows leave the list once it has quit.
    private func quitSelectedApp() {
        guard let item = selectedItem, let app = NSRunningApplication(processIdentifier: item.pid),
              item.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if !app.terminate() { note = "\(item.appName) didn't quit." }
    }

    private func toggleGrouping() {
        groupsByApp.toggle()
        UserDefaults.standard.set(groupsByApp, forKey: Self.groupByAppKey)
        selectedIndex = 0
    }

    // MARK: Keys

    /// Cycling keys are routed here by KeyboardMonitor's event tap — the tap
    /// sees every keyDown first and would otherwise swallow the bound
    /// shortcut (⌥Tab re-pressed) before a local monitor could step.
    /// Returns true when the key belonged to the switcher.
    func handleSwitcherKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard isShowing else { return false }
        if modifiers.contains(.command) {
            switch keyCode {
            case 13: closeSelectedWindow() // W
            case 46: toggleMinimizeSelected() // M
            case 4: hideSelectedApp() // H
            case 12: if !isRepeat { quitSelectedApp() } // Q
            case 5: toggleGrouping() // G
            case 48: moveSelection(modifiers.contains(.shift) ? -1 : 1) // ⌘Tab-style triggers
            default: return false
            }
            return true
        }
        switch keyCode {
        case 123: step(-1) // left
        case 124: step(1) // right
        case 125: moveRow(1) // down
        case 126: moveRow(-1) // up
        case 48: step(modifiers.contains(.shift) ? -1 : 1) // Tab cycles like AltTab; ⇧Tab goes back
        case 36, 76: confirm() // return / enter
        case 53: // esc: the search first, then the switcher
            if query.isEmpty { cancel() } else { query = "" }
        default: return false
        }
        return true
    }

    private func installMonitors() {
        // A modifier was held when the switcher opened (e.g. ⌥Tab): releasing
        // it confirms. Releasing a modifier that was never held must not.
        sawHeldModifier = !initialModifiers.isEmpty
        let flags = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, self.isShowing else { return event }
            let held = event.modifierFlags.intersection([.command, .control, .option])
            if held.isEmpty {
                if self.sawHeldModifier && !self.searchMode { self.confirm() }
            } else {
                self.sawHeldModifier = true
            }
            return event
        }
        if let flags { monitors.append(flags) }
        // Typing while the trigger (⌥, ⌃) is still held searches with the
        // plain letters, not ⌥-characters ("å"); the panel's field gets the
        // rest, so Korean input methods work once the trigger is released.
        // The switcher's own keys are handled here too when KeyboardMonitor's
        // event tap isn't running, so ⌘Q never reaches AOM's Quit item.
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isShowing else { return event }
            if self.handleSwitcherKey(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat) {
                return nil
            }
            let held = event.modifierFlags.intersection([.option, .control])
            guard !held.isEmpty, !event.modifierFlags.contains(.command),
                  let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 else { return event }
            self.query.append(characters)
            return nil
        }
        if let keys { monitors.append(keys) }
        // A click on a card activates it (handled in SwiftUI); clicks in other
        // apps deactivate AOM, which also cancels — closing on any outside click.
        let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isShowing, event.window !== self.panel else { return event }
            self.cancel()
            return event
        }
        if let click { monitors.append(click) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isShowing else { return }
                    self.cancel()
                }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                else { return }
                MainActor.assumeIsolated { self?.items.removeAll { $0.pid == pid } }
            })
    }

    /// One selection step, repeated keys included so holding the trigger key
    /// cycles; the view animates every change.
    private func step(_ offset: Int) {
        withAnimation(AOMDesign.animation(.easeOut(duration: 0.12))) { moveSelection(offset) }
    }

    // MARK: Preview

    /// Isolated screenshots: made-up windows with drawn pictures and system
    /// app icons, never the user's windows.
    func showPreviewSample() {
        guard PresetManager.isUIPreview, panel == nil else { return }
        func icon(_ bundleID: String) -> NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let samples: [(String, String, String, SwitcherWindowState, NSColor)] = [
            ("Lecture notes — Week 9", "Notes", "com.apple.Notes", .normal, .systemYellow),
            ("Swift Forums", "Safari", "com.apple.Safari", .normal, .systemBlue),
            ("~/Projects — zsh", "Terminal", "com.apple.Terminal", .normal, .darkGray),
            ("Downloads", "Finder", "com.apple.finder", .normal, .systemTeal),
            ("Assignment 3.pages", "Pages", "com.apple.iWork.Pages", .otherSpace, .systemOrange),
            ("Calendar", "Calendar", "com.apple.iCal", .minimized, .systemRed),
            ("Music", "Music", "com.apple.Music", .hidden, .systemPink),
            ("과제방", "KakaoTalk", "com.kakao.KakaoTalkMac", .normal, .systemYellow),
        ]
        previousApp = nil
        initialModifiers = []
        query = ""
        items = samples.enumerated().map { index, sample in
            Item(id: CGWindowID(100 + index), title: sample.0, appName: sample.1, icon: icon(sample.2), axWindow: nil,
                 pid: pid_t(9000 + index), thumbnail: Self.sampleThumbnail(sample.4), state: sample.3, bundleID: nil,
                 windowMenuItem: nil)
        }
        selectedIndex = 1
        screenRecordingAllowed = true
        buildPanel()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.lastIndex(of: "--aom-preview-switcher-query"), arguments.indices.contains(index + 1) {
            query = arguments[index + 1]
        }
    }

    private static func sampleThumbnail(_ color: NSColor) -> CGImage? {
        let size = SwitcherThumbnailCache.pixelSize
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(color.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: 0, y: size.height - 36, width: size.width, height: 36))
        context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        for line in 0..<6 {
            let width = size.width * (line % 2 == 0 ? 0.78 : 0.56)
            context.fill(CGRect(x: 20, y: size.height - 64 - CGFloat(line) * 24, width: width, height: 10))
        }
        return context.makeImage()
    }
}

/// A borderless panel that still takes the keyboard (the search field and
/// the switcher's keys), without a title bar band above the grid.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The grid's measurements (thumbnail 176 × 112, AOMFeatureSize).
private enum SwitcherMetrics {
    static let cardWidth: CGFloat = AOMFeatureSize.switcherThumbnail.width + AOMSpace.x3
    static let cardHeight: CGFloat = AOMFeatureSize.switcherThumbnail.height + 52
    static let gap: CGFloat = AOMSpace.x2
    static let padding: CGFloat = AOMSpace.x4
    static let maximumColumns = 6
    static let maximumRows = 3
    static let minimumWidth: CGFloat = 640
    /// Search field, footer and padding.
    static let chromeHeight: CGFloat = 124
    static let emptyHeight: CGFloat = 140
}

private struct WindowSwitcherView: View {
    @ObservedObject var controller: WindowSwitcherController
    @FocusState private var searchFocused: Bool
    @State private var hovered: CGWindowID?

    var body: some View {
        let visible = controller.visibleItems
        VStack(spacing: 0) {
            searchField(count: visible.count)
            AOMDivider()
            if visible.isEmpty {
                emptyState
            } else {
                grid(visible)
            }
            AOMDivider()
            footer
        }
        // Glass chrome draws its own edge and shadow; nothing is added on top (c.4).
        .aomFloatingSurface(.panel, radius: AOMRadius.panel)
        .onAppear { searchFocused = true }
    }

    private func searchField(count: Int) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: "magnifyingglass")
                .font(AOMFont.body.weight(.medium))
                .foregroundStyle(AOMColor.textSecondary)
                .accessibilityHidden(true)
            TextField("Type to search windows", text: $controller.query)
                .textFieldStyle(.plain)
                .font(AOMFont.body)
                .focused($searchFocused)
                .accessibilityLabel("Search windows")
            Text(controller.query.isEmpty ? "\(count) window\(count == 1 ? "" : "s")" : "\(count) of \(controller.items.count)")
                .font(AOMFont.caption.monospacedDigit())
                .foregroundStyle(AOMColor.textTertiary)
            if controller.groupsByApp {
                AOMStatusPill("By App", tone: .neutral, symbol: "square.grid.2x2")
            }
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: AOMSize.rowStandard + AOMSpace.x1)
    }

    private func grid(_ visible: [WindowSwitcherController.Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(SwitcherMetrics.cardWidth), spacing: SwitcherMetrics.gap,
                                                             alignment: .top),
                                         count: max(1, controller.columns)),
                          spacing: SwitcherMetrics.gap) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == controller.selectedIndex
                        WindowSwitcherCard(item: item, isSelected: isSelected, isHovered: hovered == item.id)
                            .onTapGesture { controller.selectAndConfirm(id: item.id) }
                            .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(accessibilityLabel(item))
                            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                            .accessibilityAction { controller.selectAndConfirm(id: item.id) }
                            .id(item.id)
                    }
                }
                .padding(SwitcherMetrics.padding)
            }
            .aomAnimation(.quick, value: controller.selectedIndex)
            .onChange(of: controller.selectedIndex) { _, newIndex in
                guard visible.indices.contains(newIndex) else { return }
                proxy.scrollTo(visible[newIndex].id, anchor: nil)
            }
        }
    }

    private func accessibilityLabel(_ item: WindowSwitcherController.Item) -> String {
        [item.appName, item.title.isEmpty ? "window" : item.title, item.state.label].compactMap { $0 }.joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: controller.query.isEmpty ? "macwindow.on.rectangle" : "magnifyingglass")
                .font(AOMFont.title.weight(.regular)).imageScale(.large)
                .foregroundStyle(AOMColor.textSecondary)
                .accessibilityHidden(true)
            Text(controller.query.isEmpty ? "No windows to switch to" : "No windows match “\(controller.query)”")
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
            if !controller.screenRecordingAllowed {
                Text("Allow Screen Recording for All of MacOS to see window titles and pictures.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(AOMSpace.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: AOMSpace.x3) {
            if let note = controller.note {
                Label(note, systemImage: "info.circle")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            } else if !controller.screenRecordingAllowed {
                Label("Pictures need Screen Recording", systemImage: "rectangle.dashed")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x2)
            hint("Switch", "↩")
            hint("Close", "⌘W")
            hint("Minimize", "⌘M")
            hint("Hide", "⌘H")
            hint("Quit", "⌘Q")
            hint("Group", "⌘G")
            hint(controller.query.isEmpty ? "Cancel" : "Clear", "esc")
        }
        .padding(.horizontal, AOMSpace.x4)
        .frame(height: AOMSize.rowStandard)
        .background(AOMColor.track)
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: AOMSpace.x1) {
            Text(title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            AOMKeycap(text: keys)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct WindowSwitcherCard: View {
    let item: WindowSwitcherController.Item
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            ZStack(alignment: .bottomLeading) {
                picture
                    .frame(width: AOMFeatureSize.switcherThumbnail.width, height: AOMFeatureSize.switcherThumbnail.height)
                    .background(AOMColor.raised,
                                in: RoundedRectangle(cornerRadius: AOMRadius.concentric(AOMRadius.card, inset: AOMSpace.x1 + AOMSpace.x0_5),
                                                     style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: AOMRadius.concentric(AOMRadius.card, inset: AOMSpace.x1 + AOMSpace.x0_5),
                                                style: .continuous))
                    .opacity(item.state == .minimized || item.state == .hidden ? 0.7 : 1)
                if item.thumbnail != nil, let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: AOMIcon.listBadge + AOMSpace.x1, height: AOMIcon.listBadge + AOMSpace.x1)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(AOMSpace.x1)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let label = item.state.label {
                    AOMStatusPill(label, tone: .neutral, symbol: stateSymbol)
                        .padding(AOMSpace.x1)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(AOMFont.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1).truncationMode(.middle)
                if !item.title.isEmpty {
                    Text(item.appName)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: AOMFeatureSize.switcherThumbnail.width, alignment: .leading)
        }
        .padding(AOMSpace.x1 + AOMSpace.x0_5)
        .background(isSelected ? AOMColor.selection.opacity(contrast == .increased ? 0.32 : 0.2)
                               : (isHovered ? AOMColor.rowHover : .clear), in: shape)
        .aomFocusRing(isSelected, radius: AOMRadius.card)
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail = item.thumbnail {
            Image(decorative: thumbnail, scale: 2).resizable().scaledToFit()
        } else if let icon = item.icon {
            Image(nsImage: icon).resizable().scaledToFit().padding(AOMSpace.x6)
        } else {
            Image(systemName: "macwindow").font(AOMFont.title.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
        }
    }

    private var stateSymbol: String {
        switch item.state {
        case .minimized: return "arrow.down.right.and.arrow.up.left"
        case .hidden: return "eye.slash"
        case .otherSpace: return "rectangle.on.rectangle"
        case .normal: return "macwindow"
        }
    }
}
