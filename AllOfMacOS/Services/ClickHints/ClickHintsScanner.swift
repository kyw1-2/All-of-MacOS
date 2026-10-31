import AppKit
import ApplicationServices

/// Reads another app's Accessibility tree for the collector: one batch
/// request per element (`AXUIElementCopyMultipleAttributeValues`), every
/// request bounded by `AXUIElementSetMessagingTimeout` and the walk's time
/// budget. Runs on a background queue, never on the main thread.
final class ClickHintsLiveReader: ClickHintsTreeReader {
    typealias Node = AXUIElement

    private let deadline: AXDeadline
    /// Requests sent, for the scan summary.
    private(set) var requests = 0
    /// Children lists are capped so one huge container can't eat the budget.
    let maxChildren: Int

    init(budget: TimeInterval, perRequest: Float = 0.1, maxChildren: Int = 1_500) {
        deadline = AXDeadline(perRequest: perRequest, budget: budget)
        self.maxChildren = maxChildren
    }

    static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute
    ]

    var isExhausted: Bool { deadline.isSpent }

    func attributes(of element: AXUIElement) -> ClickHintsAttributes? {
        guard deadline.allow(element) else { return nil }
        requests += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == Self.attributeNames.count else { return nil }
        return Self.parse(list)
    }

    /// Turns one batch answer into attributes. Missing values come back as
    /// an AXValue of the error type or CFNull.
    static func parse(_ list: [AnyObject]) -> ClickHintsAttributes? {
        guard let role = string(list[0]) else { return nil }
        var attributes = ClickHintsAttributes(role: role)
        attributes.subrole = string(list[1])
        if let origin = point(list[2]), let size = size(list[3]) {
            attributes.frame = CGRect(origin: origin, size: size)
        }
        attributes.enabled = bool(list[4])
        attributes.title = string(list[5])
        attributes.label = string(list[6])
        attributes.placeholder = string(list[7])
        attributes.help = string(list[8])
        return attributes
    }

    func children(of element: AXUIElement, role: String) -> [AXUIElement] {
        switch role {
        case kAXTableRole, kAXOutlineRole:
            // Only the rows on screen (a library may hold 10,000), plus the
            // column header with its sort buttons.
            if let rows = elements(element, kAXVisibleRowsAttribute) {
                var result = rows
                if let header = single(element, kAXHeaderAttribute) { result.insert(header, at: 0) }
                return Array(result.prefix(maxChildren))
            }
        case kAXListRole, kAXBrowserRole, kAXGridRole:
            if let visible = elements(element, kAXVisibleChildrenAttribute), !visible.isEmpty {
                return Array(visible.prefix(maxChildren))
            }
        default:
            break
        }
        return Array((elements(element, kAXChildrenAttribute) ?? []).prefix(maxChildren))
    }

    func actions(of element: AXUIElement) -> [String] {
        guard deadline.allow(element) else { return [] }
        requests += 1
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func isValueSettable(_ element: AXUIElement) -> Bool {
        guard deadline.allow(element) else { return false }
        requests += 1
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func element(of node: AXUIElement) -> AXUIElement? { node }
    func identifier(of node: AXUIElement, index: Int) -> Int { index }

    // MARK: Values

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard deadline.allow(element) else { return nil }
        requests += 1
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return (value as? [AnyObject])?.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    private func single(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard deadline.allow(element) else { return nil }
        requests += 1
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ value: AnyObject?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    static func bool(_ value: AnyObject?) -> Bool? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        guard type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

/// One read of the front app for hint mode: the focused window, and
/// optionally the app's menu bar and the Dock.
enum ClickHintsScanner {
    struct Request {
        var pid: pid_t
        var includesMenuBar = false
        var includesDock = false
        /// Ask a Chromium or Electron app to build its accessibility tree first.
        var enhancedAccessibility = false
        /// Display frames in Accessibility coordinates.
        var screens: [CGRect]
        /// The pointer in Accessibility coordinates.
        var pointer: CGPoint
        /// About half a second for the window, a little more for the extras.
        var windowBudget: TimeInterval = 0.5
        var extrasBudget: TimeInterval = 0.15
    }

    enum Failure: Equatable {
        /// The app shows no window (and no extras were asked for).
        case noWindow
        /// The app didn't answer in time.
        case notResponding
    }

    struct Result {
        /// In rank order: the first gets the shortest label.
        var targets: [ClickHintsTarget]
        var windowFrame: CGRect?
        var truncated = false
        var visited = 0
        var elapsed: TimeInterval = 0
        var failure: Failure?
        /// Puts AXEnhancedUserInterface back when hint mode ends.
        var restore: (() -> Void)?
    }

    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let dockBundleID = "com.apple.dock"
    /// More hints than this would need four-letter labels and help no one.
    static let maxTargets = 1_000

    /// Reads the app (call off the main thread).
    static func scan(_ request: Request, dockPID: pid_t?) -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var restore: (() -> Void)?
        if request.enhancedAccessibility {
            restore = enableAccessibility(app)
        }

        var targets: [ClickHintsTarget] = []
        var windowFrame: CGRect?
        var truncated = false
        var visited = 0
        var appAnswered = false

        if let window = focusedWindow(of: app) {
            appAnswered = true
            let reader = ClickHintsLiveReader(budget: request.windowBudget)
            if let frame = reader.attributes(of: window)?.frame, ClickHintsCollector.isUsable(frame) {
                windowFrame = frame
                let collection = ClickHintsCollector.collect(root: window, reader: reader, window: frame,
                                                             screens: request.screens, tier: .window)
                targets += collection.targets
                truncated = collection.truncated
                visited += collection.visited
            }
        }

        let everywhere = request.screens.reduce(CGRect.null) { $0.union($1) }
        if request.includesMenuBar, !everywhere.isNull, let menuBar = element(app, kAXMenuBarAttribute) {
            appAnswered = true
            let reader = ClickHintsLiveReader(budget: request.extrasBudget)
            let collection = ClickHintsCollector.collect(root: menuBar, reader: reader, window: everywhere,
                                                         screens: request.screens, tier: .menuBar)
            targets += collection.targets
            visited += collection.visited
        }
        if request.includesDock, !everywhere.isNull, let dockPID {
            let dock = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(dock, 0.15)
            let reader = ClickHintsLiveReader(budget: request.extrasBudget)
            let collection = ClickHintsCollector.collect(root: dock, reader: reader, window: everywhere,
                                                         screens: request.screens, tier: .dock)
            targets += collection.targets
            visited += collection.visited
        }

        // Ids stay unique across the window, the menu bar and the Dock.
        for index in targets.indices { targets[index].id = index }
        let reference = windowFrame.map { $0.contains(request.pointer) ? request.pointer : $0.origin } ?? request.pointer
        var order = ClickHintsCollector.rank(targets, reference: reference)
        if order.count > maxTargets {
            // The most likely thousand; labels stay at three letters at most.
            order = Array(order.prefix(maxTargets))
            truncated = true
        }
        var result = Result(targets: order.map { targets[$0] }, windowFrame: windowFrame, truncated: truncated,
                            visited: visited, elapsed: ProcessInfo.processInfo.systemUptime - started, restore: restore)
        if targets.isEmpty, windowFrame == nil {
            result.failure = appAnswered || answers(app) ? .noWindow : .notResponding
        }
        return result
    }

    /// The window hints cover: the focused window, else the main window,
    /// else the first window.
    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        if let window = element(app, kAXFocusedWindowAttribute) { return window }
        if let window = element(app, kAXMainWindowAttribute) { return window }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AnyObject], let first = windows.first,
              CFGetTypeID(first) == AXUIElementGetTypeID() else { return nil }
        return (first as! AXUIElement)
    }

    /// Whether the app answers Accessibility at all (its role).
    static func answers(_ app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value) == .success
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Electron apps build their tree when AXManualAccessibility is set
    /// (no side effects; it stays on, as Vimac does). Chromium apps that
    /// don't support it get AXEnhancedUserInterface, VoiceOver's flag, which
    /// can slow their window moves, so it is set only while hints are shown
    /// and put back afterwards (AOM's window moves already suspend it).
    static func enableAccessibility(_ app: AXUIElement) -> (() -> Void)? {
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, manualAccessibility as CFString, &current) == .success,
           (current as? Bool) == true {
            return nil
        }
        if AXUIElementSetAttributeValue(app, manualAccessibility as CFString, kCFBooleanTrue) == .success {
            // The tree is built on demand; give it a moment.
            usleep(120_000)
            return nil
        }
        var enhanced: CFTypeRef?
        let readable = AXUIElementCopyAttributeValue(app, enhancedUserInterface as CFString, &enhanced) == .success
        if readable, (enhanced as? Bool) == true { return nil }
        guard AXUIElementSetAttributeValue(app, enhancedUserInterface as CFString, kCFBooleanTrue) == .success else {
            return nil
        }
        usleep(250_000)
        let element = app
        return { _ = AXUIElementSetAttributeValue(element, enhancedUserInterface as CFString, kCFBooleanFalse) }
    }
}
