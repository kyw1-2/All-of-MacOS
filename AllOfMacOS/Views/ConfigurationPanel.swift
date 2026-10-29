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
/// card in a card): a hairline above, a monochrome symbol, the title,
/// "Advanced" as its detail, an ⓘ for the explanation and a disclosure
/// chevron. Pass `rows: true` when the content is `AOMSettingRow`s.
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
        AOMEditorGroup(title, symbol: systemImage, detail: isAdvanced ? "Advanced" : nil, help: help,
                       rows: rows, isExpanded: $expanded) {
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
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Action: \(action.actionType.rawValue)") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: action.actionType.iconName)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text(action.actionType.rawValue)
                            .font(.headline)
                    }

                    Divider()

                    Toggle("Enabled", isOn: Binding(get: { action.isEnabled }, set: { value in
                        saveAction { $0.isEnabled = value }
                    }))
                }
                .padding(8)
            }

            GroupBox("Name & Notes") {
                VStack(alignment: .leading) {
                    TextField("Optional action name", text: stringParameter(\.label))
                    TextField("Notes", text: stringParameter(\.notes), axis: .vertical).lineLimit(2...4)
                }.textFieldStyle(.roundedBorder).padding(8)
            }

            // Action-specific parameters
            switch action.actionType {
            case .triggerNamedTrigger:
                GroupBox("Named Trigger to Run") {
                    VStack(alignment: .leading) {
                        TextField("Exact callable name", text: stringParameter(\.namedTriggerName))
                        Menu("Choose Named Trigger") {
                            ForEach(appState.currentPreset.triggers.filter { if case .namedTrigger = $0.input { return true }; return false }) { named in
                                if case .namedTrigger(let name) = named.input {
                                    Button(name + " · " + (named.appBundleID ?? "All Apps")) { saveAction { $0.parameters.namedTriggerName = name } }
                                }
                            }
                        }
                        Text("Create reusable macros in Other Triggers. This step waits until the called macro finishes; recursive calls fail safely.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            case .saveWindowLayout, .restoreWindowLayout:
                GroupBox("Window Layout") {
                    VStack(alignment: .leading) {
                        TextField("Saved layout name", text: stringParameter(\.windowLayoutName))
                        Text("Use the same name to save and restore. Only identifiable open windows on connected displays are restored.").font(.caption)
                    }.padding(8)
                }
            case .showHUD:
                GroupBox("HUD Message") { TextField("Message", text: stringParameter(\.hudText)).padding(8) }
            case .showCheatSheet:
                Text("Shows or hides the bindings available to the current application.").font(.callout)
            case .actionGroup:
                GroupBox("Group") {
                    Text("Select this group and choose Add to Group to insert child actions. Conditions and repeat settings apply to the entire group.")
                        .font(.callout).foregroundStyle(.secondary).padding(8)
                }
            case .setVariable:
                GroupBox("Set Workflow Variable") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name (letters, numbers, underscore)", text: stringParameter(\.variableName))
                        TextField("String value", text: stringParameter(\.variableValue))
                        Text("Variable values are shared across triggers and persist across restarts. 128 variables maximum; values up to 512 characters. Do not store passwords.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            case .ifElse:
                GroupBox("If / Else Condition") {
                    VStack(alignment: .leading, spacing: 8) {
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
                        }
                        Picker("Comparison", selection: Binding(get: { action.parameters.conditionOperator ?? "equals" }, set: { op in
                            saveAction { $0.parameters.conditionOperator = op }
                        })) {
                            ForEach(WorkflowBranchCondition.operators, id: \.id) { entry in
                                Text(entry.title).tag(entry.id)
                            }
                        }
                        TextField("Compare to", text: stringParameter(\.conditionValue))
                        Text("THEN: \(action.parameters.children?.count ?? 0) steps   ELSE: \(action.parameters.elseChildren?.count ?? 0) steps")
                            .font(.caption.bold())
                        Text("Select the If/Else step in the Action Sequence panel and choose Add THEN or Add ELSE. The condition is checked after the step delay.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).padding(8)
                }
            case .customSnapWindow:
                GroupBox("Custom Snap Area") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Target display", selection: Binding(get: { action.parameters.snapDisplay ?? "current" }, set: { mode in
                            saveAction { $0.parameters.snapDisplay = mode }
                        })) {
                            Text("Current display").tag("current")
                            Text("Primary display").tag("primary")
                            Text("Next display").tag("next")
                            Text("Display under pointer").tag("pointer")
                        }
                        Text("Percent of visible screen area (top-left origin)")
                            .font(.caption).foregroundStyle(.secondary)
                        snapSetting("X", key: \.snapX, fallback: 0)
                        snapSetting("Y", key: \.snapY, fallback: 0)
                        snapSetting("Width", key: \.snapWidth, fallback: 0.5)
                        snapSetting("Height", key: \.snapHeight, fallback: 1)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.5))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.3))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2))
                                .frame(width: geometry.size.width * (action.parameters.snapWidth ?? 0.5),
                                       height: geometry.size.height * (action.parameters.snapHeight ?? 1))
                                .offset(x: geometry.size.width * (action.parameters.snapX ?? 0),
                                        y: geometry.size.height * (action.parameters.snapY ?? 0))
                        }
                        .frame(height: 110)
                        HStack {
                            Button("Left Half") { setSnap(x: 0, y: 0, width: 0.5, height: 1) }
                            Button("Right Half") { setSnap(x: 0.5, y: 0, width: 0.5, height: 1) }
                            Button("Top Third") { setSnap(x: 0, y: 0, width: 1, height: 0.333) }
                        }
                        Text("The window is moved only when this action runs. The area automatically scales across different monitor resolutions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            case .wait:
                GroupBox("Wait") { timingField("Duration (ms)", key: \.waitMs, defaultValue: 250).padding(8) }
            case .volumeUp, .volumeDown:
                GroupBox("Volume step") {
                    Stepper(value: Binding(get: { action.parameters.volumeStepPercent ?? 6 },
                                           set: { value in saveAction { $0.parameters.volumeStepPercent = value } }), in: 1...100, step: 1) {
                        Text("\(Int(action.parameters.volumeStepPercent ?? 6)) percentage points per click")
                    }.padding(8)
                }
            case .setSoundOutput:
                SoundOutputConfig(action: action) { name, uid in
                    saveAction { $0.parameters.audioOutputName = name; $0.parameters.audioOutputUID = uid }
                }
                .id(action.id)
            case .typeText:
                GroupBox("Text to Type") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .onChange(of: text) { _, newValue in saveAction { $0.parameters.text = newValue } }
                        Stepper(value: Binding(get: { action.parameters.typingIntervalMs ?? 20 },
                            set: { value in saveAction { $0.parameters.typingIntervalMs = value } }), in: 0...500, step: 5) {
                            Text("Delay between characters: \(action.parameters.typingIntervalMs ?? 20) ms")
                        }
                        Text("Types one character at a time without changing your clipboard. Tabs and line breaks press Tab and Return. Works in password fields, including macOS authorization dialogs. {{var:name}} inserts a workflow variable.")
                            .font(.caption).foregroundStyle(.secondary)
                        if case .keyboardShortcut(let shortcut) = trigger.input,
                           let alias = SecureInputHotKeys.secureAlias(for: shortcut) {
                            Label("In password fields macOS keeps \(shortcut.displayString) for typing characters, so press \(alias.displayString) there instead.",
                                  systemImage: "lock.shield")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                }

            case .runAppleScript, .runShellScript:
                GroupBox(action.actionType == .runAppleScript ? "AppleScript" : "Shell Script") {
                    TextEditor(text: $scriptContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .onChange(of: scriptContent) { _, newValue in
                            saveAction { $0.parameters.scriptContent = newValue }
                        }
                        .padding(4)
                }

                TextField("Output variable (optional, up to 55 characters)", text: stringParameter(\.scriptResultVariable))
                Text("Saves up to 512 output characters plus _exitCode and _timedOut status variables. Later steps can insert the output with {{var:name}}.").font(.caption).foregroundStyle(.secondary)
                GroupBox("Execution timeout") {
                    HStack {
                        Text("Seconds")
                        TextField("30", value: Binding(get: { action.parameters.scriptTimeoutSeconds ?? 30 }, set: { value in
                            saveAction { $0.parameters.scriptTimeoutSeconds = min(120, max(0.1, value)) }
                        }), format: .number).textFieldStyle(.roundedBorder)
                    }.padding(8)
                }

            case .captureArea, .captureFullscreen, .captureWindow, .captureWindowUnderCursor,
                 .capturePreviousArea, .captureScrolling, .captureAllDisplays, .captureText,
                 .captureTextWithLineBreaks, .captureTextWithoutLineBreaks:
                GroupBox("Capture Options") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ActionType.describeCaptureAction(action.actionType))
                            .font(.callout).foregroundStyle(.secondary)
                        if action.actionType == .captureScrolling {
                            Text("Scrolls the window under the region and stitches the frames. Stop scrolling to finish; a diagonal or reversed scroll ends it early.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !ScreenCaptureService.hasPermission {
                            Label("Screen Recording permission is required.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }.controlSize(.small)
                        }
                    }.padding(8)
                }
            case .captureSelfTimer:
                GroupBox("Self-Timer") {
                    VStack(alignment: .leading, spacing: 8) {
                        timingField("Delay before capture (seconds)", key: \.selfTimerSeconds, defaultValue: 5)
                        Text("Counts down on the HUD, then opens the area selection.").font(.caption)
                    }.padding(8)
                }
            case .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
                 .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
                GroupBox("Most Recent Capture") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ActionType.describeCaptureAction(action.actionType))
                            .font(.callout).foregroundStyle(.secondary)
                        if action.actionType == .ocrLastCapture {
                            Toggle("Keep line breaks", isOn: boolParameter(\.ocrKeepsLineBreaks))
                        }
                    }.padding(8)
                }

            case .openURL:
                GroupBox("URL") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("https://...", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: url) { _, newValue in
                                saveAction { $0.parameters.url = newValue }
                            }
                        Text("{{var:name}} inserts a workflow variable, for example a script's output.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

            case .activateApplication, .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
                GroupBox("Application") {
                    Button("Choose Application…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let selected = panel.url {
                            applicationName = Bundle(url: selected)?.bundleIdentifier ?? selected.deletingPathExtension().lastPathComponent
                            saveAction { $0.parameters.applicationPath = selected.path; $0.parameters.applicationName = applicationName }
                        }
                    }.padding(.top, 8)
                    TextField("Application name or bundle ID", text: $applicationName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: applicationName) { _, newValue in
                            saveAction {
                                if $0.parameters.applicationName != newValue { $0.parameters.applicationPath = nil }
                                $0.parameters.applicationName = newValue
                            }
                        }
                        .padding(8)
                    if action.actionType == .forceQuitApplication {
                        Text("Leave empty to force quit the frontmost app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }

            case .sendKeyStroke:
                TextField("Target app bundle ID (empty = focused app)", text: stringParameter(\.targetApplicationBundleID))
                Text("A named app must already be running. Delivery uses its process ID; app support for background shortcuts varies.").font(.caption).foregroundStyle(.secondary)
                GroupBox("Keyboard Shortcut to Send") {
                    let monitoring = keyboardMonitor.isMonitoring
                    VStack(spacing: 12) {
                        // Display box
                        ZStack {
                            if monitoring {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 10, height: 10)
                                        .overlay(
                                            Circle()
                                                .fill(.red.opacity(0.4))
                                                .frame(width: 18, height: 18)
                                                .scaleEffect(monitoring ? 1.3 : 1.0)
                                                .opacity(monitoring ? 0 : 1)
                                                .animation(AOMDesign.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)), value: monitoring)
                                        )
                                    Text("RECORDING — press any key...")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.red)
                                }
                            } else if let shortcut = recordedShortcut {
                                Text(shortcut.displayString)
                                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            } else {
                                Text("No shortcut set")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(height: 56)
                        .frame(maxWidth: .infinity)
                        .background(
                            monitoring
                                ? Color.red.opacity(0.08)
                                : Color(nsColor: .textBackgroundColor)
                        )
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    monitoring ? Color.red : Color.gray.opacity(0.3),
                                    lineWidth: monitoring ? 2 : 1
                                )
                        )
                        .animation(AOMDesign.animation(.easeInOut(duration: 0.2)), value: monitoring)

                        // Buttons
                        HStack(spacing: 12) {
                            if monitoring {
                                Button(action: {
                                    keyboardMonitor.stopRecording()
                                }) {
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(.white)
                                            .frame(width: 10, height: 10)
                                        Text("Stop")
                                    }
                                    .frame(minWidth: 100)
                                    .padding(.vertical, 4)
                                }
                                .keyboardShortcut(.escape, modifiers: [])
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
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
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 10, height: 10)
                                        Text("Record Shortcut")
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
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
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle")
                                        Text("Clear")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(8)
                }

            default:
                if ActionParameterForm.handles(action.actionType) {
                    ActionParameterForm(action: action, triggers: appState.currentPreset.triggers) { modify in saveAction(modify) }
                } else {
                    GroupBox("Info") {
                        Text(action.actionType.description)
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }
            }

            if action.actionType.isDestructive {
                GroupBox("Safety") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Ask for confirmation before running", isOn: Binding(
                            get: { action.parameters.requiresConfirmation != false },
                            set: { on in saveAction { $0.parameters.requiresConfirmation = on ? nil : false } }))
                        if action.parameters.requiresConfirmation == false {
                            Label("This will run without asking. \(action.actionType.rawValue) cannot be undone.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(8)
                }
            }

            GroupBox("Sequence Options") {
                VStack(alignment: .leading, spacing: 10) {
                    timingField("Before (ms)", key: \.delayBeforeMs)
                    timingField("After (ms)", key: \.delayAfterMs)
                    Stepper(value: Binding(get: { action.parameters.repeatCount ?? 1 }, set: { count in
                        saveAction { $0.parameters.repeatCount = count }
                    }), in: 1...100) { Text("Repeat \(action.parameters.repeatCount ?? 1) time(s)") }
                    timingField("Between repeats (ms)", key: \.repeatIntervalMs)
                    Toggle("Continue to next step on failure", isOn: boolParameter(\.continueOnFailure))
                    if action.actionType.category == .windowManagement {
                        Toggle("Use the currently focused window at this step", isOn: boolParameter(\.useCurrentWindow))
                        Text("Off: keep the window selected when the sequence began. On: use the window focused after earlier actions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            GroupBox("Run Only When") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("App bundle ID (blank = any app)", text: stringParameter(\.onlyAppBundleID))
                    TextField("Window title contains (blank = any title)", text: stringParameter(\.windowTitleContains))
                    TextField("Window title regex (optional)", text: stringParameter(\.windowTitleRegex))
                    optionalCondition("Battery at least (%)", key: \.minimumBatteryPercent, range: 0...100)
                    optionalCondition("Battery at most (%)", key: \.maximumBatteryPercent, range: 0...100)
                    optionalCondition("At least displays", key: \.minimumDisplayCount, range: 1...32)
                    optionalCondition("At most displays", key: \.maximumDisplayCount, range: 1...32)
                    Picker("Power", selection: stringParameter(\.powerSource)) {
                        Text("Any").tag(""); Text("AC power").tag("ac"); Text("Battery").tag("battery")
                    }
                    Text("All enabled conditions must match. Unknown battery information skips battery-dependent steps.")
                        .font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(8)
            }

            // Test button
            Button(action: {
                ActionExecutor.executeActions([action], fromTrackpad: trigger.input.category == .trackpad, triggerID: trigger.id)
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Test Action")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
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
        HStack(spacing: 8) {
            Text(title).frame(width: 52, alignment: .leading)
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
            Text("\(Int((action.parameters[keyPath: key] ?? fallback) * 100))%")
                .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }

    private func optionalCondition(_ title: String, key: WritableKeyPath<ActionParameters, Int?>, range: ClosedRange<Int>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { action.parameters[keyPath: key] != nil }, set: { enabled in
                saveAction { $0.parameters[keyPath: key] = enabled ? range.lowerBound : nil }
            }))
            if action.parameters[keyPath: key] != nil {
                TextField("Value", value: Binding(get: { action.parameters[keyPath: key] ?? range.lowerBound }, set: { value in
                    saveAction { $0.parameters[keyPath: key] = min(range.upperBound, max(range.lowerBound, value)) }
                }), format: .number).frame(width: 55)
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
        HStack {
            Text(title)
            TextField("0", value: Binding(get: { action.parameters[keyPath: key] ?? defaultValue }, set: { value in
                saveAction { $0.parameters[keyPath: key] = min(60000, max(0, value)) }
            }), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
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
        GroupBox("Sound Output") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Device or AirPlay room name (e.g. Bedroom)", text: Binding(
                    get: { name }, set: { name = $0; save($0, nil) }))
                    .textFieldStyle(.roundedBorder)
                Menu("Choose connected device") {
                    ForEach(devices.filter { $0.name != "AirPlay" }) { device in
                        Button(device.name) {
                            name = device.name
                            save(device.name, device.uid)
                        }
                    }
                }
                Button("Refresh devices") { devices = AudioOutputService.devices() }
                    .controlSize(.small)
                Text("For AirPlay, enter the exact room name. Sound settings opens briefly to connect and closes after confirmation.")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(8)
        }
        .onAppear { devices = AudioOutputService.devices() }
    }
}
