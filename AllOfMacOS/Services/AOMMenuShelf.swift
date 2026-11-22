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
    /// 7.6: how many items the app had in this scan, and whether this item's
    /// identifier was the only one of its kind in the app.
    var siblings = 1
    var identifierIsUnique = true
    /// Where the item sits (screen points, top-left origin), when AX says.
    var frame: CGRect? = nil

    /// One scan's row: the app and the item's place in it (7.6, Codex MB01:
    /// two items sharing an identifier are two rows).
    var id: String { "\(ownerBundleID)|\(pid)|#\(ordinal)" }

    /// What a pin remembers across scans: the identifier when it names one
    /// item, else the place — never the title, which changes (18°C → 19°C).
    var pinKey: String {
        !axIdentifier.isEmpty && identifierIsUnique ? "\(ownerBundleID)|ax:\(axIdentifier)" : "\(ownerBundleID)|pos:\(ordinal)"
    }

    /// The pre-7.6 id, to carry old pins over when it picks out one item.
    var legacyID: String {
        "\(ownerBundleID)|" + (axIdentifier.isEmpty ? "\(ordinal)|\(title)" : axIdentifier)
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
                let a = pinned.contains($0.pinKey), b = pinned.contains($1.pinKey)
                if a != b { return a }
                let lhs = $0.ownerName.localizedStandardCompare($1.ownerName)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    /// Pure (Codex MB01): old pin keys that name exactly one scanned item
    /// become that item's pin key; the rest stay as they were.
    static func migratePins(_ pinned: Set<String>, items: [AOMMenuShelfItem]) -> Set<String> {
        let current = Set(items.map(\.pinKey))
        var out = Set<String>()
        for key in pinned {
            if current.contains(key) || key.contains("|ax:") || key.contains("|pos:") { out.insert(key); continue }
            let matches = items.filter { $0.legacyID == key }
            if matches.count == 1 { out.insert(matches[0].pinKey) } else { out.insert(key) }
        }
        return out
    }

    /// One item read back just before it is pressed.
    struct Live: Equatable {
        let identifier: String
        let title: String
    }

    /// Pure (Codex MB01): which of the app's items to press now, or nil when
    /// it isn't one item for sure — never "the first with that identifier".
    static func resolve(_ item: AOMMenuShelfItem, in live: [Live]) -> Int? {
        if !item.axIdentifier.isEmpty {
            let matches = live.indices.filter { live[$0].identifier == item.axIdentifier }
            // A lone match counts only if the identifier was unique when scanned;
            // a twin that closed must not hand its click to the other (Gemini 7.6).
            if matches.count == 1, item.identifierIsUnique { return matches[0] }
            return matches.contains(item.ordinal) && live.count == item.siblings ? item.ordinal : nil
        }
        // No identifier: the same place in a list of the same length (a title may change).
        guard live.count == item.siblings, live.indices.contains(item.ordinal), live[item.ordinal].identifier.isEmpty else { return nil }
        return item.ordinal
    }

    /// System extras first, then apps by name; processes macOS doesn't let
    /// have a menu bar item go last, so a long list doesn't spend the
    /// deadline on them.
    static func orderedApps(_ running: [NSRunningApplication]) -> [AOMMenuShelfApp] {
        running.filter { $0.processIdentifier > 0 }
            .sorted { a, b in
                func rank(_ app: NSRunningApplication) -> Int {
                    let id = app.bundleIdentifier ?? ""
                    if id.hasPrefix("com.apple.controlcenter") || id.hasPrefix("com.apple.systemuiserver") { return 0 }
                    return app.activationPolicy == .prohibited ? 2 : 1
                }
                return rank(a) != rank(b) ? rank(a) < rank(b) : (a.localizedName ?? "") < (b.localizedName ?? "")
            }
            .map { AOMMenuShelfApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "pid:\($0.processIdentifier)",
                                   name: $0.localizedName ?? $0.bundleIdentifier ?? "App") }
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

struct AOMMenuShelfApp: Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String
}

/// Accessibility requests must never block AppKit's main thread.
/// A response uses immutable identifiers, not retained foreign AXUIElements:
/// the target is resolved again immediately before it is pressed.
enum AOMMenuShelfProbe {
    private static func attribute(_ el: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key, &value) == .success ? value : nil
    }

    private static func string(_ el: AXUIElement, _ key: CFString) -> String {
        attribute(el, key) as? String ?? ""
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attribute(el, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
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
        if let bar = attribute(app, kAXMenuBarAttribute as CFString),
           CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let menu = bar as! AXUIElement
            AXUIElementSetMessagingTimeout(menu, 0.12)
            return children(menu).filter { string($0, kAXSubroleAttribute as CFString) == "AXMenuExtra" }
        }
        return []
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func title(_ element: AXUIElement, index: Int) -> String {
        [string(element, kAXTitleAttribute as CFString), string(element, kAXDescriptionAttribute as CFString),
         string(element, kAXHelpAttribute as CFString)].first { !$0.isEmpty } ?? "Item \(index + 1)"
    }

    struct Snapshot {
        var items: [AOMMenuShelfItem] = []
        /// Apps not read before the deadline (Codex MB02); 0: every app was read.
        var appsLeft = 0
    }

    /// The deadline is checked before every item, not only between apps.
    static func snapshot(apps: [AOMMenuShelfApp], deadline: TimeInterval = 2.0) -> Snapshot {
        let started = ProcessInfo.processInfo.systemUptime
        var result = Snapshot()
        let list = Array(apps.prefix(90))
        result.appsLeft = max(0, apps.count - list.count)
        for (number, app) in list.enumerated() {
            if ProcessInfo.processInfo.systemUptime - started >= deadline { result.appsLeft += list.count - number; break }
            let elements = Array(items(pid: app.pid).prefix(30))
            var found: [AOMMenuShelfItem] = []
            for (index, element) in elements.enumerated() {
                if ProcessInfo.processInfo.systemUptime - started >= deadline { break }
                AXUIElementSetMessagingTimeout(element, 0.1)
                found.append(AOMMenuShelfItem(pid: app.pid, ownerBundleID: app.bundleID, ownerName: app.name,
                                              title: title(element, index: index),
                                              axIdentifier: string(element, kAXIdentifierAttribute as CFString), ordinal: index,
                                              siblings: elements.count, frame: frame(element)))
            }
            let partial = found.count < elements.count
            if partial { result.appsLeft += 1 }
            var counts: [String: Int] = [:]
            for item in found where !item.axIdentifier.isEmpty { counts[item.axIdentifier, default: 0] += 1 }
            result.items += found.map { item in
                var copy = item
                // An app read only in part can't vouch that an identifier is unique.
                copy.identifierIsUnique = !partial && (counts[item.axIdentifier] ?? 0) <= 1
                return copy
            }
        }
        return result
    }

    /// Reads the app's items again and presses the one item that matches.
    static func activate(_ item: AOMMenuShelfItem) -> Bool {
        guard item.pid > 0, AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier.map({ $0 == item.ownerBundleID }) ?? item.ownerBundleID.hasPrefix("pid:") else { return false }
        let list = items(pid: item.pid)
        let live = list.enumerated().map { AOMMenuShelfPolicy.Live(identifier: string($1, kAXIdentifierAttribute as CFString), title: title($1, index: $0)) }
        guard let index = AOMMenuShelfPolicy.resolve(item, in: live) else { return false }
        AXUIElementSetMessagingTimeout(list[index], 0.2)
        return AXUIElementPerformAction(list[index], kAXPressAction as CFString) == .success
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

    /// Apps not read in the last scan (0: all were).
    @Published private(set) var appsLeft = 0

    func refresh() {
        // 7.6 (Codex MB03): a scan already running can't publish after this.
        scanGeneration &+= 1
        let generation = scanGeneration
        guard AXIsProcessTrusted() else {
            items = []; loading = false; appsLeft = 0
            message = "Accessibility permission is required to list other apps' menu-bar controls."
            return
        }
        loading = true
        message = nil
        let ordered = AOMMenuShelfPolicy.orderedApps(NSWorkspace.shared.runningApplications)
        worker.async { [weak self] in
            let result = AOMMenuShelfProbe.snapshot(apps: ordered)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                guard AXIsProcessTrusted() else {
                    self.items = []; self.loading = false
                    self.message = "Accessibility permission is required to list other apps' menu-bar controls."
                    return
                }
                self.items = result.items
                self.appsLeft = result.appsLeft
                self.loading = false
                let migrated = AOMMenuShelfPolicy.migratePins(self.pinned, items: result.items)
                if migrated != self.pinned { self.pinned = migrated }
                if result.items.isEmpty {
                    self.message = result.appsLeft > 0 ? "Apps took too long to answer; try Refresh."
                        : "No accessible menu-bar items. macOS may not expose every third-party icon."
                } else if result.appsLeft > 0 {
                    // Codex MB02: a partial list says it is partial; pins stay.
                    self.message = "Some items: \(result.appsLeft) app\(result.appsLeft == 1 ? "" : "s") didn't answer in time. Refresh to try again."
                }
            }
        }
    }

    func activate(_ item: AOMMenuShelfItem, retry: String = "Open the shelf and pick it again.") {
        dismiss()
        worker.async { [weak self] in
            let success = AOMMenuShelfProbe.activate(item)
            if !success {
                DispatchQueue.main.async {
                    self?.message = "Could not activate \(item.title); its menu-bar item may have moved or closed."
                    GestureHUD.shared.show(title: "Menu Bar Item Not Opened",
                                           detail: "\(item.title) moved, closed, or two items now match it. \(retry)")
                }
            }
        }
    }

    func togglePinned(_ item: AOMMenuShelfItem) {
        if pinned.contains(item.pinKey) { pinned.remove(item.pinKey) }
        else { pinned.insert(item.pinKey) }
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
                                    Image(systemName: controller.pinned.contains(item.pinKey) ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless)
                                .help(controller.pinned.contains(item.pinKey) ? "Unpin item" : "Pin in shelf")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if controller.appsLeft > 0, let message = controller.message, !controller.loading {
                Text(message).font(.caption).foregroundStyle(.orange)
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
