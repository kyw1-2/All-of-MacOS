import AppKit
import Foundation

/// AppleScript support (CleanShot's cleanshot:// and BTT's AppleScript
/// parity). Every command is translated into the aom:// link that does the
/// same thing and handed to the app's single URL handler, so scripts, links,
/// Shortcuts and MCP share one execution path and its validation.
enum AOMScriptingRoute {
    enum Failure: LocalizedError {
        case unknownMode(String), invalidURL(String), emptyName
        var errorDescription: String? {
            switch self {
            case .unknownMode(let mode): return "Unknown capture mode “\(mode)”."
            case .invalidURL(let text): return "“\(text)” is not a supported aom:// link."
            case .emptyName: return "Give the named trigger’s name."
            }
        }
    }

    static let captureModes: [String: String] = [
        "area": "capture-area", "all in one": "all-in-one", "full screen": "capture-fullscreen",
        "fullscreen": "capture-fullscreen", "window": "capture-window", "previous area": "capture-previous-area",
        "scrolling": "scrolling-capture", "self timer": "self-timer", "text": "capture-text",
        "record screen": "record-screen",
    ]

    static func capture(mode: String?) throws -> URL {
        let key = (mode ?? "area").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: " ")
        guard let host = captureModes[key.isEmpty ? "area" : key] else { throw Failure.unknownMode(mode ?? "") }
        return URL(string: "aom://\(host)")!
    }

    static func runTrigger(named name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        var parts = URLComponents()
        parts.scheme = "aom"
        parts.host = "trigger"
        parts.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        return parts.url!
    }

    static let restoreQuickAccess = URL(string: "aom://restore-recently-closed")!

    /// Only links the app itself understands are accepted.
    static func validated(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              AOMCaptureDeepLink.parse(url) != nil || AOMAutomationLink.parse(url) != nil else {
            throw Failure.invalidURL(text)
        }
        return url
    }

    @MainActor
    static func perform(_ url: URL) {
        AppDelegate.current?.application(NSApp, open: [url])
    }
}

/// Shared command plumbing: run on the main actor, report errors to the script.
class AOMScriptCommand: NSScriptCommand {
    func route() throws -> URL { fatalError("subclass") }

    override func performDefaultImplementation() -> Any? {
        do {
            let url = try route()
            DispatchQueue.main.async { MainActor.assumeIsolated { AOMScriptingRoute.perform(url) } }
        } catch {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = error.localizedDescription
        }
        return nil
    }
}

@objc(AOMScriptRunTriggerCommand)
final class AOMScriptRunTriggerCommand: AOMScriptCommand {
    override func route() throws -> URL { try AOMScriptingRoute.runTrigger(named: directParameter as? String ?? "") }
}

@objc(AOMScriptCaptureCommand)
final class AOMScriptCaptureCommand: AOMScriptCommand {
    override func route() throws -> URL { try AOMScriptingRoute.capture(mode: directParameter as? String) }
}

@objc(AOMScriptRestoreCommand)
final class AOMScriptRestoreCommand: AOMScriptCommand {
    override func route() throws -> URL { AOMScriptingRoute.restoreQuickAccess }
}

@objc(AOMScriptOpenURLCommand)
final class AOMScriptOpenURLCommand: AOMScriptCommand {
    override func route() throws -> URL { try AOMScriptingRoute.validated(directParameter as? String ?? "") }
}
