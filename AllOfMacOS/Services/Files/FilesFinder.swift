import AppKit
import CoreServices
import Foundation

/// The folders of the open Finder windows, front to back, through Apple
/// Events to the Finder. Off the main thread, with a timeout, and never
/// prompting by itself: the Automation permission is asked for only when the
/// person clicks Allow Finder Access.
enum FilesFinder {
    enum Permission: Equatable {
        case granted, denied, notAsked, finderNotRunning, unknown
    }

    enum Failure: Error, Equatable {
        case permission(Permission)
        case timedOut
        case failed(String)
    }

    static let bundleID = "com.apple.finder"

    /// AppleScript's "Finder windows" are numbered front to back. Windows on
    /// places without a folder (Recents, AirDrop, search results) are skipped.
    static let script = """
    set out to ""
    tell application "Finder"
        repeat with aWindow in Finder windows
            try
                set out to out & POSIX path of (target of aWindow as alias) & linefeed
            end try
        end repeat
    end tell
    return out
    """

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Asks the system whether AOM may send the Finder Apple Events. With
    /// `ask` the system shows its Automation prompt if the person hasn't
    /// answered yet (it blocks until they do: background thread only).
    static func permission(ask: Bool) -> Permission {
        guard isRunning else { return .finderNotRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        if status == noErr { return .granted }
        if status == OSStatus(errAEEventNotPermitted) { return .denied }
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .notAsked }
        if status == OSStatus(procNotFound) { return .finderNotRunning }
        return .unknown
    }

    /// Front-to-back folder paths. Fails without asking when the permission
    /// isn't granted yet.
    static func windowFolders(timeout: TimeInterval = 2) -> Result<[String], Failure> {
        let state = permission(ask: false)
        guard state == .granted || state == .unknown else { return .failure(.permission(state)) }
        let output = FilesProcess.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        if output.timedOut { return .failure(.timedOut) }
        guard output.status == 0 else {
            if output.stderr.contains("-1743") { return .failure(.permission(.denied)) }
            return .failure(.failed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(parse(output.stdout))
    }

    /// One path per line, trailing slashes removed except for "/".
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            let path = String(line).trimmingCharacters(in: .whitespaces)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }.filter { $0.hasPrefix("/") }
    }

    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
