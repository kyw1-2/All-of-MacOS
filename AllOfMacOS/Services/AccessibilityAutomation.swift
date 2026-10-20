import AppKit
import ApplicationServices

struct AccessibilityElementSelector {
    var title: String
    var identifier: String
    var role: String
    func matches(title actualTitle: String, identifier actualID: String, role actualRole: String) -> Bool {
        (!title.isEmpty || !identifier.isEmpty) && (title.isEmpty || title == actualTitle) &&
            (identifier.isEmpty || identifier == actualID) && (role.isEmpty || role == actualRole)
    }
}

enum AccessibilityAutomation {
    static func perform(_ action: TriggerAction, isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void) {
        let p = action.parameters
        let target = p.targetApplicationBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? (p.targetApplicationBundleID?.isEmpty != false ? NSWorkspace.shared.frontmostApplication : nil)
        guard let target, !target.isTerminated, AXIsProcessTrusted() else { completion(false); return }
        let selector = AccessibilityElementSelector(title: p.uiElementTitle ?? "", identifier: p.uiElementIdentifier ?? "", role: p.uiElementRole ?? "")
        guard !selector.title.isEmpty || !selector.identifier.isEmpty else { completion(false); return }
        let pid = target.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var queue: [(AXUIElement, Int)] = [(app, 0)]
            var offset = 0
            var found: AXUIElement?
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            func string(_ element: AXUIElement, _ key: CFString) -> String {
                var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, key, &value)
                return value as? String ?? ""
            }
            while offset < queue.count, offset < 2_000, ProcessInfo.processInfo.systemUptime < deadline {
                let (element, depth) = queue[offset]; offset += 1
                if selector.matches(title: string(element, kAXTitleAttribute as CFString),
                                    identifier: string(element, kAXIdentifierAttribute as CFString),
                                    role: string(element, kAXRoleAttribute as CFString)) { found = element; break }
                guard depth < 12 else { continue }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let elements = children as? [AXUIElement] {
                    queue.append(contentsOf: elements.prefix(max(0, 2_000 - queue.count)).map { ($0, depth + 1) })
                }
            }
            DispatchQueue.main.async {
                guard !isCancelled(), !target.isTerminated, let found else { completion(false); return }
                let succeeded: Bool
                if action.actionType == .setAccessibilityValue {
                    succeeded = AXUIElementSetAttributeValue(found, kAXValueAttribute as CFString, (p.uiElementValue ?? "") as CFString) == .success
                } else { succeeded = AXUIElementPerformAction(found, kAXPressAction as CFString) == .success }
                completion(succeeded)
            }
        }
    }

    static func sendShortcut(_ p: ActionParameters) -> Bool {
        guard let bundle = p.targetApplicationBundleID, !bundle.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              !app.isTerminated, let code = p.shortcutKeyCode, AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        let flags = ClickPlan.flags(from: p.shortcutModifiers)
        down.flags = flags; up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        return true
    }
}
