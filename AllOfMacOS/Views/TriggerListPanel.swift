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
                    if appState.selectedTriggerCategory == .all && !appState.isSearchingTriggers && !appState.displayedTriggers.contains(where: \.isFavorite) {
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
                Button("Move Up") { appState.moveTrigger(trigger, offset: -1) }.disabled(!appState.canMoveTrigger(trigger, offset: -1))
                Button("Move Down") { appState.moveTrigger(trigger, offset: 1) }.disabled(!appState.canMoveTrigger(trigger, offset: 1))
                Divider()
                Button("Delete", role: .destructive) { appState.removeTrigger(trigger) }
            }
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
                .fill(isFlashing ? Color.green : (trigger.isEnabled ? Color.green : Color.gray))
                .frame(width: 8, height: 8)
                .scaleEffect(isFlashing ? 1.8 : 1.0)

            Image(systemName: trigger.input.category.iconName)
                .frame(width: 18).foregroundStyle(.tint).accessibilityLabel(trigger.input.category.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let scope { Text(scope).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                if trigger.requiredModifiers != nil {
                    Text(trigger.modifierLabel).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                if trigger.keyboardPhase == .keyUp || trigger.repeatWhileHeld {
                    Text(trigger.repeatWhileHeld ? "Repeat while held" : "Key up").font(.caption).foregroundStyle(.secondary)
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
                .fill(Color.green.opacity(isFlashing ? 0.15 : 0))
        )
        .onHover { isHovering = $0 }
        .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
            let flashing = id == trigger.id
            if isFlashing != flashing { isFlashing = flashing }
        }
        .animation(.easeOut(duration: 0.3), value: isFlashing)
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
    }

    @State private var selectedGesture: TrackpadGesture = .twoFingerSwipeUp
    @State private var selectedMouseButton: MouseButton = .button3
    @State private var recordedShortcut: KeyboardShortcut?
    @State private var keyboardMode = "shortcut"
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
    @State private var systemEventKind = "display"
    @State private var powerOnAC = true
    @State private var systemEventAppID = ""
    @State private var systemEventAppName = ""
    @State private var gestureSearch = ""
    @State private var drawingName = ""
    @State private var drawingSamples: [[DrawingPoint]] = []
    @State private var drawingCertainty: Double = 0.7
    @State private var drawingIgnoreDirection = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Add New Trigger")
                .font(.headline)

            Picker("Input type", selection: $category) {
                ForEach(TriggerCategory.inputCategories) { item in
                    Label(item.rawValue, systemImage: item.iconName).tag(item)
                }
            }.onChange(of: category) { _, _ in keyboardMonitor.stopRecording() }

            Divider()

            switch category {
            case .trackpad:
                trackpadPicker
            case .keyboard:
                Picker("Keyboard input", selection: $keyboardMode) {
                    Text("Shortcut").tag("shortcut")
                    Text("Key Sequence").tag("sequence")
                }.pickerStyle(.segmented)
                if keyboardMode == "sequence" { sequenceRecorder } else { keyboardRecorder }
            case .normalMouse:
                mousePicker
            case .drawings:
                ScrollView {
                    DrawingPatternComposer(name: $drawingName, samples: $drawingSamples,
                                           certainty: $drawingCertainty,
                                           ignoreDirection: $drawingIgnoreDirection)
                        .padding(3)
                }.frame(height: 510)
            case .otherTriggers:
                otherTriggerPicker
            default:
                Text("Coming soon for \(category.rawValue)")
                    .foregroundColor(.secondary)
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
        .padding(20)
        .frame(width: category == .drawings ? 540 : 400)
    }

    private var canAdd: Bool {
        switch category {
        case .keyboard: return keyboardMode == "sequence" ?
            ((sequenceHoldEnabled ? sequenceStrokes.count == 1 : sequenceStrokes.count >= 2) && sequenceStrokes.count <= 6) : recordedShortcut != nil
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Select Gesture:")
                .font(.subheadline)
            TextField("Search gestures...", text: $gestureSearch)
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredGestures) { gesture in
                            let selected = selectedGesture == gesture
                            HStack {
                                Image(systemName: gestureIcon(gesture))
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
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedGesture = gesture
                                }
                                addTrigger()
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedGesture = gesture
                                }
                            }
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
                            .id(gesture)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: gestureSearch) { _ in
                    if let first = filteredGestures.first {
                        selectedGesture = first
                        withAnimation { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        }
    }

    private var sequenceRecorder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sequenceStrokes.isEmpty ? "No steps recorded" : sequenceStrokes.map(\.displayName).joined(separator: " → "))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            HStack {
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
                }.disabled(sequenceStrokes.count >= 6)
                Button("Undo") { if !sequenceStrokes.isEmpty { sequenceStrokes.removeLast() } }
                    .disabled(sequenceStrokes.isEmpty)
            }
            Toggle("Single-key hold instead of sequence", isOn: $sequenceHoldEnabled)
            if sequenceHoldEnabled {
                Stepper("Hold for \(sequenceHoldMs) ms", value: $sequenceHoldMs, in: 300...5000, step: 100)
            } else {
                Stepper("Max gap: \(sequenceGapMs) ms", value: $sequenceGapMs, in: 100...2000, step: 50)
            }
            Text("Regular keys still reach the active app. Modifier-only key presses are available via Modifier Press. At least 2 steps are needed unless hold is selected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func appendModifier(_ code: UInt16) {
        if sequenceStrokes.count < 6 { sequenceStrokes.append(KeySequenceStroke(keyCode: code, modifiers: 0)) }
    }

    private var keyboardRecorder: some View {
        VStack(spacing: 12) {
            Text(recordedShortcut?.displayString ?? "Press a key combination...")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(keyboardMonitor.isMonitoring ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 2)
                )

            Button(keyboardMonitor.isMonitoring ? "Recording..." : "Record Shortcut") {
                keyboardMonitor.startRecording { shortcut in
                    recordedShortcut = shortcut
                }
            }
            .disabled(keyboardMonitor.isMonitoring)
        }
    }

    private var mousePicker: some View {
        VStack(alignment: .leading) {
            Text("Select Mouse Button:")
                .font(.subheadline)
            Picker("Button", selection: $selectedMouseButton) {
                ForEach(MouseButton.allCases) { button in
                    Text(button.rawValue).tag(button)
                }
            }
            .labelsHidden()
        }
    }

    private var otherTriggerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 8) {
            Picker("Schedule", selection: $scheduleKind) {
                Text("Daily").tag("daily")
                Text("Weekly").tag("weekly")
                Text("Interval").tag("interval")
            }.pickerStyle(.segmented)

            if scheduleKind == "interval" {
                HStack {
                    Text("Every")
                    TextField("30", value: $intervalMinutes, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                    Text("minutes")
                }
            } else {
                HStack {
                    Text("At")
                    Picker("", selection: $scheduleHour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: 70)
                    Text(":")
                    Picker("", selection: $scheduleMinute) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: 70)
                }
            }

            if scheduleKind == "weekly" {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let label = ["S", "M", "T", "W", "T", "F", "S"][day - 1]
                        Button(label) {
                            if selectedWeekdays.contains(day) { selectedWeekdays.remove(day) }
                            else { selectedWeekdays.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedWeekdays.contains(day) ? .accentColor : .secondary)
                        .frame(width: 28)
                    }
                }
                Text(SystemTriggerKind.weekdayNames(Array(selectedWeekdays)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Runs while AOM is open. Missed times are not replayed on launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// System events are discrete state changes rather than times, so they only
    /// need which event, plus an app for the launch/quit cases.
    private var systemEventField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Event", selection: $systemEventKind) {
                Text("Display configuration changes").tag("display")
                Text("Power source changes").tag("power")
                Text("Screen locks").tag("lock")
                Text("Screen unlocks").tag("unlock")
                Text("Application launches").tag("appLaunch")
                Text("Application quits").tag("appQuit")
            }

            if systemEventKind == "power" {
                Picker("When", selection: $powerOnAC) {
                    Text("Power is connected").tag(true)
                    Text("Switched to battery").tag(false)
                }.pickerStyle(.segmented)
            }

            if systemEventKind == "appLaunch" || systemEventKind == "appQuit" {
                Button("Choose Application…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        systemEventAppID = Bundle(url: url)?.bundleIdentifier ?? ""
                        systemEventAppName = url.deletingPathExtension().lastPathComponent
                    }
                }
                if !systemEventAppName.isEmpty {
                    Text(systemEventAppName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds the Other Triggers input. Kept separate from `addTrigger` so the
    /// validity check and the constructed value cannot drift apart.
    private func otherTriggerInput() -> TriggerInput {
        switch otherTriggerMode {
        case "scheduled":
            switch scheduleKind {
            case "interval": return .systemEvent(.everyMinutes(max(1, intervalMinutes)))
            case "weekly":
                return .systemEvent(.weekly(days: Array(selectedWeekdays).sorted(),
                                            hour: scheduleHour, minute: scheduleMinute))
            default: return .systemEvent(.daily(hour: scheduleHour, minute: scheduleMinute))
            }
        case "event":
            switch systemEventKind {
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

    private var canAddOtherTrigger: Bool {
        switch otherTriggerMode {
        case "scheduled":
            if scheduleKind == "interval" { return intervalMinutes >= 1 && intervalMinutes <= 1440 }
            if scheduleKind == "weekly" { return !selectedWeekdays.isEmpty }
            return true
        case "event":
            if systemEventKind == "appLaunch" || systemEventKind == "appQuit" { return !systemEventAppID.isEmpty }
            return true
        default:
            return !namedTriggerName.isEmpty
        }
    }

    private var namedTriggerField: some View {
        VStack(alignment: .leading) {
            Text("Named Trigger:")
                .font(.subheadline)
            TextField("Enter trigger name", text: $namedTriggerName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func addTrigger() {
        let input: TriggerInput
        switch category {
        case .trackpad:
            input = .trackpadGesture(selectedGesture)
        case .keyboard:
            if keyboardMode == "sequence" {
                input = .keySequence(sequenceStrokes)
            } else {
                guard let shortcut = recordedShortcut else { return }
                input = .keyboardShortcut(shortcut)
            }
        case .normalMouse:
            input = .mouseButton(selectedMouseButton)
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
    @State private var selectedMouseButton: MouseButton = .button3
    @State private var changeGesture = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Trigger")
                .font(.headline)

            Text("Current: \(trigger.input.displayName)")
                .foregroundColor(.secondary)

            Divider()

            TextField("Trigger Name", text: $triggerName)
                .textFieldStyle(.roundedBorder)

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
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            triggerName = trigger.name
            // Pre-select current gesture if applicable
            if case .trackpadGesture(let g) = trigger.input {
                selectedGesture = g
            }
            if case .mouseButton(let b) = trigger.input {
                selectedMouseButton = b
            }
        }
    }

    @ViewBuilder
    private var gestureEditor: some View {
        switch trigger.input.category {
        case .trackpad:
            ScrollView {
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
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedGesture = gesture
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
                    }
                }
                .padding(4)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        case .normalMouse:
            Picker("Button", selection: $selectedMouseButton) {
                ForEach(MouseButton.allCases) { button in
                    Text(button.rawValue).tag(button)
                }
            }
            .labelsHidden()
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

        if changeGesture {
            switch trigger.input.category {
            case .trackpad:
                updated.input = .trackpadGesture(selectedGesture)
            case .normalMouse:
                updated.input = .mouseButton(selectedMouseButton)
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
            Button("Add New Trigger") { editor?.newTrigger() }.keyboardShortcut("n", modifiers: .command).disabled(editor == nil)
        }
        CommandGroup(before: .textEditing) {
            Button("Search Triggers") { editor?.search() }.keyboardShortcut("f", modifiers: .command).disabled(editor == nil)
        }
    }
}
