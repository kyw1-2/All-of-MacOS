import ApplicationServices
import Foundation

/// A selected range in the focused element, in UTF-16 units.
struct TextSelectionRange: Equatable {
    var location: Int
    var length: Int
}

/// What Accessibility said about the focused element, as plain values, so
/// the privacy rules are tested without a real app.
struct TextSelectionAttributes: Equatable {
    var role: String?
    var subrole: String?
    /// The selected text; "" when the element has no selection, nil when it
    /// does not share its selection at all (or did not answer in time).
    var selectedText: String?
    /// Accessibility can replace the selected text.
    var isSettable = false
    var range: TextSelectionRange?
    /// Accessibility coordinates: top-left origin of the main display.
    var bounds: CGRect?
}

/// The state of the Mac when a selection ends, as plain values.
struct TextActionsEnvironment: Equatable {
    var isTrusted = true
    /// AOM's master switch (menu bar Automation).
    var automationOn = true
    /// Pause AOM (timed, indefinite, or for the front app).
    var paused = false
    /// Secure keyboard entry: a password field or a terminal in secure mode has the keyboard.
    var secureInput = false
    var screenLocked = false
    var bundleID: String?
}

/// Why the bar does not appear.
enum TextActionsBlock: Equatable, CustomStringConvertible {
    case switchedOff, noAccessibility, paused, secureInput, screenLocked, excludedApp, ownApp, passwordField
    case noSelection, notText

    var description: String {
        switch self {
        case .switchedOff: return "Text Actions is off"
        case .noAccessibility: return "All of MacOS needs Accessibility to read the selection"
        case .paused: return "AOM is paused"
        case .secureInput: return "Secure keyboard entry is on"
        case .screenLocked: return "The screen is locked"
        case .excludedApp: return "Text Actions is off in this app"
        case .ownApp: return "The selection is in All of MacOS"
        case .passwordField: return "The selection is in a password field"
        case .noSelection: return "No text is selected"
        case .notText: return "The selection is not text"
        }
    }
}

/// The privacy rules, in the order they are taken: before anything is read,
/// then on what Accessibility returned, then before ⌘C is pressed.
enum TextActionsGate {
    static let ownBundleIDs: Set<String> = ["com.kyw.allofmacos", "com.kyw.allofmacos.preview"]
    /// File views: a drag there selects files, and ⌘C would copy files.
    static let fileListRoles: Set<String> = ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXImage"]
    /// ChatGPT desktop is Chromium-backed and its native "Ask ChatGPT"
    /// bubble may take AX focus away from the selected response. A bounded
    /// local ⌘C read is allowed for this specific host even when the general
    /// fallback setting is off; the pasteboard is restored by the caller.
    /// Other apps retain the user's explicit opt-in.
    static let selectionCopyRecoveryHosts: Set<String> = ["com.openai.codex", "com.openai.chat", "com.openai.chatgpt"]

    static func mayRecoverWithCopy(automatic: Bool, settings: TextActionsSettings, bundleID: String?) -> Bool {
        !automatic || settings.readsWithCopy ||
            (bundleID.map { selectionCopyRecoveryHosts.contains($0.lowercased()) } ?? false)
    }

    /// Checked before any read. Automatic triggers need the master switch;
    /// the shortcut works without it. Everything else applies to both.
    static func check(_ environment: TextActionsEnvironment, settings: TextActionsSettings, automatic: Bool) -> TextActionsBlock? {
        if automatic && !settings.isOn { return .switchedOff }
        if !environment.automationOn || environment.paused { return .paused }
        if environment.screenLocked { return .screenLocked }
        if environment.secureInput { return .secureInput }
        if let id = environment.bundleID?.lowercased(), ownBundleIDs.contains(id) { return .ownApp }
        if settings.excludes(environment.bundleID) { return .excludedApp }
        if !environment.isTrusted { return .noAccessibility }
        return nil
    }

    static func isPasswordField(role: String?, subrole: String?) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return subrole == secure || role == secure
    }

    /// Checked on what Accessibility returned: never a password field, never
    /// blank text.
    static func check(_ attributes: TextSelectionAttributes) -> TextActionsBlock? {
        if isPasswordField(role: attributes.role, subrole: attributes.subrole) { return .passwordField }
        guard let text = attributes.selectedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noSelection }
        return nil
    }

    /// May AOM press ⌘C to read the selection? Only when the option is on (or
    /// for the shortcut), only when Accessibility had no text, never in a
    /// password field, under secure input, or in a file list.
    static func mayReadWithCopy(_ attributes: TextSelectionAttributes?, settings: TextActionsSettings, automatic: Bool,
                                environment: TextActionsEnvironment) -> Bool {
        guard mayRecoverWithCopy(automatic: automatic, settings: settings, bundleID: environment.bundleID) else { return false }
        guard check(environment, settings: settings, automatic: automatic) == nil else { return false }
        guard let attributes else { return true }
        if isPasswordField(role: attributes.role, subrole: attributes.subrole) { return false }
        if let role = attributes.role, fileListRoles.contains(role) { return false }
        let text = attributes.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
    }

    /// What ⌘C produced counts as a text selection only with a string and no
    /// files (Finder puts both on the clipboard for copied files).
    static func copiedText(string: String?, types: [String]) -> String? {
        let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType", "com.apple.finder.node"]
        guard !types.contains(where: fileTypes.contains), let string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    /// A drag that left the selection exactly as it was (the same element and
    /// range as at mouse down) moved a window, a scroll bar or a slider; it
    /// did not select text.
    static func isUnchangedSelection(anchor: TextSelectionRange?, final: TextSelectionRange?, sameElement: Bool) -> Bool {
        guard sameElement, let anchor, let final, anchor.length > 0 else { return false }
        return anchor == final
    }
}
