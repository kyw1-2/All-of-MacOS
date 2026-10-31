import CoreGraphics
import Foundation

/// What Accessibility says about a window, read once per focus change. The
/// classifier works on this value only, so its rules are tested with
/// snapshots instead of live dialogs.
///
/// Observed on macOS 27.2 (the probe in docs/files-3.4.0.md): NSOpenPanel is an
/// AXWindow, subrole AXStandardWindow, identifier "open-panel"; NSSavePanel is
/// "save-panel", as an AXSheet (description "save") when attached to a
/// document. Both carry the buttons "OKButton" and "CancelButton", the
/// location pop-up "where popup", and Save adds "saveAsNameTextField". Part of
/// the panel's content always comes from the remote service
/// com.apple.appkit.xpc.openAndSavePanelService, for sandboxed and
/// non-sandboxed apps alike.
struct FilesDialogSnapshot: Equatable {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var roleDescription: String?
    /// The element belongs to the open-and-save panel service process.
    var ownedByPanelService = false
    /// Some element inside it belongs to the panel service.
    var containsPanelServiceContent = false
    /// Identifiers found among its descendants (bounded walk).
    var descendantIdentifiers: Set<String> = []
    /// Titles of its buttons (bounded walk), for panels without identifiers.
    var buttonTitles: Set<String> = []
    var frame: CGRect?
}

enum FilesDialogKind: String, Equatable {
    case open, save
}

struct FilesDialogClassification: Equatable {
    var kind: FilesDialogKind
    var isSheet: Bool
    /// The panel shows content from the remote panel service (sandboxed apps
    /// before macOS 26 hosted the whole panel there).
    var isRemote: Bool
}

enum FilesDialogClassifier {
    static let openIdentifier = "open-panel"
    static let saveIdentifier = "save-panel"
    static let goToIdentifier = "GoToWindow"
    static let pathFieldIdentifier = "PathTextField"
    static let okIdentifier = "OKButton"
    static let cancelIdentifier = "CancelButton"
    static let locationIdentifier = "where popup"
    static let nameFieldIdentifier = "saveAsNameTextField"
    static let panelServiceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"

    /// The Go to Folder sheet the helper opens inside a dialog.
    static func isGoToSheet(_ snapshot: FilesDialogSnapshot) -> Bool {
        snapshot.identifier == goToIdentifier
    }

    /// Open, Save, or nil for anything else (documents, alerts, palettes,
    /// the Go to Folder sheet).
    static func classify(_ snapshot: FilesDialogSnapshot) -> FilesDialogClassification? {
        let role = snapshot.role ?? ""
        guard role == "AXWindow" || role == "AXSheet" else { return nil }
        guard !isGoToSheet(snapshot) else { return nil }
        let isSheet = role == "AXSheet"
        let remote = snapshot.ownedByPanelService || snapshot.containsPanelServiceContent
        func result(_ kind: FilesDialogKind) -> FilesDialogClassification {
            FilesDialogClassification(kind: kind, isSheet: isSheet, isRemote: remote)
        }
        // 1. The identifiers AppKit gives its panels.
        switch snapshot.identifier {
        case openIdentifier: return result(.open)
        case saveIdentifier: return result(.save)
        default: break
        }
        // 2. The panel's own controls, for panels whose window identifier is
        //    missing (custom subclasses, older systems).
        let ids = snapshot.descendantIdentifiers
        let hasButtons = ids.contains(okIdentifier) && ids.contains(cancelIdentifier)
        if hasButtons && ids.contains(nameFieldIdentifier) { return result(.save) }
        if hasButtons && ids.contains(locationIdentifier) { return result(.open) }
        // 3. The remote panel service draws the panel (sandboxed apps): its
        //    window or content plus a default and a cancel button.
        if remote && (hasButtons || snapshot.buttonTitles.contains(where: isCancelTitle)) {
            if ids.contains(nameFieldIdentifier) || snapshot.roleDescription?.lowercased() == "save" { return result(.save) }
            return result(.open)
        }
        return nil
    }

    /// "Cancel" in the languages AOM's people use most; only a fallback for
    /// panels without identifiers.
    static func isCancelTitle(_ title: String) -> Bool {
        ["cancel", "취소", "キャンセル", "取消", "annuler", "abbrechen", "cancelar", "annulla"].contains(title.lowercased())
    }
}
