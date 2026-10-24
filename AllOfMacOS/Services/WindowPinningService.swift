import AppKit
import ScreenCaptureKit

/// Live pinning inspired by Topit's public behavior, implemented for AOM's
/// window targets, permissions, menus and automation lifecycle. See docs/window-pinning.md.
@MainActor
final class WindowPinningService: NSObject, ObservableObject {
    static let shared = WindowPinningService()
    @Published private(set) var pins: [LivePinnedWindow] = []
    @Published private(set) var isChoosingWindow = false
    @Published private(set) var lastError: String?
    @Published var options: WindowPinningOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: WindowPinningOptions.defaultsKey) }
            for pin in pins where options.excludedBundleIDs.contains(pin.bundleID) { unpin(pin.id) }
            tick()
        }
    }
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activePinID: CGWindowID?
    private var activationDeadline = Date.distantPast
    private var pendingIDs = Set<CGWindowID>()
    private var epoch = 0
    private var sleeping = false
    private var spaceTransitionUntil = Date.distantPast
    private var selection: SelectionOverlayController?

    nonisolated static let actionTypes: Set<ActionType> = [.showPinnedWindowPicker, .selectWindowToPin,
                                              .togglePinFrontWindow, .togglePinWindowUnderCursor, .unpinAllWindows]

    override private init() {
        defaults = (PresetManager.isRunningTests || PresetManager.isUIPreview)
            ? UserDefaults(suiteName: "AOMWindowPinning-Isolated-\(UUID().uuidString)")! : .standard
        if let data = defaults.data(forKey: WindowPinningOptions.defaultsKey),
           let saved = try? JSONDecoder().decode(WindowPinningOptions.self, from: data) { options = saved }
        else { options = WindowPinningOptions() }
        super.init()
    }

    func perform(_ type: ActionType, target: WindowManager.Target? = nil,
                 isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isCancelled() else { completion(false); return }
        if type == .unpinAllWindows { unpinAll(); completion(true); return }
        if type == .showPinnedWindowPicker { chooseWindow(isCancelled: isCancelled, completion: completion); return }
        if type == .selectWindowToPin { selectWindow(isCancelled: isCancelled, completion: completion); return }
        let captured: WindowManager.Target?
        if type == .togglePinWindowUnderCursor {
            // The overlay belongs to AOM; resolve it before AX hit testing.
            if let pin = pins.reversed().first(where: { $0.frame.contains(NSEvent.mouseLocation) && ($0.panel.isVisible || $0.controls.isVisible) }) {
                unpin(pin.id); completion(true); return
            }
            captured = WindowManager.shared.captureTarget(atMousePoint: NSEvent.mouseLocation)
        } else { captured = target ?? WindowManager.shared.captureTarget() }
        guard let captured, captured.pid != ProcessInfo.processInfo.processIdentifier else {
            report("Choose another application's window to pin."); completion(false); return
        }
        if let existing = pins.first(where: { $0.target.pid == captured.pid && CFEqual($0.target.window, captured.window) }) {
            unpin(existing.id); completion(true); return
        }
        let requestEpoch = epoch
        Task {
            do {
                let windows = try await availableWindows()
                guard epoch == requestEpoch, !isCancelled() else { completion(false); return }
                guard let window = matchingWindow(for: captured, in: windows) else {
                    throw PinError.message("The window is unavailable or excluded. Try Choose Window instead.")
                }
                let result = try await pin(window, target: captured, isCancelled: isCancelled)
                completion(result)
            } catch { report(error); completion(false) }
        }
    }

    func availableWindows() async throws -> [SCWindow] {
        try requirePermissions()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            options.allows(bundleID: $0.owningApplication?.bundleIdentifier ?? "", title: $0.title ?? "",
                           ownPID: ProcessInfo.processInfo.processIdentifier, pid: $0.owningApplication?.processID ?? 0,
                           layer: $0.windowLayer, frame: $0.frame)
        }.sorted {
            let a = "\($0.owningApplication?.applicationName ?? "") \($0.title ?? "")"
            let b = "\($1.owningApplication?.applicationName ?? "") \($1.title ?? "")"
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func chooseWindow(isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isChoosingWindow else { completion(false); return }
        isChoosingWindow = true
        let requestEpoch = epoch
        Task {
            defer { isChoosingWindow = false }
            do {
                let windows = try await availableWindows().filter { window in !pins.contains { $0.id == window.windowID } }
                guard epoch == requestEpoch, !isCancelled() else { completion(false); return }
                guard !windows.isEmpty else { throw PinError.message("No unpinned windows are available. Check the app filter or open a window.") }
                guard let selected = await WindowPickerController.present(windows: windows, title: "Pin Window", actionLabel: "Pin", showsThumbnails: true),
                      epoch == requestEpoch, !isCancelled() else { completion(false); return }
                completion(try await pin(selected, isCancelled: isCancelled))
            } catch { report(error); completion(false) }
        }
    }

    func selectWindow(isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !SelectionOverlayController.isActive, !isChoosingWindow else { completion(false); return }
        do { try requirePermissions() } catch { report(error); completion(false); return }
        isChoosingWindow = true
        let requestEpoch = epoch
        let overlay = SelectionOverlayController(startInWindowMode: true) { [weak self] rect in
            guard let self else { completion(false); return }
            let id = self.selection?.selectedMode == .window ? self.selection?.selectedWindowID : nil
            self.selection = nil
            self.isChoosingWindow = false
            guard rect != nil, let id, self.epoch == requestEpoch, !isCancelled() else { completion(false); return }
            if self.pins.contains(where: { $0.id == id }) { self.unpin(id); completion(true); return }
            Task {
                do {
                    let windows = try await self.availableWindows()
                    guard self.epoch == requestEpoch, !isCancelled() else { completion(false); return }
                    guard let window = windows.first(where: { $0.windowID == id }) else {
                        throw PinError.message("That window is unavailable or excluded.")
                    }
                    completion(try await self.pin(window, isCancelled: isCancelled))
                } catch { self.report(error); completion(false) }
            }
        }
        selection = overlay
        overlay.present()
    }

    @discardableResult
    func pin(_ window: SCWindow, target: WindowManager.Target? = nil,
             isCancelled: @escaping () -> Bool = { false }) async throws -> Bool {
        try requirePermissions()
        guard options.allows(bundleID: window.owningApplication?.bundleIdentifier ?? "", title: window.title ?? "",
                             ownPID: ProcessInfo.processInfo.processIdentifier, pid: window.owningApplication?.processID ?? 0,
                             layer: window.windowLayer, frame: window.frame) else { return false }
        guard !isCancelled(), !pins.contains(where: { $0.id == window.windowID }),
              pendingIDs.insert(window.windowID).inserted else { return false }
        defer { pendingIDs.remove(window.windowID) }
        let requestEpoch = epoch
        var resolvedTarget = target ?? accessibilityTarget(for: window)
        // AX can lag ScreenCaptureKit when an app has just opened a window.
        for _ in 0..<3 where resolvedTarget == nil {
            try await Task.sleep(for: .milliseconds(80))
            guard epoch == requestEpoch, !isCancelled() else { return false }
            resolvedTarget = accessibilityTarget(for: window)
        }
        guard let target = resolvedTarget,
              target.pid != ProcessInfo.processInfo.processIdentifier else {
            throw PinError.message("This window does not expose an unambiguous Accessibility window for interaction.")
        }
        AXUIElementSetMessagingTimeout(target.window, 0.05)
        let pin = LivePinnedWindow(window: window, target: target)
        pin.capture.onFailure = { [weak self, weak pin] error in
            guard let self, let pin else { return }
            self.unpin(pin.id)
            self.report(error)
        }
        pins.append(pin)
        lastError = nil
        startMonitoring()
        let frame = pin.frame
        // Start without activating another app or changing the source window.
        pin.update(frame: frame, options: options, visible: true, interacting: false, ducked: false)
        do { try await pin.capture.waitForStart() }
        catch { unpin(pin.id); throw error }
        guard !isCancelled(), !pin.isClosed else { unpin(pin.id); return false }
        return true
    }

    func unpin(_ id: CGWindowID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if !pin.restoreSource(defaults: defaults), NSRunningApplication(processIdentifier: pin.target.pid)?.isTerminated == false {
            report("The source window could not be restored. AOM will retry recovery on its next launch.")
        }
        pin.close()
        pins.removeAll { $0.id == id }
        if activePinID == id { activePinID = nil }
        if pins.isEmpty { stopMonitoring() }
    }

    func unpinAll() {
        epoch += 1
        for pin in pins { unpin(pin.id) }
        activePinID = nil
        stopMonitoring()
        if let selection, SelectionOverlayController.activeController === selection { SelectionOverlayController.cancelActive() }
    }

    func activate(_ pin: LivePinnedWindow) {
        guard !pin.isClosed, !pin.isPaused, AXIsProcessTrusted(), !ScreenLock.isLocked else { return }
        guard let app = NSRunningApplication(processIdentifier: pin.target.pid), !app.isTerminated else { unpin(pin.id); return }
        guard pin.restoreSource(defaults: defaults) else { report("The source window could not be restored."); return }
        // Deliver subsequent input to the real window; never synthesize clicks.
        _ = AXUIElementSetAttributeValue(pin.target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementSetAttributeValue(pin.target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(pin.target.window, kAXRaiseAction as CFString) == .success
        guard raised, activated else {
            report("The source window could not be activated."); return
        }
        activePinID = pin.id
        activationDeadline = Date().addingTimeInterval(0.5)
        pin.wasMouseInside = true
        tick()
    }

    func togglePause(_ pin: LivePinnedWindow) {
        pin.isPaused.toggle()
        if activePinID == pin.id { activePinID = nil }
        tick()
    }

    func setOpacity(_ value: Double, for pin: LivePinnedWindow) {
        guard value.isFinite else { return }
        pin.opacity = min(1, max(0.2, value))
        tick()
    }

    func closeSource(_ pin: LivePinnedWindow) {
        guard pin.restoreSource(defaults: defaults) else { report("The source window could not be restored."); return }
        _ = NSRunningApplication(processIdentifier: pin.target.pid)?.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(pin.target.window, kAXRaiseAction as CFString)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(pin.target.window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success else {
            report("The source window could not be closed."); return
        }
        unpin(pin.id)
    }

    private func requirePermissions() throws {
        guard !ScreenLock.isLocked else { throw PinError.message("Unlock your Mac before pinning a window.") }
        guard AXIsProcessTrusted() else {
            throw PinError.message("Enable Accessibility for All of MacOS in System Settings → Privacy & Security.")
        }
        // Recovers a previous interrupted translucent session after permission
        // was granted late. Active pins are not recovery candidates.
        if pins.isEmpty { WindowPinRestoration.recover(defaults: defaults) }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw PinError.message("Enable Screen Recording for All of MacOS in System Settings → Privacy & Security.")
        }
    }

    /// Public AX has no universal window-ID attribute. Require a unique frame /
    /// title match; identical overlapping windows are rejected rather than guessed.
    func accessibilityTarget(for window: SCWindow) -> WindowManager.Target? {
        guard let pid = window.owningApplication?.processID else { return nil }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let targets = windows.map { WindowManager.Target(window: $0, pid: pid) }
        let matches = targets.filter {
            AXUIElementSetMessagingTimeout($0.window, 0.25)
            guard let frame = WindowManager.shared.frame(of: $0) else { return false }
            return WindowGeometry.close(frame, window.frame)
        }
        if matches.count == 1 { return matches[0] }
        // A freshly shown or moved window may have changed frame since the SC
        // snapshot. A unique nonempty title in the same PID is also a valid match.
        guard let name = window.title, !name.isEmpty else { return nil }
        let titled = targets.filter { title(of: $0) == name }
        return titled.count == 1 ? titled[0] : nil
    }

    func matchingWindow(for target: WindowManager.Target, in windows: [SCWindow]) -> SCWindow? {
        guard let frame = WindowManager.shared.frame(of: target) else { return nil }
        let matches = windows.filter { $0.owningApplication?.processID == target.pid && WindowGeometry.close($0.frame, frame) }
        if matches.count == 1 { return matches[0] }
        let titled = matches.filter { $0.title == title(of: target) }
        return titled.count == 1 ? titled[0] : nil
    }

    private func title(of target: WindowManager.Target) -> String? {
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(target.window, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    private func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true; self?.tick() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false; self?.tick() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activePinID = nil
                self.spaceTransitionUntil = Date().addingTimeInterval(0.5)
                self.tick()
            }
        })
    }

    private func stopMonitoring() {
        timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        sleeping = false
    }

    private func tick() {
        guard !pins.isEmpty else { return }
        let unavailable = sleeping || Date() < spaceTransitionUntil || ScreenLock.isLocked ||
            !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess()
        guard !unavailable,
              let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            for pin in pins {
                _ = pin.restoreSource(defaults: defaults)
                pin.update(frame: pin.frame, options: options, visible: false, interacting: false, ducked: false)
            }
            return
        }
        let byID = Dictionary(info.compactMap { item -> (CGWindowID, [String: Any])? in
            guard let id = item[kCGWindowNumber as String] as? UInt32 else { return nil }
            return (id, item)
        }, uniquingKeysWith: { first, _ in first })
        let mouse = NSEvent.mouseLocation
        if let active = pins.first(where: { $0.id == activePinID }) {
            let focused = WindowManager.shared.captureTarget(pid: active.target.pid)
            let lostFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier != active.target.pid ||
                (focused.map { !CFEqual($0.window, active.target.window) } ?? true)
            if !active.frame.contains(mouse) || (Date() > activationDeadline && lostFocus) { activePinID = nil }
        }
        let activeFrame = pins.first(where: { $0.id == activePinID })?.frame
        for pin in pins {
            guard let item = byID[pin.id], (item[kCGWindowOwnerPID as String] as? pid_t) == pin.target.pid,
                  let app = NSRunningApplication(processIdentifier: pin.target.pid), !app.isTerminated,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { unpin(pin.id); continue }
            if let parked = pin.parkedFrame, !WindowGeometry.close(parked, cgFrame) { pin.sourceMoved(defaults: defaults) }
            let frame = pin.parkedFrame == nil
                ? WindowPinningGeometry.appKitFrame(cgFrame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0) : pin.frame
            var minimized: CFTypeRef?; var fullscreen: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(pin.target.window, kAXMinimizedAttribute as CFString, &minimized)
            _ = AXUIElementCopyAttributeValue(pin.target.window, "AXFullScreen" as CFString, &fullscreen)
            let visible = !unavailable && !app.isHidden && minimized as? Bool != true && fullscreen as? Bool != true &&
                ((item[kCGWindowIsOnscreen as String] as? Bool == true) || pin.parkedFrame != nil) &&
                NSScreen.screens.contains { $0.frame.intersects(frame) } && frame.width > 0 && frame.height > 0
            let inside = frame.contains(mouse)
            let ducked = pin.id != activePinID && WindowPinningGeometry.shouldDuck(frame, activeFrame: activeFrame, enabled: options.duckOverlappingWindows)
            let shouldActivate = visible && !pin.isPaused && !ducked && !isChoosingWindow && !SelectionOverlayController.isActive &&
                options.activation == .hover && inside && !pin.wasMouseInside && !pin.controls.frame.contains(mouse) &&
                NSEvent.pressedMouseButtons == 0
            pin.wasMouseInside = inside
            if pin.opacity < 1, visible, !pin.isPaused, pin.id != activePinID, !ducked {
                if !pin.parkSource(defaults: defaults) {
                    pin.opacity = 1
                    report("This app cannot move its window off screen for transparency. The pin remains opaque.")
                }
            } else { _ = pin.restoreSource(defaults: defaults) }
            pin.update(frame: frame, options: options, visible: visible, interacting: pin.id == activePinID, ducked: ducked)
            if shouldActivate { activate(pin); return }
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        report(error.localizedDescription)
    }
    private func report(_ message: String) {
        lastError = message
        GestureHUD.shared.show(title: "Window Pinning", detail: message)
    }

    enum PinError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

extension WindowPinningService {
    func statusMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Always on Top", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        let menu = NSMenu(title: item.title)
        for (title, selector) in [("Choose Window…", #selector(chooseFromMenu)),
                                  ("Select Window on Screen…", #selector(selectFromMenu)),
                                  ("Pin / Unpin Front Window", #selector(toggleFrontFromMenu))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        if !pins.isEmpty {
            menu.addItem(.separator())
            for pin in pins {
                let entry = NSMenuItem(title: "\(pin.appName) — \(pin.title)", action: nil, keyEquivalent: "")
                entry.submenu = self.menu(for: pin)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let all = NSMenuItem(title: "Unpin All Windows", action: #selector(unpinAllFromMenu), keyEquivalent: "")
            all.target = self; menu.addItem(all)
        }
        item.submenu = menu
        return item
    }

    func menu(for pin: LivePinnedWindow) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; item.representedObject = NSNumber(value: pin.id); item.tag = tag
            return item
        }
        menu.addItem(item("Unpin", #selector(unpinFromMenu(_:))))
        menu.addItem(item(pin.isPaused ? "Resume" : "Pause", #selector(pauseFromMenu(_:))))
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let value = item("\(percent)%", #selector(opacityFromMenu(_:)), tag: percent)
            value.state = Int((pin.opacity * 100).rounded()) == percent ? .on : .off
            submenu.addItem(value)
        }
        opacity.submenu = submenu; menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(item("Close Source Window", #selector(closeFromMenu(_:))))
        return menu
    }
    private func pin(from item: NSMenuItem) -> LivePinnedWindow? {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value else { return nil }
        return pins.first { $0.id == id }
    }
    @objc private func chooseFromMenu() { chooseWindow() }
    @objc private func selectFromMenu() { selectWindow() }
    @objc private func toggleFrontFromMenu() { perform(.togglePinFrontWindow) }
    @objc private func unpinAllFromMenu() { unpinAll() }
    @objc private func unpinFromMenu(_ item: NSMenuItem) { if let pin = pin(from: item) { unpin(pin.id) } }
    @objc private func pauseFromMenu(_ item: NSMenuItem) { if let pin = pin(from: item) { togglePause(pin) } }
    @objc private func opacityFromMenu(_ item: NSMenuItem) { if let pin = pin(from: item) { setOpacity(Double(item.tag) / 100, for: pin) } }
    @objc private func closeFromMenu(_ item: NSMenuItem) { if let pin = pin(from: item) { closeSource(pin) } }
}
