import AppKit
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
            if let notch = display.notch, notch.intersects(frame.insetBy(dx: 2, dy: 0)) { return Placed(item: item, hidden: true) }
            return Placed(item: item, hidden: !display.frame.contains(frame))
        }
        return placed.sorted { a, b in
            if a.hidden != b.hidden { return a.hidden }
            return (a.item.frame?.minX ?? -.infinity) > (b.item.frame?.minX ?? -.infinity)
        }
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

@MainActor
final class MenuBarStripController: ObservableObject {
    static let shared = MenuBarStripController()

    @Published private(set) var placed: [MenuBarStripPolicy.Placed] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published var selection = 0
    private var panel: MenuBarStripPanel?
    private var generation = 0
    private let worker = DispatchQueue(label: "com.kyw.aom.menubar-strip-ax", qos: .userInitiated)

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { if isVisible { dismiss() } else { show() } }

    func show() {
        guard !ScreenLock.isLocked else { return }
        guard AXIsProcessTrusted() else {
            GestureHUD.shared.show(title: "Menu Bar Strip", detail: "Needs Accessibility to read other apps' menu bar items: System Settings › Privacy & Security › Accessibility.")
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let width = min(screen.visibleFrame.width - 40, 1100)
        let height: CGFloat = 92
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - max(24, menuBar) - height - 6, width: width, height: height),
                       display: true)
        selection = 0
        panel.makeKeyAndOrderFront(nil)
        scan()
    }

    func dismiss() {
        generation += 1
        panel?.orderOut(nil)
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
        panel.onKey = { [weak self] code in
            guard let self else { return false }
            switch code {
            case 123: self.move(-1)
            case 124: self.move(1)
            case 36, 76: self.open()
            case 53: self.dismiss()
            default: return false
            }
            return true
        }
        return panel
    }

    private func scan() {
        generation += 1
        let mine = generation
        loading = true
        message = nil
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AOMMenuShelfApp? in
            guard app.processIdentifier > 0 else { return nil }
            return AOMMenuShelfApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                   name: app.localizedName ?? app.bundleIdentifier ?? "App")
        }
        let displays = MenuBarStripPolicy.displays()
        worker.async { [weak self] in
            let snapshot = AOMMenuShelfProbe.snapshot(apps: apps)
            let placed = MenuBarStripPolicy.arrange(snapshot.items, displays: displays)
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.generation else { return }
                self.loading = false
                self.placed = placed
                self.selection = 0
                if placed.isEmpty { self.message = "No menu bar items could be read." }
                else if snapshot.appsLeft > 0 { self.message = "Some items: \(snapshot.appsLeft) app\(snapshot.appsLeft == 1 ? "" : "s") didn't answer in time." }
            }
        }
    }

    func move(_ delta: Int) {
        guard !placed.isEmpty else { return }
        selection = (selection + delta + placed.count) % placed.count
    }

    func open(_ index: Int? = nil) {
        let index = index ?? selection
        guard placed.indices.contains(index) else { return }
        let item = placed[index].item
        dismiss()
        // The panel is gone before the press, so it can't take the menu's click.
        AOMMenuShelfController.shared.activate(item)
    }
}

private struct MenuBarStripView: View {
    @ObservedObject var controller: MenuBarStripController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Menu Bar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let message = controller.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
                Text("← → move · ↩ open · esc close").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if controller.loading && controller.placed.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(controller.placed.enumerated()), id: \.element.item.id) { index, placed in
                                chip(placed, selected: index == controller.selection)
                                    .id(index)
                                    .onTapGesture { controller.open(index) }
                            }
                        }
                    }
                    .onChange(of: controller.selection) { _, value in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) } }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar items")
    }

    private func chip(_ placed: MenuBarStripPolicy.Placed, selected: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon = NSRunningApplication(processIdentifier: placed.item.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app").frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(placed.item.title).font(.system(size: 12)).lineLimit(1)
                Text(placed.hidden ? "\(placed.item.ownerName) · hidden" : placed.item.ownerName)
                    .font(.system(size: 10)).foregroundStyle(placed.hidden ? Color.orange : .secondary).lineLimit(1)
            }
            .frame(maxWidth: 160, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(placed.item.title), \(placed.item.ownerName)\(placed.hidden ? ", hidden" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
