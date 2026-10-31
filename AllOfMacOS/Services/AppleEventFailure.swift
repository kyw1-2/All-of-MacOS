import Foundation

/// What a failed AppleScript or JavaScript for Automation run means for the
/// person who has to fix it, read from osascript's output (3.4.0 audit).
/// osascript ends an Apple Events failure with its status in parentheses:
/// "execution error: Not authorized to send Apple events to Finder. (-1743)".
/// Until 3.4.0 AOM's own commands said "allow AOM to control System Events"
/// for any failure (a timeout, an app that had quit) and the person's own
/// scripts logged only "Script completed (exit 1)", so turning AOM off for an
/// app in Privacy & Security › Automation looked like a broken script.
enum AppleEventFailure: Equatable {
    /// errAEEventNotPermitted (-1743): AOM may not control the app.
    case notPermitted(app: String?)
    /// errAEEventWouldRequireUserConsent (-1744): macOS has to ask first.
    case consentRequired(app: String?)
    /// procNotFound (-600): the app is not running (it quit, or was quitting).
    case appNotRunning(app: String?)
    /// errAETimeout (-1712), or the run outlasted its time limit.
    case timedOut(app: String?)

    static func classify(output: String) -> AppleEventFailure? {
        guard let code = errorCode(in: output) else { return nil }
        let app = appName(in: output)
        switch code {
        case -1743: return .notPermitted(app: app)
        case -1744: return .consentRequired(app: app)
        case -600: return .appNotRunning(app: app)
        case -1712: return .timedOut(app: app)
        default: return nil
        }
    }

    private static let codeExpression = try? NSRegularExpression(pattern: #"\((-\d{3,5})\)"#)
    private static let appExpressions: [NSRegularExpression] = [
        #"Apple ?events to ([^.\n]{1,80}?)\."#,       // -1743, -1744
        #"([^:\n]{1,80}?) got an error"#,              // "System Events got an error: … (-600)"
        #"[Aa]pplication "([^"\n]{1,80})""#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The last "(-NNNN)" in the output: osascript puts the status of the
    /// failure that ended the script last.
    static func errorCode(in output: String) -> Int? {
        let range = NSRange(output.startIndex..., in: output)
        guard let match = codeExpression?.matches(in: output, range: range).last,
              let found = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[found])
    }

    /// The app the failed event was for, when the output names it.
    static func appName(in output: String) -> String? {
        let range = NSRange(output.startIndex..., in: output)
        for expression in appExpressions {
            guard let match = expression.firstMatch(in: output, range: range),
                  let found = Range(match.range(at: 1), in: output) else { continue }
            let name = output[found].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private var app: String? {
        switch self {
        case .notPermitted(let app), .consentRequired(let app), .appNotRunning(let app), .timedOut(let app): return app
        }
    }

    var title: String {
        switch self {
        case .notPermitted, .consentRequired: return "Automation Permission Needed"
        case .appNotRunning: return "\(app ?? "The App") Is Not Running"
        case .timedOut: return "\(app ?? "The App") Did Not Answer"
        }
    }

    var detail: String {
        let name = app.map { "“\($0)”" } ?? "the app"
        switch self {
        case .notPermitted:
            return "Allow All of MacOS to control \(name) in System Settings › Privacy & Security › Automation, then try again."
        case .consentRequired:
            return "macOS has to ask whether All of MacOS may control \(name). Run it again and choose Allow."
        case .appNotRunning:
            return "AOM could not reach \(name); it may have quit. Open it and try again."
        case .timedOut:
            return "\(app.map { "“\($0)”" } ?? "The app") may be busy or showing a dialog. Try again when it is free."
        }
    }
}

/// AOM's own AppleScript commands (Dark Mode, Dock hiding, Empty Trash, Log
/// Out) and the person's scripts, with Apple Events failures explained.
enum AppleEventScripts {
    typealias Runner = (_ kind: String, _ source: String, _ timeout: Double,
                        _ completion: @escaping (Int32, String, Bool) -> Void) -> Void
    /// Seams for tests; production runs scripts in the XPC helper.
    nonisolated(unsafe) static var runner: Runner = { kind, source, timeout, completion in
        ScriptRunnerClient.shared.run(kind: kind, source: source, timeout: timeout, completion: completion)
    }
    nonisolated(unsafe) static var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    nonisolated(unsafe) static var report: (_ failure: AppleEventFailure?, _ action: String, _ output: String) -> Void = {
        failure, action, output in
        guard let failure else {
            let message = "\(action) failed" + (output.isEmpty ? "." : ": \(output.prefix(160))")
            Task { @MainActor in GestureLog.shared.log(message, level: .error) }
            return
        }
        Task { @MainActor in GestureLog.shared.log("\(action): \(failure.title). \(failure.detail)", level: .error) }
        guard AppleEventScripts.shouldShow(failure, now: ProcessInfo.processInfo.systemUptime) else { return }
        GestureHUD.shared.show(title: failure.title, detail: failure.detail)
    }
    static let retryDelay: TimeInterval = 0.5

    /// One HUD per failure and app a minute: a trigger fired again and again
    /// does not cover the screen with the same advice.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shown: [String: TimeInterval] = [:]
    static func shouldShow(_ failure: AppleEventFailure, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = failure.title + failure.detail
        if let last = shown[key], now - last >= 0, now - last < 60 { return false }
        shown[key] = now
        return true
    }

    /// Runs one of AOM's own commands. The event never reached an app that
    /// was not running (-600), so it is sent once more (a toggle has not
    /// toggled); any other failure tells the person what to do.
    static func run(_ source: String, action: String, timeout: Double, completion: @escaping (Bool) -> Void) {
        attempt(source, action: action, timeout: timeout, retriesLeft: 1, completion: completion)
    }

    private static func attempt(_ source: String, action: String, timeout: Double, retriesLeft: Int,
                                completion: @escaping (Bool) -> Void) {
        runner("applescript", source, timeout) { code, output, timedOut in
            guard code != 0 || timedOut else { completion(true); return }
            let failure = timedOut ? AppleEventFailure.timedOut(app: AppleEventFailure.appName(in: output))
                : AppleEventFailure.classify(output: output)
            if case .appNotRunning? = failure, retriesLeft > 0 {
                after(retryDelay) {
                    attempt(source, action: action, timeout: timeout, retriesLeft: retriesLeft - 1, completion: completion)
                }
                return
            }
            report(failure, action, output)
            completion(false)
        }
    }

    /// The person's own AppleScript or JavaScript failed: never sent again
    /// (it may have done part of its work), only explained when Apple Events
    /// were the reason. Returns the failure, if any.
    @discardableResult
    static func explain(kind: String, output: String) -> AppleEventFailure? {
        guard kind == "applescript" || kind == "javascript",
              let failure = AppleEventFailure.classify(output: output) else { return nil }
        report(failure, "Script", output)
        return failure
    }
}
