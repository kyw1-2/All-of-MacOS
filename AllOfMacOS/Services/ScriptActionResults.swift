import Foundation

enum ScriptActionResults {
    /// Workflow variables are bounded to 512 characters. Status is retained on
    /// failures as well, so a continue-on-failure branch can inspect the result.
    static func record(name: String?, output: String, code: Int32, timedOut: Bool) {
        guard let name, !name.isEmpty else { return }
        WorkflowVariables.set(name, value: String(output.prefix(512)))
        WorkflowVariables.set(name + "_exitCode", value: String(code))
        WorkflowVariables.set(name + "_timedOut", value: timedOut ? "true" : "false")
    }
}
