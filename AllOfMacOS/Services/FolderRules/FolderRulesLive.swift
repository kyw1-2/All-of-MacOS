import AppKit
import Foundation

/// The live environment's ties to AppKit and the Automation engine. Each one
/// hops to the main thread; runs call them from the engine's own queue.
enum FolderRulesLive {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    static func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
    }

    static func open(_ file: URL, with app: URL?) -> Bool {
        guard let app else { return onMain { NSWorkspace.shared.open(file) } }
        let done = DispatchSemaphore(value: 0)
        let opened = Box(false)
        onMain {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration) { _, error in
                opened.value = error == nil
                done.signal()
            }
        }
        if Thread.isMainThread { return true }
        guard done.wait(timeout: .now() + 30) == .success else { return false }
        return opened.value
    }

    static func isRunning(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        return onMain {
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == path }
        }
    }

    /// The variables an automation reads as `{{var:FolderRuleFile}}` and
    /// `{{var:FolderRuleFileName}}`.
    static let fileVariable = "FolderRuleFile"
    static let fileNameVariable = "FolderRuleFileName"

    /// Runs an automation's actions the way the editor's test run does, after
    /// the Pause AOM check, and waits for it to finish (at most 5 minutes).
    static func runAutomation(id: UUID, name: String, file: URL) -> Result<Void, FolderRuleFailure> {
        let label = name.isEmpty ? "The automation" : "“\(name)”"
        let done = DispatchSemaphore(value: 0)
        let outcome = Box<Result<Void, FolderRuleFailure>>(.failure(FolderRuleFailure("\(label) didn't finish within 5 minutes.")))
        let started: Bool = onMain {
            guard AutomationGate.isOn, !TriggerSuppression.shared.isPaused else {
                outcome.value = .failure(FolderRuleFailure("AOM is paused, so \(label) didn't run."))
                return false
            }
            guard let trigger = ActionExecutor.registeredTriggers.first(where: { $0.id == id }) else {
                outcome.value = .failure(FolderRuleFailure("\(label) is turned off or was deleted."))
                return false
            }
            // A path the variables can't hold must not leave the previous file's path behind.
            if !WorkflowVariables.set(fileVariable, value: file.path) { WorkflowVariables.remove(fileVariable) }
            if !WorkflowVariables.set(fileNameVariable, value: file.lastPathComponent) { WorkflowVariables.remove(fileNameVariable) }
            ActionExecutor.executeActions(trigger.actions, triggerID: trigger.id) { ok in
                outcome.value = ok ? .success(()) : .failure(FolderRuleFailure("\(label) didn't finish (it may already be running)."))
                done.signal()
            }
            return true
        }
        guard started else { return outcome.value }
        if Thread.isMainThread { return .success(()) }
        _ = done.wait(timeout: .now() + 300)
        return outcome.value
    }

    static func confirmReplace(_ appName: String) -> FolderRuleReplaceChoice {
        onMain {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace “\(appName)” in Applications?"
            alert.informativeText = "The installed copy moves to the Trash, where you can put it back. Keep Both installs the new one beside it."
            alert.addButton(withTitle: "Replace").hasDestructiveAction = true
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            AOMOverlayActivation.activateForOverlay()
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .replace
            case .alertSecondButtonReturn: return .keepBoth
            default: return .cancel
            }
        }
    }

    /// The manual install's question when one disk image holds several apps.
    static func chooseApp(_ apps: [URL]) -> URL? {
        onMain {
            let alert = NSAlert()
            alert.messageText = "Which app do you want to install?"
            alert.informativeText = "This disk image holds \(apps.count) apps."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
            for app in apps { popup.addItem(withTitle: app.deletingPathExtension().lastPathComponent) }
            popup.setAccessibilityLabel("App to install")
            alert.accessoryView = popup
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            AOMOverlayActivation.activateForOverlay()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let index = popup.indexOfSelectedItem
            return apps.indices.contains(index) ? apps[index] : nil
        }
    }

    static func copyAsAdministrator(_ source: URL, _ destination: URL) -> FolderRuleFailure? {
        let result = onMain {
            SystemToolsCommand.runAsAdministrator([.init(path: "/usr/bin/ditto", arguments: [source.path, destination.path])])
        }
        switch result {
        case .done: return nil
        case .cancelled: return FolderRuleFailure("Cancelled at the administrator prompt.")
        case .failed(let message): return FolderRuleFailure(message)
        }
    }
}
