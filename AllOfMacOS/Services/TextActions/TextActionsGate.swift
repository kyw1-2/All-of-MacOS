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

    /// A video double-click toggles fullscreen. Never synthesize Command-C
    /// from a click gesture with no confirmed AX text selection; it could
    /// copy stale WebArea text or trigger unrelated host-app shortcuts.
    static func mayUseCopyFallback(automatic: Bool, gesture: TextSelectionMonitor.Gesture.Kind?) -> Bool {
        guard automatic else { return true }
        return gesture != .doubleClick && gesture != .tripleClick
    }

    /// A double-click is just a mouse gesture (fullscreen, window zoom,
    /// select a row, etc.), not proof that text was newly selected. Require
    /// evidence tied to that click. In particular a retained AXWebArea
    /// selection without a range or new text must never display the toolbar.
    static func confirmedClickSelection(gesture: TextSelectionMonitor.Gesture.Kind?,
                                        anchorAvailable: Bool, sameElement: Bool,
                                        initialRange: TextSelectionRange?, finalRange: TextSelectionRange?,
                                        initialText: String?, finalText: String?,
                                        finalBounds: CGRect?, pointer: CGPoint?) -> Bool {
        guard gesture == .doubleClick || gesture == .tripleClick else { return true }
        guard anchorAvailable, let finalText,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if sameElement {
            if let before = initialRange, let after = finalRange,
               after.length > 0, before != after { return true }
            // AXWebArea frequently does not expose a range; the before/after
            // selected-text snapshots still establish a change. An unchanged
            // selection or missing initial snapshot is *not* affirmative proof.
            if let before = initialText, before != finalText { return true }
        }
        // Some apps move AX focus to a new text node. The only acceptable
        // alternate evidence is a bounded selection rectangle at the click.
        // A huge/stale WebArea rectangle must not qualify.
        if let finalBounds, let pointer, finalBounds.width > 0,
           finalBounds.height > 0, finalBounds.height <= 76,
           finalBounds.width <= 600,
           finalBounds.insetBy(dx: -10, dy: -10).contains(pointer) { return true }
        return false
    }

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

    /// Used for both the focused AX node and any hit-tested ancestor. A
    /// blocked hit must be returned to the caller, never treated as nil.
    static let mediaRoles: Set<String> = ["AXVideo", "AXMedia", "AXMovie"]

    /// Treat actual media player hit targets, including YouTube's Chromium AX
    /// wrappers, as non-text. Do not blacklist the whole website: captions,
    /// descriptions and comments remain selectable outside the player DOM.
    static func isMediaSurface(role: String?, identifier: String?, htmlTag: String?, domClasses: [String]) -> Bool {
        if let role, mediaRoles.contains(role) { return true }
        if let htmlTag, ["video", "audio"].contains(htmlTag.lowercased()) { return true }
        let identifier = identifier?.lowercased() ?? ""
        if ["movie_player", "html5-video-player"].contains(identifier) { return true }
        let knownClasses: Set<String> = [
            "html5-video-player", "html5-main-video", "video-stream", "ytp-chrome-controls",
            "ytp-player-content", "ytp-gradient-bottom", "ytp-chrome-bottom",
            "ytp-progress-bar-container", "ytp-chrome-top", "ytp-scrubber-container"
        ]
        return domClasses.contains { knownClasses.contains($0.lowercased()) }
    }

    static func isForbiddenSelectionTarget(role: String?, subrole: String?) -> Bool {
        isPasswordField(role: role, subrole: subrole) ||
            (role.map { fileListRoles.contains($0) || mediaRoles.contains($0) } ?? false)
    }

    /// Checked on what Accessibility returned: never a password field, never
    /// blank text.
    static func check(_ attributes: TextSelectionAttributes) -> TextActionsBlock? {
        if isPasswordField(role: attributes.role, subrole: attributes.subrole) { return .passwordField }
        if let role = attributes.role, fileListRoles.contains(role) || mediaRoles.contains(role) { return .notText }
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
        if isForbiddenSelectionTarget(role: attributes.role, subrole: attributes.subrole) { return false }
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
    static func isUnchangedSelection(anchor: TextSelectionRange?, final: TextSelectionRange?, sameElement: Bool,
                                     initialText: String? = nil, finalText: String? = nil) -> Bool {
        guard sameElement else { return false }
        if let anchor, let final, anchor.length > 0 { return anchor == final }
        // Browser-backed text selections often have AXSelectedText but no
        // AXSelectedTextRange. Compare their stable snapshots instead of
        // interpreting an unchanged selection as a fresh double-click.
        guard let initialText, let finalText, !initialText.isEmpty else { return false }
        return initialText == finalText
    }
}
