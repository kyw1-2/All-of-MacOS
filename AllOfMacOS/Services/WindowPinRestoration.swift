import AppKit

/// Translucent pins temporarily park the opaque source outside the desktop.
/// Journal before moving it, and recover only the same process/window after a
/// crash. No source content, title or screenshot is persisted.
@MainActor
enum WindowPinRestoration {
    struct Entry: Codable {
        let windowID: CGWindowID
        let pid: pid_t
        let bundleID: String
        let launchDate: Date
        let frame: CGRect // AX coordinates
        var parkedFrame: CGRect?
    }
    static let key = "AOMParkedWindowRecoveryV1"

    static func entries(in defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key), data.count < 1_000_000,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func remember(_ pin: LivePinnedWindow, frame: CGRect, defaults: UserDefaults) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pin.target.pid), let date = app.launchDate else { return false }
        var entries = entries(in: defaults).filter { $0.windowID != pin.id }
        entries.append(Entry(windowID: pin.id, pid: pin.target.pid, bundleID: pin.bundleID, launchDate: date, frame: frame, parkedFrame: nil))
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        defaults.set(data, forKey: key)
        // This small journal must reach disk before the source leaves the desktop.
        return defaults.synchronize()
    }

    static func recordParkedFrame(_ frame: CGRect, id: CGWindowID, defaults: UserDefaults) -> Bool {
        var entries = entries(in: defaults)
        guard let index = entries.firstIndex(where: { $0.windowID == id }) else { return false }
        entries[index].parkedFrame = frame
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        defaults.set(data, forKey: key)
        return defaults.synchronize()
    }

    static func shouldRecover(_ entry: Entry, current: CGRect, screens: [CGRect]) -> Bool {
        if let parked = entry.parkedFrame { return WindowGeometry.close(parked, current) }
        // A crash between AXMove and the second journal write: macOS may clamp
        // the title bar to a display edge. Recover only a mostly off-screen
        // window with the original size, never an ordinary user placement.
        guard abs(current.width - entry.frame.width) <= 4, abs(current.height - entry.frame.height) <= 4,
              !current.intersects(entry.frame), current.width > 0, current.height > 0 else { return false }
        let visibleArea = screens.reduce(CGFloat(0)) { area, screen in
            let overlap = screen.intersection(current)
            return area + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        return visibleArea / (current.width * current.height) < 0.25
    }

    static func forget(_ id: CGWindowID, defaults: UserDefaults) {
        let remaining = entries(in: defaults).filter { $0.windowID != id }
        if remaining.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(remaining) { defaults.set(data, forKey: key) }
    }

    static func move(_ target: WindowManager.Target, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, value) == .success
    }

    static func restore(_ target: WindowManager.Target, frame: CGRect) -> Bool {
        // A removed display must not strand the restored source off screen.
        let screens = WindowManager.shared.screens()
        let destination: CGRect
        if screens.contains(where: { $0.visible.intersects(frame) }) { destination = frame }
        else if let visible = screens.first?.visible { destination = WindowGeometry.moved(frame, into: visible, maximize: false) }
        else { return false }
        guard move(target, to: destination.origin), let actual = WindowManager.shared.frame(of: target) else { return false }
        return abs(actual.minX - destination.minX) <= 4 && abs(actual.minY - destination.minY) <= 4
    }

    static func recover(defaults: UserDefaults = .standard) {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview, AXIsProcessTrusted() else { return }
        let entries = entries(in: defaults)
        guard !entries.isEmpty,
              let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        for entry in entries {
            guard let app = NSRunningApplication(processIdentifier: entry.pid),
                  app.bundleIdentifier == entry.bundleID, app.launchDate == entry.launchDate,
                  let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == entry.windowID &&
                      ($0[kCGWindowOwnerPID as String] as? pid_t) == entry.pid }),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let current = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                forget(entry.windowID, defaults: defaults); continue
            }
            // If the user already brought it back, leave that placement alone.
            if !shouldRecover(entry, current: current, screens: WindowManager.shared.screens().map(\.frame)) {
                forget(entry.windowID, defaults: defaults); continue
            }
            var value: CFTypeRef?
            let axApp = AXUIElementCreateApplication(entry.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            let matches = windows.map { WindowManager.Target(window: $0, pid: entry.pid) }.filter {
                AXUIElementSetMessagingTimeout($0.window, 0.25)
                guard let frame = WindowManager.shared.frame(of: $0) else { return false }
                return WindowGeometry.close(frame, current)
            }
            if matches.count == 1, restore(matches[0], frame: entry.frame) { forget(entry.windowID, defaults: defaults) }
        }
    }
}
