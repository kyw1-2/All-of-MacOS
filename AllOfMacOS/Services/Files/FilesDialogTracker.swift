import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// An Open or Save dialog the helper is attached to.
struct FilesDialogState {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let element: AXUIElement
    let classification: FilesDialogClassification
    /// Accessibility coordinates: global, top-left origin.
    var frame: CGRect

    func isSameDialog(as other: FilesDialogState?) -> Bool {
        guard let other else { return false }
        return other.pid == pid && CFEqual(other.element, element)
    }
}

/// Why a jump didn't happen. Each case reads as the end of "Couldn't go to
/// “Downloads” because …".
enum FilesJumpFailure: Error, Equatable {
    case noDialog, notFrontmost, secureInput, noAccessibility, folderMissing
    case goToDidNotOpen, fieldNotFound, couldNotEnterPath, notAccepted

    var reason: String {
        switch self {
        case .noDialog: return "the dialog closed"
        case .notFrontmost: return "the dialog's app is no longer in front"
        case .secureInput: return "secure input is on (a password field is active)"
        case .noAccessibility: return "All of MacOS needs the Accessibility permission"
        case .folderMissing: return "the folder no longer exists"
        case .goToDidNotOpen: return "the dialog didn't open Go to Folder"
        case .fieldNotFound: return "Go to Folder had no path field"
        case .couldNotEnterPath: return "the path couldn't be entered"
        case .notAccepted: return "the dialog didn't accept the folder"
        }
    }
}

/// Watches the frontmost app with an AXObserver (focused window, new windows
/// and sheets, moves and resizes) and reports when its focused window is an
/// Open or Save dialog. All Accessibility work happens on one serial queue
/// with short timeouts; the observer's callbacks only hop onto it.
final class FilesDialogTracker: @unchecked Sendable {
    static let shared = FilesDialogTracker()

    let queue = DispatchQueue(label: "com.kyw.allofmacos.files.dialogs", qos: .userInitiated)
    /// Called on the main thread with the attached dialog, or nil.
    var publish: (@MainActor (FilesDialogState?) -> Void)?

    // Queue-confined state.
    private var enabled = false
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var bundleID: String?
    private var appName = ""
    private var current: FilesDialogState?
    private var observedDialog: AXUIElement?
    /// The last focused window that wasn't a dialog (not read again until focus moves).
    private var lastRejected: AXUIElement?
    private var scheduled = false
    private var jumping = false
    private var liveness: DispatchSourceTimer?

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                                           kAXSheetCreatedNotification, kAXWindowMovedNotification,
                                           kAXWindowResizedNotification, kAXFocusedUIElementChangedNotification,
                                           kAXMainWindowChangedNotification]
    private static let dialogNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification]

    // MARK: Control (any thread)

    func setEnabled(_ on: Bool) {
        queue.async {
            self.enabled = on
            if on { self.retarget(force: true) } else { self.teardown() }
        }
    }

    /// The frontmost app changed (NSWorkspace notification).
    func frontmostChanged(pid: pid_t, bundleID: String?, name: String) {
        queue.async {
            let changed = pid != self.pid
            self.pid = pid
            self.bundleID = bundleID
            self.appName = name
            if changed { self.retarget(force: true) }
        }
    }

    fileprivate func noteNotification(_ name: String) {
        queue.async {
            let moved = name == (kAXWindowMovedNotification as String) || name == (kAXMovedNotification as String)
            self.schedule(after: moved ? 0.016 : 0.05)
            // A new window or sheet may not answer yet when its notification
            // arrives (the panel's remote content is still loading); look again
            // shortly after.
            let appeared = [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXFocusedWindowChangedNotification]
                .contains { $0 as String == name }
            if appeared {
                self.lastRejected = nil
                // Measured on macOS 27.2: the focused window can still be the
                // old one, or answer slowly, while a panel or sheet appears.
                for delay in [0.25, 0.6, 1.2] {
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.lastRejected = nil
                        self.schedule(after: 0)
                    }
                }
            }
        }
    }

    // MARK: Observer

    private func retarget(force: Bool) {
        teardownObserver()
        set(nil)
        lastRejected = nil
        guard enabled, pid > 0, pid != getpid(), AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, filesAXObserverCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for name in Self.appNotifications { _ = AXObserverAddNotification(created, app, name as CFString, nil) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        appElement = app
        schedule(after: 0.05)
    }

    private func teardownObserver() {
        stopLiveness()
        if let observer {
            if let observedDialog { for name in Self.dialogNotifications { AXObserverRemoveNotification(observer, observedDialog, name as CFString) } }
            if let appElement { for name in Self.appNotifications { AXObserverRemoveNotification(observer, appElement, name as CFString) } }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedDialog = nil
        appElement = nil
    }

    private func teardown() {
        teardownObserver()
        set(nil)
    }

    private func schedule(after delay: TimeInterval) {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { self.evaluate() }
    }

    // MARK: Evaluation

    private func evaluate() {
        scheduled = false
        guard enabled, let app = appElement else { set(nil); return }
        guard !jumping else { return }
        // Nothing is read while secure input is on (a password field is active).
        guard !IsSecureEventInputEnabled() else { set(nil); return }
        let focused = FilesAX.element(app, kAXFocusedWindowAttribute) ?? remotePanelWindow(app)
        guard let focused else { set(nil); return }
        if var current, CFEqual(current.element, focused) {
            if let frame = FilesAX.frame(focused), frame != current.frame {
                current.frame = frame
                set(current)
            }
            return
        }
        // The same ordinary window as last time: nothing to read again (apps
        // that send many focus notifications stay cheap), unless a remote
        // panel inside it has the focus.
        if current == nil, let lastRejected, CFEqual(lastRejected, focused) {
            if let remote = remotePanelWindow(app) { attachIfDialog(remote) }
            return
        }
        let snapshot = FilesAX.snapshot(focused, appPID: pid)
        // Go to Folder (opened by a jump) and sheets on the dialog keep it attached.
        if FilesDialogClassifier.isGoToSheet(snapshot) { return }
        if let classification = FilesDialogClassifier.classify(snapshot), let frame = snapshot.frame {
            lastRejected = nil
            set(FilesDialogState(pid: pid, bundleID: bundleID, appName: appName, element: focused,
                                 classification: classification, frame: frame))
            return
        }
        if let current, isInside(focused, current.element) { return }
        if let remote = remotePanelWindow(app), !CFEqual(remote, focused), attachIfDialog(remote) { return }
        lastRejected = focused
        set(nil)
    }

    @discardableResult
    private func attachIfDialog(_ window: AXUIElement) -> Bool {
        let snapshot = FilesAX.snapshot(window, appPID: pid)
        guard let classification = FilesDialogClassifier.classify(snapshot), let frame = snapshot.frame else { return false }
        lastRejected = nil
        set(FilesDialogState(pid: pid, bundleID: bundleID, appName: appName, element: window,
                             classification: classification, frame: frame))
        return true
    }

    /// The window of the focused element when that element lives in the
    /// open-and-save panel service (a remote panel).
    private func remotePanelWindow(_ app: AXUIElement) -> AXUIElement? {
        guard let focusedElement = FilesAX.element(app, kAXFocusedUIElementAttribute) else { return nil }
        let owner = FilesAX.pid(focusedElement)
        guard owner != pid, FilesAX.isPanelService(owner) else { return nil }
        return FilesAX.element(focusedElement, kAXWindowAttribute) ?? FilesAX.element(focusedElement, kAXTopLevelUIElementAttribute)
    }

    private func isInside(_ element: AXUIElement, _ dialog: AXUIElement) -> Bool {
        var cursor: AXUIElement? = element
        for _ in 0..<4 {
            guard let next = cursor.flatMap({ FilesAX.element($0, kAXParentAttribute) }) else { return false }
            if CFEqual(next, dialog) { return true }
            cursor = next
        }
        return false
    }

    private func set(_ state: FilesDialogState?) {
        let sameDialog = state?.isSameDialog(as: current) ?? (current == nil)
        let sameFrame = state?.frame == current?.frame
        if !sameDialog { observeDialog(state?.element) }
        current = state
        if state == nil { stopLiveness() } else if !sameDialog { startLiveness() }
        guard !(sameDialog && sameFrame) else { return }
        let publish = self.publish
        DispatchQueue.main.async { MainActor.assumeIsolated { publish?(state) } }
    }

    private func observeDialog(_ element: AXUIElement?) {
        guard let observer else { observedDialog = nil; return }
        if let observedDialog { for name in Self.dialogNotifications { AXObserverRemoveNotification(observer, observedDialog, name as CFString) } }
        observedDialog = element
        if let element { for name in Self.dialogNotifications { _ = AXObserverAddNotification(observer, element, name as CFString, nil) } }
    }

    /// A once-a-second check while attached, for apps that don't send every
    /// notification (the dialog closing above all).
    private func startLiveness() {
        stopLiveness()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.schedule(after: 0) }
        timer.resume()
        liveness = timer
    }

    private func stopLiveness() {
        liveness?.cancel()
        liveness = nil
    }

    // MARK: Jump

    /// Goes to `folder` in the attached dialog: ⌘⇧G, the path into Go to
    /// Folder's field through Accessibility (typed when that fails), Return,
    /// then checks that Go to Folder closed. Verified on macOS 27.2: the keys
    /// have to come through the session event tap (posting them to the app's
    /// process doesn't open Go to Folder), the sheet is "GoToWindow" and its
    /// field "PathTextField"; a folder that doesn't exist leaves the sheet open.
    func jump(to folder: URL, frontmostPID: @escaping @Sendable () -> pid_t?,
              completion: @escaping @MainActor (Result<URL, FilesJumpFailure>) -> Void) {
        queue.async {
            let result = self.performJump(to: folder, frontmostPID: frontmostPID)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    private func performJump(to folder: URL, frontmostPID: @escaping () -> pid_t?) -> Result<URL, FilesJumpFailure> {
        guard let dialog = current else { return .failure(.noDialog) }
        guard AXIsProcessTrusted() else { return .failure(.noAccessibility) }
        guard !IsSecureEventInputEnabled() else { return .failure(.secureInput) }
        guard FileManager.default.fileExists(atPath: folder.path) else { return .failure(.folderMissing) }
        jumping = true
        defer { jumping = false; schedule(after: 0.1) }
        let front = { frontmostPID() == dialog.pid }
        guard front() else { return .failure(.notFrontmost) }
        FilesKeys.post(CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
        guard let sheet = wait(1.5, { self.goToSheet(in: dialog) }) else { return .failure(.goToDidNotOpen) }
        guard let field = wait(1.0, { self.pathField(in: sheet) }) else {
            if front() { FilesKeys.post(CGKeyCode(kVK_Escape)) }
            return .failure(.fieldNotFound)
        }
        let path = folder.path
        var entered = FilesAX.setValue(field, kAXValueAttribute, path as CFString) && FilesAX.string(field, kAXValueAttribute) == path
        if !entered {
            guard front(), !IsSecureEventInputEnabled() else { return .failure(.notFrontmost) }
            FilesKeys.post(CGKeyCode(kVK_ANSI_A), flags: [.maskCommand])
            usleep(80_000)
            FilesKeys.type(path)
            entered = wait(1.0, { FilesAX.string(field, kAXValueAttribute) == path ? true : nil }) ?? false
        }
        guard entered else {
            if front() { FilesKeys.post(CGKeyCode(kVK_Escape)) }
            return .failure(.couldNotEnterPath)
        }
        usleep(120_000)
        guard front() else { return .failure(.notFrontmost) }
        FilesKeys.post(CGKeyCode(kVK_Return))
        let closed = wait(3.0, { self.goToSheet(in: dialog) == nil ? true : nil }) ?? false
        guard closed else {
            if front() { FilesKeys.post(CGKeyCode(kVK_Escape)) }
            return .failure(.notAccepted)
        }
        return .success(folder)
    }

    private func goToSheet(in dialog: FilesDialogState) -> AXUIElement? {
        if let app = appElement, let focused = FilesAX.element(app, kAXFocusedWindowAttribute),
           FilesAX.string(focused, kAXIdentifierAttribute) == FilesDialogClassifier.goToIdentifier { return focused }
        return FilesAX.first(below: dialog.element, maxDepth: 3, limit: 120) { role, identifier, _ in
            identifier == FilesDialogClassifier.goToIdentifier || (role == "AXSheet" && identifier == nil)
        }
    }

    private func pathField(in sheet: AXUIElement) -> AXUIElement? {
        FilesAX.first(below: sheet, maxDepth: 5, limit: 120) { role, identifier, _ in
            identifier == FilesDialogClassifier.pathFieldIdentifier || (identifier == nil && (role == "AXTextField" || role == "AXComboBox"))
        }
    }

    private func wait<T>(_ seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let value = probe() { return value }
            usleep(50_000)
        } while ProcessInfo.processInfo.systemUptime < end
        return probe()
    }
}

private func filesAXObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                     _ refcon: UnsafeMutableRawPointer?) {
    FilesDialogTracker.shared.noteNotification(notification as String)
}

/// Key events for Go to Folder: a private event source (a `.hidSystemState`
/// source carrying ⌘ or ⇧ can latch that modifier, ActionExecutor.textEvents),
/// tagged so AOM's own monitors skip them, posted through the session tap.
enum FilesKeys {
    static func post(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Types text one character at a time as Unicode key events.
    static func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            guard let (down, up) = ActionExecutor.textEvents(units) else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }
}
