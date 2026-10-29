import SwiftUI

// NSView-based double-click handler that doesn't interfere with SwiftUI single-click selection
struct DoubleClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> DoubleClickView {
        let view = DoubleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: DoubleClickView, context: Context) {
        nsView.action = action
    }

    class DoubleClickView: NSView {
        var action: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            // Always pass through so List selection works
            super.mouseDown(with: event)
            if event.clickCount == 2 {
                action?()
            }
        }

        // Accept first mouse so clicks always reach us
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

struct TriggerListPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var showingEditTrigger = false
    @State private var addCategory: TriggerCategory = .trackpad
    @FocusState private var searchFocused: Bool
    @ObservedObject private var clipboard = TriggerClipboard.shared
    @AppStorage("AOMGroupTriggersByFolder") private var groupByFolder = false

    var body: some View {
        let conflicts = TriggerConflictKey.counts(appState.currentPreset.triggers)
        VStack(spacing: 0) {
            // Header: Category Title + Trigger Count
            HStack(spacing: 6) {
                Image(systemName: appState.selectedTriggerCategory.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(appState.selectedTriggerCategory == .all ? "All Triggers" : "\(appState.selectedTriggerCategory.rawValue) Triggers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(appState.displayedTriggers.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Triggers", text: $appState.triggerSearch)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityIdentifier("AOMSearchTriggers")
                    if !appState.triggerSearch.isEmpty {
                        Button { appState.triggerSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear trigger search")
                    }
                    // The count rides inside the search field. Beside the
                    // sort control it read as a sort option, and at this pane
                    // width its digits were clipped by the picker.
                    Text("\(appState.displayedTriggers.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .fixedSize()
                        .accessibilityLabel("\(appState.displayedTriggers.count) triggers shown")
                }.padding(7).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Sort:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Picker("", selection: $appState.triggerSortMode) {
                        ForEach(TriggerSortMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120, alignment: .leading)

                    Spacer(minLength: 0)
                    Toggle(isOn: $groupByFolder) { Image(systemName: "folder") }
                        .toggleStyle(.button).help("Group triggers by folder")
                }
                if appState.isSearchingTriggers {
                    Text("Searching all apps, groups and input types, including disabled triggers.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(8)
                .help("Filter with app:Safari, type:trackpad, group:\"Work\", action:paste or enabled:no. Quote a value that contains a space, such as type:\"normal mouse\".")
            Divider()

            // BTT-style All overview: one section per input device, keeping
            // scope selection independent from category selection.
            if appState.displayedTriggers.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: appState.selectedTriggerCategory.iconName)
                        .font(.system(size: 37)).foregroundStyle(.secondary)
                    Text(appState.isSearchingTriggers ? "No matching triggers" : appState.selectedTriggerCategory == .all ? "No configured triggers" :
                         "No \(appState.selectedTriggerCategory.rawValue) triggers")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(appState.isSearchingTriggers ? "Try a different name or filter, or clear the search." : "Choose an input type, record a gesture, then assign actions.")
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if appState.isSearchingTriggers { Button("Clear Search") { appState.triggerSearch = "" } }
                    else { addTriggerControl(prominent: true) }
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(
                    get: { appState.selectedTrigger?.id },
                    set: { id in
                        appState.selectedTrigger = appState.displayedTriggers.first { $0.id == id }
                        appState.selectedAction = nil
                    }
                )) {
                    if groupByFolder {
                        ForEach(Array(Set(appState.displayedTriggers.map { $0.folder ?? "" })).sorted(), id: \.self) { folder in
                            Section(folder.isEmpty ? "Ungrouped" : folder) {
                                ForEach(appState.displayedTriggers.filter { ($0.folder ?? "") == folder }) { trigger in
                                    triggerRow(trigger, conflicts: conflicts)
                                }
                            }
                        }
                    } else if appState.selectedTriggerCategory == .all && !appState.isSearchingTriggers && !appState.displayedTriggers.contains(where: \.isFavorite) {
                        ForEach(TriggerCategory.inputCategories) { category in
                            let items = appState.displayedTriggers.filter { $0.input.category == category }
                            if !items.isEmpty {
                                Section {
                                    ForEach(items) { trigger in triggerRow(trigger, conflicts: conflicts) }
                                } header: {
                                    HStack(spacing: 7) {
                                        Image(systemName: category.iconName)
                                        Text(category.rawValue)
                                        Spacer(minLength: 0)
                                        Text("\(items.count)").monospacedDigit()
                                    }
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        ForEach(appState.displayedTriggers) { trigger in triggerRow(trigger, conflicts: conflicts) }
                    }
                }.listStyle(.inset)
                    .onDeleteCommand {
                        if let selected = appState.selectedTrigger, appState.displayedTriggers.contains(where: { $0.id == selected.id }) {
                            appState.removeTrigger(selected)
                        }
                    }
            }

            Divider()

            // Bottom bar with add button
            HStack(spacing: 6) {
                addTriggerControl(prominent: false)
                Button { showingEditTrigger = true } label: { Image(systemName: "pencil") }
                    .help("Edit trigger").disabled(appState.selectedTrigger == nil)
                Button {
                    if let trigger = appState.selectedTrigger { appState.removeTrigger(trigger) }
                } label: { Image(systemName: "minus") }
                    .help("Remove trigger").disabled(appState.selectedTrigger == nil)
                if let trigger = appState.selectedTrigger {
                    Button { appState.moveTrigger(trigger, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(!appState.canMoveTrigger(trigger, offset: -1)).help("Move trigger up in this scope and category")
                        .accessibilityLabel("Move trigger up")
                    Button { appState.moveTrigger(trigger, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(!appState.canMoveTrigger(trigger, offset: 1)).help("Move trigger down in this scope and category")
                        .accessibilityLabel("Move trigger down")
                }
                Spacer()
                Button { pasteTrigger() } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste copied trigger into the current scope")
                    .disabled(clipboard.copied == nil)
            }.padding(8)
        }
        .background(.background.opacity(0.22))
        .focusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { if !showingEditTrigger && !appState.showingAddTrigger && !appState.showingAddAction { searchFocused = true } },
            newTrigger: beginNewTrigger))
        .onChange(of: appState.triggerSearch) { _, _ in clearHiddenSelection() }
        .onChange(of: appState.selectedTriggerCategory) { _, _ in clearHiddenSelection() }
        .sheet(isPresented: $showingEditTrigger) {
            if let trigger = appState.selectedTrigger { EditTriggerSheet(trigger: trigger) }
        }
        .sheet(isPresented: $appState.showingAddTrigger) {
            AddTriggerSheet(keyboardMonitor: appState.keyboardMonitor, category: addCategory)
        }
    }

    @ViewBuilder private func triggerRow(_ trigger: Trigger, conflicts: [UUID: Int]) -> some View {
        TriggerRow(trigger: trigger, conflictCount: conflicts[trigger.id] ?? 0,
            scope: appState.isSearchingTriggers ? TriggerListQuery.scopeLabel(trigger, preset: appState.currentPreset) : nil)
            .tag(trigger.id)
            .overlay(DoubleClickHandler {
                appState.selectedTrigger = trigger
                showingEditTrigger = true
            })
            .contextMenu {
                Button("Edit") { appState.selectedTrigger = trigger; showingEditTrigger = true }
                Button(trigger.isEnabled ? "Disable" : "Enable") { appState.toggleTrigger(trigger) }
                Button(trigger.isFavorite ? "Unpin from Top" : "Pin to Top") { appState.toggleFavorite(trigger) }
                Button("Copy Trigger") { clipboard.copied = trigger }
                Button("Paste Trigger") { pasteTrigger() }.disabled(clipboard.copied == nil)
                Button("Duplicate") {
                    appState.addTrigger(TriggerClipboard.duplicate(trigger))
                }
                Button("Move Up") { appState.moveTrigger(trigger, offset: -1) }.disabled(!appState.canMoveTrigger(trigger, offset: -1))
                Button("Move Down") { appState.moveTrigger(trigger, offset: 1) }.disabled(!appState.canMoveTrigger(trigger, offset: 1))
                Divider()
                Button("Delete", role: .destructive) { appState.removeTrigger(trigger) }
            }
    }

    private func pasteTrigger() {
        guard let source = clipboard.copied else { return }
        var copy = TriggerClipboard.duplicate(source)
        copy.appBundleID = appState.selectedActivationGroupID == nil ? appState.selectedAppTarget.bundleID : nil
        copy.activationGroupID = appState.selectedActivationGroupID
        appState.addTrigger(copy)
    }

    private func beginNewTrigger() {
        guard !showingEditTrigger, !appState.showingAddTrigger, !appState.showingAddAction else { return }
        addCategory = appState.selectedTriggerCategory == .all ? .trackpad : appState.selectedTriggerCategory
        appState.showingAddTrigger = true
    }
    private func clearHiddenSelection() {
        if let selected = appState.selectedTrigger, !appState.displayedTriggers.contains(where: { $0.id == selected.id }) {
            appState.selectedTrigger = nil; appState.selectedAction = nil
        }
    }

    private func addTriggerControl(prominent: Bool) -> some View {
        Button(action: beginNewTrigger) {
            Label("Add Trigger", systemImage: "plus")
                .frame(minHeight: 24)
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .help("Add a trigger; choose its input type in the editor")
        .accessibilityIdentifier("AOMAddTrigger")
    }
}

/// One-click access to *all* categories even in the narrow middle pane.
/// The previous horizontally-scrolling tab strip hid Drawings entirely.
struct TriggerCategoryTabBar: View {
    @EnvironmentObject var appState: AppState

    /// A horizontal strip rather than a dropdown, following BTT's trigger
    /// category bar. The categories are the fastest way to move around the
    /// list, and a strip shows where the others are and how much is in them —
    /// a menu hides both until it is opened.
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The strip scrolls instead of compressing. Six labels cannot fit
            // a 250pt pane, and squeezing them overlapped the icons and
            // clipped the counts.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(TriggerCategory.allCases) { category in
                        categoryButton(category)
                    }
                }
                .padding(4)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))

            if let id = appState.selectedActivationGroupID,
               let group = appState.currentPreset.activationGroups.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GROUP · \(group.name)").font(.caption.weight(.semibold))
                    Text(group.appliesToAllApps ? "All apps except \(group.excludedBundleIDs.count) exclusions" : "\(group.includedBundleIDs.count) included apps")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !group.appliesToAllApps && group.includedBundleIDs.isEmpty {
                        Label("No apps selected — gestures won't run", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// One category. The count is shown on the tab so a category that is empty
    /// in this scope reads as empty before it is selected.
    private func categoryButton(_ category: TriggerCategory) -> some View {
        let selected = appState.selectedTriggerCategory == category
        let count = appState.triggers(in: category).count
        return Button {
            appState.selectedTriggerCategory = category
            appState.selectedTrigger = nil
            appState.selectedAction = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: category.iconName)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                if selected {
                    Text(category.rawValue)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .frame(minWidth: 12, alignment: .trailing)
                        .foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .padding(.horizontal, selected ? 8 : 7)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 26)
            .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(category.rawValue) — \(count) trigger\(count == 1 ? "" : "s")")
        .accessibilityLabel("Category \(category.rawValue), \(count) triggers")
        .accessibilityIdentifier("AOMCategory_\(category.rawValue)")
    }
}

struct TriggerRow: View {
    let trigger: Trigger
    var conflictCount = 0
    var scope: String?
    @EnvironmentObject var appState: AppState
    // Subscribe only to trigger flashes, not every trackpad contact/trail frame.
    @State private var isFlashing = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isFlashing ? AOMTheme.positive : (trigger.isEnabled ? AOMTheme.positive : AOMTheme.textTertiary))
                .frame(width: 8, height: 8)
                .scaleEffect(isFlashing ? 1.8 : 1.0)

            Image(systemName: trigger.input.category.iconName)
                .frame(width: 18).foregroundStyle(.tint).accessibilityLabel(trigger.input.category.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let label = trigger.colorLabel, !label.isEmpty {
                    Label(label, systemImage: "tag.fill").font(.caption2)
                        .foregroundStyle(TriggerLabel.color(label))
                }
                if let folder = trigger.folder, !folder.isEmpty {
                    Label(folder, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                }
                if !trigger.notes.isEmpty {
                    Text(trigger.notes).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(trigger.notes)
                }
                if let scope { Text(scope).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                if trigger.requiredModifiers != nil {
                    Text(trigger.modifierLabel).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                if (trigger.input.category == .keyboard && trigger.keyboardPhase != .keyDown) || trigger.repeatWhileHeld {
                    Text(trigger.repeatWhileHeld ? "Repeat while held" : trigger.keyboardPhase.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(trigger.input.displayName) · \(trigger.actions.count) action\(trigger.actions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if trigger.isFavorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("Pinned trigger") }
            if conflictCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("\(conflictCount) other binding(s) use the same input, scope, modifiers and key phase. Enabling more than one can run multiple actions.")
                    .accessibilityLabel("Duplicate binding: \(conflictCount) other triggers")
            }
            Spacer()

            // BTT lets a binding be switched off from the list, which is the
            // move you want when a gesture is fighting another app for a
            // moment. Revealed on hover so an untouched list stays quiet.
            if isHovering || !trigger.isEnabled {
                Toggle("", isOn: Binding(
                    get: { trigger.isEnabled },
                    set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(trigger.isEnabled ? "Disable this trigger" : "Enable this trigger")
                .accessibilityLabel("\(trigger.displayName) enabled")
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(trigger.isEnabled ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(AOMTheme.positive.opacity(isFlashing ? 0.15 : 0))
        )
        .onHover { isHovering = $0 }
        .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
            let flashing = id == trigger.id
            if isFlashing != flashing { isFlashing = flashing }
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.3)), value: isFlashing)
    }
}

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
    @State private var systemEventAppName = ""
    @State private var gestureSearch = ""
    @State private var drawingName = ""
    @State private var drawingSamples: [[DrawingPoint]] = []
    @State private var drawingCertainty: Double = 0.7
    @State private var drawingIgnoreDirection = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            Text("Add New Trigger")
                .font(AOMFont.pageStatus)
                .foregroundStyle(AOMColor.text)
                .accessibilityAddTraits(.isHeader)

            Picker("Input type", selection: $category) {
                ForEach(TriggerCategory.inputCategories) { item in
                    Label(item.rawValue, systemImage: item.iconName).tag(item)
                }
            }.onChange(of: category) { _, _ in keyboardMonitor.stopRecording() }

            AOMDivider()

            switch category {
            case .trackpad:
                trackpadPicker
            case .keyboard:
                Picker("Keyboard input", selection: $keyboardMode) {
                    Text("Shortcut").tag("shortcut")
                    Text("Key Sequence").tag("sequence")
                    Text("Typed String").tag("typed")
                }.pickerStyle(.segmented)
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
            default:
                Text("Coming soon for \(category.rawValue)")
                    .foregroundStyle(AOMColor.textSecondary)
            }

            TextField("Trigger Name (optional)", text: $triggerName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addTrigger() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: category == .drawings ? AOMEditorSize.drawingSheet : AOMEditorSize.triggerSheet)
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
            TextField("Search gestures...", text: $gestureSearch)
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredGestures) { gesture in
                            let selected = selectedGesture == gesture
                            let onAccent = AOMTheme.onAccent(AOMColor.accent)
                            HStack(spacing: AOMSpace.x2) {
                                Image(systemName: gestureIcon(gesture))
                                    .frame(width: AOMIcon.row)
                                    .foregroundStyle(selected ? onAccent : AOMColor.textSecondary)
                                Text(gesture.rawValue)
                                    .font(AOMFont.body)
                                    .foregroundStyle(selected ? onAccent : AOMColor.text)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(onAccent)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, AOMSpace.x2)
                            .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                                    .fill(selected ? AOMColor.accent : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                withAnimation(AOMMotion.quick) { selectedGesture = gesture }
                                addTrigger()
                            }
                            .onTapGesture {
                                withAnimation(AOMMotion.quick) { selectedGesture = gesture }
                            }
                            .id(gesture)
                        }
                    }
                    .padding(AOMSpace.x1)
                }
                .onChange(of: gestureSearch) { _ in
                    if let first = filteredGestures.first {
                        selectedGesture = first
                        withAnimation(AOMMotion.standard) { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            }
            .frame(height: AOMEditorSize.gestureList)
            .background(AOMColor.raised, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous).strokeBorder(AOMTheme.hairline, lineWidth: 0.5))
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
                Button(keyboardMonitor.isMonitoring ? "Recording..." : "Record Next Key") {
                    keyboardMonitor.startRecording { shortcut in
                        if sequenceStrokes.count < 6 {
                            sequenceStrokes.append(KeySequenceStroke(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue))
                        }
                    }
                }.disabled(keyboardMonitor.isMonitoring || sequenceStrokes.count >= 6)
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
                    Text("Press a key combination...")
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

            Button(keyboardMonitor.isMonitoring ? "Recording..." : "Record Shortcut") {
                keyboardMonitor.startRecording { shortcut in
                    recordedShortcut = shortcut
                }
            }
            .disabled(keyboardMonitor.isMonitoring)
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
                        let label = ["S", "M", "T", "W", "T", "F", "S"][day - 1]
                        Button(label) {
                            if selectedWeekdays.contains(day) { selectedWeekdays.remove(day) }
                            else { selectedWeekdays.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedWeekdays.contains(day) ? AOMColor.accent : AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea)
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
                    TextField("Device name / SSID filter (empty = any)", text: $eventFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMEditorSize.rowField)
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

struct EditTriggerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let trigger: Trigger
    @State private var triggerName: String = ""
    @State private var selectedGesture: TrackpadGesture = .twoFingerSwipeUp
    @State private var mouseSpec = MouseTriggerSpec(button: 2, kind: .click)
    @State private var mouseModifiers: UInt = 0
    @State private var changeGesture = false
    @State private var notes = ""
    @State private var folder = ""
    @State private var colorLabel = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Trigger")
                .font(.headline)

            Text("Current: \(trigger.input.displayName)")
                .foregroundColor(.secondary)

            Divider()

            TextField("Trigger Name", text: $triggerName)
                .textFieldStyle(.roundedBorder)

            TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField("Folder (optional)", text: $folder).textFieldStyle(.roundedBorder)
            Picker("Color label", selection: $colorLabel) {
                Text("None").tag("")
                ForEach(TriggerLabel.names, id: \.self) { Text($0).tag($0) }
                if !colorLabel.isEmpty && !TriggerLabel.names.contains(colorLabel) { Text(colorLabel).tag(colorLabel) }
            }

            // Option to change the gesture/input
            Toggle("Change gesture", isOn: $changeGesture)

            if changeGesture {
                gestureEditor
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveTrigger() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changeGesture && (
                        (trigger.input.category == .normalMouse
                         && TriggerValidation.problem(for: MouseTriggerEditor.input(for: mouseSpec), requiredModifiers: mouseModifiers) != nil) ||
                        (trigger.input.category == .trackpad
                         && TriggerValidation.problem(for: .trackpadGesture(selectedGesture), requiredModifiers: trigger.requiredModifiers) != nil)))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            triggerName = trigger.name
            notes = trigger.notes; folder = trigger.folder ?? ""; colorLabel = trigger.colorLabel ?? ""
            // Pre-select current gesture if applicable
            if case .trackpadGesture(let g) = trigger.input {
                selectedGesture = g
            }
            if case .mouseButton(let b) = trigger.input { mouseSpec = MouseTriggerSpec(legacy: b) }
            if case .mouse(let spec) = trigger.input { mouseSpec = spec }
            mouseModifiers = (trigger.requiredModifiers ?? 0) & TriggerResolver.modifierMask
        }
    }

    @ViewBuilder
    private var gestureEditor: some View {
        switch trigger.input.category {
        case .trackpad:
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(TrackpadGesture.allCases) { gesture in
                        let selected = selectedGesture == gesture
                        HStack {
                            Image(systemName: gestureIconForEdit(gesture))
                                .frame(width: 20)
                                .foregroundColor(selected ? .white : .accentColor)
                            Text(gesture.rawValue)
                                .foregroundColor(selected ? .white : .primary)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14))
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color.accentColor : Color.clear)
                        )
                        .scaleEffect(selected ? 1.02 : 1.0)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AOMDesign.animation(.spring(response: 0.3, dampingFraction: 0.7))) {
                                selectedGesture = gesture
                            }
                        }
                        .animation(AOMDesign.animation(.spring(response: 0.3, dampingFraction: 0.7)), value: selected)
                    }
                }
                .padding(4)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous).strokeBorder(AOMTheme.hairline, lineWidth: 0.5))
        case .normalMouse:
            MouseTriggerEditor(spec: $mouseSpec, modifiers: $mouseModifiers)
        default:
            Text("Cannot change this input type here")
                .foregroundColor(.secondary)
        }
    }

    private func gestureIconForEdit(_ gesture: TrackpadGesture) -> String {
        let name = gesture.rawValue.lowercased()
        if name.contains("swipe") { return "hand.draw" }
        if name.contains("pinch") { return "arrow.up.left.and.arrow.down.right" }
        if name.contains("rotate") { return "arrow.triangle.2.circlepath" }
        if name.contains("tap") || name.contains("click") { return "hand.tap" }
        if name.contains("tiptap") { return "hand.point.up.left.and.text" }
        if name.contains("circle") { return "circle.dashed" }
        if name.contains("corner") { return "square.topright" }
        if name.contains("middle click") { return "rectangle.center.inset.filled" }
        return "hand.point.up"
    }

    private func saveTrigger() {
        var updated = trigger
        updated.name = triggerName
        updated.notes = notes
        let cleanFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.folder = cleanFolder.isEmpty ? nil : cleanFolder
        updated.colorLabel = colorLabel.isEmpty ? nil : colorLabel

        if changeGesture {
            switch trigger.input.category {
            case .trackpad:
                updated.input = .trackpadGesture(selectedGesture)
            case .normalMouse:
                let input = MouseTriggerEditor.input(for: mouseSpec)
                // Left/right/scroll triggers without a modifier are refused, exactly as at creation.
                guard TriggerValidation.problem(for: input, requiredModifiers: mouseModifiers) == nil else { return }
                updated.input = input
                if case .mouse = input { updated.requiredModifiers = mouseModifiers == 0 ? nil : mouseModifiers }
            default:
                break
            }
        }

        appState.updateTrigger(updated)
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

    static func input(for spec: MouseTriggerSpec) -> TriggerInput {
        if spec.kind == .click, let legacy = MouseButton.from(cgButton: Int64(spec.button)) { return .mouseButton(legacy) }
        return .mouse(spec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mouse trigger:").font(.subheadline)
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
                    ForEach(MouseTriggerSpec.pickerButtons, id: \.self) { Text(MouseTriggerSpec.buttonName($0) + ($0 < 3 ? "" : " (\($0 + 1))")).tag($0) }
                }
            }
            RequiredModifierToggles(modifiers: $modifiers)
            if let problem = TriggerValidation.problem(for: MouseTriggerEditor.input(for: spec), requiredModifiers: modifiers) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// ⌃ ⌥ ⇧ ⌘ fn toggle row bound to a raw `NSEvent.ModifierFlags` mask.
struct RequiredModifierToggles: View {
    @Binding var modifiers: UInt
    private static let choices: [(String, NSEvent.ModifierFlags)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command), ("fn", .function)]
    var body: some View {
        HStack(spacing: 6) {
            Text("Required modifiers").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.choices, id: \.0) { label, flag in
                Toggle(label, isOn: Binding(
                    get: { modifiers & flag.rawValue != 0 },
                    set: { on in if on { modifiers |= flag.rawValue } else { modifiers &= ~flag.rawValue } }))
                    .toggleStyle(.button)
            }
        }
    }
}
