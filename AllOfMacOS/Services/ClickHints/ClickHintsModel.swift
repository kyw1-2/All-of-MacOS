import AppKit
import ApplicationServices

// Shared value types of Click Hints. Frames are in Accessibility (Quartz)
// coordinates: global points, origin at the top-left of the primary display,
// y growing downwards.

/// What one Accessibility element reported, read in one batch request.
struct ClickHintsAttributes: Equatable {
    var role: String
    var subrole: String? = nil
    /// nil when the element has no position or size.
    var frame: CGRect? = nil
    /// nil when the element doesn't report AXEnabled (treated as enabled).
    var enabled: Bool? = nil
    var title: String? = nil
    /// AXDescription.
    var label: String? = nil
    var placeholder: String? = nil
    var help: String? = nil

    /// The words search mode matches, best first.
    var searchText: String {
        [title, label, placeholder, help]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Why an element gets a hint.
enum ClickHintsKind: Int, Equatable, Comparable {
    /// Buttons, links, checkboxes, pop-ups, tabs, sliders, menu bar and Dock items…
    case control = 0
    /// Text fields and text areas: acting focuses them.
    case text = 1
    /// A table or outline row (or a cell outside one) that can be selected.
    case row = 2
    /// Any other element that offers AXPress, AXConfirm or AXPick.
    case pressable = 3

    static func < (lhs: ClickHintsKind, rhs: ClickHintsKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a target comes from; window content gets the shortest labels.
enum ClickHintsTier: Int, Equatable, Comparable {
    case window = 0, menuBar = 1, dock = 2

    static func < (lhs: ClickHintsTier, rhs: ClickHintsTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One element that gets a hint. `element` is nil in tests.
struct ClickHintsTarget: @unchecked Sendable {
    var element: AXUIElement?
    var attributes: ClickHintsAttributes
    var kind: ClickHintsKind
    var tier: ClickHintsTier
    /// The element's frame.
    var frame: CGRect
    /// The part of the frame inside the window (or screen) that is visible:
    /// pills sit on its top-left corner and clicks land at its centre.
    var visibleFrame: CGRect
    /// The element's actions when they were read; nil when not read yet.
    var actions: [String]?
    /// Fixture node id (tests) or a running number.
    var id: Int

    var role: String { attributes.role }
    var clickPoint: CGPoint { CGPoint(x: visibleFrame.midX, y: visibleFrame.midY) }
}

/// What typing a complete label does.
enum ClickHintsClickKind: Equatable {
    /// The element's own action (AXPress…), focus for text, else a click.
    case press
    /// AXShowMenu or a right-click at the centre (⇧ or ⌃).
    case rightClick
    /// A ⌘-click at the centre (⌘): opens links in a new tab in browsers.
    case commandClick
    /// Moves the pointer to the centre without clicking (⌥).
    case movePointer

    /// ⌥ wins, then ⌘, then ⇧ or ⌃ (both mean a secondary click on macOS).
    init(modifiers: ClickHintsModifiers) {
        if modifiers.contains(.option) {
            self = .movePointer
        } else if modifiers.contains(.command) {
            self = .commandClick
        } else if modifiers.contains(.shift) || modifiers.contains(.control) {
            self = .rightClick
        } else {
            self = .press
        }
    }

    var title: String {
        switch self {
        case .press: return "Click"
        case .rightClick: return "Right-Click"
        case .commandClick: return "⌘-Click"
        case .movePointer: return "Move Pointer"
        }
    }
}

/// The modifier keys held with a hint key.
struct ClickHintsModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let shift = ClickHintsModifiers(rawValue: 1 << 0)
    static let control = ClickHintsModifiers(rawValue: 1 << 1)
    static let option = ClickHintsModifiers(rawValue: 1 << 2)
    static let command = ClickHintsModifiers(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: ClickHintsModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }
}

/// Accessibility names the collector and the performer use.
enum ClickHintsAX {
    static let press = kAXPressAction as String
    static let confirm = kAXConfirmAction as String
    static let pick = kAXPickAction as String
    static let showMenu = kAXShowMenuAction as String
    /// The element's own activation actions, in the order they are tried.
    static let activationActions = [press, confirm, pick]

    static let secureTextField = kAXSecureTextFieldSubrole as String
    static let dockItem = "AXDockItem"
    static let separatorDockItem = "AXSeparatorDockItem"
}
