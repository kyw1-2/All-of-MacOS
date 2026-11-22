import AppKit
import Combine
import SwiftUI

/// 7.6 (Codex M08; Ice Bar, Bartender Bar): every menu bar icon AOM can
/// reach, in one row just under the menu bar of the display you are on —
/// for when you don't know what to search for. Icons hidden behind the
/// notch or pushed off by the Menu Bar Hider come first. ← → moves, ↩
/// opens the item's own menu, esc closes and leaves the app you were in in
/// front. It reuses the Menu Bar Shelf's inventory and its one-match press,
/// shows app icons and item names (no Screen Recording), and moves nothing.
enum MenuBarStripPolicy {
    struct Placed: Equatable {
        let item: AOMMenuShelfItem
        /// Behind the notch, off the screen, or without a position.
        let hidden: Bool
    }

    /// A display in Accessibility coordinates (top-left origin, y down) and its notch.
    struct Display: Equatable {
        let frame: CGRect
        var notch: CGRect?
    }

    /// Pure: hidden items first (right to left, as they sit), then the
    /// rest right to left; items without a position count as hidden.
    static func arrange(_ items: [AOMMenuShelfItem], displays: [Display]) -> [Placed] {
        let placed = items.map { item -> Placed in
            guard let frame = item.frame, frame.width > 0 else { return Placed(item: item, hidden: true) }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let display = displays.first(where: { $0.frame.contains(center) }) else { return Placed(item: item, hidden: true) }
            // A sliver isn't shrunk to nothing before the notch test.
            let probe = frame.width > 6 ? frame.insetBy(dx: 2, dy: 0) : frame
            if let notch = display.notch, notch.intersects(probe) { return Placed(item: item, hidden: true) }
            return Placed(item: item, hidden: !display.frame.contains(frame))
        }
        return placed.sorted { a, b in
            if a.hidden != b.hidden { return a.hidden }
            return (a.item.frame?.minX ?? -.infinity) > (b.item.frame?.minX ?? -.infinity)
        }
    }

    /// Pure: AOM's own Hider dividers aren't something to open (Gemini 7.6 idea).
    static func isOwnDivider(_ item: AOMMenuShelfItem, ownPID: pid_t) -> Bool {
        item.pid == ownPID && item.title.localizedCaseInsensitiveContains("divider")
    }

    /// Pure: an AppKit screen rect (bottom-left origin) in Accessibility coordinates.
    static func axRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displays() -> [Display] {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            Display(frame: axRect(screen.frame, primaryHeight: primary),
                    notch: GestureHUD.notchRect(screen).map { axRect($0, primaryHeight: primary) })
        }
    }
}

private final class MenuBarStripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// ← → ↩ esc, taken before any view sees them.
    var onKey: ((UInt16) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event.keyCode) { return }
        super.sendEvent(event)
    }
}

/// 7.9: the Bartender Bar. A strip of the menu bar's own colour just under
/// it, right-aligned below the Hider's chevron (or under the pointer), with
/// each hidden item's picture and nothing else — hover names it, a click opens
/// its menu. Hidden items come back into the menu bar for that click and hide
/// again on the Hider's timer, which waits while their menu is open. ← → and
/// ↩ or 1–9 open one; esc or a click elsewhere closes. Without the Hider it
/// shows every item.
@MainActor
final class MenuBarStripController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MenuBarStripController()

    @Published var selection = 0
    @Published private(set) var hovered: String?
    /// Always Hidden icons too — ⌥-click or the bar's eye button (Gemini 7.9:
    /// the lane promises "only with ⌥-click or Show All").
    @Published var includeAlways = false
    private var panel: MenuBarStripPanel?
    private var observer: AnyCancellable?
    private var leaveWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// What the bar lists: hidden then always-hidden (Bartender Bar), or
    /// everything when nothing is hidden; locked system items stay off it.
    var entries: [MenuBarLayoutItem] {
        let model = MenuBarLayoutModel.shared
        let lanes = model.lanes
        let hidden = (lanes[.hidden] ?? []) + (includeAlways ? (lanes[.alwaysHidden] ?? []) : [])
        let list = MenuBarHider.shared.isRunning || model.isSample ? hidden : (lanes[.shown] ?? [])
        return list.filter { $0.lockedReason == nil || $0.section != .shown }
    }

    func toggle(includeAlways: Bool = false) { if isVisible { dismiss() } else { show(includeAlways: includeAlways) } }

    func show(includeAlways: Bool = false) {
        guard !ScreenLock.isLocked else { return }
        self.includeAlways = includeAlways
        let model = MenuBarLayoutModel.shared
        guard AXIsProcessTrusted() || model.isSample else {
            GestureHUD.shared.show(title: "Menu Bar", detail: "Needs Accessibility to read other apps' menu bar items: System Settings › Privacy & Security › Accessibility.")
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        selection = 0
        place(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        // The pictures come from the last full read (the Layout page); a
        // quick read here keeps the list current without revealing anything.
        if !model.isSample, !model.busy, Date().timeIntervalSince(model.lastRefresh ?? .distantPast) > 20 {
            model.refresh(reveal: false)
        }
        observer = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { if let panel = self?.panel, panel.isVisible { self?.place(panel) } }
        }
    }

    func dismiss() {
        observer = nil
        leaveWork?.cancel()
        panel?.orderOut(nil)
    }

    func setIncludeAlways(_ on: Bool) {
        includeAlways = on
        selection = 0
        if let panel, panel.isVisible { place(panel) }
    }

    /// Bartender: the bar goes a moment after the pointer leaves it.
    func pointerInside(_ inside: Bool) {
        leaveWork?.cancel()
        guard !inside, !PresetManager.isUIPreview else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Pure: each tile is its picture's width (28–44 pt) plus padding; the
    /// row ends with the bar's three buttons (Gemini 7.9: a fixed 34 pt a tile
    /// cut wide icons off).
    static func width(tiles: [CGFloat], screen: CGFloat) -> CGFloat {
        let icons = tiles.reduce(0) { $0 + min(44, max(28, $1)) + 6 }
        return min(max(160, icons + 12 + 3 * 26 + 10), screen - 16)
    }

    /// Right-aligned under the chevron on its display, else under the pointer.
    private func place(_ panel: MenuBarStripPanel) {
        let model = MenuBarLayoutModel.shared
        let tiles = entries.map { model.images[$0.imageKey]?.size.width ?? 28 }
        let anchorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let width = Self.width(tiles: tiles, screen: anchorScreen?.frame.width ?? 1200)
        let height: CGFloat = 34
        let chevron = MenuBarHider.shared.isRunning ? MenuBarHider.shared.toggleWindowFrame : nil
        let anchorPoint = chevron.map { CGPoint(x: $0.maxX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) }) ?? NSScreen.main else { return }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        var x = (chevron?.maxX ?? anchorPoint.x + width / 2) - width
        x = min(max(screen.frame.minX + 8, x), screen.frame.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: screen.frame.maxY - menuBar - height - 4, width: width, height: height), display: true)
    }

    private func makePanel() -> MenuBarStripPanel {
        let panel = MenuBarStripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MenuBarStripView(controller: self))
        // Clicking anywhere else closes it (Gemini 7.6 review).
        panel.delegate = self
        panel.onKey = { [weak self] code in
            guard let self else { return false }
            switch code {
            case 123: self.move(-1)
            case 124: self.move(1)
            case 36, 76: self.open()
            case 53: self.dismiss()
            // 1–9 open the first nine.
            case 18, 19, 20, 21, 23, 22, 26, 28, 25:
                let order: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                self.open(order.firstIndex(of: code))
            default: return false
            }
            return true
        }
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !PresetManager.isUIPreview else { return }
        dismiss()
    }

    func setHovered(_ id: String?) { if hovered != id { hovered = id } }

    func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func open(_ index: Int? = nil) {
        let list = entries
        let index = index ?? selection
        guard list.indices.contains(index) else { return }
        dismiss()
        openItem(list[index].item, section: list[index].section)
    }

    /// Opens an item's own menu; a hidden one first comes back into the
    /// menu bar (Bartender's "show and click"), and hides again later on the
    /// Hider's timer, which waits while its menu is open.
    func openItem(_ item: AOMMenuShelfItem, section: MenuBarSection) {
        let hider = MenuBarHider.shared
        // 7.10 (macOS 27): the app is let back into the menu bar for this
        // click, then hidden again once its menu has closed.
        if hider.native, section != .shown, MenuBarNativeHiding.shared.isHolding {
            MenuBarNativeHiding.shared.showTemporarily(item.ownerBundleID) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    AOMMenuShelfController.shared.activate(item, retry: "Open the bar and pick it again.")
                }
            }
            return
        }
        // Gemini 7.9: an always-hidden item needs Show All even when the
        // ordinary hidden ones are already out.
        let reveal = hider.isRunning && ((section == .hidden && hider.isCollapsed)
            || (section == .alwaysHidden && (hider.isCollapsed || !hider.showsAll)))
        if reveal { hider.expand(all: section == .alwaysHidden) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reveal ? 0.35 : 0)) {
            AOMMenuShelfController.shared.activate(item, retry: "Open the bar and pick it again.")
        }
    }
}

private struct MenuBarStripView: View {
    @ObservedObject var controller: MenuBarStripController
    @ObservedObject private var model = MenuBarLayoutModel.shared

    var body: some View {
        let entries = controller.entries
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 4) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        Spacer(minLength: 0)
                        if entries.isEmpty {
                            Text(model.busy ? "Reading the menu bar…" : "Nothing hidden")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            icon(entry, selected: index == controller.selection, hovered: controller.hovered == entry.id)
                                .onTapGesture { controller.open(index) }
                                .onHover { inside in controller.setHovered(inside ? entry.id : nil) }
                                .help(entry.item.displayName)
                        }
                    }
                    .frame(minWidth: geometry.size.width, maxHeight: .infinity, alignment: .trailing)
                }
            }
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18)
            barButton(controller.includeAlways ? "eye.fill" : "eye", help: controller.includeAlways ? "Hide Always Hidden icons" : "Show Always Hidden icons too") {
                controller.setIncludeAlways(!controller.includeAlways)
            }
            barButton("magnifyingglass", help: "Search every menu bar icon") {
                controller.dismiss(); AOMMenuShelfController.shared.show()
            }
            barButton("gearshape", help: "Arrange the menu bar") {
                controller.dismiss(); MenuBarNavigation.open()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { controller.pointerInside($0) }
        .background {
            ZStack {
                VisualEffectBackground(material: .menu, blendingMode: .behindWindow, state: .active, cornerRadius: 10)
                if let color = model.barColor { Color(nsColor: color).opacity(0.55) }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hidden menu bar items")
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func icon(_ entry: MenuBarLayoutItem, selected: Bool, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Group {
            if let image = model.images[entry.imageKey] {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 44, maxHeight: 22)
            } else {
                MenuBarItemGlyph(item: entry.item, size: 16)
            }
        }
        .frame(minWidth: 28, minHeight: 26)
        .padding(.horizontal, 2)
        .background(selected || hovered ? Color.primary.opacity(selected ? 0.16 : 0.09) : .clear, in: shape)
        .contentShape(shape)
        .accessibilityElement()
        .accessibilityLabel(entry.item.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
