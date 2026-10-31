import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Decides when "hold ⌘" means "show the shortcuts": ⌘ alone goes down and
/// nothing else happens for the hold time. Any key (⌘C is a shortcut, not a
/// hold), any mouse button or any other modifier cancels it. Pure, so the
/// rule is testable without event monitors.
struct PaletteHoldDetector: Equatable {
    enum Event: Equatable {
        case modifiers(NSEvent.ModifierFlags)
        case key
        case mouse
    }

    enum Output: Equatable {
        case none
        /// Start the hold timer.
        case arm
        /// Cancel the timer and hide the sheet.
        case disarm
    }

    private(set) var armed = false

    static let considered: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    mutating func handle(_ event: Event) -> Output {
        switch event {
        case .modifiers(let flags):
            let held = flags.intersection(Self.considered)
            if held == .command {
                if armed { return .none }
                armed = true
                return .arm
            }
            return disarm()
        case .key, .mouse:
            return disarm()
        }
    }

    private mutating func disarm() -> Output {
        guard armed else { return .none }
        armed = false
        return .disarm
    }
}

/// KeyClu-style shortcut sheet: hold ⌘ for a moment in any app and its menu
/// shortcuts appear in a centred HUD, grouped by menu; let go and it's gone.
/// Off by default; the event monitors exist only while it is on. The menus
/// come from the palette's menu index (read off the main thread, kept 10
/// minutes per app version).
@MainActor
final class PaletteShortcutSheet {
    static let shared = PaletteShortcutSheet()
    static let enabledKey = "AOMPaletteShortcutSheetEnabled"
    static let holdKey = "AOMPaletteShortcutSheetHoldSeconds"
    static let holdRange: ClosedRange<Double> = 0.8...2.0
    static let defaultHold = 1.2

    private var monitors: [Any] = []
    private var detector = PaletteHoldDetector()
    private var timer: DispatchWorkItem?
    private var prefetch: DispatchWorkItem?
    private var panel: NSPanel?
    /// Opened from the palette: stays until Esc or a click.
    private var sticky = false
    private var stickyMonitors: [Any] = []
    private var generation = 0
    private var armedAt: TimeInterval = 0

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var holdSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: Self.holdKey)
        return stored == 0 ? Self.defaultHold : min(Self.holdRange.upperBound, max(Self.holdRange.lowerBound, stored))
    }

    var holdDescription: String { String(format: "%.1f s", holdSeconds) }

    /// At launch (PaletteModule.start): installs the monitors when the switch is on.
    func start() {
        guard isEnabled, monitors.isEmpty, !PresetManager.isUIPreview, NSClassFromString("XCTestCase") == nil else { return }
        install()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { uninstall() }
    }

    func setHoldSeconds(_ seconds: Double) {
        UserDefaults.standard.set(min(Self.holdRange.upperBound, max(Self.holdRange.lowerBound, seconds)), forKey: Self.holdKey)
    }

    private func install() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                                                  .otherMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        cancelTimers()
        if !sticky { hide() }
    }

    private func handle(_ event: NSEvent) {
        let input: PaletteHoldDetector.Event
        switch event.type {
        case .flagsChanged: input = .modifiers(event.modifierFlags)
        case .keyDown: input = .key
        default: input = .mouse
        }
        switch detector.handle(input) {
        case .none: break
        case .arm: arm()
        case .disarm:
            cancelTimers()
            if !sticky { hide() }
        }
    }

    private func arm() {
        cancelTimers()
        armedAt = ProcessInfo.processInfo.systemUptime
        let hold = holdSeconds
        let prefetch = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load(show: false) } }
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load(show: true) } }
        self.prefetch = prefetch
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + hold / 2, execute: prefetch)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: timer)
    }

    /// Whether ⌘ has been held alone since `armedAt`: still down with no
    /// other modifier, and no key or click since, counting the ones the
    /// system keeps for itself (⌘Tab, ⌘Space never reach app monitors).
    static func isStillAHold(since armedAt: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard NSEvent.modifierFlags.intersection(PaletteHoldDetector.considered) == .command else { return false }
        let elapsed = now - armedAt
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.allSatisfy { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= elapsed - 0.02 }
    }

    private func cancelTimers() {
        timer?.cancel(); timer = nil
        prefetch?.cancel(); prefetch = nil
        generation += 1
    }

    /// The app the sheet is for, or nil when it must not appear: AOM itself,
    /// a game, secure input (a password field), Pause AOM, a mouse button held.
    static func eligibleFrontApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSEvent.pressedMouseButtons == 0, !IsSecureEventInputEnabled(), AutomationGate.isOn else { return nil }
        if let url = app.bundleURL, let bundle = Bundle(url: url),
           let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category.contains("games") { return nil }
        return app
    }

    private func load(show: Bool) {
        guard Self.isStillAHold(since: armedAt), let app = Self.eligibleFrontApp() else { return }
        present(for: app, show: show, sticky: false)
    }

    /// From the palette ("Show Keyboard Shortcuts for …"): the app that was in
    /// front before it, shown until Esc or a click.
    func showForPreviousApp() {
        guard let app = PaletteSession.previousApp() else {
            GestureHUD.shared.show(title: "No App to Show", detail: "Open an app first.")
            return
        }
        app.activate(options: [])
        present(for: app, show: true, sticky: true)
    }

    private func present(for app: NSRunningApplication, show: Bool, sticky: Bool) {
        generation += 1
        let current = generation
        let pid = app.processIdentifier
        let name = app.localizedName ?? "App"
        let bundleID = app.bundleIdentifier
        let version = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let icon = app.icon
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                PaletteMenuIndex.shared.snapshot(pid: pid, appName: name, bundleID: bundleID, version: version,
                                                 maxAge: PaletteMenuIndex.sheetLifetime)
            }.value
            guard let self, show else { return }
            // Still held (or opened from the palette)?
            guard sticky || (current == self.generation && self.detector.armed && Self.isStillAHold(since: self.armedAt)) else { return }
            switch result {
            case .success(let snapshot):
                let groups = PaletteMenuSearch.shortcutGroups(snapshot.items)
                guard !groups.isEmpty else {
                    if sticky { GestureHUD.shared.show(title: "No Shortcuts", detail: "\(name) has no menu shortcuts.") }
                    return
                }
                self.showPanel(PaletteShortcutSheetContent(appName: name, icon: icon, groups: groups, sticky: sticky), sticky: sticky)
            case .failure(.notTrusted):
                if sticky { GestureHUD.shared.show(title: "Accessibility Needed", detail: "Allow All of MacOS in Privacy & Security › Accessibility.") }
            case .failure(.unreadable):
                if sticky { GestureHUD.shared.show(title: "Couldn't Read Menus", detail: "\(name) didn't answer.") }
            }
        }
    }

    private func showPanel(_ content: PaletteShortcutSheetContent, sticky: Bool) {
        hide()
        self.sticky = sticky
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let host = NSHostingView(rootView: PaletteShortcutSheetView(content: content, maxSize: CGSize(width: visible.width * 0.9,
                                                                                                      height: visible.height * 0.86)))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !sticky
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        guard sticky else { return }
        // A sticky sheet closes on Esc, a click or the next app switch.
        let keys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
        stickyMonitors = [keys, local].compactMap { $0 }
    }

    func hide() {
        stickyMonitors.forEach { NSEvent.removeMonitor($0) }
        stickyMonitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        sticky = false
    }

    /// Isolated screenshots: a made-up app's shortcuts.
    func showPreviewSample() {
        guard PresetManager.isUIPreview else { return }
        let nodes = [
            PaletteMenuNode(title: "File", children: [
                PaletteMenuNode(title: "New Window", commandCharacter: "N"),
                PaletteMenuNode(title: "New Tab", commandCharacter: "T"),
                PaletteMenuNode(title: "Open File…", commandCharacter: "O"),
                PaletteMenuNode(title: "Close Tab", commandCharacter: "W"),
                PaletteMenuNode(title: "Export as PDF…", commandCharacter: "E", commandModifiers: 1),
            ]),
            PaletteMenuNode(title: "Edit", children: [
                PaletteMenuNode(title: "Undo", commandCharacter: "Z"),
                PaletteMenuNode(title: "Redo", commandCharacter: "Z", commandModifiers: 1),
                PaletteMenuNode(title: "Copy", commandCharacter: "C"),
                PaletteMenuNode(title: "Paste and Match Style", commandCharacter: "V", commandModifiers: 3),
                PaletteMenuNode(title: "Find…", commandCharacter: "F"),
            ]),
            PaletteMenuNode(title: "View", children: [
                PaletteMenuNode(title: "Show Sidebar", commandCharacter: "S", commandModifiers: 4),
                PaletteMenuNode(title: "Enter Full Screen", commandCharacter: "F", commandModifiers: 4),
                PaletteMenuNode(title: "Zoom In", commandCharacter: "+"),
                PaletteMenuNode(title: "Zoom Out", commandCharacter: "-"),
            ]),
            PaletteMenuNode(title: "Window", children: [
                PaletteMenuNode(title: "Minimize", commandCharacter: "M"),
                PaletteMenuNode(title: "Show Previous Tab", commandModifiers: 6, commandGlyph: 0x64),
                PaletteMenuNode(title: "Show Next Tab", commandModifiers: 6, commandGlyph: 0x65),
            ]),
        ]
        let items = PaletteMenuFlattener.flatten(nodes).map(\.item)
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        showPanel(PaletteShortcutSheetContent(appName: "Safari", icon: icon,
                                              groups: PaletteMenuSearch.shortcutGroups(items), sticky: true), sticky: true)
    }
}

struct PaletteShortcutSheetContent {
    let appName: String
    let icon: NSImage?
    let groups: [(menu: String, items: [PaletteMenuItem])]
    let sticky: Bool
}

/// The HUD: one column per menu (File, Edit, View …), each row the item's
/// title with its key caps trailing.
private struct PaletteShortcutSheetView: View {
    let content: PaletteShortcutSheetContent
    let maxSize: CGSize

    private static let columnWidth: CGFloat = 250
    private static let rowsPerColumn = 18

    /// Long menus are split over columns; at most five columns, the rest is
    /// counted in the footer.
    private var columns: [(title: String, items: [PaletteMenuItem])] {
        var result: [(title: String, items: [PaletteMenuItem])] = []
        for group in content.groups {
            let chunks = stride(from: 0, to: group.items.count, by: Self.rowsPerColumn).map {
                Array(group.items[$0..<min($0 + Self.rowsPerColumn, group.items.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                result.append((title: index == 0 ? group.menu : "\(group.menu) (cont.)", items: chunk))
            }
        }
        let fitting = max(1, min(5, Int(maxSize.width / (Self.columnWidth + AOMSpace.x4))))
        return Array(result.prefix(fitting))
    }

    private var hiddenCount: Int {
        let shown = columns.reduce(0) { $0 + $1.items.count }
        return content.groups.reduce(0) { $0 + $1.items.count } - shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                if let icon = content.icon {
                    Image(nsImage: icon).resizable().frame(width: AOMIcon.listBadge + AOMSpace.x2, height: AOMIcon.listBadge + AOMSpace.x2)
                        .accessibilityHidden(true)
                }
                Text("\(content.appName) Shortcuts").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                Spacer(minLength: AOMSpace.x4)
                Text(content.sticky ? "Press any key to close" : "Release ⌘ to close")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
            }
            HStack(alignment: .top, spacing: AOMSpace.x4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: AOMSpace.x1) {
                        Text(column.title)
                            .font(AOMFont.caption.weight(.semibold))
                            .foregroundStyle(AOMColor.textSecondary)
                            .padding(.bottom, AOMSpace.x0_5)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(column.items) { item in
                            HStack(spacing: AOMSpace.x2) {
                                Text(item.title)
                                    .font(AOMFont.callout)
                                    .foregroundStyle(item.isEnabled ? AOMColor.text : AOMColor.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: AOMSpace.x2)
                                if let keys = item.shortcut {
                                    HStack(spacing: AOMSpace.x0_5) {
                                        ForEach(Array(AOMShortcutKeys.parts(keys).enumerated()), id: \.offset) { _, part in
                                            AOMKeycap(text: part)
                                        }
                                    }
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.title), \(item.shortcut ?? "")")
                        }
                    }
                    .frame(width: Self.columnWidth, alignment: .topLeading)
                }
            }
            if hiddenCount > 0 {
                Text("\(hiddenCount) more in menus not shown")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textTertiary)
            }
        }
        .padding(AOMSpace.x5)
        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: .topLeading)
        .fixedSize()
        .aomFloatingSurface(.hud, radius: AOMRadius.hud)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.appName) keyboard shortcuts")
    }
}

/// The switch and the hold time for Settings › Shortcuts (design-340 b.17).
/// The integrator places this in the Shortcuts pane.
struct PaletteShortcutSheetSettings: View {
    @AppStorage(PaletteShortcutSheet.enabledKey) private var enabled = false
    @AppStorage(PaletteShortcutSheet.holdKey) private var hold = PaletteShortcutSheet.defaultHold

    var body: some View {
        AOMSection("Shortcut sheet", footer: "Holding ⌘ alone shows the front app's menu shortcuts; any key, click or other modifier cancels it. Never in games, password fields or while AOM is paused.") {
            AOMToggleRow("Hold ⌘ to show the app's shortcuts", detail: "Like KeyClu: release ⌘ to close",
                         symbol: "command", isOn: Binding(get: { enabled }, set: { value in
                             enabled = value
                             PaletteShortcutSheet.shared.setEnabled(value)
                         }))
            AOMSettingRow("Hold time", detail: String(format: "%.1f seconds", hold), symbol: "timer") {
                Slider(value: $hold, in: PaletteShortcutSheet.holdRange, step: 0.1)
                    .frame(width: AOMFeatureSize.keyPicker)
                    .disabled(!enabled)
                    .accessibilityLabel("Hold time")
                    .accessibilityValue(String(format: "%.1f seconds", hold))
            }
        }
    }
}
