import Foundation

enum ScriptActionResults {
    /// Workflow variables are bounded to 512 characters. Status is retained on
    /// failures as well, so a continue-on-failure branch can inspect the result.
    ///
    /// 3.4.0 audit: a write the variables refused (a name over 55 characters,
    /// so `_exitCode` pushed it past 64; a name with other than ASCII letters,
    /// digits and _; 128 variables already stored) was dropped silently, and
    /// an If/Else then read the previous run's value. Returns whether all
    /// three were stored; a refusal is logged with the reason.
    @discardableResult
    static func record(name: String?, output: String, code: Int32, timedOut: Bool,
                       log: @escaping (String) -> Void = { message in
                           Task { @MainActor in GestureLog.shared.log(message, level: .error) }
                       }) -> Bool {
        guard let name, !name.isEmpty else { return true }
        let stored = [WorkflowVariables.set(name, value: String(output.prefix(512))),
                      WorkflowVariables.set(name + "_exitCode", value: String(code)),
                      WorkflowVariables.set(name + "_timedOut", value: timedOut ? "true" : "false")]
        guard stored.contains(false) else { return true }
        log(problem(name: name))
        return false
    }

    /// Why the result could not be kept under `name`.
    static func problem(name: String) -> String {
        if !WorkflowVariables.isValid(name: name + "_timedOut") {
            return "The script result was not stored: “\(name)” must be at most 55 letters, digits or _ "
                + "(AOM adds _exitCode and _timedOut)."
        }
        return "The script result was not stored in “\(name)”: AOM keeps at most 128 variables. Remove some first."
    }
}
