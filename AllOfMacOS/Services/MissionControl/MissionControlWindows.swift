import AppKit
import ApplicationServices

// Mission Control and App Exposé as Accessibility shows them (3.3.3).
//
// macOS 27 moved Mission Control's tree from the Dock to WindowManager
// (com.apple.WindowManager). While Mission Control shows, each display there
// is an AXGroup "mc.display"; its window thumbnails are AXButtons identified
// "<bundle id>.space.<space id>" and titled with the window's title, and the
// Spaces bar is "mc.spaces" › "mc.spaces.list". The Dock keeps an empty "mc"
// group. Earlier systems keep the tree in the Dock: "mc" › "mc.display" ›
// "mc.windows" › one element per thumbnail. (Reported for macOS 27.0 in
// PaperWM.spoon issue #173; AOM's reading of it still needs a check on real
// hardware.) The same report found that Mission Control ignores synthetic
// mouse events on macOS 27 and that the private Space calls no longer move
// windows, so nothing here moves a window to another Space.

/// One window thumbnail in Mission Control or App Exposé.
struct MissionControlThumbnail: Equatable {
    /// AXTitle: the window's title.
    var title: String?
    /// AXIdentifier: "<bundle id>.space.<space id>" on macOS 27.
    var identifier: String?
    /// Accessibility coordinates (top-left origin).
    var frame: CGRect

    /// The owner's bundle identifier, when the identifier names one.
    var bundleID: String? { MissionControlWindows.bundleID(fromIdentifier: identifier) }
}

enum MissionControlWindows {
    // MARK: Pure (unit-tested)

    /// "com.apple.Safari.space.3" → "com.apple.Safari"; nil for anything else.
    static func bundleID(fromIdentifier identifier: String?) -> String? {
        guard let identifier, let marker = identifier.range(of: ".space.", options: .backwards) else { return nil }
        let bundle = identifier[..<marker.lowerBound]
        let space = identifier[marker.upperBound...]
        guard !bundle.isEmpty, !space.isEmpty, space.allSatisfy(\.isNumber) else { return nil }
        return String(bundle)
    }

    /// A node of Mission Control's tree as the walk read it; tests build them by hand.
    struct Node: Equatable {
        var role: String?
        var identifier: String?
        var title: String?
        var frame: CGRect?
        var children: [Node] = []
    }

    /// The window thumbnails in a tree: macOS 27's "<bundle id>.space.<n>"
    /// elements and, on earlier systems, the children of "mc.windows". The
    /// Spaces bar holds Spaces, not windows.
    static func thumbnails(in roots: [Node]) -> [MissionControlThumbnail] {
        var found: [MissionControlThumbnail] = []
        func visit(_ node: Node, inWindowList: Bool, depth: Int) {
            guard depth < 8, node.identifier?.hasPrefix("mc.spaces") != true else { return }
            if inWindowList || bundleID(fromIdentifier: node.identifier) != nil {
                if let frame = node.frame, frame.width >= 20, frame.height >= 20 {
                    found.append(MissionControlThumbnail(title: node.title, identifier: node.identifier, frame: frame))
                }
                return
            }
            for child in node.children {
                visit(child, inWindowList: node.identifier == "mc.windows", depth: depth + 1)
            }
        }
        roots.forEach { visit($0, inWindowList: false, depth: 0) }
        return found
    }

    /// The thumbnail under a point (Accessibility coordinates): the smallest holding it.
    static func thumbnail(at point: CGPoint, in thumbnails: [MissionControlThumbnail]) -> MissionControlThumbnail? {
        thumbnails.filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A window a thumbnail may stand for.
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleID: String?
        let title: String?
        /// Its place in its app's window list.
        let index: Int
    }

    /// The one window a thumbnail stands for: of the app it names (when it
    /// names one) and with its title. Nil unless exactly one window matches:
    /// a thumbnail without a title, or with a title several windows share, is
    /// never guessed at.
    static func match(_ thumbnail: MissionControlThumbnail, among candidates: [Candidate]) -> Candidate? {
        guard let title = thumbnail.title, !title.isEmpty else { return nil }
        let bundle = thumbnail.bundleID?.lowercased()
        let hits = candidates.filter { $0.title == title && (bundle == nil || $0.bundleID?.lowercased() == bundle) }
        return hits.count == 1 ? hits[0] : nil
    }

    // MARK: Live (bounded Accessibility)

    /// The processes that draw Mission Control: WindowManager (macOS 27), then the Dock.
    static func ownerPIDs() -> [pid_t] {
        ["com.apple.WindowManager", "com.apple.dock"].compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
    }

    /// Mission Control's thumbnails, every request bounded and the whole walk
    /// to `budget`; nil while Mission Control is not showing. Runs off the
    /// main thread (the ✕ overlay polls with it).
    static func liveThumbnails(budget: TimeInterval = 0.35) -> [MissionControlThumbnail]? {
        let limit = AXDeadline(perRequest: 0.1, budget: budget)
        for pid in ownerPIDs() {
            let app = AXUIElementCreateApplication(pid)
            guard limit.allow(app) else { return nil }
            let roots = AX.children(app).filter { element in
                guard limit.allow(element), let id = AX.string(element, "AXIdentifier") else { return false }
                return id == "mc" || id == "mc.display"
            }
            var nodes = 400
            let tree = roots.compactMap { read($0, depth: 0, leaf: false, limit: limit, nodes: &nodes) }
            // An "mc" group without children is the Dock's stub on macOS 27.
            guard tree.contains(where: { !$0.children.isEmpty }) else { continue }
            return thumbnails(in: tree)
        }
        return nil
    }

    /// The thumbnail under an AppKit point, or nil (Mission Control not
    /// showing, or no thumbnail there): a hit-test on the process that draws
    /// Mission Control, then a short walk up, every request bounded and all
    /// of it to 0.25 s.
    @MainActor static func thumbnail(at point: CGPoint) -> MissionControlThumbnail? {
        // The ✕ overlay's poller already knows whether Mission Control shows.
        let overlay = MissionControlOverlayService.shared
        if overlay.isPolling, !overlay.isMissionControlActive { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let limit = AXDeadline(perRequest: 0.1, budget: 0.25)
        for pid in ownerPIDs() {
            let app = AXUIElementCreateApplication(pid)
            var hit: AXUIElement?
            guard limit.allow(app),
                  AXUIElementCopyElementAtPosition(app, Float(point.x), Float(top - point.y), &hit) == .success,
                  var current = hit else { continue }
            var below: AXUIElement?
            for _ in 0..<6 {
                guard limit.allow(current), let values = attributes(current, children: false) else { break }
                if bundleID(fromIdentifier: values.identifier) != nil, let frame = values.frame {
                    return MissionControlThumbnail(title: values.title, identifier: values.identifier, frame: frame)
                }
                if values.identifier == "mc.windows" {
                    guard let below, limit.allow(below), let thumb = attributes(below, children: false),
                          let frame = thumb.frame else { break }
                    return MissionControlThumbnail(title: thumb.title, identifier: thumb.identifier, frame: frame)
                }
                // Mission Control's own groups ("mc", "mc.display", the Spaces
                // bar): no thumbnail above this.
                if values.identifier?.hasPrefix("mc") == true { break }
                guard limit.allow(current), let parent = AX.element(current, kAXParentAttribute) else { break }
                below = current
                current = parent
            }
        }
        return nil
    }

    /// The real window behind a thumbnail, never one of AOM's own: the
    /// standard windows of the app it names (of every regular app when it
    /// names none), each request bounded and all of them to `budget`, then
    /// `match`. Nil when no single window matches.
    @MainActor static func window(for thumbnail: MissionControlThumbnail,
                                  budget: TimeInterval = 0.5) -> (element: AXUIElement, pid: pid_t)? {
        let own = ProcessInfo.processInfo.processIdentifier
        let bundle = thumbnail.bundleID?.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own
                && (bundle == nil || $0.bundleIdentifier?.lowercased() == bundle)
        }
        let limit = AXDeadline(perRequest: 0.2, budget: budget)
        var candidates: [Candidate] = []
        var elements: [AXUIElement] = []
        for app in apps {
            guard !limit.isSpent else { break }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard limit.allow(element),
                  AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for (index, window) in windows.prefix(64).enumerated() {
                guard limit.allow(window), AX.isStandardWindow(window), limit.allow(window) else { continue }
                candidates.append(Candidate(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                            title: AX.string(window, kAXTitleAttribute), index: index))
                elements.append(window)
            }
        }
        guard let hit = match(thumbnail, among: candidates), let position = candidates.firstIndex(of: hit) else { return nil }
        let window = elements[position]
        AXUIElementSetMessagingTimeout(window, 0.5)
        return (window, hit.pid)
    }

    /// Presses the window's own close button (the app may ask to save).
    @discardableResult
    static func close(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.5)
        guard let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
        AXUIElementSetMessagingTimeout(button, 0.5)
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Closes every standard window of an app with its close buttons, never
    /// AOM's own; how many closed.
    @MainActor static func closeAllWindows(of pid: pid_t, budget: TimeInterval = 1) -> Int {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return 0 }
        let limit = AXDeadline(perRequest: 0.3, budget: budget)
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard limit.allow(app), AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return 0 }
        var closed = 0
        for window in windows where limit.allow(window) && AX.isStandardWindow(window) {
            if close(window) { closed += 1 }
        }
        return closed
    }

    // MARK: Reading the tree

    private struct Values {
        var role: String?
        var identifier: String?
        var title: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    private static func read(_ element: AXUIElement, depth: Int, leaf: Bool, limit: AXDeadline, nodes: inout Int) -> Node? {
        guard nodes > 0, limit.allow(element),
              let values = attributes(element, children: !leaf && depth < 5) else { return nil }
        nodes -= 1
        var node = Node(role: values.role, identifier: values.identifier, title: values.title, frame: values.frame)
        // A thumbnail's insides are not read.
        guard !leaf, bundleID(fromIdentifier: values.identifier) == nil else { return node }
        for child in values.children.prefix(64) {
            if let read = read(child, depth: depth + 1, leaf: values.identifier == "mc.windows", limit: limit, nodes: &nodes) {
                node.children.append(read)
            }
        }
        return node
    }

    /// Role, identifier, title, frame (and children) in one request.
    private static func attributes(_ element: AXUIElement, children: Bool) -> Values? {
        var names: [String] = [kAXRoleAttribute, "AXIdentifier", kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute]
        if children { names.append(kAXChildrenAttribute) }
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &raw) == .success,
              let list = raw as? [AnyObject], list.count == names.count else { return nil }
        var values = Values(role: list[0] as? String, identifier: list[1] as? String, title: list[2] as? String)
        if let origin = axPoint(list[3]), let size = axSize(list[4]) { values.frame = CGRect(origin: origin, size: size) }
        if children { values.children = list[5] as? [AXUIElement] ?? [] }
        return values
    }

    private static func axPoint(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var point = CGPoint.zero
        return AXValueGetType(ax) == .cgPoint && AXValueGetValue(ax, .cgPoint, &point) ? point : nil
    }

    private static func axSize(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var size = CGSize.zero
        return AXValueGetType(ax) == .cgSize && AXValueGetValue(ax, .cgSize, &size) ? size : nil
    }
}
