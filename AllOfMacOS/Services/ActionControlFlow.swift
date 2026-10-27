import AppKit

extension Notification.Name {
    /// userInfo: "selector" (String), "enabled" (Bool). Observed by AppState,
    /// which owns the preset and therefore the only authority to flip a trigger.
    static let aomSetTriggerEnabled = Notification.Name("AOMActionSetTriggerEnabled")
}

/// In-memory state for the stateful control-flow actions. Keyed by the action's
/// own id, so a cycle or toggle keeps its place between runs of the same trigger
/// and a duplicated action starts fresh. Never persisted: a relaunch restarts it.
enum ActionFlowState {
    private static let lock = NSLock()
    private static var cycle: [UUID: (index: Int, at: TimeInterval)] = [:]
    private static var toggles: [UUID: Bool] = [:]
    private static var debounces: [UUID: UInt64] = [:]
    private static var counter: UInt64 = 0
    static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The step a Cycle Through Actions run should execute, and remember it.
    static func nextCycleIndex(id: UUID, count: Int, resetAfter: Double?) -> Int {
        guard count > 0 else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let time = now()
        var next = 0
        if let last = cycle[id], last.index + 1 < count {
            let idle = time - last.at
            if let reset = resetAfter, reset > 0, idle > reset { next = 0 } else { next = last.index + 1 }
        }
        cycle[id] = (next, time)
        return next
    }

    /// True for the "on" list. The first run is "on".
    static func nextToggle(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let next = !(toggles[id] ?? false)
        toggles[id] = next
        return next
    }

    static func beginDebounce(_ id: UUID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counter += 1; debounces[id] = counter
        return counter
    }
    static func isLatestDebounce(_ id: UUID, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return debounces[id] == token
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        cycle.removeAll(); toggles.removeAll(); debounces.removeAll()
        now = { ProcessInfo.processInfo.systemUptime }
    }
}

/// Finds triggers named by Enable / Disable Trigger.
enum TriggerSelector {
    /// A UUID matches exactly one trigger; any other text matches every trigger
    /// with that name (case-insensitive), or that input's display name.
    static func matches(_ selector: String, trigger: Trigger) -> Bool {
        let text = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let id = UUID(uuidString: text) { return trigger.id == id }
        let custom = trigger.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.caseInsensitiveCompare(text) == .orderedSame
            || (custom.isEmpty && trigger.input.displayName.caseInsensitiveCompare(text) == .orderedSame)
    }

    static func request(selector: String, enabled: Bool) {
        let post = {
            NotificationCenter.default.post(name: .aomSetTriggerEnabled, object: nil,
                                            userInfo: ["selector": selector, "enabled": enabled])
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

extension AppState {
    /// Applies an Enable / Disable Trigger request. Returns how many triggers changed.
    @discardableResult
    func applyTriggerEnableRequest(selector: String, enabled: Bool) -> Int {
        let ids = currentPreset.triggers.filter { TriggerSelector.matches(selector, trigger: $0) && $0.isEnabled != enabled }.map(\.id)
        ids.forEach { setTriggerEnabled(enabled, triggerID: $0) }
        return ids.count
    }
}

/// Environment a Wait For… poll reads. Replaced in tests.
struct WaitProbe {
    var runningBundleIDs: () -> Set<String>
    var frontmostBundleID: () -> String?
    var fileExists: (String) -> Bool
    var clipboardChangeCount: () -> Int
    var now: () -> TimeInterval
    /// "bundleID|title" of the focused window, for the window conditions.
    var focusedWindow: () -> String? = { nil }

    static let live = WaitProbe(
        runningBundleIDs: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        fileExists: { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) },
        clipboardChangeCount: { NSPasteboard.general.changeCount },
        now: { ProcessInfo.processInfo.systemUptime },
        focusedWindow: {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            var window: CFTypeRef?
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
            }
            return "\(app.bundleIdentifier ?? "\(app.processIdentifier)")|\(title as? String ?? "")"
        })
}

enum WaitFor {
    /// Conditions that need no target text.
    static let targetless: Set<String> = ["clipboardChange", "windowChange"]

    static func isSatisfied(condition: String, target: String, baselineClipboard: Int, probe: WaitProbe,
                            baselineWindow: String? = nil) -> Bool {
        switch condition {
        case "appRunning": return probe.runningBundleIDs().contains(target)
        case "appFrontmost": return probe.frontmostBundleID() == target
        case "appQuit": return !target.isEmpty && !probe.runningBundleIDs().contains(target)
        case "fileExists": return !target.isEmpty && probe.fileExists(target)
        case "fileGone": return !target.isEmpty && !probe.fileExists(target)
        case "clipboardChange": return probe.clipboardChangeCount() != baselineClipboard
        // BTT's "wait for focused window change": another window, or a new title.
        case "windowChange": return probe.focusedWindow() != baselineWindow
        case "windowTitleContains":
            guard let window = probe.focusedWindow(), let bar = window.firstIndex(of: "|") else { return false }
            return window[window.index(after: bar)...].localizedCaseInsensitiveContains(target)
        default: return false
        }
    }

    /// Polls on the main queue every `interval` seconds until the condition holds
    /// (true), the timeout passes (`continueOnTimeout`), or `isCancelled` says stop.
    static func run(_ p: ActionParameters, probe: WaitProbe = .live, interval: TimeInterval = 0.1,
                    isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void) {
        let condition = p.waitCondition ?? "appRunning"
        let target = (p.waitTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ActionParameterValidation.waitConditions.contains(condition),
              targetless.contains(condition) || !target.isEmpty else { completion(false); return }
        let timeout = Double(p.waitTimeoutMs ?? 30_000) / 1000
        let baseline = probe.clipboardChangeCount()
        let baselineWindow = condition == "windowChange" ? probe.focusedWindow() : nil
        let started = probe.now()
        func poll() {
            guard !isCancelled() else { completion(false); return }
            if isSatisfied(condition: condition, target: target, baselineClipboard: baseline, probe: probe,
                           baselineWindow: baselineWindow) { completion(true); return }
            if probe.now() - started >= timeout { completion(p.waitContinueOnTimeout == true); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: poll)
        }
        poll()
    }
}

/// Source of the text for Ask For Input. The default shows an NSAlert; tests
/// inject a provider so nothing is ever presented.
enum AskForInput {
    static var provider: ((_ prompt: String, _ initial: String, _ answer: @escaping (String?) -> Void) -> Void)?

    static func ask(prompt: String, initial: String, answer: @escaping (String?) -> Void) {
        if let provider { provider(prompt, initial, answer); return }
        let show = {
            let alert = NSAlert()
            alert.messageText = prompt.isEmpty ? "Enter a value" : prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = initial
            field.setAccessibilityLabel(alert.messageText)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }
}

/// Leaf control-flow actions: they have no nested steps, so the sequence runner
/// calls them like any other action. Container actions (Repeat, Cycle, Toggle,
/// Debounce, Break) live in `ActionSequenceRunner` because they own steps.
enum ControlFlowActions {
    static let handled: Set<ActionType> = [
        .increaseVariable, .decreaseVariable, .askForInput, .stopAllSequences,
        .enableTrigger, .disableTrigger, .waitFor, .disableTriggersForSeconds, .resumeTriggers]
    static func handles(_ type: ActionType) -> Bool { handled.contains(type) }

    /// Formats a variable so whole numbers stay whole ("3", not "3.0").
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// Adds `delta` to a numeric variable; a missing or non-numeric value counts as 0.
    @discardableResult
    static func adjust(variable name: String, by delta: Double) -> Bool {
        guard delta.isFinite else { return false }
        let current = WorkflowVariables.value(name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let next = current + delta
        guard next.isFinite else { return false }
        return WorkflowVariables.set(name, value: format(next))
    }

    /// `testing` is true when an `onActionExecuted` hook is installed: the action is
    /// reported to the hook and any effect outside this process's memory is skipped.
    static func perform(_ action: TriggerAction, testing: Bool, isCancelled: @escaping () -> Bool,
                        completion: @escaping (Bool) -> Void) {
        let p = action.parameters
        let report = { ActionExecutor.onActionExecuted?(action) }
        switch action.actionType {
        case .increaseVariable, .decreaseVariable:
            let step = p.variableStep ?? 1
            let ok = adjust(variable: p.variableName ?? "", by: action.actionType == .increaseVariable ? step : -step)
            if ok { report() }
            completion(ok)
        case .askForInput:
            if testing && AskForInput.provider == nil { report(); completion(true); return }
            let name = p.variableName ?? ""
            guard !name.isEmpty else { completion(false); return }
            AskForInput.ask(prompt: p.inputPrompt ?? "", initial: p.variableValue ?? "") { value in
                guard let value else { GestureLog.shared.logFromAnyThread("Ask For Input cancelled", level: .action); completion(false); return }
                let ok = WorkflowVariables.set(name, value: value)
                if ok { report() }
                completion(ok)
            }
        case .stopAllSequences:
            report()
            if !testing { ActionExecutor.cancelAllSequences() }
            completion(true)
        case .enableTrigger, .disableTrigger:
            let selector = (p.triggerSelector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else { completion(false); return }
            report()
            if !testing { TriggerSelector.request(selector: selector, enabled: action.actionType == .enableTrigger) }
            completion(true)
        case .disableTriggersForSeconds:
            report()
            if !testing {
                let seconds = p.pauseSeconds ?? 5
                DispatchQueue.main.async { TriggerSuppression.shared.pause(for: seconds) }
            }
            completion(true)
        case .resumeTriggers:
            report()
            if !testing { DispatchQueue.main.async { TriggerSuppression.shared.resume() } }
            completion(true)
        case .waitFor:
            if testing { report(); completion(true); return }
            WaitFor.run(p, isCancelled: isCancelled, completion: completion)
        default: completion(false)
        }
    }
}
