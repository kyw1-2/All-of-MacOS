import AppKit

/// ⌘K's app row actions (6.5, after Raycast's Applications): Open, Show in
/// Finder, Hide, Quit, Force Quit…, Uninstall…, in that fixed order, so ↩
/// always opens and ⌘↩ always shows the app in Finder whether or not it runs.
///
/// The row is an installed copy, identified by its path. Every action finds
/// the running instances of that copy again when it runs (a second copy with
/// the same bundle ID, or a relaunch after the palette opened, is never the
/// target), and Force Quit names the app in a confirmation first. AOM itself,
/// the Dock, the menu bar hosts and Finder are never quit from here.
enum PaletteAppControl {
    enum Command: Equatable, CaseIterable {
        case showInFinder, hide, quit, forceQuit, uninstall

        var title: String {
            switch self {
            case .showInFinder: return "Show in Finder"
            case .hide: return "Hide"
            case .quit: return "Quit"
            case .forceQuit: return "Force Quit…"
            case .uninstall: return "Uninstall…"
            }
        }

        var symbol: String {
            switch self {
            case .showInFinder: return "folder"
            case .hide: return "eye.slash"
            case .quit: return "xmark.circle"
            case .forceQuit: return "exclamationmark.octagon"
            case .uninstall: return "trash"
            }
        }
    }

    static let finderBundleID = "com.apple.finder"

    static func isOwn(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID.hasPrefix("com.kyw.allofmacos") || FocusIdlePolicy.aomBundleIDs.contains(bundleID)
    }

    /// Never quit or force quit from a search row: AOM, the system hosts
    /// title-bar gestures already protect, and Finder.
    static func isProtected(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return isOwn(bundleID) || bundleID == finderBundleID
            || SwishSnap.protectedGestureBundleIDs.contains(bundleID)
    }

    /// Whether System Tools' uninstall review would take the app at all
    /// (the same rule as `CleanupTools.uninstallIdentity`), so the row does
    /// not offer a review that can only refuse.
    static func isUninstallable(bundleID: String?, path: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !path.hasPrefix("/System/") && !bundleID.hasPrefix("com.apple.") && !isOwn(bundleID)
    }

    /// Pure: the secondary actions of an app row, in their fixed order.
    static func commands(isRunning: Bool, bundleID: String?, path: String) -> [Command] {
        var commands: [Command] = [.showInFinder]
        if isRunning, !isOwn(bundleID) { commands.append(.hide) }
        if isRunning, !isProtected(bundleID) { commands += [.quit, .forceQuit] }
        if isUninstallable(bundleID: bundleID, path: path) { commands.append(.uninstall) }
        return commands
    }

    /// The comparable path of an installed copy (symlinks resolved).
    static func installedKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The comparable path of a running app (LaunchServices reports the
    /// real path; no file system access while typing).
    static func runningKey(_ app: NSRunningApplication) -> String? {
        app.bundleURL?.standardizedFileURL.path
    }

    /// Keys of every running app with a bundle, read once per palette pass.
    static func runningKeys() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.isTerminated ? nil : runningKey($0) })
    }

    /// Pure: the instances that are this copy, and only this copy.
    static func matches(installedKey: String, bundleID: String?,
                        running: [(key: String?, bundleID: String?)]) -> [Int] {
        running.indices.filter { index in
            let candidate = running[index]
            guard candidate.key == installedKey else { return false }
            // A different app now at the same path is not the one searched.
            if let bundleID, let other = candidate.bundleID, other != bundleID { return false }
            return true
        }
    }

    /// Resolved again when the action runs.
    static func instances(of app: URL) -> [NSRunningApplication] {
        let key = installedKey(app)
        let bundleID = PaletteApplications.bundleID(for: app)
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let picked = matches(installedKey: key, bundleID: bundleID,
                             running: running.map { (runningKey($0), $0.bundleIdentifier) })
        return picked.map { running[$0] }
    }

    @MainActor
    static func hide(_ app: URL, name: String) {
        let targets = instances(of: app).filter { !isOwn($0.bundleIdentifier) }
        guard !targets.isEmpty else { notRunning(name); return }
        targets.forEach { $0.hide() }
    }

    /// The normal quit: the app can still ask to save.
    @MainActor
    static func quit(_ app: URL, name: String) {
        let targets = instances(of: app).filter { !isProtected($0.bundleIdentifier) }
        guard !targets.isEmpty else { notRunning(name); return }
        targets.forEach { $0.terminate() }
        GestureHUD.shared.show(title: "Quitting \(name)", detail: "It can still ask to save your work.")
    }

    @MainActor
    static func forceQuit(_ app: URL, name: String) {
        let targets = instances(of: app).filter { !isProtected($0.bundleIdentifier) }
        guard !targets.isEmpty else { notRunning(name); return }
        let alert = NSAlert()
        alert.messageText = "Force Quit “\(name)”?"
        alert.informativeText = "\(name) closes at once. Unsaved changes in it are lost."
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: "Force Quit")
        button.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The same instances, unless one ended or changed meanwhile.
        let key = installedKey(app)
        for target in targets where !target.isTerminated && runningKey(target) == key {
            target.forceTerminate()
        }
        GestureLog.shared.logFromAnyThread("Force quit \(name) from ⌘K", level: .action)
    }

    @MainActor
    private static func notRunning(_ name: String) {
        GestureHUD.shared.show(title: "\(name) Isn't Running", detail: nil)
    }
}
