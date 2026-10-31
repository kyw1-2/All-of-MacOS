import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Where a window is, from the switcher's point of view.
enum SwitcherWindowState: String, Equatable {
    /// On screen in the current Space.
    case normal
    /// In the Dock.
    case minimized
    /// Its app is hidden (⌘H).
    case hidden
    /// In another Space (or full screen); reached through the app's Window menu.
    case otherSpace

    var label: String? {
        switch self {
        case .normal: return nil
        case .minimized: return "Minimized"
        case .hidden: return "Hidden"
        case .otherSpace: return "Other Space"
        }
    }
}

/// A window from the window server's list (CGWindowListCopyWindowInfo).
struct SwitcherServerWindow: Equatable {
    var windowID: CGWindowID
    var pid: pid_t
    /// Empty without Screen Recording permission.
    var title: String
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool
    var alpha: Double
}

/// A window as Accessibility reports it (the current Space and the Dock).
struct SwitcherAXWindow {
    var title: String
    var frame: CGRect?
    var isMinimized: Bool
    var element: AXUIElement?
}

/// One app's side of the list.
struct SwitcherApp {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var isHidden: Bool
    var axWindows: [SwitcherAXWindow]
    /// Titles in the app's Window menu, with the items that bring them forward.
    var windowMenu: [(title: String, element: AXUIElement?)]
}

/// A row of the switcher before icons and thumbnails are added.
struct SwitcherEntry {
    var windowID: CGWindowID
    var pid: pid_t
    var appName: String
    var bundleID: String?
    var title: String
    var state: SwitcherWindowState
    var axWindow: AXUIElement?
    var windowMenuItem: AXUIElement?
    var frame: CGRect
}

enum SwitcherWindowList {
    /// The smallest window worth switching to (smaller ones are palettes,
    /// tooltips and helper windows).
    static let minimumSize = CGSize(width: 120, height: 80)
    /// IDs for windows only Accessibility knows (minimized windows when the
    /// window server list has no match), well above real window numbers.
    static let syntheticIDBase: CGWindowID = 0x7000_0000

    /// Builds the list, best first: windows on screen front to back, then
    /// hidden apps' windows, windows in other Spaces and minimized windows,
    /// each group in the order apps were last used (`recentApps`). A window
    /// that is off screen is listed only when something vouches for it (a
    /// minimized Accessibility window, a hidden app, or the app's Window
    /// menu), so closed-but-kept windows never show up.
    static func build(server: [SwitcherServerWindow], apps: [pid_t: SwitcherApp], recentApps: [pid_t]) -> [SwitcherEntry] {
        var onScreen: [SwitcherEntry] = []
        var hidden: [SwitcherEntry] = []
        var otherSpace: [SwitcherEntry] = []
        var minimized: [SwitcherEntry] = []
        var usedAX: [pid_t: Set<Int>] = [:]
        var usedMenu: [pid_t: Set<Int>] = [:]

        func axMatch(_ window: SwitcherServerWindow, in app: SwitcherApp, minimizedOnly: Bool) -> Int? {
            let taken = usedAX[app.pid] ?? []
            let candidates = app.axWindows.indices.filter { !taken.contains($0) && (!minimizedOnly || app.axWindows[$0].isMinimized) }
            if let byFrame = candidates.first(where: { index in
                guard let frame = app.axWindows[index].frame else { return false }
                return close(frame, window.frame) && (window.title.isEmpty || app.axWindows[index].title == window.title)
            }) { return byFrame }
            guard !window.title.isEmpty else { return nil }
            let titled = candidates.filter { app.axWindows[$0].title == window.title }
            return titled.count == 1 ? titled[0] : nil
        }

        for window in server where window.layer == 0 && window.alpha > 0
            && window.frame.width >= minimumSize.width && window.frame.height >= minimumSize.height {
            guard let app = apps[window.pid] else { continue }
            var entry = SwitcherEntry(windowID: window.windowID, pid: window.pid, appName: app.name, bundleID: app.bundleID,
                                      title: window.title, state: .normal, axWindow: nil, windowMenuItem: nil, frame: window.frame)
            if window.isOnScreen {
                if let index = axMatch(window, in: app, minimizedOnly: false) {
                    usedAX[app.pid, default: []].insert(index)
                    entry.axWindow = app.axWindows[index].element
                    if entry.title.isEmpty { entry.title = app.axWindows[index].title }
                }
                onScreen.append(entry)
                continue
            }
            if let index = axMatch(window, in: app, minimizedOnly: true) {
                usedAX[app.pid, default: []].insert(index)
                entry.axWindow = app.axWindows[index].element
                if entry.title.isEmpty { entry.title = app.axWindows[index].title }
                entry.state = .minimized
                minimized.append(entry)
                continue
            }
            if app.isHidden {
                if let index = axMatch(window, in: app, minimizedOnly: false) {
                    usedAX[app.pid, default: []].insert(index)
                    entry.axWindow = app.axWindows[index].element
                    if entry.title.isEmpty { entry.title = app.axWindows[index].title }
                } else if entry.title.isEmpty {
                    continue
                }
                entry.state = .hidden
                hidden.append(entry)
                continue
            }
            guard !window.title.isEmpty else { continue }
            let taken = usedMenu[app.pid] ?? []
            guard let menuIndex = app.windowMenu.indices.first(where: { !taken.contains($0) && app.windowMenu[$0].title == window.title })
            else { continue }
            usedMenu[app.pid, default: []].insert(menuIndex)
            entry.windowMenuItem = app.windowMenu[menuIndex].element
            entry.state = .otherSpace
            otherSpace.append(entry)
        }

        // Minimized windows the server list didn't report.
        var synthetic = syntheticIDBase
        for (pid, app) in apps {
            for (index, window) in app.axWindows.enumerated() where window.isMinimized && !(usedAX[pid]?.contains(index) ?? false) {
                synthetic += 1
                minimized.append(SwitcherEntry(windowID: synthetic, pid: pid, appName: app.name, bundleID: app.bundleID,
                                               title: window.title, state: .minimized, axWindow: window.element,
                                               windowMenuItem: nil, frame: window.frame ?? .zero))
            }
        }

        let rank = Dictionary(recentApps.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func byRecency(_ list: [SwitcherEntry]) -> [SwitcherEntry] {
            list.enumerated().sorted { lhs, rhs in
                let l = rank[lhs.element.pid] ?? Int.max, r = rank[rhs.element.pid] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return onScreen + byRecency(hidden) + byRecency(otherSpace) + byRecency(minimized)
    }

    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Type-to-filter and grouping, kept apart from the panel so they are testable.
enum SwitcherFilter {
    /// Items matching `query` on the app name, the window title or both
    /// ("chr git" → Chrome's GitHub window), best first; ties keep the
    /// switcher's order (most recently used first).
    static func filtered<Item>(_ items: [Item], query: String, appName: (Item) -> String, title: (Item) -> String) -> [Item] {
        guard let prepared = PaletteFuzzy.Query(query) else { return items }
        let scored: [(item: Item, score: Int, order: Int)] = items.enumerated().compactMap { order, item in
            let name = appName(item), window = title(item)
            guard let score = PaletteFuzzy.bestScore(prepared, fields: [(window, 0), (name, 10), ("\(name) \(window)", 20)])
            else { return nil }
            return (item, score, order)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.item)
    }

    /// Windows of one app together, apps in the order their first window
    /// appears, windows keeping their order inside each app.
    static func groupedByApp<Item>(_ items: [Item], key: (Item) -> pid_t) -> [Item] {
        var order: [pid_t] = []
        var groups: [pid_t: [Item]] = [:]
        for item in items {
            let pid = key(item)
            if groups[pid] == nil { order.append(pid) }
            groups[pid, default: []].append(item)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    /// The first selection: the window after the one already in front, as
    /// ⌘Tab starts on the previous app.
    static func initialSelection(count: Int, firstIsFrontmost: Bool) -> Int {
        count > 1 && firstIsFrontmost ? 1 : 0
    }

    /// Arrow keys in a grid of `columns`: left and right step and wrap, up
    /// and down move a row and stay put at the edges.
    static func move(_ index: Int, by offset: Int, count: Int, columns: Int, vertical: Bool) -> Int {
        guard count > 0 else { return 0 }
        if !vertical { return ((index + offset) % count + count) % count }
        let target = index + offset * max(1, columns)
        return (0..<count).contains(target) ? target : index
    }
}

/// Reads windows from the window server and Accessibility. Off the main
/// thread; every Accessibility request is bounded.
enum SwitcherWindowReader {
    static func serverWindows() -> [SwitcherServerWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return SwitcherServerWindow(windowID: id, pid: pid, title: window[kCGWindowName as String] as? String ?? "",
                                        frame: frame, layer: layer, isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false,
                                        alpha: window[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// Accessibility windows and, when `readWindowMenu`, the Window menu's
    /// titles of one app.
    static func app(pid: pid_t, name: String, bundleID: String?, isHidden: Bool, readWindowMenu: Bool,
                    limit: AXDeadline) -> SwitcherApp {
        var app = SwitcherApp(pid: pid, name: name, bundleID: bundleID, isHidden: isHidden, axWindows: [], windowMenu: [])
        let element = AXUIElementCreateApplication(pid)
        guard limit.allow(element) else { return app }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for window in windows.prefix(40) {
                guard limit.allow(window) else { break }
                let role = string(window, kAXSubroleAttribute)
                guard role == nil || role == (kAXStandardWindowSubrole as String) || role == (kAXDialogSubrole as String) else { continue }
                app.axWindows.append(SwitcherAXWindow(title: string(window, kAXTitleAttribute) ?? "", frame: frame(window),
                                                      isMinimized: bool(window, kAXMinimizedAttribute) ?? false, element: window))
            }
        }
        if readWindowMenu { app.windowMenu = windowMenu(element, limit: limit) }
        return app
    }

    /// The Window menu is the top-level menu holding Minimize (⌘M); its
    /// window list is the items below the last separator group. Found by its
    /// ⌘M item, so it works in any language.
    static func windowMenu(_ application: AXUIElement, limit: AXDeadline) -> [(title: String, element: AXUIElement?)] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success, let bar = value,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        let menuBar = bar as! AXUIElement
        guard limit.allow(menuBar) else { return [] }
        for barItem in children(menuBar).reversed() {
            guard limit.allow(barItem), let menu = children(barItem).first, limit.allow(menu) else { continue }
            let items = children(menu)
            let hasMinimize = items.prefix(6).contains { item in
                limit.allow(item) && string(item, "AXMenuItemCmdChar")?.uppercased() == "M"
                    && ((number(item, "AXMenuItemCmdModifiers") ?? 0) & 0x7) == 0
            }
            guard hasMinimize else { continue }
            return items.compactMap { item in
                guard limit.allow(item), let title = string(item, kAXTitleAttribute), !title.isEmpty else { return nil }
                return (title, item)
            }
        }
        return []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

/// Small window pictures, kept between openings (at most 48, about 24 MB)
/// so the switcher shows the last picture at once and replaces it when the
/// new one arrives.
final class SwitcherThumbnailCache: @unchecked Sendable {
    static let shared = SwitcherThumbnailCache()
    private let cache: NSCache<NSNumber, CGImageBox> = {
        let cache = NSCache<NSNumber, CGImageBox>()
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func image(for windowID: CGWindowID) -> CGImage? { cache.object(forKey: NSNumber(value: windowID))?.image }

    func store(_ image: CGImage, for windowID: CGWindowID) {
        cache.setObject(CGImageBox(image), forKey: NSNumber(value: windowID), cost: image.bytesPerRow * image.height)
    }

    func removeAll() { cache.removeAllObjects() }

    /// Twice the card size (Retina), never larger than the window.
    static let pixelSize = CGSize(width: 352, height: 224)

    /// One picture of `window` through ScreenCaptureKit (needs Screen Recording).
    static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.queueDepth = 1
        let scale = min(pixelSize.width / max(1, window.frame.width), pixelSize.height / max(1, window.frame.height), 2)
        configuration.width = max(32, Int(window.frame.width * scale))
        configuration.height = max(32, Int(window.frame.height * scale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// Window commands from the switcher (⌘W, ⌘M, ↩ on a minimized window …),
/// through Accessibility and off the main thread.
enum SwitcherWindowActions {
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.switcher.actions", qos: .userInitiated)

    /// Presses the window's close button, so an unsaved document still asks.
    static func close(_ window: AXUIElement, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            AXUIElementSetMessagingTimeout(window, 0.5)
            var value: CFTypeRef?
            var closed = false
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                closed = AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(closed) } }
        }
    }

    static func setMinimized(_ window: AXUIElement, _ minimized: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            AXUIElementSetMessagingTimeout(window, 0.5)
            let done = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                    (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(done) } }
        }
    }

    /// Brings `entry` forward: un-minimizes, unhides, presses the Window
    /// menu item for another Space, raises and focuses the window.
    static func bringForward(_ entry: SwitcherEntry, app: NSRunningApplication?) {
        if entry.state == .hidden { app?.unhide() }
        app?.activate(options: [])
        queue.async {
            if let window = entry.axWindow {
                AXUIElementSetMessagingTimeout(window, 0.5)
                if entry.state == .minimized {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            } else if let item = entry.windowMenuItem {
                // Choosing it in the Window menu switches to its Space.
                AXUIElementSetMessagingTimeout(item, 0.6)
                AXUIElementPerformAction(item, kAXPressAction as CFString)
            }
        }
    }
}
