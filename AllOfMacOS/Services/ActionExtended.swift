import AppKit
import AVFoundation
import UserNotifications

/// Asks before a destructive action. The presenter is replaceable so tests never
/// open a real alert.
enum ActionConfirmation {
    typealias Presenter = (_ title: String, _ message: String, _ confirmTitle: String, _ answer: @escaping (Bool) -> Void) -> Void
    static var presenter: Presenter = defaultPresenter
    static let defaultPresenter: Presenter = { title, message, confirmTitle, answer in
        let show = {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }

    static func wording(for type: ActionType) -> (title: String, message: String, confirm: String) {
        switch type {
        case .emptyTrash: return ("Empty the Trash?", "Everything in the Trash will be permanently deleted. This cannot be undone.", "Empty Trash")
        case .logOut: return ("Log out now?", "Apps will be asked to quit and you will be logged out.", "Log Out")
        case .forceQuitApplication: return ("Force quit?", "The app is killed immediately and unsaved work is lost.", "Force Quit")
        default: return ("Run \(type.rawValue)?", "This action cannot be undone.", "Run")
        }
    }

    static func confirm(_ type: ActionType, answer: @escaping (Bool) -> Void) {
        let words = wording(for: type)
        presenter(words.title, words.message, words.confirm, answer)
    }
}

/// Actions added for BetterTouchTool parity that are not window-geometry or
/// control-flow: spaces, input synthesis, system utilities. Each runs through
/// `ActionExecutor`, which skips this type entirely when a test hook is set.
enum ExtendedActions {
    static let handled: Set<ActionType> = [
        .switchSpaceLeft, .switchSpaceRight, .switchToDesktop, .moveWindowToPreviousSpace, .moveWindowToNextSpace,
        .missionControl, .appExpose, .launchpad, .showDesktop, .hideOtherApps,
        .ctrlLeftClick, .optionLeftClick, .shiftLeftClick, .cmdDoubleClick, .customClick, .scrollCustom, .moveMouseRelative,
        .pasteString, .pressFunctionKey, .modifierKeyDown, .modifierKeyUp, .allModifiersUp, .toggleCapsLock,
        .pressPageUp, .pressPageDown, .pressHome, .pressEnd, .pressArrowKey, .pressContextMenuKey,
        .startScreenSaver, .emptyTrash, .sleepDisplay, .logOut, .toggleHiddenFiles, .openNotificationCenter,
        .openControlCenter, .setVolume, .setBrightness, .toggleMuteMicrophone, .startDictation,
        .playSoundFile, .speakText, .showNotification, .copyTextToClipboard, .openFileOrFolder, .revealInFinder,
        .runAppleShortcut, .runJavaScript, .matchScreenImage]

    static func handles(_ type: ActionType) -> Bool { handled.contains(type) }

    private static var heldModifiers = Set<String>()
    /// Release only keys AOM pressed when stopping all workflows or quitting.
    static func releaseHeldModifiers() {
        for name in heldModifiers.sorted() {
            heldModifiers.remove(name)
            _ = SyntheticInput.modifier(name, down: false, held: heldModifiers)
        }
    }
    private static var sounds: [NSSound] = []
    private static let synthesizer = AVSpeechSynthesizer()

    private static func log(_ message: String, error: Bool = true) {
        GestureLog.shared.logFromAnyThread(message, level: error ? .error : .action)
    }
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    static func perform(_ action: TriggerAction, isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void) {
        let p = action.parameters
        switch action.actionType {
        case .matchScreenImage: ImageTemplateAutomation.perform(action, isCancelled: isCancelled, completion: completion)
        // MARK: Spaces & Mission Control
        case .switchSpaceLeft: postHotKey(SymbolicHotKeys.spaceLeft, completion)
        case .switchSpaceRight: postHotKey(SymbolicHotKeys.spaceRight, completion)
        case .switchToDesktop:
            let number = p.desktopNumber ?? 1
            guard (1...9).contains(number) else { completion(false); return }
            postHotKey(SymbolicHotKeys.desktop(number), completion)
        case .moveWindowToPreviousSpace: moveWindowToSpace(next: false, completion)
        case .moveWindowToNextSpace: moveWindowToSpace(next: true, completion)
        case .missionControl: openSystemApp(["/System/Applications/Mission Control.app"], completion)
        case .appExpose: postHotKey(SymbolicHotKeys.appWindows, completion)
        case .launchpad: openSystemApp(["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"], completion)
        case .showDesktop: postHotKey(SymbolicHotKeys.showDesktop, completion)
        case .hideOtherApps:
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let own = ProcessInfo.processInfo.processIdentifier
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != front && app.processIdentifier != own && !app.isHidden {
                app.hide()
            }
            completion(true)

        // MARK: Mouse
        case .ctrlLeftClick, .optionLeftClick, .shiftLeftClick, .cmdDoubleClick:
            guard let preset = ClickPlan.presetClick(action.actionType) else { completion(false); return }
            click(button: 0, count: preset.count, flags: preset.flags, completion)
        case .customClick:
            click(button: p.clickButton ?? 0, count: p.clickCount ?? 1, flags: ClickPlan.flags(from: p.clickModifiers), completion)
        case .scrollCustom: scroll(p, isCancelled: isCancelled, completion)
        case .moveMouseRelative:
            let dx = p.mouseDeltaX ?? 0, dy = p.mouseDeltaY ?? 0
            guard dx.isFinite, dy.isFinite else { completion(false); return }
            let here = CGEvent(source: nil)?.location ?? .zero
            let bounds = DisplayGeometry.unionBounds()
            let target = CGPoint(x: min(max(here.x + dx, bounds.minX), bounds.maxX - 1),
                                 y: min(max(here.y + dy, bounds.minY), bounds.maxY - 1))
            let source = CGEventSource(stateID: .hidSystemState)
            completion(SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)))

        // MARK: Keyboard
        case .pasteString:
            let target = NSWorkspace.shared.frontmostApplication
            pasteString(p.text ?? "", press: {
                guard !isCancelled(), let target, !target.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return false }
                let source = CGEventSource(stateID: .privateState)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
                for event in [down, up] {
                    event.flags = .maskCommand
                    event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
                    event.postToPid(target.processIdentifier)
                }
                return true
            }, completion)
        case .pressFunctionKey:
            guard let code = KeyCodes.functionKey(p.functionKeyNumber ?? 1) else { completion(false); return }
            completion(SyntheticInput.key(code, flags: .maskSecondaryFn))
        case .modifierKeyDown, .modifierKeyUp:
            let name = p.modifierKey ?? "command"
            guard ModifierKeys.table[name] != nil else { completion(false); return }
            let down = action.actionType == .modifierKeyDown
            if down { heldModifiers.insert(name) } else { heldModifiers.remove(name) }
            completion(SyntheticInput.modifier(name, down: down, held: heldModifiers))
        case .allModifiersUp:
            var ok = true
            for name in heldModifiers.sorted() {
                heldModifiers.remove(name)
                ok = SyntheticInput.modifier(name, down: false, held: heldModifiers) && ok
            }
            // Also release modifiers the system thinks are down but AOM did not press.
            for name in ["command", "shift", "option", "control", "fn"] { _ = SyntheticInput.modifier(name, down: false, held: []) }
            completion(ok)
        case .toggleCapsLock: completion(SyntheticInput.toggleCapsLock())
        case .pressPageUp: completion(SyntheticInput.key(KeyCodes.pageUp, flags: .maskSecondaryFn))
        case .pressPageDown: completion(SyntheticInput.key(KeyCodes.pageDown, flags: .maskSecondaryFn))
        case .pressHome: completion(SyntheticInput.key(KeyCodes.home, flags: .maskSecondaryFn))
        case .pressEnd: completion(SyntheticInput.key(KeyCodes.end, flags: .maskSecondaryFn))
        case .pressContextMenuKey: completion(SyntheticInput.key(KeyCodes.contextMenu))
        case .pressArrowKey:
            guard let code = KeyCodes.arrows[p.arrowDirection ?? "down"] else { completion(false); return }
            let count = min(100, max(1, p.keyRepeatCount ?? 1))
            var ok = true
            for _ in 0..<count { ok = SyntheticInput.key(code, flags: [.maskSecondaryFn, .maskNonCoalesced]) && ok }
            completion(ok)

        // MARK: System
        case .startScreenSaver: openSystemApp(["/System/Library/CoreServices/ScreenSaverEngine.app"], completion)
        case .sleepDisplay: runProcess("/usr/bin/pmset", ["displaysleepnow"], completion)
        case .emptyTrash:
            runScript(kind: "applescript", source: "tell application \"Finder\" to empty trash", timeout: 60, completion)
        case .logOut:
            runScript(kind: "applescript", source: "tell application \"loginwindow\" to «event aevtrlgo»", timeout: 15, completion)
        case .toggleHiddenFiles: toggleHiddenFiles(completion)
        case .openNotificationCenter: completion(MenuBarExtras.press(.notificationCenter))
        case .openControlCenter: completion(MenuBarExtras.press(.controlCenter))
        case .setVolume:
            guard let level = p.levelPercent else { completion(false); return }
            AudioOutputService.shared.setVolume(percent: level, completion: completion)
        case .setBrightness:
            guard let level = p.levelPercent else { completion(false); return }
            completion(setBrightness(percent: level))
        case .toggleMuteMicrophone:
            guard let muted = AudioOutputService.toggleInputMute() else {
                log("The default microphone has no software mute switch"); completion(false); return
            }
            onMain { GestureHUD.shared.show(muted ? "Microphone muted" : "Microphone on") }
            completion(true)
        case .startDictation: startDictation(completion)

        // MARK: Utility
        case .playSoundFile: playSound(p, completion)
        case .speakText: speak(p, completion)
        case .showNotification: notify(title: p.notificationTitle ?? "AOM", body: p.text ?? p.hudText ?? "", completion)
        case .copyTextToClipboard:
            let text = p.text ?? ""
            guard text.utf8.count <= 1_048_576 else { completion(false); return }
            onMain {
                NSPasteboard.general.clearContents()
                completion(NSPasteboard.general.setString(text, forType: .string))
            }
        case .openFileOrFolder:
            guard let url = fileURL(p.filePath) else { log("File or folder not found"); completion(false); return }
            onMain { completion(NSWorkspace.shared.open(url)) }
        case .revealInFinder:
            guard let url = fileURL(p.filePath) else { log("File or folder not found"); completion(false); return }
            onMain { NSWorkspace.shared.activateFileViewerSelecting([url]); completion(true) }

        // MARK: Scripts (same XPC helper as AppleScript / shell)
        case .runAppleShortcut:
            let name = (p.shortcutName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, !name.contains("\0") else { log("Choose a shortcut name"); completion(false); return }
            runScript(kind: "shell", source: "/usr/bin/shortcuts run \(ShellQuote.single(name))", timeout: p.scriptTimeoutSeconds ?? 60, completion)
        case .runJavaScript:
            ScriptRunnerClient.shared.run(kind: "javascript", source: p.scriptContent ?? "", timeout: p.scriptTimeoutSeconds ?? 30) { code, output, timedOut in
                ScriptActionResults.record(name: p.scriptResultVariable, output: output, code: code, timedOut: timedOut)
                completion(code == 0 && !timedOut)
            }

        default: completion(false)
        }
    }

    // MARK: - Spaces

    /// Posts the user's own Mission Control shortcut. When it is switched off the
    /// action fails and, once, tells the user where to turn it on.
    static func postHotKey(_ id: Int, table: [String: Any]? = SymbolicHotKeys.load(),
                           defaults: UserDefaults = .standard, post: (UInt16, CGEventFlags) -> Bool = { SyntheticInput.key($0, flags: $1, tap: .cghidEventTap) },
                           _ completion: @escaping (Bool) -> Void) {
        guard let key = SymbolicHotKeys.hotKey(id: id, in: table) else { completion(false); return }
        guard key.isEnabled else {
            log("System shortcut #\(id) is off. \(SymbolicHotKeys.hintText(for: id))")
            if !defaults.bool(forKey: SymbolicHotKeys.hintShownKey) {
                defaults.set(true, forKey: SymbolicHotKeys.hintShownKey)
                onMain { GestureHUD.shared.show(title: "System shortcut is off", detail: SymbolicHotKeys.hintText(for: id)) }
            }
            completion(false); return
        }
        completion(post(key.keyCode, key.flags))
    }

    /// Grabs the window by its title bar, switches Space with the system shortcut,
    /// then lets go; macOS carries a held window along.
    private static func moveWindowToSpace(next: Bool, _ completion: @escaping (Bool) -> Void) {
        guard let target = WindowManager.shared.captureTarget(), let frame = WindowManager.shared.frame(of: target),
              frame.width > 120 else { log("No accessible window to move"); completion(false); return }
        let table = SymbolicHotKeys.load()
        let id = next ? SymbolicHotKeys.spaceRight : SymbolicHotKeys.spaceLeft
        guard let key = SymbolicHotKeys.hotKey(id: id, in: table), key.isEnabled else {
            postHotKey(id, table: table, completion); return
        }
        let origin = CGEvent(source: nil)?.location ?? .zero
        let grab = CGPoint(x: frame.midX, y: frame.minY + 10)
        let source = CGEventSource(stateID: .hidSystemState)
        SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: grab, mouseButton: .left), tap: .cghidEventTap)
        SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left), tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = SyntheticInput.key(key.keyCode, flags: key.flags, tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: grab, mouseButton: .left), tap: .cghidEventTap)
                SyntheticInput.post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left), tap: .cghidEventTap)
                completion(true)
            }
        }
    }

    private static func openSystemApp(_ paths: [String], _ completion: @escaping (Bool) -> Void) {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("System app not found"); completion(false); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    // MARK: - Mouse

    private static func click(button: Int, count: Int, flags: CGEventFlags, _ completion: @escaping (Bool) -> Void) {
        guard let spec = ClickPlan.spec(button: button), (1...3).contains(count) else { completion(false); return }
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGEvent(source: nil)?.location ?? .zero
        var ok = true
        for index in 1...count {
            let down = CGEvent(mouseEventSource: source, mouseType: spec.downType, mouseCursorPosition: point, mouseButton: spec.button)
            let up = CGEvent(mouseEventSource: source, mouseType: spec.upType, mouseCursorPosition: point, mouseButton: spec.button)
            for event in [down, up] {
                event?.flags = flags
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                event?.setIntegerValueField(.mouseEventButtonNumber, value: spec.buttonNumber)
            }
            ok = SyntheticInput.post(down) && SyntheticInput.post(up) && ok
        }
        completion(ok)
    }

    private static func scroll(_ p: ActionParameters, isCancelled: @escaping () -> Bool, _ completion: @escaping (Bool) -> Void) {
        guard let steps = ScrollPlan.steps(direction: p.scrollDirection ?? "down", amount: abs(p.scrollAmount ?? 3),
                                           durationMs: p.scrollDurationMs ?? 0) else { completion(false); return }
        let unit: CGScrollEventUnit = (p.scrollUnit ?? "lines") == "pixels" ? .pixel : .line
        let source = CGEventSource(stateID: .hidSystemState)
        func run(_ index: Int) {
            guard !isCancelled() else { completion(false); return }
            guard index < steps.count else { completion(true); return }
            let step = steps[index]
            let event = CGEvent(scrollWheelEvent2Source: source, units: unit, wheelCount: 2,
                                wheel1: step.vertical, wheel2: step.horizontal, wheel3: 0)
            guard SyntheticInput.post(event) else { completion(false); return }
            guard index + 1 < steps.count else { completion(true); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(steps[index + 1].delayMs)) { run(index + 1) }
        }
        run(0)
    }

    // MARK: - Keyboard

    /// Puts `text` on the clipboard, presses ⌘V, then restores whatever was there.
    /// The temporary item carries the pasteboard "transient" marker so clipboard
    /// managers (including AOM's) do not record it.
    static func pasteString(_ text: String, pasteboard: NSPasteboard = .general, press: @escaping () -> Bool = { SyntheticInput.key(9, flags: .maskCommand) },
                            restoreDelay: TimeInterval = 0.4, _ completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty, text.utf8.count <= 1_048_576 else { completion(text.isEmpty); return }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard pasteboard.writeObjects([item]) else { snapshot.restore(to: pasteboard); completion(false); return }
        let ours = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard pasteboard.changeCount == ours else { completion(false); return }
            let ok = press()
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                // Leave the clipboard alone if something else wrote to it meanwhile.
                if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
                completion(ok)
            }
        }
    }

    // MARK: - System

    private static func runProcess(_ path: String, _ arguments: [String], _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            let ok = (try? task.run()) != nil
            if ok { task.waitUntilExit() }
            DispatchQueue.main.async { completion(ok && task.terminationStatus == 0) }
        }
    }

    private static func runScript(kind: String, source: String, timeout: Double, _ completion: @escaping (Bool) -> Void) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { log("Script is empty"); completion(false); return }
        ScriptRunnerClient.shared.run(kind: kind, source: source, timeout: timeout) { code, output, timedOut in
            log(timedOut ? "Script timed out" : "Script completed (exit \(code))", error: code != 0 || timedOut)
            if code != 0, !output.isEmpty { log(String(output.prefix(300))) }
            completion(code == 0 && !timedOut)
        }
    }

    /// Finder frontmost: ⌘⇧. toggles without restarting Finder. Otherwise flip the
    /// preference and relaunch Finder, as the defaults command always has.
    private static func toggleHiddenFiles(_ completion: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            completion(SyntheticInput.key(47, flags: [.maskCommand, .maskShift])); return
        }
        let script = """
        v=$(/usr/bin/defaults read com.apple.finder AppleShowAllFiles 2>/dev/null)
        if [ "$v" = "1" ] || [ "$v" = "true" ] || [ "$v" = "YES" ]; then n=false; else n=true; fi
        /usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool $n && /usr/bin/killall Finder
        """
        runScript(kind: "shell", source: script, timeout: 15, completion)
    }

    /// Hardware brightness where the panel has it; a software dim otherwise, which
    /// never goes fully black so the screen stays recoverable.
    static func setBrightness(percent: Double) -> Bool {
        guard percent.isFinite, (0...100).contains(percent) else { return false }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        let id = CGDirectDisplayID(number.uint32Value)
        return DisplayControlService.setBrightness(id, brightnessValue(percent: percent, hardware: DisplayControlService.supportsHardwareBrightness(id)))
    }
    static func brightnessValue(percent: Double, hardware: Bool) -> Float {
        let value = Float(min(100, max(0, percent)) / 100)
        return hardware ? value : max(0.1, value)
    }

    private static func startDictation(_ completion: @escaping (Bool) -> Void) {
        if MenuBarExtras.pressEditMenuItem(prefix: "Start Dictation") { completion(true); return }
        // Fall back to the default shortcut: press fn twice.
        let first = SyntheticInput.modifier("fn", down: true, held: ["fn"])
            && SyntheticInput.modifier("fn", down: false, held: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let second = SyntheticInput.modifier("fn", down: true, held: ["fn"])
                && SyntheticInput.modifier("fn", down: false, held: [])
            completion(first && second)
        }
    }

    // MARK: - Utility

    static func fileURL(_ path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty, path.count <= 4096 else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private static func playSound(_ p: ActionParameters, _ completion: @escaping (Bool) -> Void) {
        guard let url = fileURL(p.filePath) else { log("Sound file not found"); completion(false); return }
        onMain {
            guard let sound = NSSound(contentsOf: url, byReference: true) else { log("Cannot play this file"); completion(false); return }
            sound.volume = Float((p.levelPercent ?? 100) / 100)
            sounds.append(sound)
            if sounds.count > 8 { sounds.removeFirst(sounds.count - 8) }
            completion(sound.play())
        }
    }

    private static func speak(_ p: ActionParameters, _ completion: @escaping (Bool) -> Void) {
        let text = (p.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 5000 else { completion(false); return }
        onMain {
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = Float(p.speechRate ?? Double(AVSpeechUtteranceDefaultSpeechRate))
            if let id = p.speechVoiceID, let voice = AVSpeechSynthesisVoice(identifier: id) { utterance.voice = voice }
            synthesizer.speak(utterance)
            completion(true)
        }
    }

    private static func notify(title: String, body: String, _ completion: @escaping (Bool) -> Void) {
        let fallback = { onMain { GestureHUD.shared.show(title: title, detail: body.isEmpty ? nil : body); completion(true) } }
        // UNUserNotificationCenter needs a real app bundle; bare executables trap.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { fallback(); return }
        let center = UNUserNotificationCenter.current()
        func post() {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                DispatchQueue.main.async { if error == nil { completion(true) } else { fallback() } }
            }
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in granted ? post() : fallback() }
            default: fallback()
            }
        }
    }
}

enum DisplayGeometry {
    /// Union of all display frames in CG (top-left) coordinates.
    static func unionBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }
}

/// Menu-bar items hosted by Control Center / SystemUIServer, pressed through
/// Accessibility. Their identifiers are not documented API, so each lookup is
/// best-effort and reports failure rather than guessing.
enum MenuBarExtras {
    enum Item {
        case notificationCenter, controlCenter
        var identifiers: [String] {
            switch self {
            case .notificationCenter: return ["com.apple.menuextra.clock"]
            case .controlCenter: return ["com.apple.menuextra.controlcenter"]
            }
        }
    }
    private static let hosts = ["com.apple.controlcenter", "com.apple.systemuiserver"]

    static func press(_ item: Item) -> Bool {
        for bundleID in hosts {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
                  CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { continue }
            for child in list {
                var identifier: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier) == .success,
                   let id = identifier as? String, item.identifiers.contains(id) {
                    return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Presses the first Edit-menu item whose title starts with `prefix`.
    static func pressEditMenuItem(prefix: String) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        func children(_ node: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success ? (value as? [AXUIElement] ?? []) : []
        }
        func title(_ node: AXUIElement) -> String {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &value) == .success ? (value as? String ?? "") : ""
        }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) where title(item).hasPrefix(prefix) {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }
}
