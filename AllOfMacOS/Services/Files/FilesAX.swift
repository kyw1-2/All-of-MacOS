import AppKit
import ApplicationServices
import Darwin

/// Accessibility reads for the dialog helper. Every call sets a short
/// messaging timeout on the element it asks (never on the system-wide
/// element), so a hung app costs at most that long. Call these off the main
/// thread.
enum FilesAX {
    static let timeout: Float = 0.25

    static func value(_ element: AXUIElement, _ attribute: String, timeout: Float = timeout) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Role, subrole, identifier, title, role description and children in one
    /// round trip.
    static func basics(_ element: AXUIElement) -> (role: String?, subrole: String?, identifier: String?,
                                                    title: String?, roleDescription: String?, children: [AXUIElement]) {
        AXUIElementSetMessagingTimeout(element, timeout)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
                     kAXRoleDescriptionAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [Any], list.count == 6 else {
            return (nil, nil, nil, nil, nil, [])
        }
        func text(_ index: Int) -> String? { list[index] as? String }
        return (text(0), text(1), text(2), text(3), text(4), list[5] as? [AXUIElement] ?? [])
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func pid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    static func setValue(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Breadth-first search below `root`, at most `limit` elements and
    /// `maxDepth` levels, skipping the inside of lists and tables (file rows).
    static func first(below root: AXUIElement, maxDepth: Int = 6, limit: Int = 400,
                      where test: (_ role: String?, _ identifier: String?, AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < limit {
            let (element, depth) = queue[index]
            index += 1
            let info = basics(element)
            if depth > 0, test(info.role, info.identifier, element) { return element }
            guard depth < maxDepth, !skipsChildren(info.role) else { continue }
            queue.append(contentsOf: info.children.prefix(80).map { ($0, depth + 1) })
        }
        return nil
    }

    static func skipsChildren(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXRow", "AXColumn", "AXWebArea", "AXTextArea"].contains(role)
    }

    // MARK: Processes

    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var panelServicePIDs: [pid_t: Bool] = [:]

    /// True for the open-and-save panel service (XPC services are not
    /// NSRunningApplications, so this reads the executable path).
    static func isPanelService(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        pathLock.lock()
        if let cached = panelServicePIDs[pid] { pathLock.unlock(); return cached }
        pathLock.unlock()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        let result = path.contains(FilesDialogClassifier.panelServiceBundleID)
        pathLock.lock()
        if panelServicePIDs.count > 64 { panelServicePIDs.removeAll() }
        panelServicePIDs[pid] = result
        pathLock.unlock()
        return result
    }

    // MARK: Snapshots

    /// The classifier's view of a window: its own attributes plus a bounded
    /// walk for control identifiers, button titles and remote content.
    static func snapshot(_ window: AXUIElement, appPID: pid_t) -> FilesDialogSnapshot {
        let info = basics(window)
        var snapshot = FilesDialogSnapshot(role: info.role, subrole: info.subrole, identifier: info.identifier,
                                           title: info.title, roleDescription: info.roleDescription)
        let owner = pid(window)
        snapshot.ownedByPanelService = owner != appPID && isPanelService(owner)
        snapshot.frame = frame(window)
        // Panels AppKit names need no walk. Only sheets, dialog windows and
        // remote panels get a short one: document windows (often huge web
        // views in Electron apps) are never walked.
        guard info.identifier != FilesDialogClassifier.openIdentifier,
              info.identifier != FilesDialogClassifier.saveIdentifier,
              info.identifier != FilesDialogClassifier.goToIdentifier else { return snapshot }
        let dialogLike = info.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(info.subrole ?? "")
            || snapshot.ownedByPanelService
        guard dialogLike else { return snapshot }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var queue: [(AXUIElement, Int)] = info.children.prefix(60).map { ($0, 1) }
        var index = 0
        while index < queue.count, index < 220, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]
            index += 1
            let child = basics(element)
            if let identifier = child.identifier, !identifier.isEmpty { snapshot.descendantIdentifiers.insert(identifier) }
            if child.role == "AXButton", let title = child.title, !title.isEmpty { snapshot.buttonTitles.insert(title) }
            let childPID = pid(element)
            if childPID != appPID, isPanelService(childPID) { snapshot.containsPanelServiceContent = true }
            guard depth < 4, !skipsChildren(child.role) else { continue }
            queue.append(contentsOf: child.children.prefix(40).map { ($0, depth + 1) })
        }
        return snapshot
    }
}
