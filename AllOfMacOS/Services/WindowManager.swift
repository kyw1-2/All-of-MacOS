import AppKit
import Combine

enum SnapPosition { case left, right, topLeft, topRight, bottomLeft, bottomRight }

enum WindowGeometry {
    /// AX/CG use a top-left origin; AppKit uses bottom-left of the primary display.
    static func accessibilityFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func screenIndex(for window: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { rect -> CGFloat in
            let overlap = rect.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        return screens.indices.min {
            hypot(screens[$0].midX - window.midX, screens[$0].midY - window.midY) <
            hypot(screens[$1].midX - window.midX, screens[$1].midY - window.midY)
        }
    }
    static func moved(_ window: CGRect, into visible: CGRect, maximize: Bool) -> CGRect {
        if maximize { return visible }
        let size = CGSize(width: min(window.width, visible.width), height: min(window.height, visible.height))
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    /// Fractions of a display's visible area, in Accessibility top-left coordinates.
    static func normalizedRect(x: Double, y: Double, width: Double, height: Double) -> CGRect? {
        let numbers = [x, y, width, height]
        guard numbers.allSatisfy({ $0.isFinite }), x >= 0, y >= 0,
              width >= 0.05, height >= 0.05, x + width <= 1.000001,
              y + height <= 1.000001 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func snapFrame(normalized: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + visible.width * normalized.minX,
               y: visible.minY + visible.height * normalized.minY,
               width: visible.width * normalized.width,
               height: visible.height * normalized.height)
    }

    static func normalizedDropPoint(_ cursor: CGPoint, in visible: CGRect) -> CGPoint? {
        guard visible.width > 0, visible.height > 0,
              visible.contains(cursor) else { return nil }
        return CGPoint(x: (cursor.x - visible.minX) / visible.width,
                       y: (visible.maxY - cursor.y) / visible.height)
    }
    static func windowActuallyMoved(from before: CGRect, to after: CGRect) -> Bool {
        abs(before.width - after.width) <= 4 && abs(before.height - after.height) <= 4 &&
        abs(before.minX - after.minX) + abs(before.minY - after.minY) >= 6
    }
    static func screenEdgeDropPoint(_ point: CGPoint, screen: CGRect, visible: CGRect) -> CGPoint? {
        guard screen.contains(point), visible.width > 0, visible.height > 0 else { return nil }
        // Menu bar / Dock strips still activate the nearest usable edge.
        return CGPoint(x: min(1, max(0, (point.x-visible.minX)/visible.width)),
                       y: min(1, max(0, (visible.maxY-point.y)/visible.height)))
    }
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) <= 3 && abs(a.minY-b.minY) <= 3 &&
        abs(a.width-b.width) <= 3 && abs(a.height-b.height) <= 3
    }
}

struct SavedWindowPlacement: Codable, Equatable {
    var bundleID: String
    var title: String
    var identifier: String
    var displayID: String
    var normalizedFrame: CGRect
    static func uniqueMatch(_ wanted: SavedWindowPlacement, in candidates: [SavedWindowPlacement]) -> Int? {
        let matching = candidates.indices.filter {
            candidates[$0].bundleID == wanted.bundleID &&
            (wanted.identifier.isEmpty ? candidates[$0].title == wanted.title : candidates[$0].identifier == wanted.identifier)
        }
        return matching.count == 1 ? matching[0] : nil
    }
}
struct SavedWindowLayout: Identifiable, Codable {
    var id = UUID()
    var name: String
    var windows: [SavedWindowPlacement]
}

final class WindowManager: ObservableObject {
    static let shared = WindowManager()
    final class Target {
        let window: AXUIElement
        let pid: pid_t
        init(window: AXUIElement, pid: pid_t) { self.window = window; self.pid = pid }
    }
    private struct Saved { let target: Target; let frame: CGRect }
    private var saved: [Saved] = []
    private var history: [[Saved]] = []
    private var moving = Set<String>()
    @Published private(set) var historyCount = 0
    @Published private(set) var layouts: [SavedWindowLayout] = {
        guard let data = UserDefaults.standard.data(forKey: "AOMWindowLayoutsV1"), data.count <= 2_000_000,
              let layouts = try? JSONDecoder().decode([SavedWindowLayout].self, from: data) else { return [] }
        return Array(layouts.prefix(20))
    }()
    @Published private(set) var layoutBusy = false
    @Published private(set) var lastLayoutResult = ""
    private func remember(_ frames: [Saved]) {
        guard !frames.isEmpty else { return }
        history.append(frames); if history.count > 50 { history.removeFirst() }
        historyCount = history.count
    }
    private func text(_ target: Target, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.window, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
    private func visibleWindows() -> [(Target, SavedWindowPlacement)] {
        let screens = self.screens()
        let ids = NSScreen.screens.map { DisplayTopology.identifier($0) ?? "" }
        var result: [(Target, SavedWindowPlacement)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.bundleIdentifier != "com.kyw.allofmacos" && !app.isHidden {
            guard let bundle = app.bundleIdentifier else { continue }
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &list) == .success,
                  let windows = list as? [AXUIElement] else { continue }
            for window in windows {
                let target = Target(window: window, pid: app.processIdentifier)
                var minimized: CFTypeRef?; var fullscreen: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                _ = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen)
                guard minimized as? Bool != true, fullscreen as? Bool != true,
                      text(target, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      let frame = frame(of: target), frame.width > 0, frame.height > 0,
                      let index = WindowGeometry.screenIndex(for: frame, screens: screens.map(\.frame)), !ids[index].isEmpty else { continue }
                let visible = screens[index].visible
                let normalized = CGRect(x: (frame.minX-visible.minX)/visible.width, y: (frame.minY-visible.minY)/visible.height,
                    width: frame.width/visible.width, height: frame.height/visible.height)
                result.append((target, SavedWindowPlacement(bundleID: bundle, title: text(target, kAXTitleAttribute),
                    identifier: text(target, kAXIdentifierAttribute), displayID: ids[index], normalizedFrame: normalized)))
                if result.count >= 100 { return result }
            }
        }
        return result
    }
    func diagnosticTargets(pid: pid_t) -> [Target] {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.kyw.allofmacos.gesture-test" else { return [] }
        return visibleWindows().filter { $0.0.pid == pid }.map { $0.0 }
    }
    /// Accessible, unminimized standard windows of visible apps, for the bulk
    /// window actions (gather, side by side).
    func standardWindowTargets() -> [Target] { visibleWindows().map(\.0) }
    /// Places several windows as one undo step, so Undo Last Window Placement
    /// puts all of them back. Reports (moved, failed).
    func applyPlacements(_ placements: [(Target, CGRect)], completion: @escaping (Int, Int) -> Void) {
        guard !layoutBusy, moving.isEmpty else { completion(0, placements.count); return }
        applyBatch(placements.map { Saved(target: $0.0, frame: $0.1) }, recordUndo: true, completion: completion)
    }
    @discardableResult
    func saveLayout(name: String, onlyPID: pid_t? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !layoutBusy, !name.isEmpty, name.count <= 128 else { return false }
        let windows = visibleWindows().filter { onlyPID == nil || $0.0.pid == onlyPID }.map { $0.1 }
        guard !windows.isEmpty else { lastLayoutResult = "No accessible normal windows to save."; return false }
        if let index = layouts.firstIndex(where: { $0.name == name }) { layouts[index].windows = windows }
        else {
            guard layouts.count < 20 else { lastLayoutResult = "Up to 20 layouts can be saved."; return false }
            layouts.append(SavedWindowLayout(name: name, windows: windows))
        }
        persistLayouts(); lastLayoutResult = "Saved \(windows.count) windows."; return true
    }
    func removeLayout(_ id: UUID) { guard !layoutBusy else { return }; layouts.removeAll { $0.id == id }; persistLayouts() }
    private func persistLayouts() {
        if let data = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(data, forKey: "AOMWindowLayoutsV1") }
    }
    func restoreLayout(name: String, completion: @escaping (Bool) -> Void) {
        guard !layoutBusy, moving.isEmpty, let layout = layouts.first(where: { $0.name == name }) else { completion(false); return }
        let live = visibleWindows()
        let displays = screens()
        let ids = NSScreen.screens.map { DisplayTopology.identifier($0) ?? "" }
        var changes: [Saved] = []; var skipped = 0
        for placement in layout.windows {
            guard let match = SavedWindowPlacement.uniqueMatch(placement, in: live.map({ $0.1 })),
                  let screen = ids.firstIndex(of: placement.displayID) else { skipped += 1; continue }
            let visible = displays[screen].visible
            var rect = WindowGeometry.snapFrame(normalized: placement.normalizedFrame, visible: visible)
            rect.size.width = min(rect.width, visible.width); rect.size.height = min(rect.height, visible.height)
            rect.origin.x = max(visible.minX, min(rect.minX, visible.maxX-rect.width))
            rect.origin.y = max(visible.minY, min(rect.minY, visible.maxY-rect.height))
            changes.append(Saved(target: live[match].0, frame: rect))
        }
        applyBatch(changes, recordUndo: true) { success, failed in
            self.lastLayoutResult = "Restored \(success) · skipped \(skipped) · failed \(failed)."
            completion(success > 0 && skipped == 0 && failed == 0)
        }
    }
    func undoLastPlacement(completion: @escaping (Bool) -> Void) {
        guard !layoutBusy, moving.isEmpty, let changes = history.popLast() else { completion(false); return }
        historyCount = history.count
        applyBatch(changes, recordUndo: false) { success, failed in
            self.lastLayoutResult = "Undo: \(success) restored · \(failed) unavailable."
            completion(success > 0 && failed == 0)
        }
    }
    private func applyBatch(_ changes: [Saved], recordUndo: Bool, completion: @escaping (Int, Int) -> Void) {
        layoutBusy = true
        var before: [Saved] = []; var successes = 0; var failures = 0
        func step(_ index: Int) {
            guard index < changes.count else {
                if recordUndo { self.remember(before) }
                self.layoutBusy = false; completion(successes, failures); return
            }
            let item = changes[index]
            guard let original = self.frame(of: item.target), NSRunningApplication(processIdentifier: item.target.pid) != nil else {
                failures += 1; step(index + 1); return
            }
            // Do not restore to a monitor that disappeared since this undo was recorded.
            guard self.screens().contains(where: { $0.visible.intersects(item.frame) }) else {
                failures += 1; step(index + 1); return
            }
            self.applyFrame(item.frame, target: item.target) { ok in
                if let actual = self.frame(of: item.target), !WindowGeometry.close(original, actual) { before.append(Saved(target: item.target, frame: original)) }
                if ok { successes += 1 } else { failures += 1 }
                step(index + 1)
            }
        }
        step(0)
    }


    func captureTarget(pid: pid_t? = nil) -> Target? {
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let ref = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Target(window: value as! AXUIElement, pid: pid)
    }
    /// Capture the window actually under the mouse, including a background
    /// app's window clicked before it becomes frontmost. macOS AX coordinates
    /// are top-left based, unlike NSEvent.mouseLocation.
    func captureTarget(atMousePoint point: CGPoint) -> Target? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
            Float(point.x), Float(top - point.y), &hit)
        guard error == .success, let hit else { return nil }
        var current = hit
        for _ in 0..<24 {
            var pid: pid_t = 0
            guard AXUIElementGetPid(current, &pid) == .success, pid > 0 else { return nil }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == (kAXWindowRole as String) {
                return Target(window: current, pid: pid)
            }
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                return Target(window: window as! AXUIElement, pid: pid)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }
    /// Continuous gesture path (window drag layer): writes position and
    /// optionally size in one AX round-trip. AX frames are top-left based.
    func setFrame(_ frame: CGRect, of target: Target) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let setResult = AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, posValue)
        let sizeResult = AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, sizeValue)
        return setResult == .success && sizeResult == .success
    }
    func frame(of target: Target) -> CGRect? {
        var p: CFTypeRef?; var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(target.window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    func screens() -> [(frame: CGRect, visible: CGRect)] {
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        return screens.map { (WindowGeometry.accessibilityFrame($0.frame, primaryTop: top),
                              WindowGeometry.accessibilityFrame($0.visibleFrame, primaryTop: top)) }
    }
    func execute(_ type: ActionType, target: Target?, parameters: ActionParameters = ActionParameters(), referenceFrame: CGRect? = nil, completion: @escaping (Bool) -> Void) {
        if type == .undoWindowPlacement { undoLastPlacement(completion: completion); return }
        if type == .saveWindowLayout { completion(saveLayout(name: parameters.windowLayoutName ?? "")); return }
        if type == .restoreWindowLayout { restoreLayout(name: parameters.windowLayoutName ?? "", completion: completion); return }
        guard !layoutBusy else { completion(false); return }
        // Pointer-follow moves and resizes pick their own window under the cursor.
        if WindowDragMath.verb(for: type) != nil {
            completion(WindowDragController.shared.perform(type, timeout: parameters.windowDragTimeoutSeconds, target: target))
            return
        }
        var chosen = target
        if parameters.windowTarget == "underCursor",
           [.moveResizeWindow, .zoomWindow, .closeWindow, .toggleFullscreenWindow].contains(type) {
            guard let under = captureTarget(atMousePoint: NSEvent.mouseLocation) else {
                fail("No window under the cursor", completion); return
            }
            chosen = under
        }
        guard let target = chosen ?? captureTarget(), let current = frame(of: target) else {
            fail("No accessible focused window", completion); return
        }
        guard !moving.contains("\(target.pid):\(CFHash(target.window))") else { completion(false); return }
        if type == .minimizeWindow {
            completion(AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success)
            return
        }
        if type == .zoomWindow || type == .closeWindow {
            let attribute = type == .zoomWindow ? kAXZoomButtonAttribute : kAXCloseButtonAttribute
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target.window, attribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
                fail("The window has no \(type == .zoomWindow ? "zoom" : "close") button", completion); return
            }
            completion(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success)
            return
        }
        if type == .toggleFullscreenWindow {
            var state: CFTypeRef?
            let fullscreen = AXUIElementCopyAttributeValue(target.window, "AXFullScreen" as CFString, &state) == .success ? (state as? Bool ?? false) : false
            completion(AXUIElementSetAttributeValue(target.window, "AXFullScreen" as CFString, fullscreen ? kCFBooleanFalse : kCFBooleanTrue) == .success)
            return
        }
        let displays = screens()
        guard let index = WindowGeometry.screenIndex(for: type == .customSnapWindow ? (referenceFrame ?? current) : current, screens: displays.map(\.frame)) else {
            fail("No display available", completion); return
        }
        let chosenIndex: Int
        switch parameters.snapDisplay ?? "current" {
        case "primary": chosenIndex = 0
        case "pointer": chosenIndex = NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? index
        case "next": chosenIndex = (index + (displays.count > 1 ? 1 : 0)) % displays.count
        default: chosenIndex = index
        }
        let visible = (type == .customSnapWindow || type == .moveResizeWindow) ? displays[chosenIndex].visible : displays[index].visible
        let desired: CGRect
        switch type {
        case .customSnapWindow:
            guard let normalized = WindowGeometry.normalizedRect(x: parameters.snapX ?? 0,
                   y: parameters.snapY ?? 0, width: parameters.snapWidth ?? 0.5,
                   height: parameters.snapHeight ?? 1) else {
                fail("Invalid custom snap geometry", completion); return
            }
            desired = WindowGeometry.snapFrame(normalized: normalized, visible: visible)
        case .maximizeWindow: desired = visible
        case .snapWindowTopHalf: desired = WindowGeometry.topHalf(of: visible)
        case .snapWindowBottomHalf: desired = WindowGeometry.bottomHalf(of: visible)
        case .moveResizeWindow:
            guard let frame = WindowGeometry.customFrame(current: current, visible: visible,
                    unit: parameters.moveResizeUnit ?? "percent", anchor: parameters.moveResizeAnchor ?? "topLeft",
                    x: parameters.moveResizeX ?? 0, y: parameters.moveResizeY ?? 0,
                    width: parameters.moveResizeWidth, height: parameters.moveResizeHeight) else {
                fail("Invalid Move / Resize values", completion); return
            }
            desired = frame
        case .centerWindow: desired = WindowGeometry.moved(current, into: visible, maximize: false)
        case .moveWindowNextMonitor, .moveWindowPreviousMonitor, .moveWindowNextMonitorAndMaximize:
            guard displays.count > 1 else { fail("A second display is required", completion); return }
            let offset = type == .moveWindowPreviousMonitor ? displays.count - 1 : 1
            let next = (index + offset) % displays.count
            desired = WindowGeometry.moved(current, into: displays[next].visible,
                maximize: type == .moveWindowNextMonitorAndMaximize)
        case .restoreWindowSize:
            guard let item = saved.first(where: { CFEqual($0.target.window, target.window) && $0.target.pid == target.pid }) else {
                fail("No saved frame for this window", completion); return
            }
            desired = item.frame
        case .snapWindowLeft: desired = CGRect(x: visible.minX, y: visible.minY, width: visible.width/2, height: visible.height)
        case .snapWindowRight: desired = CGRect(x: visible.midX, y: visible.minY, width: visible.width/2, height: visible.height)
        case .snapWindowTopLeft: desired = CGRect(x: visible.minX, y: visible.minY, width: visible.width/2, height: visible.height/2)
        case .snapWindowTopRight: desired = CGRect(x: visible.midX, y: visible.minY, width: visible.width/2, height: visible.height/2)
        case .snapWindowBottomLeft: desired = CGRect(x: visible.minX, y: visible.midY, width: visible.width/2, height: visible.height/2)
        case .snapWindowBottomRight: desired = CGRect(x: visible.midX, y: visible.midY, width: visible.width/2, height: visible.height/2)
        case .snapWindowLeftThird:
            desired = CGRect(x: visible.minX, y: visible.minY, width: visible.width/3, height: visible.height)
        case .snapWindowCenterThird:
            desired = CGRect(x: visible.minX + visible.width/3, y: visible.minY, width: visible.width/3, height: visible.height)
        case .snapWindowRightThird:
            desired = CGRect(x: visible.minX + visible.width*2/3, y: visible.minY, width: visible.width/3, height: visible.height)
        case .snapWindowLeftTwoThirds:
            desired = CGRect(x: visible.minX, y: visible.minY, width: visible.width*2/3, height: visible.height)
        case .snapWindowRightTwoThirds:
            desired = CGRect(x: visible.minX + visible.width/3, y: visible.minY, width: visible.width*2/3, height: visible.height)
        case .snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
             .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth:
            // Three columns across, two rows down; the column comes from the
            // action name, the row from whether it is a top or bottom sixth.
            let column: CGFloat
            switch type {
            case .snapWindowTopLeftSixth, .snapWindowBottomLeftSixth: column = 0
            case .snapWindowTopCenterSixth, .snapWindowBottomCenterSixth: column = 1
            default: column = 2
            }
            let isTop = type == .snapWindowTopLeftSixth || type == .snapWindowTopCenterSixth || type == .snapWindowTopRightSixth
            desired = CGRect(x: visible.minX + visible.width * column / 3,
                             y: isTop ? visible.minY : visible.midY,
                             width: visible.width/3, height: visible.height/2)
        case .moveWindowLeft, .moveWindowRight, .moveWindowUp, .moveWindowDown:
            // Step by a tenth of the visible area, clamped so the window stays
            // fully on screen; BTT moves by a similar increment.
            let stepX = visible.width / 10, stepY = visible.height / 10
            var origin = current.origin
            switch type {
            case .moveWindowLeft: origin.x -= stepX
            case .moveWindowRight: origin.x += stepX
            case .moveWindowUp: origin.y -= stepY
            default: origin.y += stepY
            }
            let maxX = visible.maxX - current.width, maxY = visible.maxY - current.height
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, maxX))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, maxY))
            desired = CGRect(origin: origin, size: current.size)
        case .bringWindowToFront:
            // AXRaise is the documented way to bring another process's window
            // forward. A true always-on-top level has no public API, so this
            // raises rather than pins.
            completion(AXUIElementPerformAction(target.window, kAXRaiseAction as CFString) == .success)
            return
        case .maximizeWindowUnderCursor, .minimizeWindowUnderCursor, .closeWindowUnderCursor:
            // These act on the window under the pointer, not the focused one.
            guard let under = captureTarget(atMousePoint: NSEvent.mouseLocation), under.pid == target.pid else {
                fail("No window under the cursor", completion); return
            }
            if type == .closeWindowUnderCursor {
                var closeButton: CFTypeRef?
                let copied = AXUIElementCopyAttributeValue(under.window, kAXCloseButtonAttribute as CFString, &closeButton)
                guard copied == .success, let button = closeButton else {
                    fail("No close button on the window under the cursor", completion); return
                }
                completion(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success)
                return
            }
            guard let underFrame = frame(of: under) else { fail("No frame for the window under the cursor", completion); return }
            let underVisible = displays[WindowGeometry.screenIndex(for: underFrame, screens: displays.map(\.frame)) ?? chosenIndex].visible
            desired = type == .maximizeWindowUnderCursor
                ? underVisible
                : WindowGeometry.moved(underFrame, into: underVisible, maximize: false)
            applyFrame(desired, target: under) { success in
                completion(success)
            }
            return
        default: completion(false); return
        }
        if type != .restoreWindowSize && !saved.contains(where: { $0.target.pid == target.pid && CFEqual($0.target.window, target.window) }) {
            saved.append(Saved(target: target, frame: current))
            if saved.count > 100 { saved.removeFirst() }
        }
        let undoFrame = referenceFrame ?? current
        applyFrame(desired, target: target) { success in
            if let actual = self.frame(of: target), !WindowGeometry.close(undoFrame, actual) {
                self.remember([Saved(target: target, frame: undoFrame)])
            }
            if success && type == .restoreWindowSize {
                self.saved.removeAll { CFEqual($0.target.window, target.window) && $0.target.pid == target.pid }
            }
            completion(success)
        }
    }
    private func applyFrame(_ desired: CGRect, target: Target, completion: @escaping (Bool) -> Void) {
        let key = "\(target.pid):\(CFHash(target.window))"
        guard moving.insert(key).inserted else { completion(false); return }
        let finished = completion
        let operationCompletion: (Bool) -> Void = { success in self.moving.remove(key); finished(success) }
        // AppKit's enhanced accessibility mode can animate each AX frame write.
        // Suspend it only for this operation and restore the exact prior value
        // before notifying callers, so assistive tools retain their setting.
        let application = AXUIElementCreateApplication(target.pid)
        let enhancedKey = "AXEnhancedUserInterface" as CFString
        var enhanced: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(application, enhancedKey, &enhanced) == .success
            && (enhanced as? Bool) == true
        let suspended = hadEnhanced && AXUIElementSetAttributeValue(application, enhancedKey, kCFBooleanFalse) == .success
        let originalCompletion = operationCompletion
        let completion: (Bool) -> Void = { success in
            if suspended, let enhanced { _ = AXUIElementSetAttributeValue(application, enhancedKey, enhanced) }
            originalCompletion(success)
        }
        var position = desired.origin; var size = desired.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { completion(false); return }
        // Some apps animate AX changes. A second write interrupts that animation
        // at an intermediate frame, so wait for each stage to finish first.
        // Destination constraints can reject the first size on the source screen;
        // resizing again after moving handles displays with different dimensions.
        func write(_ attribute: String, _ value: AXValue) -> Bool {
            AXUIElementSetAttributeValue(target.window, attribute as CFString, value) == .success
        }
        func settle(_ attribute: String, then next: @escaping () -> Void) {
            var last: CGRect?
            var stable = 0
            func poll(_ count: Int) {
                guard let actual = self.frame(of: target) else { self.fail("Window closed during move", completion); return }
                if let last, WindowGeometry.close(last, actual) { stable += 1 } else { stable = 0 }
                last = actual
                let reached = attribute == kAXSizeAttribute
                    ? abs(actual.width - desired.width) <= 3 && abs(actual.height - desired.height) <= 3
                    : abs(actual.minX - desired.minX) <= 3 && abs(actual.minY - desired.minY) <= 3
                if (reached && stable >= 1) || (count >= 7 && stable >= 3) || count >= 24 {
                    next()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(count + 1) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(0) }
        }
        let stages: [(String, AXValue)] = [(kAXSizeAttribute, s), (kAXPositionAttribute, p),
                                          (kAXSizeAttribute, s), (kAXPositionAttribute, p)]
        func apply(_ index: Int) {
            if index == stages.count {
                guard let actual = self.frame(of: target), WindowGeometry.close(actual, desired) else {
                    self.fail("Window did not reach requested frame (app size limits or fullscreen)", completion); return
                }
                completion(true)
                return
            }
            let (attribute, value) = stages[index]
            guard write(attribute, value) else { self.fail("Window refused size or position", completion); return }
            settle(attribute) { apply(index + 1) }
        }
        apply(0)
    }

    private func fail(_ message: String, _ completion: (Bool) -> Void) {
        GestureLog.shared.logFromAnyThread("Window: \(message)", level: .error); completion(false)
    }
}

/// BTT-style regular window drag into a zone. Mouse events pass through.
/// AX movement proves this is a window drag (not ordinary text selection).
/// No monitor exists until a valid enabled snap zone has been saved.
final class CustomSnapZoneMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var zones: [CustomSnapZone] = []
    private var startWindow: WindowManager.Target?
    private var startFrame: CGRect?
    private let preview = SnapDragOverlay()
    private var windowMoved = false
    private var lastFrameProbe: TimeInterval = 0
    /// The most recent throttled reading of the dragged window's frame, reused
    /// by the centre fallback so a drag event costs no extra AX query.
    private var lastKnownFrame: CGRect?
    private var overlayScreen: NSScreen?
    private var overlayZoneID: UUID?
    /// Where the button went down. The window under it is only looked up
    /// once the mouse is actually dragged: an Accessibility hit-test per
    /// click is a synchronous IPC round trip (and, for AOM's own SwiftUI
    /// windows, a full accessibility-tree rebuild on the main thread).
    private var downPoint: CGPoint?
    private var probedStart = false

    var isMonitoring: Bool { globalMonitor != nil && !zones.isEmpty }
    private var requiresOption = false
    private var showsPreview = true
    func registerZones(_ newZones: [CustomSnapZone], requiresOption: Bool = false, showsPreview: Bool = true) {
        self.requiresOption = requiresOption; self.showsPreview = showsPreview
        unregister()
        zones = newZones.filter { $0.isEnabled && $0.isValid }
        guard !zones.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // AOM's floating panels (clipboard shelf, Quick Access, HUDs) are
            // never snap targets; their clicks and drags stay untouched.
            if let window = event.window, window.styleMask.contains(.nonactivatingPanel) || !window.styleMask.contains(.titled) {
                return event
            }
            self?.handle(event)
            return event
        }
        GestureLog.shared.logFromAnyThread(
            globalMonitor != nil ? "Window snapping listening (\(zones.count) layouts, normal drag)" :
                                  "Window snapping: global mouse monitoring unavailable", level: globalMonitor != nil ? .detect : .error)
    }
    private func clear() {
        downPoint = nil; probedStart = false
        startWindow = nil; startFrame = nil
        windowMoved = false; lastFrameProbe = 0; lastKnownFrame = nil
        overlayScreen = nil; overlayZoneID = nil
        preview.hide()
    }
    /// The zone under the drag, judged from the cursor first and the window's
    /// own centre second.
    ///
    /// The cursor alone cannot reach a zone in the middle of the screen. A
    /// window is dragged by its title bar, which sits at the window's top, so
    /// placing a window at the screen centre leaves the cursor well above the
    /// centre — to bring the cursor into a centre hot zone the window would
    /// have to hang mostly off the bottom of the display. Every other starter
    /// layout sits on an edge, which the cursor reaches naturally; Centre was
    /// the only one that could not be selected at all.
    ///
    /// So the cursor is tried first, keeping the edge zones behaving exactly as
    /// before, and the window centre is used only when the cursor lands on
    /// nothing. A cursor that is on a zone always wins, which is what stops the
    /// centre fallback from stealing a drag that is clearly aimed at an edge.
    private func hitZone(at point: CGPoint, windowFrame: CGRect? = nil) -> (CustomSnapZone, NSScreen)? {
        if let direct = zone(at: point) { return direct }
        guard let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        return zone(at: CGPoint(x: windowFrame.midX, y: windowFrame.midY))
    }

    private func zone(at point: CGPoint) -> (CustomSnapZone, NSScreen)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              screen.visibleFrame.width > 0, screen.visibleFrame.height > 0 else { return nil }
        guard let normalized = WindowGeometry.screenEdgeDropPoint(point, screen: screen.frame, visible: screen.visibleFrame) else { return nil }
        guard let zone = CustomSnapZone.matching(zones, x: normalized.x, y: normalized.y) else { return nil }
        return (zone, screen)
    }
    private func handle(_ event: NSEvent) {
        // Ctrl+Option drag is reserved for AOM drawing gestures.
        if event.modifierFlags.contains(.control) && event.modifierFlags.contains(.option) {
            clear(); return
        }
        if event.type == .keyDown {
            if event.keyCode == 53 { clear() }; return
        }
        if event.type == .flagsChanged {
            if requiresOption && !event.modifierFlags.contains(.option) { preview.hide(); overlayScreen = nil; overlayZoneID = nil }
            return
        }
        switch event.type {
        case .leftMouseDown:
            clear()
            downPoint = NSEvent.mouseLocation
        case .leftMouseDragged:
            if !probedStart, let point = downPoint {
                probedStart = true
                // Hit test the clicked window, not the previous focused window.
                let target = WindowManager.shared.captureTarget(atMousePoint: point)
                startWindow = target
                startFrame = target.flatMap { WindowManager.shared.frame(of: $0) }
                // Seed the centre fallback so a drag that has not yet been
                // probed still has a frame to judge against.
                lastKnownFrame = startFrame
            }
            guard let initial = startFrame, let target = startWindow else { return }
            // AX queries are throttled; the overlay is only updated when its
            // active zone or display changes, not on every drag event.
            if !windowMoved, ProcessInfo.processInfo.systemUptime - lastFrameProbe > 0.075 {
                lastFrameProbe = ProcessInfo.processInfo.systemUptime
                if let current = WindowManager.shared.frame(of: target) {
                    lastKnownFrame = current
                    windowMoved = WindowGeometry.windowActuallyMoved(from: initial, to: current)
                }
            }
            guard windowMoved else { return }
            guard showsPreview, !requiresOption || event.modifierFlags.contains(.option) else {
                preview.hide(); overlayScreen = nil; overlayZoneID = nil; return
            }
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else {
                preview.hide(); overlayScreen = nil; overlayZoneID = nil; return
            }
            // The centre fallback reads the last probed frame rather than asking
            // again: this runs on every drag event, and an AX query per event
            // would undo the throttle above.
            let zone = hitZone(at: pointer, windowFrame: lastKnownFrame)?.0
            if overlayScreen !== screen || overlayZoneID != zone?.id {
                overlayScreen = screen
                overlayZoneID = zone?.id
                preview.show(zones: zones, pointerScreen: screen, active: zone, windowFrame: initial)
            }
        case .leftMouseUp:
            // The final cursor position, not the last throttled drag event,
            // determines the target; the configured Option requirement is checked below.
            guard let initial = startFrame, let target = startWindow,
                  let current = WindowManager.shared.frame(of: target) else { clear(); return }
            let didMove = WindowGeometry.windowActuallyMoved(from: initial, to: current)
            let permitted = !requiresOption || event.modifierFlags.contains(.option)
            let matched = didMove && permitted ? hitZone(at: NSEvent.mouseLocation, windowFrame: current)?.0 : nil
            clear()
            guard let matched else { return }
            WindowManager.shared.execute(.customSnapWindow, target: target,
                parameters: matched.actionParameters, referenceFrame: initial) { success in
                GestureLog.shared.logFromAnyThread(
                    success ? "Snapped window: \(matched.name)" : "Snap failed: \(matched.name)",
                    level: success ? .action : .error)
            }
        default: break
        }
    }
    func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        clear()
    }
    deinit { unregister() }
}

/// Drawn only while a window is actually being dragged. Two reusable, click-through
/// nonactivating panels communicate the drop zones and resulting window frame.
private final class SnapDragOverlay {
    private final class LayerView: NSView {
        var zones: [CustomSnapZone] = []
        var activeID: UUID?
        var target: (CGRect, String)?
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            for zone in zones {
                let rect = CGRect(x: bounds.width * zone.hotX,
                                  y: bounds.height * (1 - zone.hotY - zone.hotHeight),
                                  width: bounds.width * zone.hotWidth,
                                  height: bounds.height * zone.hotHeight)
                let active = zone.id == activeID
                let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
                NSColor.controlAccentColor.withAlphaComponent(active ? 0.30 : 0.17).setFill()
                path.fill()
                NSColor.controlAccentColor.withAlphaComponent(active ? 0.95 : 0.70).setStroke()
                path.lineWidth = active ? 3 : 2
                path.stroke()
                let text = NSString(string: zone.name)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                      y: rect.midY - size.height / 2), withAttributes: attrs)
            }
            if let (frame, name) = target {
                let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
                NSColor.systemGreen.withAlphaComponent(0.19).setFill(); path.fill()
                NSColor.systemGreen.withAlphaComponent(0.88).setStroke()
                path.lineWidth = 3; path.stroke()
                let text = NSString(string: "⇥  \(name) · Window destination")
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: frame.midX - size.width / 2,
                                      y: frame.midY - size.height / 2), withAttributes: attrs)
            }
        }
    }
    private let dropView = LayerView()
    private let targetView = LayerView()
    private lazy var dropPanel = panel(view: dropView)
    private lazy var targetPanel = panel(view: targetView)
    private var hasShownPreview = false

    private func panel(view: NSView) -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentView = view
        return window
    }
    func show(zones: [CustomSnapZone], pointerScreen: NSScreen,
              active: CustomSnapZone?, windowFrame: CGRect?) {
        hasShownPreview = true
        let source = pointerScreen.visibleFrame
        dropPanel.setFrame(source, display: true)
        dropView.frame = CGRect(origin: .zero, size: source.size)
        dropView.zones = zones
        dropView.activeID = active?.id
        dropView.target = nil
        if let active {
            let screens = WindowManager.shared.screens()
            let current = windowFrame.flatMap { WindowGeometry.screenIndex(for: $0, screens: screens.map(\.frame)) } ?? 0
            let next: Int
            switch active.targetDisplay {
            case "pointer": next = NSScreen.screens.firstIndex(of: pointerScreen) ?? current
            case "primary": next = 0
            case "next": next = (current + (screens.count > 1 ? 1 : 0)) % screens.count
            default: next = current
            }
            if NSScreen.screens.indices.contains(next) {
                let dest = NSScreen.screens[next].visibleFrame
                let rectangle = CGRect(x: dest.width * active.targetX,
                                       y: dest.height * (1 - active.targetY - active.targetHeight),
                                       width: dest.width * active.targetWidth,
                                       height: dest.height * active.targetHeight)
                if next == (NSScreen.screens.firstIndex(of: pointerScreen) ?? -1) {
                    dropView.target = (rectangle, active.name)
                    targetPanel.orderOut(nil)
                } else {
                    targetPanel.setFrame(dest, display: true)
                    targetView.frame = CGRect(origin: .zero, size: dest.size)
                    targetView.zones = []
                    targetView.target = (rectangle, active.name)
                    targetView.needsDisplay = true
                    targetPanel.orderFrontRegardless()
                }
            }
        } else { targetPanel.orderOut(nil) }
        dropView.needsDisplay = true
        dropPanel.orderFrontRegardless()
    }
    func hide() {
        guard hasShownPreview else { return }
        if dropPanel.isVisible { dropPanel.orderOut(nil) }
        if targetPanel.isVisible { targetPanel.orderOut(nil) }
    }
}
