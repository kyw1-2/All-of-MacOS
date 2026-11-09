import SwiftUI

struct AddTriggerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var keyboardMonitor: KeyboardMonitor
    @State private var category: TriggerCategory
    init(keyboardMonitor: KeyboardMonitor, category: TriggerCategory) {
        self.keyboardMonitor = keyboardMonitor
        _category = State(initialValue: category == .all ? .trackpad : category)
        // Isolated UI previews can open the sheet on a MIDI Control Change
        // trigger (`--aom-preview-add-midi-trigger`) to review its rows.
        if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-add-midi-trigger") {
            _otherTriggerMode = State(initialValue: "event")
            _systemEventKind = State(initialValue: "midi")
            _midiStatus = State(initialValue: MIDIMessageType.controlChange.rawValue)
            _midiMinimum = State(initialValue: 0)
        }
    }

    @State private var selectedGesture: TrackpadGesture = .twoFingerSwipeUp
    @State private var mouseSpec = MouseTriggerSpec(button: 2, kind: .click)
    @State private var mouseModifiers: UInt = 0
    @State private var trackpadModifiers: UInt = 0
    @State private var longTouchMs = 500
    @State private var recordedShortcut: KeyboardShortcut?
    @State private var keyboardMode = "shortcut"
    @State private var typedAbbreviation = ""
    @State private var typedReplacement = ""
    @State private var sequenceStrokes: [KeySequenceStroke] = []
    @State private var sequenceHoldEnabled = false
    @State private var sequenceHoldMs = 600
    @State private var sequenceGapMs = 450
    @State private var triggerName = ""
    @State private var namedTriggerName = ""
    @State private var otherTriggerMode = "named"
    @State private var scheduleKind = "daily"
    @State private var scheduleHour = 9
    @State private var scheduleMinute = 0
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var intervalMinutes = 30
    @State private var restrictInterval = false
    @State private var windowStartMinute = 9 * 60
    @State private var windowEndMinute = 17 * 60
    @State private var restrictDates = false
    @State private var windowFirstDate = Date()
    @State private var windowLastDate = Date().addingTimeInterval(30 * 86400)
    @State private var systemEventKind = "display"
    @State private var eventFilter = ""
    @State private var eventNumber = 60
    @State private var hidVendor = 1
    @State private var hidProduct = 1
    @State private var hidPage = 12
    @State private var hidUsage = 1
    @State private var hidMinimum = 1
    @State private var hidMaximum = 1
    @State private var midiChannel = 0
    @State private var midiStatus = 144
    @State private var midiMinimum = 1
    @State private var midiMaximum = 127
    @State private var gamepadControl = "a"
    @State private var eventPressed = true
    @State private var powerOnAC = true
    @State private var systemEventAppID = ""
    @State private var gestureSearch = ""
    @State private var drawingName = ""
    @State private var drawingSamples: [[DrawingPoint]] = []
    @State private var drawingCertainty: Double = 0.7
    @State private var drawingIgnoreDirection = false

    /// The input kinds as one segmented control (HIG #55: five short,
    /// equal segments), so the choice that decides everything else is in
    /// view instead of inside a pop-up menu.
    private static func shortTitle(_ category: TriggerCategory) -> String {
        switch category {
        case .trackpad: return "Trackpad"
        case .keyboard: return "Keyboard"
        case .normalMouse: return "Mouse"
        case .drawings: return "Drawing"
        case .otherTriggers: return "Other"
        case .all: return "All"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            // Named like the command that opens it (File › New Automation,
            // the toolbar's New Automation), with what happens next.
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text("New Automation")
                    .font(AOMFont.title)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose what starts it. You add the actions it runs next.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
            }

            Picker("Input type", selection: $category) {
                ForEach(TriggerCategory.inputCategories) { item in
                    Text(Self.shortTitle(item)).tag(item)
                        .help(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Input type")
            .onChange(of: category) { _, _ in keyboardMonitor.stopRecording() }

            switch category {
            case .trackpad:
                trackpadPicker
            case .keyboard:
                Picker("Keyboard input", selection: $keyboardMode) {
                    Text("Shortcut").tag("shortcut")
                    Text("Key Sequence").tag("sequence")
                    Text("Typed String").tag("typed")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if keyboardMode == "sequence" { sequenceRecorder }
                else if keyboardMode == "typed" { typedStringFields }
                else { keyboardRecorder }
            case .normalMouse:
                mousePicker
            case .drawings:
                ScrollView(showsIndicators: false) {
                    DrawingPatternComposer(name: $drawingName, samples: $drawingSamples,
                                           certainty: $drawingCertainty,
                                           ignoreDirection: $drawingIgnoreDirection)
                        .padding(AOMSpace.x1)
                }.frame(height: AOMEditorSize.drawingComposer)
            case .otherTriggers:
                otherTriggerPicker
            case .all:
                EmptyView()
            }

            TextField("Automation name (optional)", text: $triggerName)
                .textFieldStyle(.roundedBorder)
                .help("Unnamed automations are titled by their input")

            AOMDivider()
            HStack(spacing: AOMSpace.x3) {
                // Why Add is unavailable, in words (HIG Feedback #109).
                if let reason = missingReason {
                    Label(reason, systemImage: "info.circle")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AOMSpace.x2)
                Button("Cancel") { keyboardMonitor.stopRecording(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addTrigger() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: category == .drawings ? AOMEditorSize.drawingSheet : AOMEditorSize.triggerSheet)
    }

    /// What is still missing before Add works; nil when it does.
    private var missingReason: String? {
        guard !canAdd else { return nil }
        switch category {
        case .keyboard:
            if keyboardMode == "sequence" {
                if sequenceHoldEnabled { return "Record exactly one key to hold." }
                return sequenceStrokes.count > 6 ? "Use at most six keys." : "Record at least two keys."
            }
            if keyboardMode == "typed" { return "Type an abbreviation of 2 to 64 characters on one line." }
            return "Record a shortcut first."
        case .trackpad:
            return TriggerValidation.problem(for: .trackpadGesture(selectedGesture), requiredModifiers: trackpadModifiers)
        case .normalMouse:
            return TriggerValidation.problem(for: mouseInput, requiredModifiers: mouseModifiers)
        case .drawings:
            return drawingSamples.isEmpty ? "Draw the shape at least once." : "Name the drawing."
        case .otherTriggers:
            switch otherTriggerMode {
            case "scheduled":
                if scheduleKind == "interval", !(1...1440).contains(intervalMinutes) { return "Choose an interval of 1 to 1,440 minutes." }
                return "Choose at least one day."
            case "event":
                if systemEventKind == "file" { return "Choose a file or folder." }
                if systemEventKind == "appLaunch" || systemEventKind == "appQuit" { return "Choose an application." }
                if ["batteryBelow", "batteryAbove"].contains(systemEventKind) { return "Choose a charge of 1 to 99%." }
                if systemEventKind == "hid" { return "Check the IDs: vendor and product 1–65535, minimum no higher than maximum." }
                return "Check the event's values."
            default:
                return "Name the trigger."
            }
        case .all:
            return nil
        }
    }

    private var canAdd: Bool {
        switch category {
        case .keyboard:
            if keyboardMode == "sequence" { return (sequenceHoldEnabled ? sequenceStrokes.count == 1 : sequenceStrokes.count >= 2) && sequenceStrokes.count <= 6 }
            if keyboardMode == "typed" { return typedStringIsValid }
            return recordedShortcut != nil
        case .trackpad: return TriggerValidation.problem(for: .trackpadGesture(selectedGesture), requiredModifiers: trackpadModifiers) == nil
        case .normalMouse: return TriggerValidation.problem(for: mouseInput, requiredModifiers: mouseModifiers) == nil
        case .drawings: return !drawingSamples.isEmpty && !drawingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .otherTriggers: return canAddOtherTrigger
        case .all: return false
        default: return true
        }
    }

    private func gestureIcon(_ gesture: TrackpadGesture) -> String {
        let name = gesture.rawValue.lowercased()
        if name.contains("swipe") { return "hand.draw" }
        if name.contains("pinch") { return "arrow.down.right.and.arrow.up.left" }
        if name.contains("rotate") { return "arrow.triangle.2.circlepath" }
        if name.contains("tap") || name.contains("click") { return "hand.tap" }
        if name.contains("tiptap") { return "hand.point.up.left.and.text" }
        if name.contains("circle") { return "circle.dashed" }
        if name.contains("corner") { return "square.topright" }
        if name.contains("middle click") { return "rectangle.center.inset.filled" }
        return "hand.point.up"
    }

    private var filteredGestures: [TrackpadGesture] {
        if gestureSearch.isEmpty { return TrackpadGesture.allCases.map { $0 } }
        return TrackpadGesture.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(gestureSearch) }
    }

    private var trackpadPicker: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text("Gesture")
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
            TextField("Search gestures", text: $gestureSearch)
                .textFieldStyle(.roundedBorder)
            // A real list: arrow keys and type-to-select move the selection,
            // Return or a double-click adds (b.4).
            ScrollViewReader { proxy in
                List(selection: Binding<TrackpadGesture?>(
                    get: { selectedGesture },
                    set: { if let gesture = $0 { selectedGesture = gesture } })) {
                    ForEach(filteredGestures) { gesture in
                        Label(gesture.rawValue, systemImage: gestureIcon(gesture))
                            .font(AOMFont.body)
                            .tag(gesture)
                            .id(gesture)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: TrackpadGesture.self) { _ in
                    EmptyView()
                } primaryAction: { gestures in
                    if let gesture = gestures.first { selectedGesture = gesture; addTrigger() }
                }
                .onChange(of: gestureSearch) { _, _ in
                    if let first = filteredGestures.first, !filteredGestures.contains(selectedGesture) {
                        selectedGesture = first
                        withAnimation(AOMMotion.standard) { proxy.scrollTo(first, anchor: .top) }
                    }
                }
                .overlay {
                    if filteredGestures.isEmpty {
                        Text("No gesture matches “\(gestureSearch)”.")
                            .font(AOMFont.body)
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                }
            }
            .frame(height: AOMEditorSize.gestureList)
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous).strokeBorder(AOMTheme.hairline, lineWidth: 0.5))
            .accessibilityLabel("Gestures")
            if selectedGesture.isLongTouch {
                Stepper("Hold for \(String(format: "%.1f", Double(longTouchMs) / 1000)) s", value: $longTouchMs, in: 100...5000, step: 100)
            }
            if selectedGesture.isTrackpadScroll {
                RequiredModifierToggles(modifiers: $trackpadModifiers)
                if let problem = TriggerValidation.problem(for: .trackpadGesture(selectedGesture), requiredModifiers: trackpadModifiers) {
                    AOMEditorNote(problem, tone: .warning)
                }
            }
        }
    }

    private var sequenceRecorder: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text(sequenceStrokes.isEmpty ? "No steps recorded" : sequenceStrokes.map(\.displayName).joined(separator: " → "))
                .font(AOMFont.body.monospaced())
                .foregroundStyle(sequenceStrokes.isEmpty ? AOMColor.textSecondary : AOMColor.text)
                .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
                .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
            HStack(spacing: AOMSpace.x2) {
                Button(keyboardMonitor.isMonitoring ? "Stop Recording" : "Record Next Key") {
                    if keyboardMonitor.isMonitoring { keyboardMonitor.stopRecording(); return }
                    keyboardMonitor.startRecording { shortcut in
                        if sequenceStrokes.count < 6 {
                            sequenceStrokes.append(KeySequenceStroke(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue))
                        }
                    }
                }.disabled(!keyboardMonitor.isMonitoring && sequenceStrokes.count >= 6)
                Menu("Modifier Press") {
                    Button("⌘ Command") { appendModifier(55) }
                    Button("⌥ Option") { appendModifier(58) }
                    Button("⌃ Control") { appendModifier(59) }
                    Button("⇧ Shift") { appendModifier(56) }
                }
                .fixedSize()
                .disabled(sequenceStrokes.count >= 6)
                Button("Undo") { if !sequenceStrokes.isEmpty { sequenceStrokes.removeLast() } }
                    .disabled(sequenceStrokes.isEmpty)
                Spacer(minLength: 0)
                AOMInfoButton("Regular keys still reach the active app. Modifier-only key presses are available via Modifier Press. At least 2 steps are needed unless hold is selected.",
                              topic: "key sequences")
            }
            Toggle("Single-key hold instead of sequence", isOn: $sequenceHoldEnabled)
            if sequenceHoldEnabled {
                Stepper("Hold for \(sequenceHoldMs) ms", value: $sequenceHoldMs, in: 300...5000, step: 100)
            } else {
                Stepper("Max gap: \(sequenceGapMs) ms", value: $sequenceGapMs, in: 100...2000, step: 50)
            }
        }
    }
    private func appendModifier(_ code: UInt16) {
        if sequenceStrokes.count < 6 { sequenceStrokes.append(KeySequenceStroke(keyCode: code, modifiers: 0)) }
    }

    private var keyboardRecorder: some View {
        VStack(spacing: AOMSpace.x3) {
            Group {
                if let shortcut = recordedShortcut {
                    AOMShortcutKeys(shortcut: shortcut)
                } else {
                    Text(keyboardMonitor.isMonitoring ? "Press a key combination…" : "No shortcut recorded")
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
            .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                    .strokeBorder(keyboardMonitor.isMonitoring ? AOMColor.accent : AOMColor.hairline,
                                  lineWidth: keyboardMonitor.isMonitoring ? 2 : 0.5)
            )
            .aomAnimation(.quick, value: keyboardMonitor.isMonitoring)

            // While recording, the same button stops (the next key combination
            // is taken otherwise).
            Button(keyboardMonitor.isMonitoring ? "Stop Recording"
                   : (recordedShortcut == nil ? "Record Shortcut" : "Record Again")) {
                if keyboardMonitor.isMonitoring { keyboardMonitor.stopRecording(); return }
                keyboardMonitor.startRecording { shortcut in
                    recordedShortcut = shortcut
                }
            }
        }
    }

    private var mousePicker: some View {
        MouseTriggerEditor(spec: $mouseSpec, modifiers: $mouseModifiers)
    }

    /// Plain presses of the extra buttons stay in the original `.mouseButton`
    /// encoding so they keep conflict-matching with existing triggers.
    private var mouseInput: TriggerInput { MouseTriggerEditor.input(for: mouseSpec) }

    private var otherTriggerPicker: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Picker("Type", selection: $otherTriggerMode) {
                Text("Named Trigger").tag("named")
                Text("Scheduled").tag("scheduled")
                Text("System Event").tag("event")
            }.pickerStyle(.segmented)

            switch otherTriggerMode {
            case "scheduled": scheduledField
            case "event": systemEventField
            default: namedTriggerField
            }
        }
    }

    /// Scheduled entries fire from the clock, so they need a time and, for
    /// weekly, the days to run on.
    private var scheduledField: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Picker("Schedule", selection: $scheduleKind) {
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                    Text("Interval").tag("interval")
                }.pickerStyle(.segmented)
                AOMInfoButton("Runs while AOM is open. Missed times are not replayed on launch.", topic: "schedules")
            }

            if scheduleKind == "interval" {
                HStack(spacing: AOMSpace.x2) {
                    Text("Every")
                    TextField("30", value: $intervalMinutes, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: AOMEditorSize.numberField)
                    Text("minutes")
                }
                Toggle("Restrict to a time and weekday window", isOn: $restrictInterval)
                if restrictInterval {
                    Stepper("From \(String(format: "%02d:%02d", windowStartMinute / 60, windowStartMinute % 60))", value: $windowStartMinute, in: 0...1439, step: 15)
                    Stepper("Until \(String(format: "%02d:%02d", windowEndMinute / 60, windowEndMinute % 60))", value: $windowEndMinute, in: 0...1439, step: 15)
                    AOMEditorNote("An end time before the start time continues into the next morning.")
                    Toggle("Restrict calendar date range", isOn: $restrictDates)
                    if restrictDates {
                        DatePicker("First date", selection: $windowFirstDate, displayedComponents: .date)
                        DatePicker("Last date", selection: $windowLastDate, in: windowFirstDate..., displayedComponents: .date)
                    }
                }
            } else {
                HStack(spacing: AOMSpace.x2) {
                    Text("At")
                    Picker("", selection: $scheduleHour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: AOMEditorSize.numberField)
                    Text(":")
                    Picker("", selection: $scheduleMinute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: AOMEditorSize.numberField)
                }
            }

            if scheduleKind == "weekly" || (scheduleKind == "interval" && restrictInterval) {
                HStack(spacing: AOMSpace.x1) {
                    ForEach(1...7, id: \.self) { day in
                        let symbols = Calendar.current.shortWeekdaySymbols
                        let names = Calendar.current.weekdaySymbols
                        let on = selectedWeekdays.contains(day)
                        Toggle(symbols[day - 1], isOn: Binding(get: { on }, set: { value in
                            if value { selectedWeekdays.insert(day) } else { selectedWeekdays.remove(day) }
                        }))
                        .toggleStyle(.button)
                        .tint(AOMColor.accent)
                        .help(names[day - 1])
                        .accessibilityLabel(names[day - 1])
                    }
                }
                AOMEditorNote(SystemTriggerKind.weekdayNames(Array(selectedWeekdays)))
            }
        }
    }

    /// System events are discrete state changes rather than times, so they only
    /// need which event, plus an app for the launch/quit cases. One card of
    /// setting rows; explanations sit in each row's ⓘ.
    private var systemEventField: some View {
        AOMSection {
            AOMSettingRow("Event", help: BTTInputTriggerKinds.kind(for: systemEventKind) != nil
                          ? "Stage 1 fires on the click, stage 2 on the deep press, once per press. Stage 2 needs Force Click and haptic feedback turned on in Trackpad settings."
                          : nil) {
                Picker("Event", selection: $systemEventKind) {
                    ForEach(Self.systemEvents, id: \.0) { event in Text(event.1).tag(event.0) }
                }
                .pickerStyle(.menu)
            }
            if ["wifiOn", "wifiOff", "usbOn", "usbOff", "btOn", "btOff", "midi", "gamepad"].contains(systemEventKind) {
                AOMSettingRow("Device or SSID",
                              help: "USB, Bluetooth and MIDI match a substring; Wi-Fi matches the full SSID. Use regex:pattern for a regular expression. SSID names require Location permission.") {
                    TextField("Empty = any", text: $eventFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
                        .accessibilityLabel("Device name / SSID filter (empty = any)")
                }
            }
            if systemEventKind == "file" {
                AOMSettingRow("Path", help: "Watches this file or immediate folder changes, including atomic replacement and later creation.") {
                    TextField("Absolute file or folder path", text: $eventFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
                }
                HStack {
                    Spacer()
                    Button("Choose File or Folder…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
                        if panel.runModal() == .OK { eventFilter = panel.url?.path ?? "" }
                    }
                }
                .aomRowInset()
            }
            if systemEventKind == "variable" {
                AOMSettingRow("Variable") {
                    TextField("Variable name (empty = any)", text: $eventFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
                }
            }
            if systemEventKind == "batteryBelow" || systemEventKind == "batteryAbove" {
                AOMSettingRow("Charge") {
                    AOMRowStepper("Charge", value: $eventNumber, in: 1...99, display: "\(eventNumber)%")
                }
            }
            if systemEventKind == "midi" {
                // Every channel-voice message, "Any" number and the 14-bit
                // Pitch Bend range (3.3.3); see BTTInputEditors.swift.
                MIDITriggerFilterFields(status: $midiStatus, channel: $midiChannel, number: $eventNumber,
                                        minimum: $midiMinimum, maximum: $midiMaximum)
            }
            if systemEventKind == "hid" {
                Group {
                    hidRow("Vendor ID", $hidVendor, help: "Opt-in IOHID input for this exact vendor/product and element usage, in decimal. Standard keyboards/mice are excluded. May require Input Monitoring permission; use values documented by your device.")
                    hidRow("Product ID", $hidProduct)
                    hidRow("Usage page", $hidPage)
                    hidRow("Usage", $hidUsage)
                    hidRow("Minimum value", $hidMinimum)
                    hidRow("Maximum value", $hidMaximum)
                }
            }
            if systemEventKind == "gamepad" {
                AOMSettingRow("Control",
                              help: "Uses macOS GameController extended and micro gamepads (including supported Siri Remotes); triggers and stick directions cross a 50% threshold.") {
                    Picker("Control", selection: $gamepadControl) {
                        ForEach(["a", "b", "x", "y", "leftShoulder", "rightShoulder", "leftTrigger", "rightTrigger", "up", "down", "left", "right", "menu", "options", "leftThumbstick", "rightThumbstick", "leftStickUp", "leftStickDown", "leftStickLeft", "leftStickRight", "rightStickUp", "rightStickDown", "rightStickLeft", "rightStickRight"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMToggleRow("On press (off = release)", isOn: $eventPressed)
            }
            if systemEventKind == "power" {
                AOMSettingRow("When") {
                    Picker("When", selection: $powerOnAC) { Text("Power connected").tag(true); Text("Battery").tag(false) }.pickerStyle(.segmented)
                }
            }
            if ["appLaunch", "appQuit", "appActive", "appInactive"].contains(systemEventKind) {
                AOMSettingRow("Application") {
                    TextField("Application bundle ID", text: $systemEventAppID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
                }
                HStack {
                    Spacer()
                    Button("Choose Application…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                        if panel.runModal() == .OK, let url = panel.url { systemEventAppID = Bundle(url: url)?.bundleIdentifier ?? "" }
                    }
                }
                .aomRowInset()
            }
        }
    }

    /// One decimal field of the generic HID filter as a row.
    private func hidRow(_ title: String, _ value: Binding<Int>, help: String? = nil) -> some View {
        AOMSettingRow(title, help: help) {
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: AOMEditorSize.numberField)
                .multilineTextAlignment(.trailing)
        }
    }
    private static let systemEvents: [(String, String)] = [
        ("display", "Display configuration changes"), ("power", "Power source changes"),
        ("lock", "Screen locks"), ("unlock", "Screen unlocks"), ("sleep", "Mac will sleep"), ("wake", "Mac wakes"),
        ("appLaunch", "Application launches"), ("appQuit", "Application quits"),
        ("appActive", "Application becomes active"), ("appInactive", "Application becomes inactive"),
        ("wifiOn", "Wi-Fi connects"), ("wifiOff", "Wi-Fi disconnects"),
        ("usbOn", "USB connects"), ("usbOff", "USB disconnects"), ("btOn", "Bluetooth connects"), ("btOff", "Bluetooth disconnects"),
        ("file", "File or folder changes"), ("variable", "Variable changes"),
        ("batteryBelow", "Battery drops below"), ("batteryAbove", "Battery rises above"),
        ("screensaverOn", "Screensaver starts"), ("screensaverOff", "Screensaver stops"),
        ("space", "Active Space changes"), ("audio", "Audio output changes"), ("input", "Input source changes"),
        ("clipboard", "Clipboard changes"), ("midi", "MIDI message"), ("gamepad", "Gamepad / Siri Remote control"), ("hid", "Generic HID device input")]
        + BTTInputTriggerKinds.options.map { ($0.key, $0.title) }

    /// Builds the Other Triggers input. Kept separate from `addTrigger` so the
    /// validity check and the constructed value cannot drift apart.
    private func otherTriggerInput() -> TriggerInput {
        switch otherTriggerMode {
        case "scheduled":
            switch scheduleKind {
            case "interval":
                if restrictInterval {
                    let window = TriggerTimeWindow(weekdays: Array(selectedWeekdays).sorted(), startMinute: windowStartMinute, endMinute: windowEndMinute,
                        firstDate: restrictDates ? windowFirstDate : nil, lastDate: restrictDates ? windowLastDate : nil)
                    return .systemEvent(.everyMinutesInWindow(interval: max(1, intervalMinutes), window: window))
                }
                return .systemEvent(.everyMinutes(max(1, intervalMinutes)))
            case "weekly":
                return .systemEvent(.weekly(days: Array(selectedWeekdays).sorted(),
                                            hour: scheduleHour, minute: scheduleMinute))
            default: return .systemEvent(.daily(hour: scheduleHour, minute: scheduleMinute))
            }
        case "event":
            // Force Touch stage 1 / 2 (3.3.3) have no other fields.
            if let kind = BTTInputTriggerKinds.kind(for: systemEventKind) { return .systemEvent(kind) }
            switch systemEventKind {
            case "hid": return .systemEvent(.hidInput(vendorID: hidVendor, productID: hidProduct, usagePage: hidPage, usage: hidUsage, minimumValue: hidMinimum, maximumValue: hidMaximum))
            case "midi": return .systemEvent(.midiMessage(device: eventFilter, status: midiStatus, channel: midiChannel, number: eventNumber, minimumValue: midiMinimum, maximumValue: max(midiMinimum, midiMaximum)))
            case "gamepad": return .systemEvent(.gamepadButton(device: eventFilter, control: gamepadControl, pressed: eventPressed))
            case "wifiOn": return .systemEvent(.wifiConnected(ssid: eventFilter))
            case "wifiOff": return .systemEvent(.wifiDisconnected(ssid: eventFilter))
            case "usbOn": return .systemEvent(.usbConnected(name: eventFilter))
            case "usbOff": return .systemEvent(.usbDisconnected(name: eventFilter))
            case "btOn": return .systemEvent(.bluetoothConnected(name: eventFilter))
            case "btOff": return .systemEvent(.bluetoothDisconnected(name: eventFilter))
            case "file": return .systemEvent(.fileDidChange(path: eventFilter))
            case "variable": return .systemEvent(.variableChanged(name: eventFilter))
            case "batteryBelow": return .systemEvent(.batteryBelow(eventNumber))
            case "batteryAbove": return .systemEvent(.batteryAbove(eventNumber))
            case "appActive": return .systemEvent(.appActivated(systemEventAppID))
            case "appInactive": return .systemEvent(.appDeactivated(systemEventAppID))
            case "sleep": return .systemEvent(.systemWillSleep)
            case "wake": return .systemEvent(.systemDidWake)
            case "screensaverOn": return .systemEvent(.screensaverStarted)
            case "screensaverOff": return .systemEvent(.screensaverStopped)
            case "space": return .systemEvent(.activeSpaceChanged)
            case "audio": return .systemEvent(.audioOutputChanged)
            case "input": return .systemEvent(.inputSourceChanged)
            case "clipboard": return .systemEvent(.clipboardChanged)
            case "power": return .systemEvent(.powerSourceChanged(ac: powerOnAC))
            case "lock": return .systemEvent(.screenLocked)
            case "unlock": return .systemEvent(.screenUnlocked)
            case "appLaunch": return .systemEvent(.appLaunched(systemEventAppID))
            case "appQuit": return .systemEvent(.appQuit(systemEventAppID))
            default: return .systemEvent(.displayChanged)
            }
        default:
            return .namedTrigger(namedTriggerName)
        }
    }

    private var typedStringIsValid: Bool {
        let abbreviation = typedAbbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        return abbreviation.count >= 2 && abbreviation.count <= 64
            && abbreviation.rangeOfCharacter(from: .newlines) == nil
    }

    private var typedStringFields: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text("Type this abbreviation in any app and it is replaced")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            TextField("Abbreviation, e.g. ;email", text: $typedAbbreviation)
                .textFieldStyle(.roundedBorder)
            Text("Replaced with")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            TextField("Replacement text (empty = run the trigger's actions)", text: $typedReplacement)
                .textFieldStyle(.roundedBorder)
            AOMEditorNote("Never expands in password fields. Leave the replacement empty to run this trigger's actions instead.")
        }
    }

    private var canAddOtherTrigger: Bool {
        switch otherTriggerMode {
        case "scheduled":
            if scheduleKind == "interval" { return intervalMinutes >= 1 && intervalMinutes <= 1440 && (!restrictInterval || !selectedWeekdays.isEmpty) }
            if scheduleKind == "weekly" { return !selectedWeekdays.isEmpty }
            return true
        case "event":
            if systemEventKind == "hid" { return (1...65535).contains(hidVendor) && (1...65535).contains(hidProduct) && (0...65535).contains(hidPage) && (0...65535).contains(hidUsage) && hidMinimum <= hidMaximum }
            if systemEventKind == "midi" || BTTInputTriggerKinds.kind(for: systemEventKind) != nil {
                // "Any" (-1) and the Pitch Bend range 0–16383 are valid; the
                // model owns the rule, so the sheet and the monitor agree.
                guard case .systemEvent(let kind) = otherTriggerInput() else { return false }
                return TriggerValidation.systemProblem(for: kind) == nil
            }
            if ["batteryBelow", "batteryAbove"].contains(systemEventKind) { return (1...99).contains(eventNumber) }
            if systemEventKind == "file" { return TriggerSystemPaths.normalized(eventFilter) != nil }
            if systemEventKind == "appLaunch" || systemEventKind == "appQuit" { return !systemEventAppID.isEmpty }
            return true
        default:
            return !namedTriggerName.isEmpty
        }
    }

    private var namedTriggerField: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text("Name")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            TextField("Enter trigger name", text: $namedTriggerName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func addTrigger() {
        guard canAdd else { return }
        let input: TriggerInput
        switch category {
        case .trackpad:
            input = .trackpadGesture(selectedGesture)
        case .keyboard:
            if keyboardMode == "sequence" {
                input = .keySequence(sequenceStrokes)
            } else if keyboardMode == "typed" {
                input = .typedString(TypedStringSpec(abbreviation: typedAbbreviation.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     replacement: typedReplacement))
            } else {
                guard let shortcut = recordedShortcut else { return }
                input = .keyboardShortcut(shortcut)
            }
        case .normalMouse:
            input = mouseInput
        case .drawings:
            input = .drawingPattern(drawingName)
        case .otherTriggers:
            input = otherTriggerInput()
        case .all:
            return
        }

        var trigger = Trigger(
            name: triggerName,
            input: input,
            appBundleID: appState.selectedActivationGroupID == nil ? appState.selectedAppTarget.bundleID : nil
        )
        trigger.activationGroupID = appState.selectedActivationGroupID
        if case .mouse = input { trigger.requiredModifiers = mouseModifiers == 0 ? nil : mouseModifiers }
        if case .trackpadGesture(let gesture) = input {
            if gesture.isTrackpadScroll, trackpadModifiers != 0 { trigger.requiredModifiers = trackpadModifiers }
            if gesture.isLongTouch { trigger.longTouchDurationMs = longTouchMs }
        }
        if case .drawingPattern = input {
            trigger.drawingSamples = drawingSamples
            trigger.drawingCertainty = drawingCertainty
            trigger.drawingIgnoreDirection = drawingIgnoreDirection
        }
        if keyboardMode == "sequence", category == .keyboard {
            trigger.sequenceMaxGapMs = sequenceGapMs
            trigger.sequenceHoldMs = sequenceHoldEnabled ? sequenceHoldMs : 0
        }
        appState.addTrigger(trigger)
        dismiss()
    }
}

struct TriggerEditorCommandActions {
    var search: () -> Void
    var newTrigger: () -> Void
}
private struct TriggerEditorCommandsKey: FocusedValueKey { typealias Value = TriggerEditorCommandActions }
extension FocusedValues {
    var triggerEditorCommands: TriggerEditorCommandActions? {
        get { self[TriggerEditorCommandsKey.self] }
        set { self[TriggerEditorCommandsKey.self] = newValue }
    }
}
struct TriggerEditorCommands: Commands {
    @FocusedValue(\.triggerEditorCommands) private var editor
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Automation") { editor?.newTrigger() }.keyboardShortcut("n", modifiers: .command).disabled(editor == nil)
        }
        CommandGroup(before: .textEditing) {
            Button("Search Automations") { editor?.search() }.keyboardShortcut("f", modifiers: .command).disabled(editor == nil)
        }
        // Controls › Pause AOM and Window › Diagnostics Console / Touch
        // Visualizer (MainShell.swift); installed here because the app
        // already lists these commands.
        AOMShellCommandMenus()
    }
}


/// Picks a Normal Mouse trigger: button, what it does, and the required
/// modifiers. Left/right buttons and scroll show BTT's "you would lose the
/// click" warning until a modifier is chosen, and the owning sheet refuses to
/// create the trigger meanwhile (`TriggerValidation`).
struct MouseTriggerEditor: View {
    @Binding var spec: MouseTriggerSpec
    @Binding var modifiers: UInt
    @State private var globalButtonRecorder: Any?
    @State private var localButtonRecorder: Any?
    @State private var recordingExtraButton = false

    private func stopButtonRecorder() {
        if let monitor = globalButtonRecorder { NSEvent.removeMonitor(monitor) }
        if let monitor = localButtonRecorder { NSEvent.removeMonitor(monitor) }
        globalButtonRecorder = nil
        localButtonRecorder = nil
        recordingExtraButton = false
    }

    private func acceptExtraButton(_ number: Int) {
        guard recordingExtraButton, (2...MouseTriggerSpec.maxButton).contains(number) else { return }
        spec = MouseTriggerSpec(button: number, kind: spec.kind)
        stopButtonRecorder()
    }

    private func startButtonRecorder() {
        stopButtonRecorder()
        recordingExtraButton = true
        globalButtonRecorder = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { event in
            DispatchQueue.main.async { acceptExtraButton(event.buttonNumber) }
        }
        localButtonRecorder = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { event in
            DispatchQueue.main.async { acceptExtraButton(event.buttonNumber) }
            return event // Never consume the user's original mouse input.
        }
    }

    static func input(for spec: MouseTriggerSpec) -> TriggerInput {
        if spec.kind == .click, let legacy = MouseButton.from(cgButton: Int64(spec.button)) { return .mouseButton(legacy) }
        return .mouse(spec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            Text("Mouse trigger")
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
            Picker("Action", selection: Binding(get: { spec.kind }, set: { spec = MouseTriggerSpec(button: spec.button, kind: $0) })) {
                Section("Press") {
                    ForEach([MouseTriggerKind.click, .doubleClick, .tripleClick, .longPress]) { Text($0.rawValue).tag($0) }
                }
                Section("Drag") {
                    ForEach([MouseTriggerKind.dragUp, .dragDown, .dragLeft, .dragRight]) { Text($0.rawValue).tag($0) }
                }
                Section("Scroll wheel") {
                    ForEach([MouseTriggerKind.scrollUp, .scrollDown, .scrollLeft, .scrollRight]) { Text($0.rawValue).tag($0) }
                }
            }
            if !spec.kind.isScroll {
                Picker("Button", selection: Binding(get: { spec.button }, set: { spec = MouseTriggerSpec(button: $0, kind: spec.kind) })) {
                    ForEach(MouseTriggerSpec.pickerButtons, id: \.self) { Text(MouseTriggerSpec.buttonName($0)).tag($0) }
                }
                HStack(spacing: AOMSpace.x2) {
                    Button(recordingExtraButton ? "Cancel Button Capture" : "Learn Extra Mouse Button") {
                        if recordingExtraButton { stopButtonRecorder() }
                        else { startButtonRecorder() }
                    }
                    if recordingExtraButton {
                        Text("Press the mouse's additional button (3–32).")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    }
                }
            }
            RequiredModifierToggles(modifiers: $modifiers)
            if let problem = TriggerValidation.problem(for: MouseTriggerEditor.input(for: spec), requiredModifiers: modifiers) {
                AOMEditorNote(problem, tone: .warning)
            }
        }
        .onDisappear { stopButtonRecorder() }
    }
}


/// ⌃ ⌥ ⇧ ⌘ fn toggle row bound to a raw `NSEvent.ModifierFlags` mask.
struct RequiredModifierToggles: View {
    @Binding var modifiers: UInt
    private static let choices: [(String, NSEvent.ModifierFlags)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command), ("fn", .function)]
    var body: some View {
        HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Text("Required modifiers").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            ForEach(Self.choices, id: \.0) { label, flag in
                Toggle(label, isOn: Binding(
                    get: { modifiers & flag.rawValue != 0 },
                    set: { on in if on { modifiers |= flag.rawValue } else { modifiers &= ~flag.rawValue } }))
                    .toggleStyle(.button)
            }
        }
    }
}
