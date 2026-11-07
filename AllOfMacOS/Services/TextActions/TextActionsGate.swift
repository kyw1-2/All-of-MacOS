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
    /// The pointer hit text, and its complete ancestry passed the guards.
    var isTextTarget = false
    var isVerifiedContext = false
    /// An incomplete/cyclic AX walk must not authorize clipboard recovery.
    var isBlocked = false
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

    /// Click recovery is restricted to a known host and a verified text hit.
    /// Neither a bare gesture nor an unreadable/blocked AX tree is evidence.
    static func mayUseCopyFallback(automatic: Bool, gesture: TextSelectionMonitor.Gesture.Kind?,
                                   bundleID: String? = nil, verifiedTextTarget: Bool = false) -> Bool {
        guard automatic, gesture == .doubleClick || gesture == .tripleClick else { return true }
        return verifiedTextTarget && (bundleID.map { selectionCopyRecoveryHosts.contains($0.lowercased()) } ?? false)
    }

    static func containsSelection(_ bounds: CGRect?, pointer: CGPoint?) -> Bool {
        guard let bounds, let pointer, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return false }
        return bounds.insetBy(dx: -10, dy: -10).contains(pointer)
    }

    /// A hit on text can confirm a selection even if passive mouse-down AX
    /// arrived after the app handled the click. Bounds must be selection bounds,
    /// never the element frame. A large WebArea alone is still not evidence.
    static func confirmedClickSelection(gesture: TextSelectionMonitor.Gesture.Kind?,
                                        anchorAvailable: Bool, sameElement: Bool,
                                        initialRange: TextSelectionRange?, finalRange: TextSelectionRange?,
                                        initialText: String?, finalText: String?,
                                        finalBounds: CGRect?, pointer: CGPoint?,
                                        verifiedTextTarget: Bool = false, directTextSelection: Bool = false) -> Bool {
        guard gesture == .doubleClick || gesture == .tripleClick else { return true }
        guard let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if anchorAvailable && sameElement {
            if let before = initialRange, let after = finalRange,
               after.length > 0, before != after { return true }
            if let before = initialText, before != finalText { return true }
        }
        if verifiedTextTarget {
            if directTextSelection { return true }
            if anchorAvailable, let before = initialText, before != finalText { return true }
        }
        if containsSelection(finalBounds, pointer: pointer) {
            if verifiedTextTarget { return true }
            if let finalBounds, finalBounds.height <= 76, finalBounds.width <= 600 { return true }
        }
        return false
    }

    enum ReadDisposition: Equatable { case blocked, retry, present, copy, ignore }

    static func mayUseFocusedDragSelection(_ final: TextSelectionAttributes, sameElement: Bool,
                                            initialText: String?, initialRange: TextSelectionRange?,
                                            initialBounds: CGRect?, startedOnText: Bool, endpointRole: String?) -> Bool {
        guard startedOnText, sameElement, final.isVerifiedContext, check(final) == nil,
              endpointRole == "AXImage" || collectionRoles.contains(endpointRole ?? "") else { return false }
        // Missing baseline data is not affirmative evidence of a changed drag.
        if let initialBounds, let bounds = final.bounds, initialBounds != bounds { return true }
        if let initialRange, let range = final.range, initialRange != range { return true }
        if let initialText, initialText != final.selectedText { return true }
        return false
    }

    /// Shared by the controller and regression tests: a missing or unsettled
    /// first read retries before the final freshness/copy decision.
    static func disposition(automatic: Bool, attempt: Int, blocked: Bool, hasSelection: Bool,
                            unchanged: Bool, click: Bool, confirmed: Bool, mayCopy: Bool,
                            incomplete: Bool = false) -> ReadDisposition {
        if incomplete { return automatic && attempt == 0 ? .retry : .blocked }
        if blocked { return .blocked }
        let accepted = hasSelection && (click ? confirmed : !unchanged)
        if accepted { return .present }
        if automatic && attempt == 0 { return .retry }
        if !hasSelection && !unchanged && mayCopy { return .copy }
        return .ignore
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

    static let collectionRoles: Set<String> = ["AXList", "AXTable", "AXOutline", "AXGrid"]
    static let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea"]
    static let contentListSubroles: Set<String> = ["AXContentList", "AXDescriptionList"]

    static func isForbiddenSelectionTarget(role: String?, subrole: String?, hasTextSelection: Bool = false) -> Bool {
        if isPasswordField(role: role, subrole: subrole) { return true }
        guard let role else { return false }
        if collectionRoles.contains(role), hasTextSelection || contentListSubroles.contains(subrole ?? "") { return false }
        return fileListRoles.contains(role) || mediaRoles.contains(role)
    }

    static func isBlocked(_ attributes: TextSelectionAttributes) -> Bool {
        attributes.isBlocked || isForbiddenSelectionTarget(role: attributes.role, subrole: attributes.subrole,
            hasTextSelection: !(attributes.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    /// Checked on what Accessibility returned: never a password field, never
    /// blank text.
    static func check(_ attributes: TextSelectionAttributes) -> TextActionsBlock? {
        if isPasswordField(role: attributes.role, subrole: attributes.subrole) { return .passwordField }
        if isBlocked(attributes) { return .notText }
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
        if isBlocked(attributes) { return false }
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

    /// Selection geometry distinguishes the same word at different locations.
    /// Equal snapshots remain stale across AX wrapper changes; when geometry
    /// is unavailable, a different wrapper alone is not a selection change.
    static func isUnchangedSelection(anchor: TextSelectionRange?, final: TextSelectionRange?, sameElement: Bool,
                                     initialText: String? = nil, finalText: String? = nil,
                                     initialBounds: CGRect? = nil, finalBounds: CGRect? = nil) -> Bool {
        if let initialBounds, let finalBounds, initialBounds != finalBounds { return false }
        if sameElement, let anchor, let final, anchor.length > 0 { return anchor == final }
        guard let initialText, let finalText, !initialText.isEmpty, initialText == finalText else { return false }
        return true
    }
}
