import Foundation
import AppKit

class ActionExecutor {
    // Hook for testing — when set, actions call this instead of performing real work
    static var onActionExecuted: ((TriggerAction) -> Void)?

    // Bind workflow actions to the real frontmost app, including AOM itself.
    // Previously AOM activation redirected input/window actions to the last external app.
    private static func executionWindow() -> WindowManager.Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return WindowManager.shared.captureTarget(pid: front.processIdentifier)
    }
    private final class ExecutionContext {
        let id = UUID()
        var cancelled = false
        var remainingCalls = 1000
    }
    private struct Invocation {
        let triggerID: UUID
        let context: ExecutionContext
        let runner: ActionSequenceRunner
    }
    private static var sequences: [UUID: Invocation] = [:]
    private(set) static var registeredTriggers: [Trigger] = []
    private static var activationGroups: [ActivationGroup] = []
    private static var holds: [UUID: HoldRepeater] = [:]

    static func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        let next = triggers.filter(\.isEnabled)
        let groupsChanged = activationGroups != groups
        for id in Array(holds.keys) where groupsChanged || registeredTriggers.first(where: { $0.id == id }) != next.first(where: { $0.id == id }) {
            cancelSequence(id)
        }
        activationGroups = groups
        registeredTriggers = next
    }
    // Historical API name; this now returns the actual frontmost bundle ID (also AOM).
    static var externalBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    static func cheatSheetTriggers() -> [Trigger] {
        let front = externalBundleID
        return registeredTriggers.filter { trigger in
            TriggerResolver.resolve(registeredTriggers, payload: trigger.input, frontBundleID: front,
                payloadOf: { $0.input }, appBundleIDOf: { $0.appBundleID },
                modifiers: trigger.requiredModifiers ?? 0, requiredModifiersOf: { $0.requiredModifiers },
                groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
                .contains { $0.id == trigger.id }
        }.sorted { $0.order < $1.order }
    }

    static func releaseHold(_ id: UUID) { if holds[id] != nil { cancelSequence(id) } }
    static func cancelSequence(_ id: UUID) {
        holds.removeValue(forKey: id)?.cancel()
        cancelInvocations(id)
    }
    private static func cancelInvocations(_ id: UUID) {
        let contexts = sequences.values.filter { $0.triggerID == id }.map(\.context)
        for context in contexts {
            context.cancelled = true
            Array(sequences.values).filter { $0.context.id == context.id }.forEach { $0.runner.cancel() }
        }
    }
    static func cancelAllSequences() {
        Array(holds.values).forEach { $0.cancel() }; holds.removeAll()
        let active = Array(sequences.values)
        active.forEach { $0.context.cancelled = true }
        active.forEach { $0.runner.cancel() }
    }
    /// Physical inputs enter here; editor tests and Named Trigger calls never start a hold loop.
    static func fire(triggerID: UUID, fallbackActions: [TriggerAction], fromTrackpad: Bool = false,
                     isHeld: (() -> Bool)? = nil) {
        let trigger = registeredTriggers.first { $0.id == triggerID }
        let startApp = externalBundleID
        let startModifiers = NSEvent.modifierFlags.rawValue & TriggerResolver.modifierMask
        let run: (@escaping (Bool) -> Void) -> Void = { done in
            executeActions(trigger?.actions ?? fallbackActions, fromTrackpad: fromTrackpad, triggerID: triggerID, completion: done)
        }
        guard let trigger, trigger.repeatWhileHeld, trigger.supportsHold, let isHeld else {
            run { _ in }; return
        }
        guard holds[triggerID] == nil, holds.count < 16 else { return }
        let repeater = HoldRepeater(delayMs: trigger.holdDelayMs, intervalMs: trigger.holdIntervalMs,
            isHeld: {
                isHeld() && externalBundleID == startApp &&
                NSEvent.modifierFlags.rawValue & TriggerResolver.modifierMask == startModifiers &&
                (UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true)
            }, perform: run)
        holds[triggerID] = repeater
        repeater.start { holds.removeValue(forKey: triggerID); cancelSequence(triggerID) }
    }
    static func executeActions(_ actions: [TriggerAction], fromTrackpad: Bool = false,
                               triggerID: UUID? = nil, completion: ((Bool) -> Void)? = nil) {
        let id = triggerID ?? UUID()
        execute(actions, fromTrackpad: fromTrackpad, triggerID: id, context: ExecutionContext(), path: [id], completion: completion)
    }
    private static func execute(_ actions: [TriggerAction], fromTrackpad: Bool, triggerID: UUID,
                                context: ExecutionContext, path: [UUID], completion: ((Bool) -> Void)?) {
        guard !context.cancelled, context.remainingCalls > 0, path.count <= 16 else { completion?(false); return }
        context.remainingCalls -= 1
        let policy = registeredTriggers.first { $0.id == triggerID }?.executionPolicy ?? .ignoreWhileRunning
        let active = sequences.values.filter { $0.triggerID == triggerID }
        if !active.isEmpty {
            switch policy {
            case .ignoreWhileRunning: completion?(false); return
            case .restart: cancelInvocations(triggerID)
            case .parallel: guard active.count < 4 else { completion?(false); return }
            }
        }
        guard sequences.count < 32 else { completion?(false); return }
        if let problem = ActionTree.problem(actions) {
            GestureLog.shared.logFromAnyThread(problem, level: .error); completion?(false); return
        }
        let key = UUID() // Invocation identity prevents old completions removing a replacement run.
        let target = onActionExecuted == nil && ActionTree.rows(actions).contains { $0.action.actionType.category == .windowManagement }
            ? executionWindow() : nil
        let runner = ActionSequenceRunner(perform: { action, done in
            guard !context.cancelled else { done(false); return }
            if action.actionType == .triggerNamedTrigger {
                let name = action.parameters.namedTriggerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let candidates = TriggerResolver.resolve(registeredTriggers, payload: name, frontBundleID: externalBundleID,
                    payloadOf: { if case .namedTrigger(let name) = $0.input { return name.trimmingCharacters(in: .whitespacesAndNewlines) }; return nil },
                    appBundleIDOf: { $0.appBundleID }, groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
                guard !name.isEmpty, candidates.count == 1, let named = candidates.first,
                      !path.contains(named.id), path.count < 16 else {
                    GestureLog.shared.logFromAnyThread("Named Trigger missing, ambiguous, or recursive", level: .error)
                    done(false); return
                }
                execute(named.actions, fromTrackpad: fromTrackpad, triggerID: named.id, context: context, path: path + [named.id], completion: done)
                return
            }
            if action.actionType == .setVariable {
                let name = action.parameters.variableName ?? ""
                let value = action.parameters.variableValue ?? ""
                let ok = WorkflowVariables.set(name, value: value)
                if ok { onActionExecuted?(action) }
                done(ok)
                return
            }
            let selected = action.parameters.useCurrentWindow == true ? executionWindow() : target
            if onActionExecuted == nil, action.actionType.category == .windowManagement,
               ![ActionType.undoWindowPlacement, .saveWindowLayout, .restoreWindowLayout].contains(action.actionType), selected == nil {
                GestureLog.shared.logFromAnyThread("No accessible window for this step", level: .error); done(false); return
            }
            executeAction(action, windowTarget: selected, fromTrackpad: fromTrackpad, completion: done)
        }, matches: { action in
            let p = action.parameters
            let app = NSWorkspace.shared.frontmostApplication
            let bundleID = app?.bundleIdentifier ?? ""
            var title = ""
            if (!(p.windowTitleContains ?? "").isEmpty || !(p.windowTitleRegex ?? "").isEmpty), let pid = app?.processIdentifier {
                let root = AXUIElementCreateApplication(pid); var window: CFTypeRef?; var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success,
                   let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value)
                    title = value as? String ?? ""
                }
            }
            let needsSystem = p.minimumBatteryPercent != nil || p.maximumBatteryPercent != nil || p.powerSource != nil || p.minimumDisplayCount != nil || p.maximumDisplayCount != nil
            return ActionSequenceRunner.matches(action, bundleID: bundleID, windowTitle: title, system: needsSystem ? SystemConditions.current() : nil)
        }, branchMatches: { action in
            let p = action.parameters
            let app = NSWorkspace.shared.frontmostApplication
            let kind = p.conditionKind ?? "variable"
            var title = ""
            if kind == "window", let pid = app?.processIdentifier {
                let root = AXUIElementCreateApplication(pid)
                var window: CFTypeRef?; var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success,
                   let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value)
                    title = value as? String ?? ""
                }
            }
            let location = WorkflowBranchCondition.cursorFraction()
            return WorkflowBranchCondition.matches(p, app: app?.bundleIdentifier ?? "", title: title,
                mouseX: location.x, mouseY: location.y, variable: { WorkflowVariables.value($0) })
        })
        sequences[key] = Invocation(triggerID: triggerID, context: context, runner: runner)
        runner.run(actions) { ok in sequences.removeValue(forKey: key); completion?(ok) }
    }

    // MARK: - Force quit

    /// One candidate for force-quitting. Kept as a plain value so the target
    /// rule below can be tested without launching or killing anything.
    struct ForceQuitCandidate: Equatable {
        let pid: pid_t
        let bundleID: String?
    }

    /// Which processes to SIGKILL, given the running apps, the configured
    /// target, the frontmost app and this process's own identity.
    ///
    /// Extracted from the executor so the two rules that matter can be tested
    /// directly: an empty target means "the frontmost app", and this process is
    /// never among the results. Getting the second one wrong kills the gesture
    /// engine from inside itself.
    static func forceQuitTargets(
        candidates: [ForceQuitCandidate],
        configuredBundleID: String?,
        frontmostBundleID: String?,
        ownPID: pid_t,
        ownBundleID: String?
    ) -> [ForceQuitCandidate] {
        let selected: [ForceQuitCandidate]
        if let configuredBundleID, !configuredBundleID.isEmpty {
            selected = candidates.filter { $0.bundleID == configuredBundleID }
        } else if let frontmostBundleID {
            selected = candidates.filter { $0.bundleID == frontmostBundleID }
        } else {
            selected = []
        }
        return selected.filter { $0.pid != ownPID && $0.bundleID != ownBundleID }
    }

    /// SIGKILL the configured app, or the frontmost one when nothing is named.
    ///
    /// SIGKILL rather than terminate(): terminate() is the polite request
    /// `quitApplication` already sends, and a hung app ignores it. This is the
    /// gesture you reach for when something has stopped responding.
    private static func forceQuit(bundleID: String?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier

        let running = NSWorkspace.shared.runningApplications
        let candidates = running.map {
            ForceQuitCandidate(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let targets = forceQuitTargets(
            candidates: candidates,
            configuredBundleID: bundleID,
            frontmostBundleID: frontmost,
            ownPID: ownPID,
            ownBundleID: ownBundleID
        )

        for target in targets {
            let name = running.first { $0.processIdentifier == target.pid }?.localizedName ?? "?"
            GestureLog.shared.logFromAnyThread(
                "forceQuit: SIGKILL \(name) (pid \(target.pid))",
                level: .action
            )
            kill(target.pid, SIGKILL)
        }
    }

    static func executeAction(_ action: TriggerAction) {
        executeActions([action])
    }

    private static func executeAction(_ action: TriggerAction, windowTarget: WindowManager.Target?, fromTrackpad: Bool = false,
                                      completion: @escaping (Bool) -> Void) {
        NSLog("[ActionExecutor] Executing: %@", action.actionType.rawValue)
        GestureLog.shared.logFromAnyThread("Executing: \(action.actionType.rawValue)\(actionDetail(action))", level: .action)

        // If test hook is set, call it and return
        if let hook = onActionExecuted {
            hook(action)
            completion(true)
            return
        }

        if action.actionType == .sendKeyStroke, action.parameters.shortcutKeyCode == nil {
            GestureLog.shared.logFromAnyThread("Record a keyboard shortcut before running this step", level: .error)
            completion(false); return
        }
        if action.actionType == .toggleDoNotDisturb {
            GestureLog.shared.logFromAnyThread("Do Not Disturb is not implemented; use a configured shortcut or script", level: .error)
            completion(false); return
        }
        if action.actionType == .openURL {
            guard let text = action.parameters.url, let url = URL(string: text), url.scheme != nil else { completion(false); return }
            completion(NSWorkspace.shared.open(url)); return
        }
        if [.runShellScript, .runAppleScript].contains(action.actionType) {
            ScriptRunnerClient.shared.run(kind: action.actionType == .runShellScript ? "shell" : "applescript",
                source: action.parameters.scriptContent ?? "", timeout: action.parameters.scriptTimeoutSeconds ?? 30) { code, _, timedOut in
                    GestureLog.shared.logFromAnyThread(timedOut ? "Script timed out" : "Script completed (exit \(code))", level: code == 0 && !timedOut ? .action : .error)
                    completion(code == 0 && !timedOut)
                }
            return
        }
        if action.actionType.category == .windowManagement {
            WindowManager.shared.execute(action.actionType, target: windowTarget,
                parameters: action.parameters, completion: completion)
            return
        }
        if action.actionType == .setSoundOutput {
            AudioOutputService.shared.select(name: action.parameters.audioOutputName ?? "",
                uid: action.parameters.audioOutputUID, completion: completion)
            return
        }
        if Self.mouseActionTypes.contains(action.actionType) {
            performMouseAction(action, completion: completion)
            return
        }
        if action.actionType == .activateApplication || action.actionType == .launchApplication {
            activateApplication(action.parameters, completion: completion)
            return
        }
        if action.actionType == .typeText {
            typeText(action.parameters.text ?? "", completion: completion)
            return
        }
        if action.actionType == .volumeUp || action.actionType == .volumeDown {
            let step = action.parameters.volumeStepPercent ?? 6
            guard step.isFinite, step > 0, step <= 100 else { completion(false); return }
            AudioOutputService.shared.adjustVolume(percentagePoints: action.actionType == .volumeUp ? step : -step, completion: completion)
            return
        }
        defer { completion(true) }
        switch action.actionType {
        case .showHUD:
            let text = action.parameters.hudText ?? action.displayName
            if Thread.isMainThread { GestureHUD.shared.show(text) }
            else { DispatchQueue.main.async { GestureHUD.shared.show(text) } }
        case .showCheatSheet:
            if Thread.isMainThread { GestureHUD.shared.toggleCheatSheet() }
            else { DispatchQueue.main.async { GestureHUD.shared.toggleCheatSheet() } }
        case .triggerNamedTrigger: break // Dispatched with the caller's recursion and cancellation context.
        case .actionGroup, .ifElse, .wait: break // Handled by ActionSequenceRunner.
        case .setVariable: break // Handled before the test hook by workflow execution.
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight,
             .snapWindowTopLeft, .snapWindowTopRight, .snapWindowBottomLeft, .snapWindowBottomRight,
             .centerWindow, .moveWindowNextMonitor, .moveWindowPreviousMonitor,
             .moveWindowNextMonitorAndMaximize, .restoreWindowSize, .customSnapWindow, .undoWindowPlacement, .saveWindowLayout, .restoreWindowLayout, .setSoundOutput,
             .snapWindowLeftThird, .snapWindowCenterThird, .snapWindowRightThird,
             .snapWindowLeftTwoThirds, .snapWindowRightTwoThirds,
             .snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
             .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth,
             .moveWindowLeft, .moveWindowRight, .moveWindowUp, .moveWindowDown,
             .bringWindowToFront, .maximizeWindowUnderCursor, .minimizeWindowUnderCursor, .closeWindowUnderCursor:
            break // Completed above; these actions must finish before the next step.

        // Mouse & Trackpad: all completed above, like the window actions.
        case .leftClick, .rightClick, .middleClick, .doubleLeftClick, .commandLeftClick,
             .moveMouseToPosition, .saveMousePosition, .restoreMousePosition,
             .startDrag, .stopDrag, .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            break

        // Keyboard
        case .sendKeyStroke:
            if let keyCode = action.parameters.shortcutKeyCode {
                let flags = NSEvent.ModifierFlags(rawValue: action.parameters.shortcutModifiers ?? 0)
                sendKeyStroke(keyCode: keyCode, flags: flags)
            }
        case .typeText, .activateApplication:
            break // Completed asynchronously above.

        // Application Control
        case .launchApplication:
            if let path = action.parameters.applicationPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else if let name = action.parameters.applicationName {
                NSWorkspace.shared.launchApplication(name)
            }
        case .quitApplication:
            if let name = action.parameters.applicationName {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: name)
                apps.forEach { $0.terminate() }
            }
        case .forceQuitApplication:
            forceQuit(bundleID: action.parameters.applicationName)
        case .hideApplication:
            if let name = action.parameters.applicationName {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: name)
                apps.forEach { $0.hide() }
            }
        case .toggleApplication:
            if let name = action.parameters.applicationName {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: name)
                if let app = apps.first {
                    if app.isHidden { app.unhide() } else { app.hide() }
                } else {
                    NSWorkspace.shared.launchApplication(name)
                }
            }

        // System Actions
        case .sleepComputer:
            let task = Process()
            task.launchPath = "/usr/bin/pmset"
            task.arguments = ["sleepnow"]
            try? task.run()
        case .lockScreen:
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "/System/Library/CoreServices/ScreenSaverEngine.app"]
            try? task.run()
        case .toggleDarkMode:
            // Toggled through Appearance directly rather than via AppleScript's
            // System Events: driving another app over Apple Events needs the
            // Automation grant, which macOS prompts for and which a rebuild
            // invalidates.
            let wasDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSApp.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
        case .toggleDoNotDisturb:
            break
        case .volumeUp, .volumeDown:
            break // Absolute percentage-point adjustment completed above.
        case .muteVolume:
            sendMediaKey(keyCode: NX_KEYTYPE_MUTE)
        case .brightnessUp:
            sendMediaKey(keyCode: NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown:
            sendMediaKey(keyCode: NX_KEYTYPE_BRIGHTNESS_DOWN)

        // Script Execution
        case .runAppleScript:
            if let script = action.parameters.scriptContent {
                runAppleScript(script)
            }
        case .runShellScript:
            if let script = action.parameters.scriptContent {
                runShellScript(script)
            }
        case .openURL:
            if let urlString = action.parameters.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }

        // Media Controls
        case .playPause:
            sendMediaKey(keyCode: NX_KEYTYPE_PLAY)
        case .nextTrack:
            sendMediaKey(keyCode: NX_KEYTYPE_NEXT)
        case .previousTrack:
            sendMediaKey(keyCode: NX_KEYTYPE_PREVIOUS)

        // Screen Capture. Every one of these is MainActor work because they end
        // in AppKit UI; the coordinator owns the async capture path itself, so
        // this dispatch is fire-and-forget and never blocks the action sequence.
        case .captureArea:
            onMain { CaptureCoordinator.shared.captureArea() }
        case .captureFullscreen:
            onMain { CaptureCoordinator.shared.captureFullscreen() }
        case .captureWindow:
            onMain { CaptureCoordinator.shared.captureWindowFromPicker() }
        case .captureWindowUnderCursor:
            onMain { CaptureCoordinator.shared.captureWindowUnderCursor() }
        case .recordScreen:
            onMain { ScreenRecordingService.shared.toggleRecording() }
        case .capturePreviousArea:
            onMain { CaptureCoordinator.shared.capturePreviousArea() }
        case .captureScrolling:
            onMain { CaptureCoordinator.shared.captureScrolling() }
        case .captureText:
            onMain { CaptureCoordinator.shared.captureText() }
        case .captureTextWithLineBreaks:
            onMain { CaptureCoordinator.shared.captureText(keepsLineBreaks: true) }
        case .captureTextWithoutLineBreaks:
            onMain { CaptureCoordinator.shared.captureText(keepsLineBreaks: false) }
        case .captureAllDisplays:
            onMain { CaptureCoordinator.shared.captureAllDisplays() }
        case .captureSelfTimer:
            let seconds = action.parameters.selfTimerSeconds ?? 5
            onMain { CaptureCoordinator.shared.captureWithSelfTimer(seconds: seconds) }
        case .annotateLastCapture:
            onMain { AnnotationEditorController.shared.openMostRecent() }
        case .pinLastCapture:
            onMain { CaptureActions.pinLastCapture() }
        case .copyLastCapture:
            onMain { CaptureActions.copyLastCapture() }
        case .saveLastCapture:
            onMain { CaptureActions.saveLastCapture() }
        case .ocrLastCapture:
            onMain { CaptureActions.copyTextFromLastCapture() }
        case .openCaptureHistory:
            onMain { CaptureHistoryWindowController.shared.present() }
        case .unpinAllCaptures:
            onMain { PinnedScreenshotController.shared.unpinAll() }
        case .showClipboardHistory:
            onMain { ClipboardPanelController.shared.show() }
        case .showPasteStack:
            onMain { ClipboardPanelController.shared.showStack() }
        case .pasteNextClipboardItem:
            onMain { ClipboardPanelController.shared.pasteNext() }
        case .toggleClipboardRecording:
            onMain { ClipboardStore.shared.paused.toggle() }
        case .toggleCaptureOverlay:
            onMain { CaptureSettings.overlayEnabled.toggle() }
        }
    }

    /// Runs `work` on the main actor from whatever thread the executor is on.
    ///
    /// The capture path is main-actor isolated, but actions can be dispatched
    /// from an event tap thread, so every capture case hops rather than assuming.
    private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    // MARK: - Key Stroke Sending (tries multiple strategies)

    // MARK: - Mouse & Trackpad

    static let mouseActionTypes: Set<ActionType> = [
        .leftClick, .rightClick, .middleClick, .doubleLeftClick, .commandLeftClick,
        .moveMouseToPosition, .saveMousePosition, .restoreMousePosition,
        .startDrag, .stopDrag, .scrollUp, .scrollDown, .scrollLeft, .scrollRight]

    /// Synthesises pointer events at the session tap, the same source the
    /// keyboard path uses. Coordinates are normalized to the visible frame of
    /// the pointer's display so a saved position survives a resolution change.
    private static func performMouseAction(_ action: TriggerAction, completion: @escaping (Bool) -> Void) {
        let source = CGEventSource(stateID: .hidSystemState)
        let type = action.actionType
        let point = CGEvent(source: nil)?.location ?? .zero

        func post(_ event: CGEvent?) -> Bool {
            guard let event else { return false }
            event.post(tap: .cgSessionEventTap)
            return true
        }
        func click(_ button: CGMouseButton, count: Int64, flags: CGEventFlags = []) {
            let down = CGEvent(mouseEventSource: source, mouseType: button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown),
                               mouseCursorPosition: point, mouseButton: button)
            let up = CGEvent(mouseEventSource: source, mouseType: button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp),
                             mouseCursorPosition: point, mouseButton: button)
            if !flags.isEmpty { down?.flags = flags; up?.flags = flags }
            down?.setIntegerValueField(.mouseEventClickState, value: count)
            up?.setIntegerValueField(.mouseEventClickState, value: count)
            let ok = post(down) && post(up)
            if count > 1 { post(down); post(up) }
            completion(ok)
        }

        switch type {
        case .leftClick: click(.left, count: 1)
        case .doubleLeftClick: click(.left, count: 2)
        case .rightClick: click(.right, count: 1)
        case .middleClick: click(.center, count: 1)
        case .commandLeftClick: click(.left, count: 1, flags: .maskCommand)
        case .moveMouseToPosition:
            guard let x = action.parameters.mouseX, let y = action.parameters.mouseY,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                completion(false); return
            }
            let visible = pointerVisibleFrame(at: point)
            // y is measured from the top so it reads like the snap zones.
            let target = globalPoint(normalized: CGPoint(x: x, y: y), in: visible)
            let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: target, mouseButton: .left)
            completion(post(move))
        case .saveMousePosition:
            guard let normalized = normalizedPoint(point, in: pointerVisibleFrame(at: point)) else {
                completion(false); return
            }
            savedMousePosition = normalized
            completion(true)
        case .restoreMousePosition:
            guard let saved = savedMousePosition else { completion(false); return }
            let target = globalPoint(normalized: saved, in: pointerVisibleFrame(at: point))
            completion(post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: target, mouseButton: .left)))
        case .startDrag, .stopDrag:
            let dragging = type == .startDrag
            completion(post(CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDown : .leftMouseUp,
                                    mouseCursorPosition: point, mouseButton: .left)))
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            let amount = action.parameters.scrollAmount ?? 3
            guard amount != 0 else { completion(false); return }
            let step = Int32(amount)
            let vertical: Int32 = type == .scrollUp ? step : (type == .scrollDown ? -step : 0)
            let horizontal: Int32 = type == .scrollLeft ? -step : (type == .scrollRight ? step : 0)
            completion(post(CGEvent(scrollWheelEvent2Source: source, units: .line,
                                    wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)))
        default:
            completion(false)
        }
    }

    /// Normalized to the pointer display's visible frame; nil until saved.
    private static var savedMousePosition: CGPoint?

    /// The display whose visible area contains the point, falling back to the
    /// main display. `NSScreen.frame` and CG event coordinates share the same
    /// space (origin at the primary display's top-left, y increasing downward),
    /// so no axis flip is needed here.
    private static func pointerVisibleFrame(at point: CGPoint) -> CGRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
    }

    /// Converts a normalized position (y from the top, as the snap zones use)
    /// into the CG coordinate the event system expects.
    private static func globalPoint(normalized: CGPoint, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.minX + visible.width * normalized.x,
                y: visible.minY + visible.height * normalized.y)
    }

    /// Inverse of `globalPoint`. Both screens are required: the display the
    /// point is on decides the frame, so a cursor parked on the built-in
    /// display is normalized against the built-in display's visible area.
    private static func normalizedPoint(_ point: CGPoint, in visible: CGRect) -> CGPoint? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        return CGPoint(x: (point.x - visible.minX) / visible.width,
                       y: (point.y - visible.minY) / visible.height)
    }

    private static func sendKeyStroke(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        GestureLog.shared.logFromAnyThread("sendKeyStroke keyCode=\(keyCode) mods=\(flags.rawValue)", level: .action)

        sendViaCGEvent(keyCode: keyCode, flags: flags, tapPoint: .cgSessionEventTap, label: "cgSessionEventTap")
    }

    private static func sendViaCGEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags, tapPoint: CGEventTapLocation, label: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            GestureLog.shared.logFromAnyThread("CGEvent[\(label)] creation failed", level: .error)
            return
        }

        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.function) { cgFlags.insert(.maskSecondaryFn) }

        // Add fn flag for function keys (F1-F15) — required on Mac laptops
        let fnKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]
        if fnKeyCodes.contains(keyCode) {
            cgFlags.insert(.maskSecondaryFn)
        }

        keyDown.flags = cgFlags
        keyUp.flags = cgFlags

        // Tag events so our own CGEventTap in KeyboardMonitor skips them
        let selfTag = Int64(0x475454) // "AOM"
        keyDown.setIntegerValueField(.eventSourceUserData, value: selfTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: selfTag)

        // Do not steal focus from AOM; CGEvent targets the real active app.
        // Generated events retain the AOM tag above to prevent recursive triggers.
        keyDown.post(tap: tapPoint)
        usleep(20000)
        keyUp.post(tap: tapPoint)
        NSLog("[ActionExecutor] CGEvent[%@] posted keyCode=%d flags=%llu front=%@",
              label, keyCode, cgFlags.rawValue,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
        GestureLog.shared.logFromAnyThread("CGEvent[\(label)] posted keyCode=\(keyCode)", level: .fire)
    }

    private static func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        let mapping: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "n", 46: "m", 47: ".", 49: " "
        ]
        return mapping[keyCode]
    }

    // MARK: - Other helpers

    private static func activateApplication(_ parameters: ActionParameters, completion: @escaping (Bool) -> Void) {
        let url = parameters.applicationPath.map { URL(fileURLWithPath: $0) }
            ?? parameters.applicationName.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                    ?? NSWorkspace.shared.fullPath(forApplication: $0).map { URL(fileURLWithPath: $0) }
            }
        guard let url, let bundleID = Bundle(url: url)?.bundleIdentifier else {
            GestureLog.shared.logFromAnyThread("Application not found", level: .error); completion(false); return
        }
        func activate(_ app: NSRunningApplication) {
            app.unhide()
            guard app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else { completion(false); return }
            func verify(_ left: Int) {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { completion(true) }
                else if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { verify(left - 1) } }
                else {
                    GestureLog.shared.logFromAnyThread("Application activation timed out", level: .error)
                    completion(false)
                }
            }
            verify(40)
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // Activate existing windows without sending a reopen event.
            activate(app)
        } else {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                DispatchQueue.main.async {
                    if let app { activate(app) }
                    else { GestureLog.shared.logFromAnyThread("Application launch failed: \(error?.localizedDescription ?? "unknown")", level: .error); completion(false) }
                }
            }
        }
    }

    /// Bounded Unicode payloads keep surrogate pairs intact, including emoji.
    static func textChunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []; var current: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > 20 { chunks.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func textEvents(_ units: [UInt16]) -> (CGEvent, CGEvent)? {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        }
        return (down, up)
    }

    private static func typeText(_ text: String, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { completion(true); return }
        let front = NSWorkspace.shared.frontmostApplication
        guard let target = front, !target.isTerminated else { completion(false); return }
        if front?.processIdentifier != target.processIdentifier { target.activate(options: .activateIgnoringOtherApps) }
        let chunks = textChunks(text)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        func begin() {
            // Wait without blocking the event tap until the invoking hotkey is released.
            let held = CGEventSource.flagsState(.combinedSessionState).intersection(shortcutFlags)
            guard held.isEmpty else {
                if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: begin) }
                else { GestureLog.shared.logFromAnyThread("Text input cancelled: release modifier keys", level: .error); completion(false) }
                return
            }
            func post(_ index: Int) {
                guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    GestureLog.shared.logFromAnyThread("Text input cancelled: focused application changed", level: .error); completion(false); return
                }
                guard index < chunks.count else { completion(true); return }
                guard let (down, up) = textEvents(chunks[index]) else { completion(false); return }
                down.postToPid(target.processIdentifier); up.postToPid(target.processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { post(index + 1) }
            }
            post(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: begin)
    }

    private static func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[ActionExecutor] AppleScript error: %@", "\(error)")
                }
            }
        }
    }

    private static func runShellScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            try? task.run()
            task.waitUntilExit()
        }
    }

    private static func sendMediaKey(keyCode: Int32) {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        func doKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: (down ? 0xa00 : 0xb00))
            let data1 = Int((keyCode << 16) | (down ? 0xa00 : 0xb00))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        doKey(down: true)
        doKey(down: false)
    }

    private static func actionDetail(_ action: TriggerAction) -> String {
        let p = action.parameters
        switch action.actionType {
        case .sendKeyStroke:
            guard let keyCode = p.shortcutKeyCode else { return "" }
            var parts: [String] = []
            let mods = NSEvent.ModifierFlags(rawValue: p.shortcutModifiers ?? 0)
            if mods.contains(.command) { parts.append("⌘") }
            if mods.contains(.option) { parts.append("⌥") }
            if mods.contains(.shift) { parts.append("⇧") }
            if mods.contains(.control) { parts.append("⌃") }
            let key = keyCodeToCharacter(keyCode)?.uppercased() ?? "key\(keyCode)"
            parts.append(key)
            return " [\(parts.joined())]"
        case .typeText:
            if let text = p.text { return " [\(text.count) characters]" }
            return ""
        case .activateApplication, .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
            return " [\(p.applicationName ?? p.applicationPath ?? "frontmost")]"
        case .runAppleScript, .runShellScript:
            if let s = p.scriptContent { return " [\(s.utf8.count) bytes]" }
            return ""
        case .openURL:
            if let u = p.url { return " [\(u.prefix(40))]" }
            return ""
        default:
            return ""
        }
    }
}

/// Bounded, asynchronous ordered runner; delays never block the contact run loop.
final class ActionSequenceRunner {
    typealias Perform = (TriggerAction, @escaping (Bool) -> Void) -> Void
    private let perform: Perform
    private let matches: (TriggerAction) -> Bool
    private let branchMatches: (TriggerAction) -> Bool
    private var cancelled = false
    private var finish: ((Bool) -> Void)?
    init(perform: @escaping Perform, matches: @escaping (TriggerAction) -> Bool = { _ in true },
         branchMatches: @escaping (TriggerAction) -> Bool = { _ in false }) {
        self.perform = perform; self.matches = matches; self.branchMatches = branchMatches
    }
    static func matches(_ action: TriggerAction, bundleID: String, windowTitle: String, system: SystemConditions? = nil) -> Bool {
        let app = action.parameters.onlyAppBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = action.parameters.windowTitleContains ?? ""
        let regex = action.parameters.windowTitleRegex ?? ""
        let regexMatches: Bool
        if regex.isEmpty { regexMatches = true }
        else if regex.count > 256 { regexMatches = false }
        else if let expression = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) {
            let text = String(windowTitle.prefix(1024))
            regexMatches = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        } else { regexMatches = false }
        return (app.isEmpty || app == bundleID) && (title.isEmpty || windowTitle.localizedCaseInsensitiveContains(title)) && regexMatches && SystemConditions.matches(action.parameters, snapshot: system)
    }
    func cancel() { cancelled = true; complete(false) }
    private func complete(_ ok: Bool) { let callback = finish; finish = nil; callback?(ok) }
    func run(_ actions: [TriggerAction], completion: @escaping (Bool) -> Void) {
        guard ActionTree.problem(actions) == nil else { completion(false); return }
        finish = completion
        sequence(actions, index: 0) { [weak self] ok in self?.complete(ok) }
    }
    private func later(_ ms: Int, _ body: @escaping () -> Void) {
        if ms == 0 { if !cancelled { body() }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000) { [weak self] in
            if self?.cancelled == false { body() }
        }
    }
    private func sequence(_ actions: [TriggerAction], index: Int, completion: @escaping (Bool) -> Void) {
        guard !cancelled else { return }
        guard actions.indices.contains(index) else { completion(true); return }
        let action = actions[index]
        guard action.isEnabled else { sequence(actions, index: index + 1, completion: completion); return }
        later(action.parameters.delayBeforeMs ?? 0) {
            // Conditions are evaluated at execution time, after the requested delay.
            guard self.matches(action) else { self.sequence(actions, index: index + 1, completion: completion); return }
            self.iteration(action, remaining: action.parameters.repeatCount ?? 1) { ok in
                guard ok || action.parameters.continueOnFailure == true else { completion(false); return }
                self.later(action.parameters.delayAfterMs ?? 0) {
                    self.sequence(actions, index: index + 1, completion: completion)
                }
            }
        }
    }
    private func iteration(_ action: TriggerAction, remaining: Int, completion: @escaping (Bool) -> Void) {
        guard !cancelled else { return }
        var replied = false
        let done: (Bool) -> Void = { ok in
            guard !replied, !self.cancelled else { return }; replied = true
            guard ok else { completion(false); return }
            guard remaining > 1 else { completion(true); return }
            // Yield even for a zero interval to avoid deep synchronous recursion.
            DispatchQueue.main.async {
                self.later(action.parameters.repeatIntervalMs ?? 0) { self.iteration(action, remaining: remaining - 1, completion: completion) }
            }
        }
        if action.actionType == .actionGroup {
            sequence(action.parameters.children ?? [], index: 0, completion: done)
        } else if action.actionType == .ifElse {
            let branch = branchMatches(action) ? action.parameters.children : action.parameters.elseChildren
            sequence(branch ?? [], index: 0, completion: done)
        } else if action.actionType == .wait {
            later(action.parameters.waitMs ?? 250) { done(true) }
        } else { perform(action, done) }
    }
}
