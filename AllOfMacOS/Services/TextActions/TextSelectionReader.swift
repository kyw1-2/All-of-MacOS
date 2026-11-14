import AppKit
import ApplicationServices

/// A focused element in another app, kept to act on its selection later.
/// AXUIElement is a CF object, and Accessibility calls on it may come from
/// any thread.
final class TextSelectionElement: @unchecked Sendable, Equatable {
    static func == (lhs: TextSelectionElement, rhs: TextSelectionElement) -> Bool { lhs.isSame(as: rhs) }
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
    var selectedText: String? = nil
    var bounds: CGRect? = nil
    var isTextTarget = false
    var isVerifiedContext = false
    var isBlocked = false
    var role: String? = nil
}

/// Filled on the reader's queue at mouse down and read there at mouse up;
/// the queue is serial, so the mouse-down read always finishes first.
final class TextSelectionAnchorBox: @unchecked Sendable {
    var pid: pid_t = 0
    var anchor: TextSelectionAnchor?
    var focusedAnchor: TextSelectionAnchor?
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

    /// Selection in browser-backed UIs is often exposed by the element under
    /// the mouse or by an AXWebArea ancestor, not by AXFocusedUIElement.
    /// A native selection bubble can even move focus to one of its buttons.
    /// Keep every AX operation on the reader queue and bound the parent walk.
    static let maxSelectionAncestors = 32
    typealias Read = (attributes: TextSelectionAttributes, element: TextSelectionElement)

    /// This is the actual AX walk, parameterized so nested web lists, media
    /// wrappers, cycles and exhausted budgets can be tested without other apps.
    static func probe<Node: Equatable>(start: Node, metadata: (Node) -> TextSelectionAttributes,
                                       selection: (Node, TextSelectionAttributes) -> TextSelectionAttributes,
                                       parent: (Node) -> Node?, expired: () -> Bool = { false })
        -> (attributes: TextSelectionAttributes, node: Node) {
        var current: Node? = start
        var visited: [Node] = []
        var first: (attributes: TextSelectionAttributes, node: Node)?
        var selected: (attributes: TextSelectionAttributes, node: Node)?
        var collection: (attributes: TextSelectionAttributes, node: Node)?
        var nonText: (attributes: TextSelectionAttributes, node: Node)?
        var textTarget = false
        var textEditor = false
        var document = false
        for _ in 0..<maxSelectionAncestors {
            guard let node = current else { break }
            guard !expired(), !visited.contains(node) else {
                return (TextSelectionAttributes(isBlocked: true), start)
            }
            visited.append(node)
            var attributes = metadata(node)
            let role = attributes.role ?? ""
            let isCollection = TextActionsGate.collectionRoles.contains(role)
            // Password/media metadata is evaluated BEFORE asking for text.
            if attributes.isBlocked || TextActionsGate.isPasswordField(role: attributes.role, subrole: attributes.subrole) ||
                TextActionsGate.mediaRoles.contains(role) {
                attributes.isBlocked = true
                return (attributes, node)
            }
            if !isCollection && TextActionsGate.fileListRoles.contains(role), nonText == nil {
                nonText = (attributes, node)
            }
            if visited.count == 1 { textTarget = TextActionsGate.textRoles.contains(role) }
            textEditor = textEditor || role == "AXTextField" || role == "AXTextArea"
            document = document || role == "AXWebArea" ||
                TextActionsGate.contentListSubroles.contains(attributes.subrole ?? "")
            if selected == nil && nonText == nil { attributes = selection(node, attributes) }
            if first == nil { first = (attributes, node) }
            if isCollection, collection == nil { collection = (attributes, node) }
            if selected == nil, let text = attributes.selectedText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selected = (attributes, node)
            }
            // Continue past the selection to check secure/media ancestors.
            if role == "AXApplication" || role == "AXWindow" { current = nil; break }
            current = parent(node)
        }
        guard current == nil, !expired() else { return (TextSelectionAttributes(isBlocked: true), start) }
        if var nonText {
            nonText.attributes.isBlocked = true
            nonText.attributes.isVerifiedContext = true
            return nonText
        }
        // Collection roles alone mean neither files nor text. A real text
        // selection or web-document context distinguishes content collections.
        if var collection, selected == nil && !document && !textEditor {
            collection.attributes.isBlocked = true
            collection.attributes.isVerifiedContext = true
            return collection
        }
        var result = selected ?? first ?? (TextSelectionAttributes(), start)
        result.attributes.isTextTarget = textTarget
        result.attributes.isVerifiedContext = true
        return result
    }

    private static func selectedTextInAncestors(of start: AXUIElement, timeout: Float) -> Read {
        let deadline = ProcessInfo.processInfo.systemUptime + (timeout == anchorTimeout ? 0.35 : 0.8)
        let result = probe(start: TextSelectionElement(start), metadata: {
            readMetadata(of: $0.element, timeout: timeout)
        }, selection: { readAttributes(of: $0.element, metadata: $1) }, parent: {
            element($0.element, kAXParentAttribute).map(TextSelectionElement.init)
        }, expired: { ProcessInfo.processInfo.systemUptime >= deadline })
        return (result.attributes, result.node)
    }

    private static func readMetadata(of node: AXUIElement, timeout: Float) -> TextSelectionAttributes {
        AXUIElementSetMessagingTimeout(node, timeout)
        var attributes = TextSelectionAttributes()
        attributes.role = string(node, kAXRoleAttribute)
        attributes.subrole = string(node, kAXSubroleAttribute)
        guard attributes.role != nil else {
            attributes.isBlocked = true
            return attributes
        }
        if TextActionsGate.isPasswordField(role: attributes.role, subrole: attributes.subrole) {
            attributes.isBlocked = true
            return attributes
        }
        var classesValue: CFTypeRef?
        let classes: [String] = AXUIElementCopyAttributeValue(node, "AXDOMClassList" as CFString, &classesValue) == .success
            ? (classesValue as? [String] ?? []) : []
        if TextActionsGate.isMediaSurface(role: attributes.role,
            identifier: string(node, "AXDOMIdentifier") ?? string(node, kAXIdentifierAttribute),
            htmlTag: string(node, "AXHTMLTag"), domClasses: classes) {
            attributes.role = "AXVideo"
            attributes.isBlocked = true
        }
        return attributes
    }

    static func readAttributes(pid: pid_t, pointer: CGPoint? = nil, primaryHeight: CGFloat = 0,
                               timeout: Float = readTimeout, dragAnchor: TextSelectionAnchor? = nil) -> Read? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let focused = element(app, kAXFocusedUIElementAttribute)
        // Includes the focused node itself, including Chromium media metadata.
        let initial = focused.map { node -> Read in
            var result = selectedTextInAncestors(of: node, timeout: timeout)
            // Focus alone never proves that a click landed on this text.
            result.attributes.isTextTarget = false
            return result
        }
        if let initial, TextActionsGate.isPasswordField(role: initial.attributes.role, subrole: initial.attributes.subrole) ||
            TextActionsGate.mediaRoles.contains(initial.attributes.role ?? "") { return initial }

        if let pointer, primaryHeight > 0, pointer.x.isFinite, pointer.y.isFinite {
            var underPointer: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(pointer.x), Float(primaryHeight - pointer.y),
                                                &underPointer) == .success, let underPointer {
                let hit = selectedTextInAncestors(of: underPointer, timeout: timeout)
                // A verified selecting drag may finish just over an adjacent
                // image/list. Passwords, media and incomplete walks still win.
                if TextActionsGate.isBlocked(hit.attributes) {
                    if hit.attributes.isVerifiedContext, let initial, let dragAnchor,
                       TextActionsGate.mayUseFocusedDragSelection(initial.attributes,
                        sameElement: dragAnchor.element.isSame(as: initial.element),
                        initialText: dragAnchor.selectedText, initialRange: dragAnchor.range,
                        initialBounds: dragAnchor.bounds,
                        startedOnText: dragAnchor.isTextTarget && dragAnchor.isVerifiedContext && !dragAnchor.isBlocked,
                        endpointRole: hit.attributes.role) { return initial }
                    return hit
                }
                if TextActionsGate.check(hit.attributes) == nil { return hit }
                if let initial, TextActionsGate.check(initial.attributes) == nil { return initial }
                return hit
            }
        }
        return initial
    }

    /// The focused element's role, its selection and where it is. A password
    /// field stops the read after its role: not even its selection length is asked.
    private static func readAttributes(of focused: AXUIElement, metadata: TextSelectionAttributes) -> TextSelectionAttributes {
        var attributes = metadata

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) {
        case .success: attributes.selectedText = (value as? String) ?? ""
        case .noValue: attributes.selectedText = ""
        default: attributes.selectedText = nil
        }
        guard let text = attributes.selectedText, !text.isEmpty else { return attributes }

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
        return attributes
    }

    /// Use the same pointer/ancestor resolution for both ends of the gesture.
    static func readAnchor(pid: pid_t, pointer: CGPoint? = nil, primaryHeight: CGFloat = 0) -> TextSelectionAnchor? {
        guard let read = readAttributes(pid: pid, pointer: pointer, primaryHeight: primaryHeight, timeout: anchorTimeout) else { return nil }
        // A timed-out/cyclic first snapshot supplies no baseline. It must not
        // veto a later, fully verified text hit, unlike an actual secure target.
        if read.attributes.isBlocked && read.attributes.role == nil { return nil }
        return TextSelectionAnchor(element: read.element, range: read.attributes.range,
            selectedText: read.attributes.selectedText, bounds: read.attributes.bounds,
            isTextTarget: read.attributes.isTextTarget, isVerifiedContext: read.attributes.isVerifiedContext,
            isBlocked: TextActionsGate.isBlocked(read.attributes), role: read.attributes.role)
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
