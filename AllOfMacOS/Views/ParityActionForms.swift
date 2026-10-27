import SwiftUI

/// Controls for the 3.1.0 parity actions, hosted by `ActionParameterForm`.
/// Every control writes straight to the action, so what the editor shows is
/// what the executor runs.
struct ParityActionForm: View {
    let action: TriggerAction
    let save: ((inout TriggerAction) -> Void) -> Void
    @State private var inputSources: [InputSources.Source] = []
    @State private var bluetoothNames: [String] = []
    @State private var pinboards: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
    }

    @ViewBuilder private var content: some View {
        let p = action.parameters
        switch action.actionType {
        case .saveSelectedText:
            variableField(default: "selection")
            note("Reads the selection through Accessibility. Apps that do not expose it get ⌘C, and your clipboard is put back. Use {{var:\(p.variableName ?? "selection")}} in later steps. Variables hold up to 512 characters.")
        case .transformSelectedText, .transformClipboardText:
            Picker("Transform", selection: string(\.textTransform, default: TextTransform.uppercase.rawValue)) {
                ForEach(TextTransform.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if let transform = TextTransform(rawValue: p.textTransform ?? TextTransform.uppercase.rawValue) {
                Text("Example: “\(transform.apply("hello world. second LINE"))”")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            note(action.actionType == .transformSelectedText
                 ? "Pastes the result over the selection, then restores your clipboard."
                 : "Replaces the text on the clipboard. Rich formatting is dropped.")
        case .searchSelectedText:
            TextField("Search URL — {query} is replaced", text: string(\.url, default: TextActionSupport.defaultSearchURL))
                .textFieldStyle(.roundedBorder)
            Menu("Search Engine") {
                ForEach(TextActionSupport.searchPresets, id: \.name) { preset in
                    Button(preset.name) { save { $0.parameters.url = preset.url } }
                }
            }.fixedSize()
            note("Any URL scheme works, including app links. The selection is percent-encoded.")
        case .speakSelectedText:
            note("Uses the system voice. Running the step again while it speaks stops it.")
        case .pasteClipboardItem:
            Stepper(value: int(\.clipboardItemIndex, default: 1), in: 1...500) {
                Text("Item \(p.clipboardItemIndex ?? 1)\((p.clipboardItemIndex ?? 1) == 1 ? " (most recent)" : "")")
            }.accessibilityLabel("Clipboard item number")
            Picker("From", selection: string(\.pinboardName, default: "")) {
                Text("Clipboard History").tag("")
                ForEach(pinboards, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Paste as plain text", isOn: Binding(get: { p.pastePlainText ?? false },
                                                        set: { value in save { $0.parameters.pastePlainText = value ? true : nil } }))
            note("Item 1 is the newest. Pinboards keep their own order.")
        case .saveClipboard, .restoreClipboard:
            note("One saved copy, in every format, kept in memory until AOM quits. Pair Save before a step that changes the clipboard with Restore after it.")
        case .clearClipboard:
            note("Nothing to configure.")
        case .chooseMenuItem:
            TextField("Menu path, e.g. File > Export > PDF…", text: string(\.menuPath, default: "")).textFieldStyle(.roundedBorder)
            TextField("App bundle ID (empty = frontmost app)", text: string(\.targetApplicationBundleID, default: "")).textFieldStyle(.roundedBorder)
            note("Separate levels with >. Titles ignore case and a trailing …; * and ? match any title. Needs Accessibility permission.")
        case .showContextMenu:
            note("Uses the element's own Show Menu action, or a secondary click when it has none.")
        case .activatePreviousApp:
            note("AOM keeps the order in which apps came to the front since it launched.")
        case .quitAppUnderCursor, .hideAppUnderCursor:
            note("Acts on the app that owns the window under the pointer; the Dock, menu bar and panels are skipped.")
        case .activateWindowByTitle:
            TextField("Window title contains", text: string(\.windowTitleQuery, default: "")).textFieldStyle(.roundedBorder)
            TextField("App bundle ID (optional)", text: string(\.targetApplicationBundleID, default: "")).textFieldStyle(.roundedBorder)
            note("Case-insensitive. Use * and ? to match the whole title instead. Windows on other Spaces are not listed by macOS.")
        case .minimizeAppWindows:
            note("Minimizes every standard window of the frontmost app.")
        case .gatherWindowsToPointerDisplay:
            note("Windows keep their relative position and shrink only when they do not fit. Undo Last Window Placement moves them back.")
        case .tileFrontWindowsSideBySide:
            note("The front window goes left and the next window right, on the front window's display. Undo Last Window Placement reverts.")
        case .switchInputSource:
            Picker("Input source", selection: string(\.inputSourceID, default: "")) {
                Text("Next input source").tag("")
                ForEach(inputSources) { Text($0.name).tag($0.id) }
            }
            note("Lists the input sources enabled in Keyboard settings.")
        case .setSoundInput:
            Picker("Input", selection: string(\.audioInputUID, default: "")) {
                Text("Choose…").tag("")
                ForEach(AudioOutputService.inputDevices()) { Text($0.name).tag($0.uid) }
            }
        case .toggleDisplayMirroring:
            note("Mirrors every display to the main display, or turns mirroring off. Needs two or more displays.")
        case .ejectAllDisks:
            note("Ejects external drives, disk images and network volumes. A disk with an open file stays mounted and the step fails.")
        case .toggleDockAutoHide:
            modePicker(on: "Hide", off: "Show")
            note("Uses System Events, so macOS asks once to let AOM control it.")
        case .setWiFiPower:
            modePicker(on: "On", off: "Off")
        case .bluetoothDevice:
            HStack {
                TextField("Device name or address", text: string(\.bluetoothDevice, default: "")).textFieldStyle(.roundedBorder)
                Menu("Paired") {
                    ForEach(bluetoothNames, id: \.self) { name in Button(name) { save { $0.parameters.bluetoothDevice = name } } }
                }.fixedSize().disabled(bluetoothNames.isEmpty)
            }
            modePicker(on: "Connect", off: "Disconnect")
        case .showEmojiPicker:
            note("Uses Edit › Emoji & Symbols, or ⌃⌘Space when the app has no such item.")
        case .recognizeScreenText:
            TextField("Text to find (empty = read all text)", text: string(\.text, default: "")).textFieldStyle(.roundedBorder)
            variableField(default: "screenText")
            if !(p.text ?? "").isEmpty {
                Toggle("Click the first match", isOn: Binding(get: { p.imageMatchClick ?? false },
                                                              set: { value in save { $0.parameters.imageMatchClick = value } }))
            }
            note((p.text ?? "").isEmpty
                 ? "Stores the text of the pointer's display in the variable (up to 512 characters)."
                 : "Sets the variable to true or false, plus _x and _y for the match. Use If / Else on it to branch. Runs on-device; needs Screen Recording permission.")
        case .sendMIDI:
            Picker("Message", selection: string(\.midiMessage, default: MIDIMessage.Kind.noteOn.rawValue)) {
                ForEach(MIDIMessage.Kind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Stepper(value: int(\.midiChannel, default: 1), in: 1...16) { Text("Channel \(p.midiChannel ?? 1)") }
            Stepper(value: int(\.midiNumber, default: 60), in: 0...127) {
                Text("\(midiNumberTitle) \(p.midiNumber ?? 60)")
            }
            if (p.midiMessage ?? "noteOn") != MIDIMessage.Kind.programChange.rawValue {
                Stepper(value: int(\.midiValue, default: 100), in: 0...127) {
                    Text("\((p.midiMessage ?? "noteOn") == "controlChange" ? "Value" : "Velocity") \(p.midiValue ?? 100)")
                }
            }
            note("Sent from AOM's virtual source “All of MacOS”; choose it as a MIDI input in the receiving app.")
        case .sendOSC:
            HStack {
                TextField("Host", text: string(\.oscHost, default: "127.0.0.1")).textFieldStyle(.roundedBorder)
                TextField("Port", value: Binding(get: { p.oscPort ?? 8000 },
                                                 set: { value in save { $0.parameters.oscPort = min(65_535, max(1, value)) } }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
            }
            TextField("Address, e.g. /scene/1/go", text: string(\.oscAddress, default: "/aom")).textFieldStyle(.roundedBorder)
            TextField("Arguments, e.g. 1 0.5 \"two words\" true", text: string(\.text, default: "")).textFieldStyle(.roundedBorder)
            note("Integers, decimals, true/false and \"quoted text\" become i, f, T/F and s arguments. Sent once over UDP.")
        case .pickScreenColor:
            variableField(default: "color")
            note("Copies the color as #RRGGBB. Escape cancels and fails the step.")
        case .hapticFeedback:
            Picker("Pattern", selection: string(\.hapticPattern, default: "generic")) {
                Text("Generic").tag("generic"); Text("Alignment").tag("alignment"); Text("Level Change").tag("levelChange")
            }.pickerStyle(.segmented)
            note("Felt only on a Force Touch trackpad while a finger rests on it.")
        case .postDistributedNotification:
            TextField("Notification name", text: string(\.notificationName, default: "")).textFieldStyle(.roundedBorder)
            TextField("Object text (optional)", text: string(\.text, default: "")).textFieldStyle(.roundedBorder)
            note("Other apps observe it with DistributedNotificationCenter; nothing else is sent.")
        case .restartRecording:
            note("Discards the take and records the same area with the same options. The recording bar has the same button.")
        case .toggleDoNotDisturb:
            TextField("Shortcut name (empty = “Toggle Focus”)", text: string(\.shortcutName, default: "")).textFieldStyle(.roundedBorder)
            note("macOS has no public Focus switch, so create a Shortcut with one “Set Focus” action and enter its name.")
        default:
            EmptyView()
        }
    }

    private var midiNumberTitle: String {
        switch MIDIMessage.Kind(rawValue: action.parameters.midiMessage ?? "") ?? .noteOn {
        case .controlChange: return "Controller"
        case .programChange: return "Program"
        default: return "Note"
        }
    }

    // MARK: Controls

    private func variableField(default value: String) -> some View {
        TextField("Save to variable", text: string(\.variableName, default: value))
            .textFieldStyle(.roundedBorder)
            .onAppear { loadLists() }
    }

    private func modePicker(on: String, off: String) -> some View {
        Picker("Mode", selection: string(\.switchMode, default: "toggle")) {
            Text("Toggle").tag("toggle"); Text(on).tag("on"); Text(off).tag("off")
        }.pickerStyle(.segmented)
        .onAppear { loadLists() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .onAppear { loadLists() }
    }

    /// Lists come from the system only when the form appears, never per frame.
    private func loadLists() {
        switch action.actionType {
        case .switchInputSource where inputSources.isEmpty: inputSources = InputSources.enabled()
        case .bluetoothDevice where bluetoothNames.isEmpty: bluetoothNames = ParityActions.pairedBluetoothNames()
        default: break
        }
        if action.actionType == .pasteClipboardItem, pinboards.isEmpty {
            pinboards = ClipboardStore.shared.boards.map(\.name)
        }
    }

    private func string(_ key: WritableKeyPath<ActionParameters, String?>, default value: String) -> Binding<String> {
        Binding(get: { action.parameters[keyPath: key] ?? value },
                set: { new in save { $0.parameters[keyPath: key] = new.isEmpty ? nil : new } })
    }

    private func int(_ key: WritableKeyPath<ActionParameters, Int?>, default value: Int) -> Binding<Int> {
        Binding(get: { action.parameters[keyPath: key] ?? value },
                set: { new in save { $0.parameters[keyPath: key] = new } })
    }
}
