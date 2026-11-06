import AppKit
import SwiftUI
import ApplicationServices
import Combine

// macOS 27 merges many status items into a single WindowServer "Menubar"
// surface. Enumerate the owning accessibility menus instead of assuming that
// each extra has a CGWindow and moving unrelated apps' windows off-screen.
// The shelf NEVER changes another process's menu-bar item position.
struct AOMMenuShelfItem: Identifiable, Equatable {
    let pid: pid_t
    let ownerBundleID: String
    let ownerName: String
    let title: String
    let axIdentifier: String
    let ordinal: Int

    var id: String {
        let key = axIdentifier.isEmpty ? "\(ordinal)|\(title)" : axIdentifier
        return "\(ownerBundleID)|\(key)"
    }
}

enum AOMMenuShelfPolicy {
    static func ordered(_ items: [AOMMenuShelfItem], pinned: Set<String>, query: String) -> [AOMMenuShelfItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var unique = Set<String>()
        return items.filter { unique.insert($0.id).inserted }
            .filter { q.isEmpty || $0.title.lowercased().contains(q)
                || $0.ownerName.lowercased().contains(q) || $0.ownerBundleID.lowercased().contains(q) }
            .sorted {
                let a = pinned.contains($0.id), b = pinned.contains($1.id)
                if a != b { return a }
                let lhs = $0.ownerName.localizedStandardCompare($1.ownerName)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    static func safeHoverZone(_ point: CGPoint, screen: CGRect, menuBarHeight: CGFloat = 24) -> Bool {
        // Centre of the physical top edge: appropriate for a notched screen,
        // but never the user's regular document or browser content.
        guard screen.width > 300, screen.height > 300 else { return false }
        return point.y >= screen.maxY - menuBarHeight &&
               point.y <= screen.maxY &&
               abs(point.x - screen.midX) <= min(180, screen.width * 0.18)
    }
}

private struct AOMMenuShelfApp: Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String
}

/// Accessibility requests must never block AppKit's main thread.
/// A response uses immutable identifiers, not retained foreign AXUIElements:
/// the target is resolved again immediately before it is pressed.
private enum AOMMenuShelfProbe {
    private static func attribute(_ el: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key, &value) == .success ? value : nil
    }

    private static func string(_ el: AXUIElement, _ key: CFString) -> String {
        attribute(el, key) as? String ?? ""
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attribute(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func items(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        // AXExtrasMenuBar works for normal status items and Apple menu extras.
        if let bar = attribute(app, "AXExtrasMenuBar" as CFString),
           CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let menu = bar as! AXUIElement
            AXUIElementSetMessagingTimeout(menu, 0.12)
            return children(menu)
        }
        // Some hosts publish extras under their ordinary AXMenuBar instead.
        if let bar = attribute(app, kAXMenuBarAttribute),
           CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let menu = bar as! AXUIElement
            AXUIElementSetMessagingTimeout(menu, 0.12)
            return children(menu).filter { string($0, kAXSubroleAttribute) == "AXMenuExtra" }
        }
        return []
    }

    static func snapshot(apps: [AOMMenuShelfApp], deadline: TimeInterval = 2.0) -> [AOMMenuShelfItem] {
        let started = ProcessInfo.processInfo.systemUptime
        var result: [AOMMenuShelfItem] = []
        for app in apps.prefix(90) {
            if ProcessInfo.processInfo.systemUptime - started >= deadline { break }
            for (index, element) in items(pid: app.pid).prefix(30).enumerated() {
                AXUIElementSetMessagingTimeout(element, 0.1)
                let identifier = string(element, kAXIdentifierAttribute)
                let title = [
                    string(element, kAXTitleAttribute),
                    string(element, kAXDescriptionAttribute),
                    string(element, kAXHelpAttribute)
                ].first { !$0.isEmpty } ?? "Item \(index + 1)"
                result.append(AOMMenuShelfItem(pid: app.pid, ownerBundleID: app.bundleID,
                                               ownerName: app.name, title: title,
                                               axIdentifier: identifier, ordinal: index))
            }
        }
        return result
    }

    static func activate(_ item: AOMMenuShelfItem) -> Bool {
        guard item.pid > 0 else { return false }
        let list = items(pid: item.pid)
        for (index, element) in list.enumerated() {
            let identifier = string(element, kAXIdentifierAttribute)
            let title = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
                string(element, kAXHelpAttribute)
            ].first { !$0.isEmpty } ?? "Item \(index + 1)"
            // Never click another icon just because an app reordered its menu.
            let same = !item.axIdentifier.isEmpty
                ? identifier == item.axIdentifier
                : index == item.ordinal && title == item.title
            guard same else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        return false
    }
}

private final class AOMMenuShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Optional, on-demand secondary menu bar. An extra keyboard/mouse event tap
/// is never installed. The hover monitor is opt-in and only watches mouseMoved.
@MainActor
final class AOMMenuShelfController: ObservableObject {
    static let shared = AOMMenuShelfController()
    private static let pinnedKey = "AOMMenuShelfPinnedItems"
    private static let hoverKey = "AOMMenuShelfNotchHover"
    @Published private(set) var items: [AOMMenuShelfItem] = []
    @Published private(set) var loading = false
    @Published var query = ""
    @Published private(set) var message: String?
    @Published private(set) var pinned: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinned).sorted(), forKey: Self.pinnedKey) }
    }
    @Published var hoverEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hoverEnabled, forKey: Self.hoverKey)
            configureHover()
        }
    }

    private var panel: AOMMenuShelfPanel?
    private let worker = DispatchQueue(label: "com.kyw.aom.menubar-shelf-ax", qos: .userInitiated)
    private var scanGeneration = 0
    private var hoverMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var hoverPending: DispatchWorkItem?

    private init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
        hoverEnabled = UserDefaults.standard.bool(forKey: Self.hoverKey)
    }

    var visibleItems: [AOMMenuShelfItem] {
        AOMMenuShelfPolicy.ordered(items, pinned: pinned, query: query)
    }

    func installHoverIfEnabled() { configureHover() }

    func toggle() {
        if let panel, panel.isVisible { dismiss() }
        else { show() }
    }

    func show() {
        guard !ScreenLock.isLocked else { return }
        if panel == nil {
            let window = AOMMenuShelfPanel(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 398),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: AOMMenuShelfView(controller: self))
            panel = window
        }
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let originX = max(visible.minX, min(screen.frame.midX - panel.frame.width / 2,
                                                visible.maxX - panel.frame.width))
            let originY = max(visible.minY, visible.maxY - panel.frame.height - 8)
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    func dismiss() { panel?.orderOut(nil) }

    func refresh() {
        guard AXIsProcessTrusted() else {
            items = []; loading = false
            message = "Accessibility permission is required to list other apps' menu-bar controls."
            return
        }
        scanGeneration &+= 1
        let generation = scanGeneration
        loading = true
        message = nil
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AOMMenuShelfApp? in
            guard app.processIdentifier > 0 else { return nil }
            return AOMMenuShelfApp(pid: app.processIdentifier,
                                   bundleID: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                   name: app.localizedName ?? app.bundleIdentifier ?? "App")
        }
        // System status extras first; other apps follow in name order.
        let ordered = apps.sorted {
            let a = $0.bundleID.hasPrefix("com.apple.controlcenter") || $0.bundleID.hasPrefix("com.apple.systemuiserver")
            let b = $1.bundleID.hasPrefix("com.apple.controlcenter") || $1.bundleID.hasPrefix("com.apple.systemuiserver")
            return a == b ? $0.name < $1.name : a
        }
        worker.async { [weak self] in
            let result = AOMMenuShelfProbe.snapshot(apps: ordered)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.items = result
                self.loading = false
                if result.isEmpty {
                    self.message = "No accessible menu-bar items. macOS may not expose every third-party icon."
                }
            }
        }
    }

    func activate(_ item: AOMMenuShelfItem) {
        dismiss()
        worker.async { [weak self] in
            let success = AOMMenuShelfProbe.activate(item)
            if !success {
                DispatchQueue.main.async {
                    self?.message = "Could not activate \(item.title); its menu-bar item may have moved or closed."
                }
            }
        }
    }

    func togglePinned(_ item: AOMMenuShelfItem) {
        if pinned.contains(item.id) { pinned.remove(item.id) }
        else { pinned.insert(item.id) }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func configureHover() {
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor); self.hoverMonitor = nil }
        if let hoverLocalMonitor { NSEvent.removeMonitor(hoverLocalMonitor); self.hoverLocalMonitor = nil }
        hoverPending?.cancel()
        hoverPending = nil
        guard hoverEnabled else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async { self?.observeHover() }
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            DispatchQueue.main.async { self?.observeHover() }
            return event
        }
    }

    private func observeHover() {
        guard hoverEnabled, panel?.isVisible != true, !ScreenLock.isLocked else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              AOMMenuShelfPolicy.safeHoverZone(point, screen: screen.frame) else {
            hoverPending?.cancel()
            hoverPending = nil
            return
        }
        guard hoverPending == nil else { return }
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverPending = nil
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                  AOMMenuShelfPolicy.safeHoverZone(point, screen: screen.frame) else { return }
            self.show()
        }
        hoverPending = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: pending)
    }
}

private struct AOMMenuShelfView: View {
    @ObservedObject var controller: AOMMenuShelfController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Menu Bar Shelf", systemImage: "rectangle.topthird.inset.filled")
                    .font(.headline)
                Spacer()
                Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh menu bar items")
                Button { controller.dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Close shelf")
            }
            TextField("Search app or menu bar item", text: $controller.query)
                .textFieldStyle(.roundedBorder)
            Toggle("Reveal shelf when hovering over the notch", isOn: $controller.hoverEnabled)
                .font(.caption)
                .toggleStyle(.switch)
            Divider()
            if controller.loading {
                ProgressView("Checking menu bar items…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !AXIsProcessTrusted() {
                VStack(spacing: 9) {
                    Text(controller.message ?? "Accessibility is required.")
                    Button("Request Accessibility Permission") { controller.requestPermission() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.visibleItems.isEmpty {
                Text(controller.message ?? "No items match your search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(controller.visibleItems) { item in
                            HStack(spacing: 8) {
                                Button { controller.activate(item) } label: {
                                    HStack(spacing: 9) {
                                        if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                        } else {
                                            Image(systemName: "app").frame(width: 20, height: 20)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title).lineLimit(1)
                                            Text(item.ownerName).font(.caption2)
                                                .foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                                Button { controller.togglePinned(item) } label: {
                                    Image(systemName: controller.pinned.contains(item.id) ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless)
                                .help(controller.pinned.contains(item.id) ? "Unpin item" : "Pin in shelf")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Divider()
            Text("Third-party icons stay in their original macOS positions. AOM does not forcibly move them.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 550, height: 398)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
