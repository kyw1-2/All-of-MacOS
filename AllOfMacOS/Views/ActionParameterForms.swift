import SwiftUI
import AVFoundation

/// Option forms for the actions added in 1.1.4. `ActionConfigView` hosts this for
/// every type where `handles` is true, so each new action has real controls with
/// units, ranges and defaults rather than a "nothing to configure" placeholder.
struct ActionParameterForm: View {
    let action: TriggerAction
    let triggers: [Trigger]
    /// Applies a change to the stored action (the host persists it).
    let save: ((inout TriggerAction) -> Void) -> Void

    static func handles(_ type: ActionType) -> Bool { formKind(type) != nil }

    private enum Kind {
        case moveResize, windowTarget, windowDrag, desktop, spaceShortcut, customClick, scroll, relativeMouse
        case textPayload, functionKey, modifier, arrow, level, filePath, speak, notification, shortcut, javascript
        case repeatLoop, cycle, toggle, variableStep, askInput, debounce, triggerSelector, waitFor, pause, info
    }

    private static func formKind(_ type: ActionType) -> Kind? {
        switch type {
        case .moveResizeWindow: return .moveResize
        case .zoomWindow, .closeWindow, .toggleFullscreenWindow: return .windowTarget
        case .startMovingWindow, .toggleMovingWindow, .startResizingWindow, .toggleResizingWindow: return .windowDrag
        case .switchToDesktop: return .desktop
        case .switchSpaceLeft, .switchSpaceRight, .moveWindowToPreviousSpace, .moveWindowToNextSpace, .appExpose, .showDesktop: return .spaceShortcut
        case .customClick: return .customClick
        case .scrollCustom: return .scroll
        case .moveMouseRelative: return .relativeMouse
        case .pasteString, .copyTextToClipboard: return .textPayload
        case .pressFunctionKey: return .functionKey
        case .modifierKeyDown, .modifierKeyUp: return .modifier
        case .pressArrowKey: return .arrow
        case .setVolume, .setBrightness: return .level
        case .playSoundFile, .openFileOrFolder, .revealInFinder: return .filePath
        case .speakText: return .speak
        case .showNotification: return .notification
        case .runAppleShortcut: return .shortcut
        case .runJavaScript: return .javascript
        case .repeatLoop: return .repeatLoop
        case .cycleActions: return .cycle
        case .toggleOnOff: return .toggle
        case .increaseVariable, .decreaseVariable: return .variableStep
        case .askForInput: return .askInput
        case .debounce: return .debounce
        case .enableTrigger, .disableTrigger: return .triggerSelector
        case .waitFor: return .waitFor
        case .disableTriggersForSeconds: return .pause
        case .snapWindowTopHalf, .snapWindowBottomHalf, .breakLoop, .stopAllSequences, .resumeTriggers,
             .missionControl, .launchpad, .hideOtherApps, .stopMovingWindow, .stopResizingWindow,
             .allModifiersUp, .toggleCapsLock, .pressPageUp, .pressPageDown, .pressHome, .pressEnd,
             .pressContextMenuKey, .ctrlLeftClick, .optionLeftClick, .shiftLeftClick, .cmdDoubleClick,
             .startScreenSaver, .sleepDisplay, .toggleHiddenFiles, .openNotificationCenter, .openControlCenter,
             .toggleMuteMicrophone, .startDictation, .emptyTrash, .logOut:
            return .info
        default: return nil
        }
    }

    var body: some View {
        if let kind = Self.formKind(action.actionType) {
            GroupBox(action.actionType.rawValue) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(action.actionType.description).font(.callout).foregroundStyle(.secondary)
                    content(kind)
                    if let problem = ActionParameterValidation.problem(for: action) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .accessibilityLabel("Problem: \(problem)")
                    }
                }.padding(8)
            }
        }
    }

    @ViewBuilder private func content(_ kind: Kind) -> some View {
        let p = action.parameters
        switch kind {
        case .info: footnote(Self.infoNote(action.actionType))
        case .moveResize: moveResize
        case .windowTarget: windowPicker
        case .windowDrag:
            windowTimeout
            footnote("Starts on the window under the pointer. A click, the matching Stop action, or the timeout ends it.")
        case .desktop:
            Stepper(value: intBinding(\.desktopNumber, default: 1), in: 1...9) { Text("Desktop \(p.desktopNumber ?? 1)") }
                .accessibilityLabel("Desktop number")
            hotKeyStatus
        case .spaceShortcut: hotKeyStatus
        case .customClick: customClick
        case .scroll: scroll
        case .relativeMouse:
            numberRow("Move right (points)", \.mouseDeltaX, default: 0, range: -10_000...10_000)
            numberRow("Move down (points)", \.mouseDeltaY, default: 0, range: -10_000...10_000)
            footnote("Negative values move left and up. The pointer stays on a display.")
        case .textPayload:
            ActionTextEditor(initial: p.text ?? "", label: "Text") { value in save { $0.parameters.text = value.isEmpty ? nil : value } }
                .id(action.id)
            footnote(action.actionType == .pasteString
                ? "Pastes with ⌘V through the clipboard, then restores what was there. Up to 1 MB."
                : "Replaces the clipboard with this text. Up to 1 MB.")
        case .functionKey:
            Picker("Key", selection: intBinding(\.functionKeyNumber, default: 1)) {
                ForEach(1...20, id: \.self) { Text("F\($0)").tag($0) }
            }
            footnote("macOS defines key codes for F1–F20 only; F21–F24 are not available.")
        case .modifier:
            Picker("Modifier", selection: stringBinding(\.modifierKey, default: "command")) {
                ForEach(ActionParameterValidation.modifierNames, id: \.self) { Text(Self.modifierTitle($0)).tag($0) }
            }
            footnote(action.actionType == .modifierKeyDown
                ? "Stays held until a Release Modifier Key or Release All Modifier Keys step."
                : "Releases a modifier held by Hold Modifier Key Down.")
        case .arrow:
            Picker("Direction", selection: stringBinding(\.arrowDirection, default: "down")) {
                Text("Up").tag("up"); Text("Down").tag("down"); Text("Left").tag("left"); Text("Right").tag("right")
            }.pickerStyle(.segmented)
            Stepper(value: intBinding(\.keyRepeatCount, default: 1), in: 1...100) {
                Text("Press \(p.keyRepeatCount ?? 1) time(s)")
            }.accessibilityLabel("Key press count")
        case .level:
            let isVolume = action.actionType == .setVolume
            Slider(value: doubleBinding(\.levelPercent, default: isVolume ? 50 : 70), in: 0...100, step: 1) {
                Text(isVolume ? "Volume" : "Brightness")
            } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("100") }
            Text("\(Int(p.levelPercent ?? (isVolume ? 50 : 70))) %").font(.callout.monospacedDigit())
            footnote(isVolume ? "Unmutes the output when raising from 0."
                              : "Uses the display under the pointer. Displays without a hardware control get a software dim that never goes fully black.")
        case .filePath: filePath
        case .speak: speak
        case .notification:
            TextField("Title", text: stringBinding(\.notificationTitle, default: "")).textFieldStyle(.roundedBorder)
            TextField("Message", text: stringBinding(\.text, default: "")).textFieldStyle(.roundedBorder)
            footnote("Falls back to an on-screen message if notifications are not allowed for AOM.")
        case .shortcut:
            TextField("Shortcut name (exactly as in Shortcuts)", text: stringBinding(\.shortcutName, default: "")).textFieldStyle(.roundedBorder)
            timeout(default: 60)
            footnote("Runs /usr/bin/shortcuts in AOM's script helper. A failing shortcut fails this step.")
        case .javascript:
            ActionTextEditor(initial: p.scriptContent ?? "", label: "JavaScript for Automation", monospaced: true) { value in
                save { $0.parameters.scriptContent = value.isEmpty ? nil : value }
            }.id(action.id)
            timeout(default: 30)
            footnote("Runs with osascript -l JavaScript in the same sandboxed helper as AppleScript and shell scripts.")
        case .repeatLoop:
            Stepper(value: intBinding(\.loopCount, default: 2), in: 1...100) { Text("Repeat \(p.loopCount ?? 2) times") }
                .accessibilityLabel("Loop count")
            footnote("Use + inside this step to add what repeats. Break Loop leaves early. A sequence may expand to at most 1,000 steps.")
        case .cycle:
            Toggle("Start over after idle time", isOn: Binding(get: { p.cycleResetSeconds != nil },
                set: { on in save { $0.parameters.cycleResetSeconds = on ? 10 : nil } }))
            if p.cycleResetSeconds != nil {
                numberRow("Idle seconds", \.cycleResetSeconds, default: 10, range: 1...86_400)
            }
            footnote("Each run executes the next inner action and wraps around. Add each variation as its own inner action; use a Group for several steps. The position resets when AOM restarts.")
        case .toggle:
            footnote("First run does the ON list, the next the OFF list, and so on. Use + inside this step to fill ON, and the OFF button for the second list. The position resets when AOM restarts.")
        case .variableStep:
            TextField("Variable name (letters, numbers, underscore)", text: stringBinding(\.variableName, default: "")).textFieldStyle(.roundedBorder)
            numberRow("Step", \.variableStep, default: 1, range: -1_000_000...1_000_000)
            footnote("An empty or non-numeric variable counts as 0.")
        case .askInput:
            TextField("Prompt", text: stringBinding(\.inputPrompt, default: "")).textFieldStyle(.roundedBorder)
            TextField("Save to variable", text: stringBinding(\.variableName, default: "")).textFieldStyle(.roundedBorder)
            TextField("Default text", text: stringBinding(\.variableValue, default: "")).textFieldStyle(.roundedBorder)
            footnote("Cancel stops the whole sequence and leaves the variable unchanged.")
        case .debounce:
            Stepper(value: intBinding(\.waitMs, default: 500), in: 0...60_000, step: 50) { Text("Wait \(p.waitMs ?? 500) ms") }
                .accessibilityLabel("Debounce delay in milliseconds")
            footnote("Only the last run inside this window continues. Set the trigger's execution policy to Restart or Parallel; with \"Ignore while running\" the later runs are dropped before they get here.")
        case .triggerSelector: triggerSelector
        case .waitFor: waitFor
        case .pause:
            numberRow("Seconds", \.pauseSeconds, default: 5, range: 0.1...86_400)
            footnote("Pauses every trigger, including this one. They resume by themselves, or earlier with Resume Triggers.")
        }
    }

    // MARK: Compound forms

    private var moveResize: some View {
        let p = action.parameters
        let percent = (p.moveResizeUnit ?? "percent") == "percent"
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Unit", selection: stringBinding(\.moveResizeUnit, default: "percent")) {
                Text("Percent of display").tag("percent"); Text("Pixels").tag("pixels")
            }.pickerStyle(.segmented)
            Picker("Anchor", selection: stringBinding(\.moveResizeAnchor, default: "topLeft")) {
                ForEach(ActionParameterValidation.anchors, id: \.self) { Text(Self.anchorTitle($0)).tag($0) }
            }
            numberRow(percent ? "X offset (%)" : "X offset (px)", \.moveResizeX, default: 0, range: -100_000...100_000)
            numberRow(percent ? "Y offset (%)" : "Y offset (px)", \.moveResizeY, default: 0, range: -100_000...100_000)
            optionalNumberRow(percent ? "Width (%)" : "Width (px)", \.moveResizeWidth, fallback: percent ? 50 : 800, range: 1...100_000)
            optionalNumberRow(percent ? "Height (%)" : "Height (px)", \.moveResizeHeight, fallback: percent ? 100 : 600, range: 1...100_000)
            windowPicker
            Picker("Display", selection: stringBinding(\.snapDisplay, default: "current")) {
                Text("Window's display").tag("current"); Text("Primary display").tag("primary")
                Text("Next display").tag("next"); Text("Display under pointer").tag("pointer")
            }
            footnote("Offsets run inward from the anchored edge; with the Center anchor positive X moves right and Y down. The window is kept fully on the display.")
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: stringBinding(\.windowTarget, default: "focused")) {
            Text("Focused window").tag("focused"); Text("Window under pointer").tag("underCursor")
        }.pickerStyle(.segmented)
    }

    private var windowTimeout: some View {
        Stepper(value: Binding(get: { Int(action.parameters.windowDragTimeoutSeconds ?? 60) },
                               set: { value in save { $0.parameters.windowDragTimeoutSeconds = Double(value) } }), in: 1...600, step: 5) {
            Text("Safety timeout \(Int(action.parameters.windowDragTimeoutSeconds ?? 60)) s")
        }.accessibilityLabel("Safety timeout in seconds")
    }

    private var hotKeyStatus: some View {
        let number = action.parameters.desktopNumber ?? 1
        let id = action.actionType.requiredHotKeyID(desktop: number)
        let key = id.flatMap { SymbolicHotKeys.hotKey(id: $0, in: SymbolicHotKeys.load()) }
        return VStack(alignment: .leading, spacing: 6) {
            if let key {
                Label(key.isEnabled ? "The system shortcut for this is on." : "The system shortcut for this is OFF, so this step will do nothing.",
                      systemImage: key.isEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(key.isEnabled ? Color.green : Color.orange)
                if !key.isEnabled {
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                    }.controlSize(.small).help("Turn on the shortcut under Keyboard Shortcuts › Mission Control")
                }
            }
            footnote("AOM presses the shortcut you set in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, so it has to be enabled there.")
        }
    }

    private var customClick: some View {
        let p = action.parameters
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Button", selection: intBinding(\.clickButton, default: 0)) {
                Text("Left").tag(0); Text("Right").tag(1); Text("Middle").tag(2)
                ForEach(3...8, id: \.self) { Text("Button \($0 + 1)").tag($0) }
            }
            Stepper(value: intBinding(\.clickCount, default: 1), in: 1...3) { Text("Click \(p.clickCount ?? 1) time(s)") }
                .accessibilityLabel("Click count")
            HStack {
                modifierToggle("⌘", .command); modifierToggle("⌥", .option); modifierToggle("⌃", .control); modifierToggle("⇧", .shift)
            }
            footnote("Clicks where the pointer is. Modifiers are held only for the click.")
        }
    }

    private func modifierToggle(_ title: String, _ flag: NSEvent.ModifierFlags) -> some View {
        Toggle(title, isOn: Binding(
            get: { NSEvent.ModifierFlags(rawValue: action.parameters.clickModifiers ?? 0).contains(flag) },
            set: { on in
                save {
                    var flags = NSEvent.ModifierFlags(rawValue: $0.parameters.clickModifiers ?? 0)
                    if on { flags.insert(flag) } else { flags.remove(flag) }
                    $0.parameters.clickModifiers = flags.rawValue == 0 ? nil : flags.rawValue
                }
            })).toggleStyle(.button).accessibilityLabel(Self.modifierName(flag))
    }

    private var scroll: some View {
        let p = action.parameters
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Direction", selection: stringBinding(\.scrollDirection, default: "down")) {
                Text("Up").tag("up"); Text("Down").tag("down"); Text("Left").tag("left"); Text("Right").tag("right")
            }.pickerStyle(.segmented)
            Picker("Unit", selection: stringBinding(\.scrollUnit, default: "lines")) {
                Text("Lines").tag("lines"); Text("Pixels").tag("pixels")
            }.pickerStyle(.segmented)
            Stepper(value: Binding(get: { abs(p.scrollAmount ?? 3) }, set: { value in save { $0.parameters.scrollAmount = value } }),
                    in: 1...10_000, step: (p.scrollUnit ?? "lines") == "pixels" ? 10 : 1) {
                Text("Amount \(abs(p.scrollAmount ?? 3)) \((p.scrollUnit ?? "lines") == "pixels" ? "px" : "lines")")
            }.accessibilityLabel("Scroll amount")
            Slider(value: Binding(get: { Double(p.scrollDurationMs ?? 0) }, set: { value in save { $0.parameters.scrollDurationMs = Int(value) } }),
                   in: 0...5000, step: 50) { Text("Duration") }
            Text((p.scrollDurationMs ?? 0) == 0 ? "Instant" : "Spread over \(p.scrollDurationMs ?? 0) ms (speed)")
                .font(.callout.monospacedDigit())
        }
    }

    private var filePath: some View {
        let type = action.actionType
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(type == .playSoundFile ? "Path to an audio file" : "Path to a file or folder", text: stringBinding(\.filePath, default: ""))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true; panel.canChooseDirectories = type != .playSoundFile
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { save { $0.parameters.filePath = url.path } }
                }.help("Choose a \(type == .playSoundFile ? "sound file" : "file or folder")")
            }
            if let path = action.parameters.filePath, !path.isEmpty, ExtendedActions.fileURL(path) == nil {
                Label("Nothing exists at this path.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if type == .playSoundFile {
                Slider(value: doubleBinding(\.levelPercent, default: 100), in: 0...100, step: 1) { Text("Volume") }
                Text("Volume \(Int(action.parameters.levelPercent ?? 100)) %").font(.callout.monospacedDigit())
            }
            footnote("A leading ~ is expanded. Missing files fail the step.")
        }
    }

    private var speak: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionTextEditor(initial: action.parameters.text ?? "", label: "Text to speak") { value in
                save { $0.parameters.text = value.isEmpty ? nil : value }
            }.id(action.id)
            Slider(value: doubleBinding(\.speechRate, default: Double(AVSpeechUtteranceDefaultSpeechRate)), in: 0.1...1, step: 0.05) { Text("Rate") }
            Text("Rate \(String(format: "%.2f", action.parameters.speechRate ?? Double(AVSpeechUtteranceDefaultSpeechRate)))")
                .font(.callout.monospacedDigit())
            Picker("Voice", selection: stringBinding(\.speechVoiceID, default: "")) {
                Text("System default").tag("")
                ForEach(AVSpeechSynthesisVoice.speechVoices().sorted { $0.name < $1.name }, id: \.identifier) { voice in
                    Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                }
            }
            footnote("Up to 5,000 characters.")
        }
    }

    private var triggerSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Trigger name or UUID", text: stringBinding(\.triggerSelector, default: "")).textFieldStyle(.roundedBorder)
            Menu("Choose a Trigger") {
                ForEach(triggers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { trigger in
                    Button("\(trigger.name) · \(trigger.input.displayName)") { save { $0.parameters.triggerSelector = trigger.id.uuidString } }
                }
            }.help("Pick from triggers that have a name")
            let selector = action.parameters.triggerSelector ?? ""
            let matches = triggers.filter { TriggerSelector.matches(selector, trigger: $0) }.count
            if !selector.isEmpty {
                Label(matches == 0 ? "No trigger matches." : "\(matches) trigger(s) match.",
                      systemImage: matches == 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(matches == 0 ? Color.orange : Color.green)
            }
            footnote("A UUID matches one trigger; a name matches every trigger with that name. Name triggers in their settings to make them selectable.")
        }
    }

    private var waitFor: some View {
        let p = action.parameters
        let condition = p.waitCondition ?? "appRunning"
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Wait until", selection: stringBinding(\.waitCondition, default: "appRunning")) {
                Text("An app is running").tag("appRunning"); Text("An app is frontmost").tag("appFrontmost")
                Text("A file or folder exists").tag("fileExists"); Text("The clipboard changes").tag("clipboardChange")
            }
            if condition != "clipboardChange" {
                TextField(condition == "fileExists" ? "Path" : "App bundle ID", text: stringBinding(\.waitTarget, default: "")).textFieldStyle(.roundedBorder)
            }
            Stepper(value: intBinding(\.waitTimeoutMs, default: 30_000), in: 0...600_000, step: 1000) {
                Text("Time out after \((p.waitTimeoutMs ?? 30_000) / 1000) s")
            }.accessibilityLabel("Timeout in seconds")
            Toggle("Continue when it times out", isOn: Binding(get: { p.waitContinueOnTimeout ?? false },
                set: { on in save { $0.parameters.waitContinueOnTimeout = on } }))
            footnote("Checks ten times a second. Off by default, a timeout stops the sequence.")
        }
    }

    // MARK: Controls

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func timeout(default value: Double) -> some View {
        numberRow("Timeout (s)", \.scriptTimeoutSeconds, default: value, range: 0.1...120)
    }
    private func numberRow(_ title: String, _ key: WritableKeyPath<ActionParameters, Double?>, default value: Double,
                           range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { action.parameters[keyPath: key] ?? value },
                                         set: { new in save { $0.parameters[keyPath: key] = min(range.upperBound, max(range.lowerBound, new)) } }),
                      format: .number).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
    }
    /// A number that can also be "keep current" (nil).
    private func optionalNumberRow(_ title: String, _ key: WritableKeyPath<ActionParameters, Double?>, fallback: Double,
                                   range: ClosedRange<Double>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { action.parameters[keyPath: key] != nil },
                                        set: { on in save { $0.parameters[keyPath: key] = on ? fallback : nil } }))
            if action.parameters[keyPath: key] != nil {
                TextField("", value: Binding(get: { action.parameters[keyPath: key] ?? fallback },
                                             set: { new in save { $0.parameters[keyPath: key] = min(range.upperBound, max(range.lowerBound, new)) } }),
                          format: .number).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                    .accessibilityLabel(title)
            } else {
                Spacer(); Text("keep current").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func stringBinding(_ key: WritableKeyPath<ActionParameters, String?>, default value: String) -> Binding<String> {
        Binding(get: { action.parameters[keyPath: key] ?? value },
                set: { new in save { $0.parameters[keyPath: key] = new.isEmpty ? nil : new } })
    }
    private func intBinding(_ key: WritableKeyPath<ActionParameters, Int?>, default value: Int) -> Binding<Int> {
        Binding(get: { action.parameters[keyPath: key] ?? value }, set: { new in save { $0.parameters[keyPath: key] = new } })
    }
    private func doubleBinding(_ key: WritableKeyPath<ActionParameters, Double?>, default value: Double) -> Binding<Double> {
        Binding(get: { action.parameters[keyPath: key] ?? value }, set: { new in save { $0.parameters[keyPath: key] = new } })
    }

    // MARK: Wording (static so tests can read it)

    static func infoNote(_ type: ActionType) -> String {
        switch type {
        case .emptyTrash, .logOut: return "Asks for confirmation each time unless you turn that off under Safety below."
        case .breakLoop: return "Leaves the nearest Repeat N Times loop; steps after it in that pass are skipped."
        case .stopAllSequences: return "Cancels every running sequence, including the one that contains this step."
        case .resumeTriggers: return "Ends a pause started by Disable Triggers For X Seconds."
        case .missionControl, .launchpad: return "Opens the system app. Nothing to configure."
        case .toggleCapsLock, .toggleMuteMicrophone: return "Flips the current state. Nothing to configure."
        case .allModifiersUp: return "Releases every modifier key AOM is holding down. Use it as a safety net after Hold Modifier Key Down."
        case .startDictation: return "Presses Edit › Start Dictation in the frontmost app, or fn fn when it has no such item."
        case .openNotificationCenter, .openControlCenter: return "Presses the item in the menu bar through Accessibility. Needs Accessibility permission."
        default: return "Nothing to configure."
        }
    }
    static func anchorTitle(_ anchor: String) -> String {
        switch anchor {
        case "topLeft": return "Top left"; case "top": return "Top"; case "topRight": return "Top right"
        case "left": return "Left"; case "center": return "Center"; case "right": return "Right"
        case "bottomLeft": return "Bottom left"; case "bottom": return "Bottom"; default: return "Bottom right"
        }
    }
    static func modifierTitle(_ name: String) -> String {
        switch name {
        case "command": return "⌘ Command (left)"; case "rightCommand": return "⌘ Command (right)"
        case "option": return "⌥ Option (left)"; case "rightOption": return "⌥ Option (right)"
        case "shift": return "⇧ Shift (left)"; case "rightShift": return "⇧ Shift (right)"
        case "control": return "⌃ Control (left)"; case "rightControl": return "⌃ Control (right)"
        default: return "fn"
        }
    }
    private static func modifierName(_ flag: NSEvent.ModifierFlags) -> String {
        flag == .command ? "Command" : flag == .option ? "Option" : flag == .control ? "Control" : "Shift"
    }
}

/// A text editor that saves as you type without being rebuilt from the model on
/// every keystroke (which would move the cursor).
struct ActionTextEditor: View {
    @State private var text: String
    let label: String
    var monospaced = false
    let onChange: (String) -> Void
    init(initial: String, label: String, monospaced: Bool = false, onChange: @escaping (String) -> Void) {
        _text = State(initialValue: initial); self.label = label; self.monospaced = monospaced; self.onChange = onChange
    }
    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .frame(minHeight: 70)
            .accessibilityLabel(label)
            .onChange(of: text) { _, value in onChange(value) }
    }
}
