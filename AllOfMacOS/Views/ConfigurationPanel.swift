import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            AOMSectionTitle("Configuration")
                .padding(.horizontal, AOMSpace.x3)
                .padding(.vertical, AOMSpace.x2)

            AOMDivider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: AOMSpace.x4) {
                    // The editors are groups inside one card (AOMSection hides
                    // the first group's hairline).
                    if let action = appState.selectedAction, let trigger = appState.selectedTrigger {
                        AOMSection {
                            ActionConfigView(keyboardMonitor: appState.keyboardMonitor, trigger: trigger, action: action)
                                .id(action.id)
                        }
                    } else if let trigger = appState.selectedTrigger {
                        AOMSection {
                            TriggerConfigView(trigger: trigger).id(trigger.id)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(AOMSpace.x4)
            }
        }
        .background(AOMColor.canvas)
    }

    private var emptyState: some View {
        AOMEmptyState("Nothing Selected", systemImage: "slider.horizontal.3",
                      message: "Select a trigger or action to configure.")
    }
}

/// One collapsible group in the trigger inspector.
///
/// BTT shows a short list of named sections rather than every control at once.
/// Everything the trigger does not use is hidden, and the sections that remain
/// open by default are the ones a user changes while tuning a gesture; the rest
/// start closed so the panel stays readable.
///
/// Drawn as a group inside the editor's card (`AOMEditorGroup`, e.2: never a
/// card in a card): a hairline above, a monochrome symbol, the title, an ⓘ
/// for the explanation and a disclosure chevron. A group starts closed unless
/// it passes `expanded: true`. Pass `rows: true` when the content is
/// `AOMSettingRow`s.
struct ConfigSection<Content: View>: View {
    let title: String
    let systemImage: String
    var isAdvanced: Bool = false
    var help: String?
    var rows = false
    @State private var expanded: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String, isAdvanced: Bool = false, help: String? = nil, rows: Bool = false,
         expanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.isAdvanced = isAdvanced
        self.help = help
        self.rows = rows
        self.content = content
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        // No "Advanced" detail: the advanced groups only ever show inside the
        // editor's Options › Advanced disclosure, which already says so.
        AOMEditorGroup(title, symbol: systemImage, help: help, rows: rows, isExpanded: $expanded) {
            content()
        }
    }
}

struct TriggerConfigView: View {
    /// Which settings to show. The Automation editor puts the input's own
    /// settings under When and the tuning under Options; name, enabled and
    /// scope live in its header, so the embedded parts omit them.
    enum Part { case all, input, options }

    @EnvironmentObject var appState: AppState
    let trigger: Trigger
    var part: Part = .all

    @State private var name: String
    @State private var isEnabled: Bool
    @AppStorage("AOMPressDragThreshold") private var pressDragThreshold: Double = 300
    @AppStorage("AOMTipTapMinRestTime") private var tipTapMinRestTime: Double = 0.12
    @AppStorage("AOMSuppressMouseDuringDrawing") private var suppressMouseDuringDrawing: Bool = true
    // swipeMinVelocity is per-gesture, handled via manual UserDefaults binding below

    init(trigger: Trigger, part: Part = .all) {
        self.trigger = trigger
        self.part = part
        _name = State(initialValue: trigger.name)
        _isEnabled = State(initialValue: trigger.isEnabled)
    }

    var body: some View {
        // Groups draw their own hairline above, so they stack with no gap
        // (e.2: groups inside a card, never a card in a card).
        VStack(alignment: .leading, spacing: 0) {
            if part == .all {
                ConfigSection("Trigger", systemImage: "cursorarrow.click", rows: true, expanded: true) {
                    AOMSettingRow("Name") {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: AOMEditorSize.rowField)
                    }
                    .onChange(of: name) { _, newValue in
                        var updated = trigger
                        updated.name = newValue
                        appState.updateTrigger(updated)
                    }
                    AOMToggleRow("Enabled", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, newValue in
                            var updated = trigger
                            updated.isEnabled = newValue
                            appState.updateTrigger(updated)
                        }
                }

                ConfigSection("Activation scope", systemImage: "square.stack.3d.up",
                              help: "App-specific overrides group bindings; groups override global bindings.",
                              rows: true, expanded: true) {
                    AOMSettingRow("Apply to") {
                        Picker("Apply to", selection: Binding<String>(
                            get: {
                                if let id = trigger.activationGroupID { return "group:" + id.uuidString }
                                return trigger.appBundleID.map { "app:" + $0 } ?? "global"
                            },
                            set: { value in
                                update { trigger in
                                    if value.hasPrefix("group:"), let id = UUID(uuidString: String(value.dropFirst(6))) {
                                        trigger.activationGroupID = id
                                        trigger.appBundleID = nil
                                    } else {
                                        trigger.activationGroupID = nil
                                        trigger.appBundleID = value == "global" ? nil : String(value.dropFirst(4))
                                    }
                                }
                            }
                        )) {
                            Text("All Apps").tag("global")
                            ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { target in
                                if let bundleID = target.bundleID {
                                    Text(target.name).tag("app:" + bundleID)
                                }
                            }
                            ForEach(appState.currentPreset.activationGroups) { group in
                                Text("Group: " + group.name).tag("group:" + group.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            if part != .options, case .drawingPattern = trigger.input {
                DrawingSamplesConfiguration(trigger: trigger) { name, samples, certainty, ignoreDirection in
                    update {
                        $0.input = .drawingPattern(name)
                        $0.drawingSamples = samples
                        $0.drawingCertainty = certainty
                        $0.drawingIgnoreDirection = ignoreDirection
                    }
                }.id(trigger.id)
            }
            if part != .options, case .keySequence(let strokes) = trigger.input {
                ConfigSection("Key sequence", systemImage: "keyboard.badge.ellipsis",
                              help: "Sequences observe physical key events and do not suppress ordinary typing.",
                              rows: true, expanded: true) {
                    VStack(alignment: .leading, spacing: AOMSpace.x2) {
                        Text(strokes.map(\.displayName).joined(separator: " → "))
                            .font(AOMFont.mono)
                            .foregroundStyle(AOMColor.text)
                        HStack(spacing: AOMSpace.x2) {
                            Button("Record Next Key") {
                                appState.keyboardMonitor.startRecording { shortcut in
                                    if strokes.count < 6 {
                                        update { $0.input = .keySequence(strokes + [KeySequenceStroke(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue)]) }
                                    }
                                }
                            }.disabled(strokes.count >= 6)
                            Button("Remove Last") {
                                if strokes.count > 1 { update { $0.input = .keySequence(Array(strokes.dropLast())) } }
                            }.disabled(strokes.count <= 1)
                        }
                    }
                    .aomRowInset()
                    // Per-stroke optionality, following BTT's BTTKEYRequired.
                    if strokes.count > 1 {
                        VStack(alignment: .leading, spacing: AOMSpace.x1) {
                            Text("Required strokes").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            ForEach(Array(strokes.enumerated()), id: \.offset) { index, stroke in
                                Toggle(isOn: Binding(
                                    get: { stroke.isRequired },
                                    set: { required in
                                        var next = strokes
                                        next[index].isRequired = required
                                        update { $0.input = .keySequence(next) }
                                    })) {
                                        Text("\(index + 1). \(stroke.displayName)")
                                            .font(AOMFont.mono)
                                            .foregroundStyle(stroke.isRequired ? AOMColor.text : AOMColor.textSecondary)
                                    }
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .aomRowInset()
                        AOMToggleRow("Order matters", help: "Off accepts the required strokes in any order.",
                                     isOn: triggerBinding(\.sequenceOrderRelevant))
                            .help("Off accepts the required strokes in any order.")
                        if !strokes.contains(where: \.isRequired) {
                            AOMEditorNote("Every stroke is optional, so this sequence never matches.", tone: .warning)
                                .aomRowInset()
                        }
                    }
                    AOMSettingRow("Maximum gap") {
                        AOMRowStepper("Maximum gap", value: triggerBinding(\.sequenceMaxGapMs), in: 100...2000, step: 50,
                                      display: "\(trigger.sequenceMaxGapMs) ms")
                    }
                    if strokes.count == 1 {
                        AOMToggleRow("Fire when held", isOn: Binding(get: { trigger.sequenceHoldMs > 0 }, set: { enabled in
                            update { $0.sequenceHoldMs = enabled ? 600 : 0 }
                        }))
                        if trigger.sequenceHoldMs > 0 {
                            AOMSettingRow("Hold for", indent: true) {
                                AOMRowStepper("Hold for", value: triggerBinding(\.sequenceHoldMs), in: 300...5000, step: 100,
                                              display: "\(trigger.sequenceHoldMs) ms")
                            }
                        }
                    }
                }
            }
            if part != .options, case .keyboardShortcut = trigger.input {
                ConfigSection("Keyboard shortcut", systemImage: "command.square",
                              help: "Press the new shortcut after clicking Record. Escape cancels recording.", expanded: true) {
                    Button("Record Replacement Shortcut") {
                        appState.keyboardMonitor.startRecording { shortcut in update { $0.input = .keyboardShortcut(shortcut) } }
                    }
                }
            }
            if part != .input {
                ConfigSection("Execution", systemImage: "play.circle", isAdvanced: true,
                              help: "What happens when the automation fires again before it has finished, and for keys, when it fires and whether it repeats while held.",
                              rows: true) {
                    AOMSettingRow("When already running") {
                        Picker("When already running", selection: triggerBinding(\.executionPolicy)) {
                            ForEach(ExecutionPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    if case .keyboardShortcut = trigger.input {
                        AOMSettingRow("Fire on") {
                            Picker("Fire on", selection: triggerBinding(\.keyboardPhase)) {
                                ForEach(KeyboardPhase.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    if trigger.supportsHold && trigger.keyboardPhase == .keyDown {
                        AOMToggleRow("Repeat while held",
                                     help: "Stops when released, modifiers change, or another app gains focus. Each iteration waits for the previous one.",
                                     isOn: triggerBinding(\.repeatWhileHeld))
                        if trigger.repeatWhileHeld {
                            AOMSettingRow("Initial delay", indent: true) {
                                AOMRowStepper("Initial delay", value: triggerBinding(\.holdDelayMs), in: 100...5000, step: 50,
                                              display: "\(trigger.holdDelayMs) ms")
                            }
                            AOMSettingRow("Repeat interval", indent: true) {
                                AOMRowStepper("Repeat interval", value: triggerBinding(\.holdIntervalMs), in: 50...5000, step: 50,
                                              display: "\(trigger.holdIntervalMs) ms")
                            }
                        }
                    }
                }
            }
            if part != .input, trigger.input.category == .trackpad || trigger.input.category == .normalMouse {
                ConfigSection("Required modifiers", systemImage: "command", isAdvanced: true,
                              help: "With exact matching, the trigger fires only while exactly these modifier keys are held. None selected means no modifiers; Caps Lock is ignored.",
                              rows: true) {
                    AOMToggleRow("Match exact modifiers",
                                 detail: trigger.requiredModifiers == nil ? "Any modifiers (legacy behavior)" : nil,
                                 isOn: Binding(get: { trigger.requiredModifiers != nil }, set: { value in
                        update { $0.requiredModifiers = value ? 0 : nil }
                    }))
                    if trigger.requiredModifiers != nil {
                        AOMSettingRow("Modifiers", detail: "None selected means no modifiers", indent: true) {
                            HStack(spacing: AOMSpace.x1) {
                                modifierToggle("⌃", .control); modifierToggle("⌥", .option)
                                modifierToggle("⇧", .shift); modifierToggle("⌘", .command); modifierToggle("fn", .function)
                            }
                        }
                    }
                }
            }
            if part != .options, case .namedTrigger(let currentName) = trigger.input {
                ConfigSection("Named trigger", systemImage: "arrow.triangle.branch",
                              help: "Other automations run this one with the Run Named Trigger action, by this exact name.") {
                    TextField("Callable name", text: Binding(get: { currentName }, set: { value in update { $0.input = .namedTrigger(value) } }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Click suppression for mouse buttons and click-based trackpad gestures
            if part != .input, isClickBasedTrigger(trigger) {
                ConfigSection("Click suppression", systemImage: "hand.raised",
                              help: "When enabled, the click will not be sent to the foreground application — only the mapped actions will fire.",
                              rows: true, expanded: true) {
                    AOMToggleRow("Suppress click pass-through", isOn: Binding(
                        get: { trigger.suppressClick },
                        set: { newValue in
                            var updated = trigger
                            updated.suppressClick = newValue
                            appState.updateTrigger(updated)
                        }
                    ))
                }
            }

            // Force Touch stage triggers (3.3.3): the stage is their only setting.
            if part != .options, case .systemEvent(let kind) = trigger.input,
               let stageKey = BTTInputTriggerKinds.key(for: kind) {
                ConfigSection("Force Touch stage", systemImage: "hand.point.up.left",
                              help: "Stage 1 fires on the click, stage 2 on the deep press, once per press. Stage 2 needs Force Click and haptic feedback turned on in Trackpad settings.",
                              rows: true, expanded: true) {
                    AOMSettingRow("Stage") {
                        Picker("Stage", selection: Binding(get: { stageKey }, set: { key in
                            if let next = BTTInputTriggerKinds.kind(for: key) { update { $0.input = .systemEvent(next) } }
                        })) {
                            ForEach(BTTInputTriggerKinds.options, id: \.key) { Text($0.title).tag($0.key) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            // Gesture animation preview
            if part != .options, case .trackpadGesture(let gesture) = trigger.input {
                GesturePreviewView(gesture: gesture)
                    .frame(maxWidth: .infinity)
                    .padding(AOMSpace.x3)
                    .overlay(alignment: .top) { AOMRowDivider(inset: 0, trailingInset: 0) }
            }
            // Continuous value binding (3.3.3): MIDI CC, Pitch Bend and pressure,
            // Force Touch stages and Scroll Up/Down can drive a value instead of
            // running the actions. The editor renders nothing for other inputs.
            if part != .input, ContinuousValueBinding.supports(trigger.input) {
                ConfigSection("Value binding", systemImage: "slider.horizontal.3",
                              help: "Lets this input set the system volume, an app's volume or the display brightness directly instead of running its actions.",
                              rows: true, expanded: trigger.valueBinding != nil) {
                    ContinuousValueBindingEditor(binding: Binding(
                        get: { trigger.valueBinding },
                        set: { value in update { $0.valueBinding = value } }),
                        input: trigger.input)
                }
            }
            if part != .input, case .trackpadGesture(let gesture) = trigger.input {
                ConfigSection("Feedback", systemImage: "waveform", rows: true, expanded: true) {
                    AOMToggleRow("Haptic feedback on recognition", isOn: Binding(
                        get: { trigger.hapticFeedback },
                        set: { value in var updated = trigger; updated.hapticFeedback = value; appState.updateTrigger(updated) }
                    ))
                }

                // TipTap sensitivity slider
                if gesture == .tipTapLeft || gesture == .tipTapRight || gesture == .tipTapMiddle {
                    ConfigSection("TipTap sensitivity", systemImage: "hand.tap",
                                  help: "How long the resting finger must be down before a tap counts. Shorter is more sensitive; longer gives fewer false positives.",
                                  rows: true, expanded: true) {
                        AOMSettingRow("Minimum rest time") {
                            HStack(spacing: AOMSpace.x2) {
                                Slider(value: $tipTapMinRestTime, in: 0.02...0.4, step: 0.01)
                                    .frame(width: AOMEditorSize.rowSlider)
                                    .accessibilityLabel("Minimum rest time")
                                    .accessibilityValue("\(Int(tipTapMinRestTime * 1000)) ms")
                                AOMRowValue("\(Int(tipTapMinRestTime * 1000)) ms")
                            }
                        }
                    }
                }

                // Mouse suppression toggle for drawings & sliders
                if [.circleClockwise, .circleCounterClockwise, .drawTriangle,
                    .leftEdgeSlideUp, .leftEdgeSlideDown, .rightEdgeSlideUp, .rightEdgeSlideDown]
                    .contains(gesture) {
                    ConfigSection("Mouse suppression", systemImage: "cursorarrow.slash", isAdvanced: true,
                                  help: "Disables mouse movement during drawings and edge sliders to prevent accidental clicks.",
                                  rows: true) {
                        AOMToggleRow("Suppress mouse while drawing", isOn: $suppressMouseDuringDrawing)
                    }
                }

                // Press-drag sensitivity slider
                if gesture == .twoFingerPressDragLeft || gesture == .twoFingerPressDragRight {
                    ConfigSection("Press-drag sensitivity", systemImage: "hand.draw",
                                  help: "How far you drag after pressing before the gesture counts. Shorter is more sensitive; longer needs a long swipe.",
                                  rows: true, expanded: true) {
                        AOMSettingRow("Minimum drag distance") {
                            HStack(spacing: AOMSpace.x2) {
                                Slider(value: $pressDragThreshold, in: 10...600, step: 10)
                                    .frame(width: AOMEditorSize.rowSlider)
                                    .accessibilityLabel("Minimum drag distance")
                                    .accessibilityValue("\(Int(pressDragThreshold)) pt")
                                AOMRowValue("\(Int(pressDragThreshold)) pt")
                            }
                        }
                    }
                }

                // Swipe velocity threshold (per-gesture)
                if [.oneFingerSwipeUpOnLeftEdge, .oneFingerSwipeDownOnLeftEdge,
                    .oneFingerSwipeUpOnRightEdge, .oneFingerSwipeDownOnRightEdge,
                    .oneFingerSwipeLeftOnTopEdge, .oneFingerSwipeRightOnTopEdge,
                    .oneFingerSwipeLeftOnBottomEdge, .oneFingerSwipeRightOnBottomEdge]
                    .contains(gesture) {
                    ConfigSection("Edge swipe", systemImage: "rectangle.portrait.and.arrow.right", isAdvanced: true) {
                        AOMEditorNote("The swipe must start within 12% of the edge and travel about a tenth of the pad. "
                                      + "A swipe that begins on the body of the trackpad is not an edge swipe.")
                    }
                }
                if [.twoFingerSwipeUp, .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight,
                    .threeFingerSwipeUp, .threeFingerSwipeDown, .threeFingerSwipeLeft, .threeFingerSwipeRight,
                    .fourFingerSwipeUp, .fourFingerSwipeDown, .fourFingerSwipeLeft, .fourFingerSwipeRight,
                    .fiveFingerSwipeUp, .fiveFingerSwipeDown, .fiveFingerSwipeLeft, .fiveFingerSwipeRight]
                    .contains(gesture) {
                    SwipeVelocityConfig(gesture: gesture)
                        .id(gesture)
                }
            }

            if part == .all { Spacer() }
        }
    }

    private func update(_ change: (inout Trigger) -> Void) {
        guard var latest = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }) else { return }
        change(&latest); appState.updateTrigger(latest)
    }
    private func triggerBinding<T>(_ key: WritableKeyPath<Trigger, T>) -> Binding<T> {
        Binding(get: { trigger[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func modifierToggle(_ label: String, _ flag: NSEvent.ModifierFlags) -> some View {
        Toggle(label, isOn: Binding(get: { (trigger.requiredModifiers ?? 0) & flag.rawValue != 0 }, set: { enabled in
            update { $0.requiredModifiers = enabled ? ($0.requiredModifiers ?? 0) | flag.rawValue : ($0.requiredModifiers ?? 0) & ~flag.rawValue }
        })).toggleStyle(.button)
    }
    private func isClickBasedTrigger(_ trigger: Trigger) -> Bool {
        if case .mouseButton = trigger.input { return true }
        if case .trackpadGesture(let gesture) = trigger.input {
            let clickGestures: [TrackpadGesture] = [
                .twoFingerClick, .threeFingerClick, .twoFingerTap, .twoFingerDoubleTap,
                .threeFingerTap, .threeFingerDoubleTap, .fourFingerTap, .fiveFingerTap,
                .cornerClickTopLeft, .cornerClickTopRight,
                .cornerClickBottomLeft, .cornerClickBottomRight,
                .middleClickTop, .middleClickBottom,
            ]
            return clickGestures.contains(gesture)
        }
        return false
    }
}

struct ActionConfigView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var keyboardMonitor: KeyboardMonitor
    let trigger: Trigger
    let action: TriggerAction

    @State private var text: String
    @State private var scriptContent: String
    @State private var url: String
    @State private var applicationName: String
    @State private var recordedShortcut: KeyboardShortcut?
    @EnvironmentObject private var state: AppState

    init(keyboardMonitor: KeyboardMonitor, trigger: Trigger, action: TriggerAction) {
        self.keyboardMonitor = keyboardMonitor
        self.trigger = trigger
        self.action = action
        _text = State(initialValue: action.parameters.text ?? "")
        _scriptContent = State(initialValue: action.parameters.scriptContent ?? "")
        _url = State(initialValue: action.parameters.url ?? "")
        if let keyCode = action.parameters.shortcutKeyCode {
            let mods = NSEvent.ModifierFlags(rawValue: action.parameters.shortcutModifiers ?? 0)
            _recordedShortcut = State(initialValue: KeyboardShortcut(keyCode: keyCode, modifiers: mods))
        } else {
            _recordedShortcut = State(initialValue: nil)
        }
        _applicationName = State(initialValue: action.parameters.applicationName ?? "")
    }

    var body: some View {
        // Groups inside the step's card, each with a hairline above (e.2).
        VStack(alignment: .leading, spacing: 0) {
            AOMEditorGroup("Step", detail: action.actionType.rawValue, rows: true) {
                AOMToggleRow("Enabled", isOn: Binding(get: { action.isEnabled }, set: { value in
                    saveAction { $0.isEnabled = value }
                }))
                AOMSettingRow("Name") {
                    TextField("Optional action name", text: stringParameter(\.label))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
                }
                TextField("Notes", text: stringParameter(\.notes), axis: .vertical).lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .aomRowInset()
            }

            // Action-specific parameters
            switch action.actionType {
            case .triggerNamedTrigger:
                AOMEditorGroup("Named trigger to run",
                               help: "Create reusable macros in Other Triggers. This step waits until the called macro finishes; recursive calls fail safely.") {
                    TextField("Exact callable name", text: stringParameter(\.namedTriggerName))
                        .textFieldStyle(.roundedBorder)
                    Menu("Choose Named Trigger") {
                        ForEach(appState.currentPreset.triggers.filter { if case .namedTrigger = $0.input { return true }; return false }) { named in
                            if case .namedTrigger(let name) = named.input {
                                Button(name + " · " + (named.appBundleID ?? "All Apps")) { saveAction { $0.parameters.namedTriggerName = name } }
                            }
                        }
                    }
                    .fixedSize()
                }
            case .saveWindowLayout, .restoreWindowLayout:
                AOMEditorGroup("Window layout",
                               help: "Use the same name to save and restore. Only identifiable open windows on connected displays are restored.") {
                    TextField("Saved layout name", text: stringParameter(\.windowLayoutName))
                        .textFieldStyle(.roundedBorder)
                }
            case .showHUD:
                AOMEditorGroup("HUD message") {
                    TextField("Message", text: stringParameter(\.hudText))
                        .textFieldStyle(.roundedBorder)
                }
            case .showCheatSheet:
                AOMEditorGroup("Cheat sheet") {
                    AOMEditorNote("Shows or hides the bindings available to the current application.")
                }
            case .actionGroup:
                AOMEditorGroup("Group") {
                    AOMEditorNote("Choose Add Inside… in this step's menu to insert child actions. Conditions and repeat settings apply to the entire group.")
                }
            case .setVariable:
                AOMEditorGroup("Set workflow variable",
                               help: "Variable values are shared across triggers and persist across restarts. 128 variables maximum; values up to 512 characters.") {
                    TextField("Name (letters, numbers, underscore)", text: stringParameter(\.variableName))
                        .textFieldStyle(.roundedBorder)
                    TextField("String value", text: stringParameter(\.variableValue))
                        .textFieldStyle(.roundedBorder)
                    AOMEditorNote("Do not store passwords.", tone: .warning)
                }
            case .ifElse:
                AOMEditorGroup("If / Else condition",
                               help: "Add the Then steps with Add Inside… and the Else steps with Add to Else… in this step's menu. The condition is checked after the step delay.") {
                    Picker("Read from", selection: Binding(get: { action.parameters.conditionKind ?? "variable" }, set: { kind in
                        saveAction { $0.parameters.conditionKind = kind }
                    })) {
                        Text("Variable").tag("variable")
                        Text("Frontmost App Bundle ID").tag("app")
                        Text("Frontmost App Name").tag("appName")
                        Text("Clipboard Text").tag("clipboard")
                        Text("Focused Window Title").tag("window")
                        Text("Pointer X (0–1)").tag("mouseX")
                        Text("Pointer Y (0–1)").tag("mouseY")
                    }
                    if (action.parameters.conditionKind ?? "variable") == "variable" {
                        TextField("Variable name", text: stringParameter(\.variableName))
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Comparison", selection: Binding(get: { action.parameters.conditionOperator ?? "equals" }, set: { op in
                        saveAction { $0.parameters.conditionOperator = op }
                    })) {
                        ForEach(WorkflowBranchCondition.operators, id: \.id) { entry in
                            Text(entry.title).tag(entry.id)
                        }
                    }
                    TextField("Compare to", text: stringParameter(\.conditionValue))
                        .textFieldStyle(.roundedBorder)
                    let thenCount = action.parameters.children?.count ?? 0
                    let elseCount = action.parameters.elseChildren?.count ?? 0
                    AOMEditorNote("Then: \(thenCount) step\(thenCount == 1 ? "" : "s") · Else: \(elseCount) step\(elseCount == 1 ? "" : "s")")
                }
            case .customSnapWindow:
                AOMEditorGroup("Custom snap area", detail: "Percent of the visible screen, from the top left",
                               help: "The window is moved only when this action runs. The area automatically scales across different monitor resolutions.",
                               rows: true) {
                    AOMSettingRow("Target display") {
                        Picker("Target display", selection: Binding(get: { action.parameters.snapDisplay ?? "current" }, set: { mode in
                            saveAction { $0.parameters.snapDisplay = mode }
                        })) {
                            Text("Current display").tag("current")
                            Text("Primary display").tag("primary")
                            Text("Next display").tag("next")
                            Text("Display under pointer").tag("pointer")
                        }
                        .pickerStyle(.menu)
                    }
                    snapSetting("X", key: \.snapX, fallback: 0)
                    snapSetting("Y", key: \.snapY, fallback: 0)
                    snapSetting("Width", key: \.snapWidth, fallback: 0.5)
                    snapSetting("Height", key: \.snapHeight, fallback: 1)
                    VStack(alignment: .leading, spacing: AOMSpace.x3) {
                        GeometryReader { geometry in
                            let screen = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                            let area = RoundedRectangle(cornerRadius: AOMRadius.keycap, style: .continuous)
                            screen.fill(AOMColor.sunken)
                            screen.strokeBorder(AOMColor.hairline, lineWidth: 1)
                            area
                                .fill(AOMTone.info.wash(increasedContrast: false))
                                .overlay(area.strokeBorder(AOMColor.accent, lineWidth: 2))
                                .frame(width: geometry.size.width * (action.parameters.snapWidth ?? 0.5),
                                       height: geometry.size.height * (action.parameters.snapHeight ?? 1))
                                .offset(x: geometry.size.width * (action.parameters.snapX ?? 0),
                                        y: geometry.size.height * (action.parameters.snapY ?? 0))
                        }
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: AOMSize.tileMin)
                        .accessibilityHidden(true)
                        HStack(spacing: AOMSpace.x2) {
                            Button("Left Half") { setSnap(x: 0, y: 0, width: 0.5, height: 1) }
                            Button("Right Half") { setSnap(x: 0.5, y: 0, width: 0.5, height: 1) }
                            Button("Top Third") { setSnap(x: 0, y: 0, width: 1, height: 0.333) }
                        }
                    }
                    .aomRowInset()
                }
            case .wait:
                AOMEditorGroup("Wait", rows: true) { timingField("Duration (ms)", key: \.waitMs, defaultValue: 250) }
            case .volumeUp, .volumeDown:
                AOMEditorGroup("Volume step", rows: true) {
                    AOMSettingRow("Step per click") {
                        AOMRowStepper("Volume step", value: Binding(get: { action.parameters.volumeStepPercent ?? 6 },
                                                                    set: { value in saveAction { $0.parameters.volumeStepPercent = value } }),
                                      in: 1...100, step: 1,
                                      display: "\(Int(action.parameters.volumeStepPercent ?? 6)) points")
                    }
                }
            case .setSoundOutput:
                SoundOutputConfig(action: action) { name, uid in
                    saveAction { $0.parameters.audioOutputName = name; $0.parameters.audioOutputUID = uid }
                }
                .id(action.id)
            case .typeText:
                AOMEditorGroup("Text to type",
                               help: "Types one character at a time without changing your clipboard. Tabs and line breaks press Tab and Return. Works in password fields, including macOS authorization dialogs. {{var:name}} inserts a workflow variable.",
                               rows: true) {
                    TextEditor(text: $text)
                        .font(AOMFont.mono)
                        .aomTextWell()
                        .onChange(of: text) { _, newValue in saveAction { $0.parameters.text = newValue } }
                        .aomRowInset()
                    AOMSettingRow("Delay between characters") {
                        AOMRowStepper("Delay between characters", value: Binding(get: { action.parameters.typingIntervalMs ?? 20 },
                            set: { value in saveAction { $0.parameters.typingIntervalMs = value } }), in: 0...500, step: 5,
                                      display: "\(action.parameters.typingIntervalMs ?? 20) ms")
                    }
                    if case .keyboardShortcut(let shortcut) = trigger.input,
                       let alias = SecureInputHotKeys.secureAlias(for: shortcut) {
                        Label("In password fields macOS keeps \(shortcut.displayString) for typing characters, so press \(alias.displayString) there instead.",
                              systemImage: "lock.shield")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .aomRowInset()
                    }
                }

            case .runAppleScript, .runShellScript:
                AOMEditorGroup(action.actionType == .runAppleScript ? "AppleScript" : "Shell script",
                               help: "Saves up to 512 output characters plus _exitCode and _timedOut status variables. Later steps can insert the output with {{var:name}}.",
                               rows: true) {
                    TextEditor(text: $scriptContent)
                        .font(AOMFont.mono)
                        .aomTextWell(minHeight: AOMSize.rowDetail * 2 + AOMSpace.x4)
                        .onChange(of: scriptContent) { _, newValue in
                            saveAction { $0.parameters.scriptContent = newValue }
                        }
                        .aomRowInset()
                    AOMSettingRow("Output variable", detail: "Optional, up to 55 characters") {
                        TextField("Output variable (optional, up to 55 characters)", text: stringParameter(\.scriptResultVariable))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: AOMEditorSize.rowField)
                    }
                    AOMSettingRow("Execution timeout", detail: "Seconds") {
                        TextField("30", value: Binding(get: { action.parameters.scriptTimeoutSeconds ?? 30 }, set: { value in
                            saveAction { $0.parameters.scriptTimeoutSeconds = min(120, max(0.1, value)) }
                        }), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: AOMEditorSize.numberField)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Execution timeout in seconds")
                    }
                }

            case .captureArea, .captureFullscreen, .captureWindow, .captureWindowUnderCursor,
                 .capturePreviousArea, .captureScrolling, .captureAllDisplays, .captureText,
                 .captureTextWithLineBreaks, .captureTextWithoutLineBreaks:
                AOMEditorGroup("Capture options",
                               help: action.actionType == .captureScrolling
                                   ? "Scrolls the window under the region and stitches the frames. Stop scrolling to finish; a diagonal or reversed scroll ends it early."
                                   : nil) {
                    AOMEditorNote(ActionType.describeCaptureAction(action.actionType))
                    if !ScreenCaptureService.hasPermission {
                        AOMNotice(.warning, "Screen Recording permission is required.") {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        }
                    }
                }
            case .captureSelfTimer:
                AOMEditorGroup("Self-timer", help: "Counts down on the HUD, then opens the area selection.", rows: true) {
                    timingField("Delay before capture (seconds)", key: \.selfTimerSeconds, defaultValue: 5)
                }
            case .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
                 .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
                AOMEditorGroup("Most recent capture", rows: true) {
                    AOMEditorNote(ActionType.describeCaptureAction(action.actionType))
                        .aomRowInset()
                    if action.actionType == .ocrLastCapture {
                        AOMToggleRow("Keep line breaks", isOn: boolParameter(\.ocrKeepsLineBreaks))
                    }
                }

            case .openURL:
                AOMEditorGroup("URL", help: "{{var:name}} inserts a workflow variable, for example a script's output.") {
                    TextField("https://…", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: url) { _, newValue in
                            saveAction { $0.parameters.url = newValue }
                        }
                }

            case .activateApplication, .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
                AOMEditorGroup("Application") {
                    HStack(spacing: AOMSpace.x2) {
                        TextField("Application name or bundle ID", text: $applicationName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: applicationName) { _, newValue in
                                saveAction {
                                    if $0.parameters.applicationName != newValue { $0.parameters.applicationPath = nil }
                                    $0.parameters.applicationName = newValue
                                }
                            }
                        Button("Choose Application…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let selected = panel.url {
                                applicationName = Bundle(url: selected)?.bundleIdentifier ?? selected.deletingPathExtension().lastPathComponent
                                saveAction { $0.parameters.applicationPath = selected.path; $0.parameters.applicationName = applicationName }
                            }
                        }
                    }
                    if action.actionType == .forceQuitApplication {
                        AOMEditorNote("Leave empty to force quit the frontmost app.")
                    }
                }

            case .sendKeyStroke:
                let monitoring = keyboardMonitor.isMonitoring
                AOMEditorGroup("Shortcut to send") {
                    // Display well: the recorded keys as key caps, or the recording state.
                    Group {
                        if monitoring {
                            Label("Recording — press any key…", systemImage: "record.circle")
                                .font(AOMFont.bodyEmphasis)
                                .foregroundStyle(AOMColor.dangerText)
                                .symbolEffect(.pulse, options: .repeating, isActive: monitoring)
                        } else if let shortcut = recordedShortcut {
                            AOMShortcutKeys(shortcut: shortcut)
                        } else {
                            Text("No shortcut set")
                                .font(AOMFont.body)
                                .foregroundStyle(AOMColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
                    .background(monitoring ? AOMTone.recording.wash(increasedContrast: false) : AOMColor.raised,
                                in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                            .strokeBorder(monitoring ? AOMColor.recording : AOMColor.hairline, lineWidth: monitoring ? 2 : 1)
                    }
                    .aomAnimation(.quick, value: monitoring)

                    // Buttons
                    HStack(spacing: AOMSpace.x3) {
                        if monitoring {
                            Button(action: {
                                keyboardMonitor.stopRecording()
                            }) {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(minWidth: AOMSize.rowDetail * 2)
                            }
                            .keyboardShortcut(.escape, modifiers: [])
                            .buttonStyle(.borderedProminent)
                            .tint(AOMColor.recording)
                        } else {
                            Button(action: {
                                keyboardMonitor.startRecording { shortcut in
                                    recordedShortcut = shortcut
                                    saveAction {
                                        $0.parameters.shortcutKeyCode = shortcut.keyCode
                                        $0.parameters.shortcutModifiers = shortcut.modifiers.rawValue
                                    }
                                }
                            }) {
                                Label("Record Shortcut", systemImage: "record.circle")
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .buttonStyle(.bordered)
                        }

                        if recordedShortcut != nil && !monitoring {
                            Button(action: {
                                recordedShortcut = nil
                                saveAction {
                                    $0.parameters.shortcutKeyCode = nil
                                    $0.parameters.shortcutModifiers = nil
                                }
                            }) {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AOMColor.dangerText)
                        }
                    }
                }
                AOMEditorGroup("Target app", help: "A named app must already be running. Delivery uses its process ID; app support for background shortcuts varies.") {
                    TextField("Target app bundle ID (empty = focused app)", text: stringParameter(\.targetApplicationBundleID))
                        .textFieldStyle(.roundedBorder)
                }

            default:
                if ActionParameterForm.handles(action.actionType) {
                    ActionParameterForm(action: action, triggers: appState.currentPreset.triggers) { modify in saveAction(modify) }
                } else {
                    AOMEditorGroup("About this action") {
                        AOMEditorNote(action.actionType.description)
                    }
                }
            }

            if action.actionType.isDestructive {
                AOMEditorGroup("Safety", rows: true) {
                    AOMToggleRow("Ask for confirmation before running", isOn: Binding(
                        get: { action.parameters.requiresConfirmation != false },
                        set: { on in saveAction { $0.parameters.requiresConfirmation = on ? nil : false } }))
                    if action.parameters.requiresConfirmation == false {
                        AOMEditorNote("This will run without asking. \(action.actionType.rawValue) cannot be undone.", tone: .warning)
                            .aomRowInset()
                    }
                }
            }

            AOMEditorGroup("Sequence options", rows: true) {
                timingField("Before (ms)", key: \.delayBeforeMs)
                timingField("After (ms)", key: \.delayAfterMs)
                AOMSettingRow("Repeat") {
                    AOMRowStepper("Repeat", value: Binding(get: { action.parameters.repeatCount ?? 1 }, set: { count in
                        saveAction { $0.parameters.repeatCount = count }
                    }), in: 1...100, display: "\(action.parameters.repeatCount ?? 1) time(s)")
                }
                timingField("Between repeats (ms)", key: \.repeatIntervalMs)
                AOMToggleRow("Continue to next step on failure", isOn: boolParameter(\.continueOnFailure))
                if action.actionType.category == .windowManagement {
                    AOMToggleRow("Use the currently focused window at this step",
                                 help: "Off: keep the window selected when the sequence began. On: use the window focused after earlier actions.",
                                 isOn: boolParameter(\.useCurrentWindow))
                }
            }
            AOMEditorGroup("Run only when",
                           help: "All enabled conditions must match. Unknown battery information skips battery-dependent steps.",
                           rows: true) {
                conditionField("App bundle ID", prompt: "Blank = any app", key: \.onlyAppBundleID)
                conditionField("Window title contains", prompt: "Blank = any title", key: \.windowTitleContains)
                conditionField("Window title regex", prompt: "Optional", key: \.windowTitleRegex)
                optionalCondition("Battery at least (%)", key: \.minimumBatteryPercent, range: 0...100)
                optionalCondition("Battery at most (%)", key: \.maximumBatteryPercent, range: 0...100)
                optionalCondition("At least displays", key: \.minimumDisplayCount, range: 1...32)
                optionalCondition("At most displays", key: \.maximumDisplayCount, range: 1...32)
                AOMSettingRow("Power") {
                    Picker("Power", selection: stringParameter(\.powerSource)) {
                        Text("Any").tag(""); Text("AC power").tag("ac"); Text("Battery").tag("battery")
                    }
                    .pickerStyle(.menu)
                }
            }

            // Test button: the step's one primary action.
            Button(action: {
                ActionExecutor.executeActions([action], fromTrackpad: trigger.input.category == .trackpad, triggerID: trigger.id)
            }) {
                Label("Test Action", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(AOMSpace.x3)
            .overlay(alignment: .top) { AOMRowDivider(inset: 0, trailingInset: 0) }

            Spacer(minLength: 0)
        }
    }

    private func setSnap(x: Double, y: Double, width: Double, height: Double) {
        saveAction { action in
            action.parameters.snapX = x; action.parameters.snapY = y
            action.parameters.snapWidth = width; action.parameters.snapHeight = height
        }
    }
    private func snapSetting(_ title: String, key: WritableKeyPath<ActionParameters, Double?>,
                             fallback: Double) -> some View {
        AOMSettingRow(title) {
            HStack(spacing: AOMSpace.x2) {
                Slider(value: Binding(get: { action.parameters[keyPath: key] ?? fallback }, set: { newValue in
                    saveAction { action in
                        let value = min(1, max(key == \.snapWidth || key == \.snapHeight ? 0.05 : 0, newValue))
                        action.parameters[keyPath: key] = value
                        let x = action.parameters.snapX ?? 0, y = action.parameters.snapY ?? 0
                        let width = action.parameters.snapWidth ?? 0.5, height = action.parameters.snapHeight ?? 1
                        if x + width > 1 {
                            if key == \.snapX { action.parameters.snapX = max(0, 1 - width) }
                            else { action.parameters.snapWidth = max(0.05, 1 - x) }
                        }
                        if y + height > 1 {
                            if key == \.snapY { action.parameters.snapY = max(0, 1 - height) }
                            else { action.parameters.snapHeight = max(0.05, 1 - y) }
                        }
                    }
                }), in: (key == \.snapWidth || key == \.snapHeight ? 0.05 : 0)...1, step: 0.01)
                    .frame(width: AOMEditorSize.rowSlider)
                    .accessibilityLabel(title)
                AOMRowValue("\(Int((action.parameters[keyPath: key] ?? fallback) * 100))%")
            }
        }
    }

    /// A text condition of Run Only When as a row.
    private func conditionField(_ title: String, prompt: String, key: WritableKeyPath<ActionParameters, String?>) -> some View {
        AOMSettingRow(title) {
            TextField(prompt, text: stringParameter(key))
                .textFieldStyle(.roundedBorder)
                .frame(width: AOMEditorSize.rowField)
                .accessibilityLabel(title)
        }
    }

    private func optionalCondition(_ title: String, key: WritableKeyPath<ActionParameters, Int?>, range: ClosedRange<Int>) -> some View {
        AOMSettingRow(title) {
            HStack(spacing: AOMSpace.x2) {
                if action.parameters[keyPath: key] != nil {
                    TextField("Value", value: Binding(get: { action.parameters[keyPath: key] ?? range.lowerBound }, set: { value in
                        saveAction { $0.parameters[keyPath: key] = min(range.upperBound, max(range.lowerBound, value)) }
                    }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.numberField)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("\(title) value")
                }
                Toggle(title, isOn: Binding(get: { action.parameters[keyPath: key] != nil }, set: { enabled in
                    saveAction { $0.parameters[keyPath: key] = enabled ? range.lowerBound : nil }
                }))
            }
        }
    }
    private func stringParameter(_ key: WritableKeyPath<ActionParameters, String?>) -> Binding<String> {
        Binding(get: { action.parameters[keyPath: key] ?? "" }, set: { value in saveAction { $0.parameters[keyPath: key] = value.isEmpty ? nil : value } })
    }
    private func boolParameter(_ key: WritableKeyPath<ActionParameters, Bool?>) -> Binding<Bool> {
        Binding(get: { action.parameters[keyPath: key] ?? false }, set: { value in saveAction { $0.parameters[keyPath: key] = value } })
    }
    private func timingField(_ title: String, key: WritableKeyPath<ActionParameters, Int?>, defaultValue: Int = 0) -> some View {
        AOMSettingRow(title) {
            TextField("0", value: Binding(get: { action.parameters[keyPath: key] ?? defaultValue }, set: { value in
                saveAction { $0.parameters[keyPath: key] = min(60000, max(0, value)) }
            }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: AOMEditorSize.numberField)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
    }
    private func saveAction(_ modify: (inout TriggerAction) -> Void) {
        var updated = ActionTree.rows(appState.currentPreset.triggers.first { $0.id == trigger.id }?.actions ?? []).first { $0.id == action.id }?.action ?? action
        modify(&updated)
        appState.updateAction(in: trigger, action: updated)
    }
}

struct SwipeVelocityConfig: View {
    let gesture: TrackpadGesture
    @State private var velocity: Double

    private var defaultsKey: String { "AOMSwipeMinVelocity_\(gesture.rawValue)" }

    init(gesture: TrackpadGesture) {
        self.gesture = gesture
        _velocity = State(initialValue: GestureSensitivity.velocity(for: gesture))
    }

    var body: some View {
        ConfigSection("Swipe sensitivity", systemImage: "speedometer",
                      help: "Higher values require a faster flick, avoiding conflicts with normal scrolling. Use Global Default removes this swipe's own value.",
                      rows: true, expanded: true) {
            AOMSettingRow("Minimum velocity") {
                HStack(spacing: AOMSpace.x2) {
                    Slider(value: Binding(get: { velocity }, set: {
                        velocity = $0; UserDefaults.standard.set($0, forKey: defaultsKey)
                    }), in: 50...2000, step: 50)
                        .frame(width: AOMEditorSize.rowSlider)
                        .accessibilityLabel("Minimum velocity")
                        .accessibilityValue("\(Int(velocity)) pt/s")
                    AOMRowValue("\(Int(velocity)) pt/s")
                }
            }
            Button("Use Global Default") {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                velocity = GestureSensitivity.velocity(for: gesture)
            }
            .aomRowInset()
        }
    }
}

struct SoundOutputConfig: View {
    let action: TriggerAction
    let save: (String, String?) -> Void
    @State private var name = ""
    @State private var devices: [AudioOutputDevice] = []
    init(action: TriggerAction, save: @escaping (String, String?) -> Void) {
        self.action = action; self.save = save
        _name = State(initialValue: action.parameters.audioOutputName ?? "")
    }
    var body: some View {
        AOMEditorGroup("Sound output",
                       help: "For AirPlay, enter the exact room name. Sound settings opens briefly to connect and closes after confirmation.") {
            TextField("Device or AirPlay room name (e.g. Bedroom)", text: Binding(
                get: { name }, set: { name = $0; save($0, nil) }))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: AOMSpace.x2) {
                Menu("Choose Connected Device") {
                    ForEach(devices.filter { $0.name != "AirPlay" }) { device in
                        Button(device.name) {
                            name = device.name
                            save(device.name, device.uid)
                        }
                    }
                }
                .fixedSize()
                Button("Refresh Devices") { devices = AudioOutputService.devices() }
                    .controlSize(.small)
            }
        }
        .onAppear { devices = AudioOutputService.devices() }
    }
}
