import AppKit
import ApplicationServices

/// A focused element in another app, kept to act on its selection later.
/// AXUIElement is a CF object, and Accessibility calls on it may come from
/// any thread.
final class TextSelectionElement: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }

    func isSame(as other: TextSelectionElement?) -> Bool {
        guard let other else { return false }
        return CFEqual(element, other.element)
    }
}

/// The selection the bar acts on.
struct TextSelection {
    enum Source: Equatable { case accessibility, copy }

    var text: String
    var traits: TextSelectionTraits
    var attributes: TextSelectionAttributes
    var element: TextSelectionElement?
    var pid: pid_t
    var bundleID: String?
    var appName: String?
    var source: Source

    var editability: TextEditability {
        switch source {
        case .copy: return .unknown
        case .accessibility: return attributes.isSettable ? .editable : .readOnly
        }
    }
}

/// What the focused element held at mouse down, so a drag that changed
/// nothing (a window, a scroll bar, a slider) is told from a selecting drag.
struct TextSelectionAnchor {
    var element: TextSelectionElement
    var range: TextSelectionRange?
}

/// Filled on the reader's queue at mouse down and read there at mouse up;
/// the queue is serial, so the mouse-down read always finishes first.
final class TextSelectionAnchorBox: @unchecked Sendable {
    var pid: pid_t = 0
    var anchor: TextSelectionAnchor?
}

/// Accessibility reads of another app's focused element. Every call runs on
/// `queue`, never on the main thread, and every element asked gets a
/// messaging timeout. The system-wide element never gets one: that would
/// change the timeout of every Accessibility call AOM makes (AXUIElement.h).
enum TextSelectionReader {
    static let queue = DispatchQueue(label: "com.kyw.allofmacos.text-actions.accessibility", qos: .userInitiated)
    static let readTimeout: Float = 0.25
    static let anchorTimeout: Float = 0.1
    static let writeTimeout: Float = 0.5
    /// Bounds are asked only for selections up to this long (UTF-16 units).
    static let boundsLimit = 5_000

    static func focusedElement(pid: pid_t, timeout: Float) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)
        return focused
    }

    /// Selection in browser-backed UIs is often exposed by the element under
    /// the mouse or by an AXWebArea ancestor, not by AXFocusedUIElement.
    /// A native selection bubble can even move focus to one of its buttons.
    /// Keep every AX operation on the reader queue and bound the parent walk.
    static let maxSelectionAncestors = 9

    static func readAttributes(pid: pid_t, pointer: CGPoint? = nil, primaryHeight: CGFloat = 0,
                               timeout: Float = readTimeout) -> (attributes: TextSelectionAttributes, element: TextSelectionElement)? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let focused = element(app, kAXFocusedUIElementAttribute)
        let initial = focused.map { readAttributes(of: $0, timeout: timeout) }
        // Password-field protections precede all alternate probes, including
        // hit-testing, so no fallback reads another element instead.
        if let initial, TextActionsGate.isPasswordField(role: initial.attributes.role, subrole: initial.attributes.subrole) {
            return initial
        }
        if let initial, TextActionsGate.check(initial.attributes) == nil { return initial }

        // The release point is captured before ChatGPT/Chromium adds its own
        // selection toolbar. Probe that precise location instead of the current
        // pointer, which may already have moved to the native toolbar.
        if let pointer, primaryHeight > 0,
           pointer.x.isFinite, pointer.y.isFinite {
            var underPointer: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(pointer.x), Float(primaryHeight - pointer.y),
                                                &underPointer) == .success,
               let underPointer,
               let found = selectedTextInAncestors(of: underPointer, timeout: timeout) {
                return found
            }
        }
        // Some editors expose the selected text on their web-area parent even
        // when the focused child is just a button or an unfocused text node.
        if let focused, let found = selectedTextInAncestors(of: focused, timeout: timeout, skipFirst: true) {
            return found
        }
        return initial
    }

    /// A private, bounded ancestor search. It stops at a password field or a
    /// file-list container and never walks into unrelated AX sibling trees.
    private static func selectedTextInAncestors(of start: AXUIElement, timeout: Float,
                                                 skipFirst: Bool = false) -> (attributes: TextSelectionAttributes, element: TextSelectionElement)? {
        var current: AXUIElement? = skipFirst ? element(start, kAXParentAttribute) : start
        var visited: [AXUIElement] = []
        var selection: (attributes: TextSelectionAttributes, element: TextSelectionElement)?
        for _ in 0..<maxSelectionAncestors {
            guard let node = current, !visited.contains(where: { CFEqual($0, node) }) else { break }
            visited.append(node)
            AXUIElementSetMessagingTimeout(node, timeout)
            let role = string(node, kAXRoleAttribute)
            let subrole = string(node, kAXSubroleAttribute)
            if TextActionsGate.isPasswordField(role: role, subrole: subrole) { return nil }
            // Do not interpret a selected filename as editable text.
            if let role, TextActionsGate.fileListRoles.contains(role) { return nil }
            // Read selection only when needed; range/bounds queries on every
            // ancestor of a large browser tree would be very expensive.
            if let text = string(node, kAXSelectedTextAttribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selection == nil {
                selection = readAttributes(of: node, timeout: timeout)
            }
            if role == "AXApplication" || role == "AXWindow" { break }
            current = element(node, kAXParentAttribute)
        }
        return selection
    }

    /// The focused element's role, its selection and where it is. A password
    /// field stops the read after its role: not even its selection length is asked.
    private static func readAttributes(of focused: AXUIElement, timeout: Float) -> (attributes: TextSelectionAttributes, element: TextSelectionElement) {
        AXUIElementSetMessagingTimeout(focused, timeout)
        var attributes = TextSelectionAttributes()
        attributes.role = string(focused, kAXRoleAttribute)
        attributes.subrole = string(focused, kAXSubroleAttribute)
        let handle = TextSelectionElement(focused)
        if TextActionsGate.isPasswordField(role: attributes.role, subrole: attributes.subrole) { return (attributes, handle) }

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) {
        case .success: attributes.selectedText = (value as? String) ?? ""
        case .noValue: attributes.selectedText = ""
        default: attributes.selectedText = nil
        }
        guard let text = attributes.selectedText, !text.isEmpty else { return (attributes, handle) }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success {
            attributes.isSettable = settable.boolValue
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let rangeValue = rangeRef as! AXValue
            var range = CFRange()
            if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) {
                attributes.range = TextSelectionRange(location: range.location, length: range.length)
                if range.length > 0, range.length <= boundsLimit {
                    attributes.bounds = rect(parameterized: focused, kAXBoundsForRangeParameterizedAttribute, rangeValue)
                }
            }
        }
        // WebKit and Chromium answer with text markers instead of a range.
        if attributes.bounds == nil {
            var markers: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, "AXSelectedTextMarkerRange" as CFString, &markers) == .success, let markers {
                attributes.bounds = rect(parameterized: focused, "AXBoundsForTextMarkerRange", markers)
            }
        }
        return (attributes, handle)
    }

    /// The focused element and its selected range at mouse down. A password
    /// field gives nothing.
    static func readAnchor(pid: pid_t) -> TextSelectionAnchor? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let focused = focusedElement(pid: pid, timeout: anchorTimeout) else { return nil }
        guard !TextActionsGate.isPasswordField(role: string(focused, kAXRoleAttribute),
                                               subrole: string(focused, kAXSubroleAttribute)) else { return nil }
        var anchor = TextSelectionAnchor(element: TextSelectionElement(focused), range: nil)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                anchor.range = TextSelectionRange(location: range.location, length: range.length)
            }
        }
        return anchor
    }

    /// Replaces the selected text through Accessibility. True only when the
    /// app took it: some apps report success and change nothing, so the
    /// selection is read back.
    static func setSelectedText(_ text: String, in handle: TextSelectionElement, replacing original: String) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        AXUIElementSetMessagingTimeout(handle.element, writeTimeout)
        guard AXUIElementSetAttributeValue(handle.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        guard text != original else { return true }
        // Still selected and unchanged: the app ignored the write.
        return string(handle.element, kAXSelectedTextAttribute) != original
    }

    // MARK: Helpers

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func rect(parameterized element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.height > 0 else { return nil }
        return rect
    }
}
