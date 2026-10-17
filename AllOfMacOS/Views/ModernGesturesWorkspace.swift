import AppKit
import SwiftUI

/// Gestures & Automations: a native source list of triggers beside a
/// Shortcuts-style workflow canvas. On wide windows the canvas splits into
/// the action sequence and a trigger inspector so the space is used, not
/// stretched; narrow windows stack the two.
struct ModernGesturesWorkspace: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var testingTriggerID: UUID?
    @State private var testResult: String?
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var showTriggerOptions = false
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var replaceActionID: UUID?
    @State private var addCategory: TriggerCategory = .trackpad
    @State private var pendingDeletion: Trigger?

    // MARK: Data

    /// Triggers in the current scope (global, one app, or one group).
    private var scopedTriggers: [Trigger] {
        appState.currentPreset.triggers.filter { trigger in
            if let targetGroupID = appState.selectedActivationGroupID {
                return trigger.activationGroupID == targetGroupID
            }
            if appState.selectedAppTarget.isGlobal {
                return trigger.activationGroupID == nil && (trigger.appBundleID?.isEmpty ?? true)
            }
            return trigger.activationGroupID == nil && trigger.appBundleID == appState.selectedAppTarget.bundleID
        }
    }

    private var filteredTriggers: [Trigger] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var triggers = scopedTriggers.filter { trigger in
            if selectedDeviceCategory != .all && trigger.input.category != selectedDeviceCategory { return false }
            guard !query.isEmpty else { return true }
            return trigger.displayName.lowercased().contains(query)
                || trigger.input.displayName.lowercased().contains(query)
                || trigger.actions.contains { $0.displayName.lowercased().contains(query) }
        }
        // Favorites first; otherwise keep the user's manual order.
        triggers.sort { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }
        return triggers
    }

    private func count(_ category: TriggerCategory) -> Int {
        category == .all ? scopedTriggers.count : scopedTriggers.filter { $0.input.category == category }.count
    }

    private var scopeTitle: String {
        if let id = appState.selectedActivationGroupID,
           let group = appState.currentPreset.activationGroups.first(where: { $0.id == id }) { return group.name }
        return appState.selectedAppTarget.isGlobal ? "All Applications" : appState.selectedAppTarget.name
    }

    // MARK: Body

    var body: some View {
        Group {
            if scopedTriggers.isEmpty {
                onboardingView
            } else {
                HSplitView {
                    gestureList
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    workflowCanvas
                        .frame(minWidth: 460, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search Gestures")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { presentAddTrigger(selectedDeviceCategory) } label: {
                    Label("New Gesture", systemImage: "plus")
                }
                .help("Create a gesture, shortcut or trigger (⌘N)")
            }
        }
        .sheet(isPresented: $appState.showingAddTrigger) {
            AddTriggerSheet(keyboardMonitor: appState.keyboardMonitor, category: addCategory)
        }
        .sheet(isPresented: $appState.showingAddAction) {
            AddActionSheet(parentID: parentID, toElse: toElse, replaceActionID: replaceActionID)
        }
        .confirmationDialog("Delete “\(pendingDeletion?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Gesture", role: .destructive) {
                if let trigger = pendingDeletion {
                    if appState.selectedTrigger?.id == trigger.id { appState.selectedTrigger = nil }
                    appState.removeTrigger(trigger)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The gesture and its actions are removed from this preset.")
        }
        .onAppear { reconcileSelection() }
        .onChange(of: filteredTriggers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: appState.selectedTrigger?.id) { _, _ in
            expandedActionIDs.removeAll()
            testResult = nil
        }
    }

    private func presentAddTrigger(_ category: TriggerCategory) {
        addCategory = category == .all ? .trackpad : category
        appState.showingAddTrigger = true
    }

    private func reconcileSelection() {
        if !filteredTriggers.contains(where: { $0.id == appState.selectedTrigger?.id }) {
            appState.selectedTrigger = filteredTriggers.first
            appState.selectedAction = nil
        }
    }

    // MARK: - Source list

    private var gestureList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if filteredTriggers.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding<UUID?>(
                    get: { appState.selectedTrigger?.id },
                    set: { id in
                        appState.selectedTrigger = filteredTriggers.first { $0.id == id }
                        appState.selectedAction = nil
                    }
                )) {
                    ForEach(filteredTriggers) { trigger in
                        GestureSummaryRow(trigger: trigger,
                                          onToggle: { appState.setTriggerEnabled($0, triggerID: trigger.id) })
                            .tag(trigger.id)
                            .contextMenu { triggerMenu(trigger) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollIndicators(.hidden)
                .accessibilityLabel("Gestures")
            }
            listFooter
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func triggerMenu(_ trigger: Trigger) -> some View {
        Button(trigger.isFavorite ? "Unpin from Top" : "Pin to Top") { appState.toggleFavorite(trigger) }
        Button("Duplicate") { appState.addTrigger(TriggerClipboard.duplicate(trigger)) }
        Button(trigger.isEnabled ? "Disable" : "Enable") { appState.toggleTrigger(trigger) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = trigger }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                scopeMenu
                Spacer(minLength: 4)
                Text("\(filteredTriggers.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(filteredTriggers.count) gestures shown")
            }
            Picker("Device", selection: $selectedDeviceCategory) {
                ForEach(TriggerCategory.allCases) { category in
                    Image(systemName: category.iconName)
                        .help("\(category == .all ? "All" : category.rawValue) (\(count(category)))")
                        .accessibilityLabel(category == .all ? "All" : category.rawValue)
                        .tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selectedDeviceCategory == .all ? "All triggers" : "\(selectedDeviceCategory.rawValue) · \(count(selectedDeviceCategory))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var scopeMenu: some View {
        Menu {
            Button {
                appState.selectedActivationGroupID = nil
                appState.selectedAppTarget = .allApps
            } label: { Label("All Applications", systemImage: "globe") }
            let apps = appState.currentPreset.appTargets.filter { !$0.isGlobal }
            if !apps.isEmpty {
                Section("Applications") {
                    ForEach(apps) { target in
                        Button(target.name) {
                            appState.selectedActivationGroupID = nil
                            appState.selectedAppTarget = target
                        }
                    }
                }
            }
            if !appState.currentPreset.activationGroups.isEmpty {
                Section("Activation Groups") {
                    ForEach(appState.currentPreset.activationGroups) { group in
                        Button(group.name) { appState.selectedActivationGroupID = group.id }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if appState.selectedActivationGroupID == nil, let icon = appState.selectedAppTarget.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: appState.selectedActivationGroupID != nil ? "square.stack.3d.up.fill"
                          : appState.selectedAppTarget.isGlobal ? "globe" : "app.fill")
                        .foregroundStyle(.tint)
                }
                Text(scopeTitle).font(.headline).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which app or group these gestures apply to")
    }

    private var listFooter: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TriggerCategory.inputCategories) { category in
                    Button { presentAddTrigger(category) } label: {
                        Label(category.rawValue, systemImage: category.iconName)
                    }
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                presentAddTrigger(selectedDeviceCategory)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a trigger")
            Button {
                if let trigger = appState.selectedTrigger { pendingDeletion = trigger }
            } label: { Image(systemName: "minus") }
            .buttonStyle(.borderless)
            .disabled(appState.selectedTrigger == nil)
            .help("Delete the selected gesture")
            Spacer()
            let disabled = scopedTriggers.filter { !$0.isEnabled }.count
            Text(disabled == 0 ? "All enabled" : "\(disabled) disabled")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Onboarding (no triggers in this scope)

    private var onboardingView: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: AOMDesign.sectionSpacing) {
                VStack(spacing: 10) {
                    AOMIconTile(systemImage: "hand.tap.fill", tint: .cyan, size: 56)
                    Text("Create your first gesture for \(scopeTitle)")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Pick what starts it — a trackpad gesture, a keyboard shortcut, a mouse button, a drawing, or a system event — then chain the actions it runs.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: AOMDesign.gridSpacing)],
                          spacing: AOMDesign.gridSpacing) {
                    AOMActionTile(title: "Trackpad Gesture", systemImage: "hand.point.up", tint: .cyan,
                                  subtitle: "Swipes, taps, pinches, TipTap") { presentAddTrigger(.trackpad) }
                    AOMActionTile(title: "Keyboard Shortcut", systemImage: "keyboard", tint: .orange,
                                  subtitle: "Shortcuts, key sequences, typed words") { presentAddTrigger(.keyboard) }
                    AOMActionTile(title: "Mouse Button", systemImage: "computermouse.fill", tint: .indigo,
                                  subtitle: "Extra buttons, clicks with modifiers") { presentAddTrigger(.normalMouse) }
                    AOMActionTile(title: "Drawing", systemImage: "hand.draw", tint: .pink,
                                  subtitle: "Draw a shape to run actions") { presentAddTrigger(.drawings) }
                    AOMActionTile(title: "Other Trigger", systemImage: "ellipsis.circle", tint: .gray,
                                  subtitle: "App launch, Wi-Fi, battery, timers") { presentAddTrigger(.otherTriggers) }
                }
                .frame(maxWidth: 760)
            }
            .padding(AOMDesign.pagePadding)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollIndicators(.hidden)
        }
    }

    // MARK: - Workflow canvas

    private var workflowCanvas: some View {
        Group {
            if let trigger = appState.selectedTrigger {
                GeometryReader { geometry in
                    let wide = geometry.size.width >= 860
                    ScrollView {
                        Group {
                            if wide {
                                HStack(alignment: .top, spacing: AOMDesign.sectionSpacing) {
                                    VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                                        triggerSummaryCard(trigger)
                                        actionSequenceSection(trigger)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    triggerInspector(trigger)
                                        .frame(width: min(340, geometry.size.width * 0.34))
                                }
                            } else {
                                VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                                    triggerSummaryCard(trigger)
                                    actionSequenceSection(trigger)
                                    triggerInspector(trigger)
                                }
                            }
                        }
                        .padding(AOMDesign.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .suppressScrollerReservation()
                }
            } else {
                AOMEmptyState("Select a Gesture", systemImage: "cursorarrow.click.2",
                              message: "Choose a gesture on the left to edit what it does.")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func categoryColor(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return .blue
        }
    }

    private func scopeDescription(_ trigger: Trigger) -> String {
        if let id = trigger.activationGroupID,
           let name = appState.currentPreset.activationGroups.first(where: { $0.id == id })?.name { return "Group · \(name)" }
        if let bundle = trigger.appBundleID, !bundle.isEmpty {
            return appState.currentPreset.appTargets.first { $0.bundleID == bundle }?.name ?? bundle
        }
        return "All Applications"
    }

    private func triggerSummaryCard(_ trigger: Trigger) -> some View {
        HStack(spacing: 14) {
            AOMIconTile(systemImage: trigger.input.category.iconName,
                        tint: categoryColor(trigger.input.category), size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(trigger.input.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    if trigger.requiredModifiers != nil {
                        Text(trigger.modifierLabel)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text("\(scopeDescription(trigger)) · \(trigger.actions.count) action\(trigger.actions.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { trigger.isEnabled },
                set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(trigger.isEnabled ? "Disable this gesture" : "Enable this gesture")
        }
        .aomSurface(padding: 16)
    }

    private func triggerInspector(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Details", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Trigger", value: trigger.input.category == .all ? "Any" : trigger.input.category.rawValue)
                LabeledContent("Applies to", value: scopeDescription(trigger))
                LabeledContent("Status", value: trigger.isEnabled ? "Enabled" : "Disabled")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aomSurface()

            DisclosureGroup(isExpanded: $showTriggerOptions) {
                TriggerConfigView(trigger: trigger)
                    .padding(.top, 8)
            } label: {
                Label("Sensitivity & Timing", systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .aomSurface()

            HStack(spacing: 8) {
                Button { appState.toggleFavorite(trigger) } label: {
                    Label(trigger.isFavorite ? "Unpin" : "Pin to Top", systemImage: trigger.isFavorite ? "pin.slash" : "pin")
                }
                Button { appState.addTrigger(TriggerClipboard.duplicate(trigger)) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { pendingDeletion = trigger } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private func actionSequenceSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Actions", systemImage: "bolt.fill",
                             caption: "Run in order when the gesture is recognized") {
                if !trigger.actions.isEmpty {
                    let isTesting = testingTriggerID == trigger.id
                    Button {
                        testingTriggerID = trigger.id
                        testResult = nil
                        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad, triggerID: trigger.id) { ok in
                            testingTriggerID = nil
                            testResult = ok ? "Workflow ran successfully" : "Workflow failed or was stopped"
                        }
                    } label: {
                        Label(isTesting ? "Running…" : "Test", systemImage: isTesting ? "hourglass" : "play.fill")
                    }
                    .controlSize(.small)
                    .disabled(isTesting || ActionTree.problem(trigger.actions) != nil)
                    .help("Run this workflow now")
                }
                Button { addAction() } label: { Label("Add Action", systemImage: "plus") }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            let rows = ActionTree.rows(trigger.actions)
            if rows.isEmpty {
                Button { addAction() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
                        Text("Add the first action").font(.headline)
                        Text("Shortcuts, window moves, app launches, scripts, captures and more.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                            .foregroundStyle(Color.accentColor.opacity(0.4))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 2, height: 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 22 + CGFloat(row.depth) * 16)
                                .accessibilityHidden(true)
                        }
                        ActionCardView(
                            action: row.action,
                            index: index + 1,
                            depth: row.depth,
                            isElse: row.isElse,
                            isExpanded: expandedActionIDs.contains(row.id),
                            trigger: trigger,
                            keyboardMonitor: appState.keyboardMonitor,
                            onToggleExpand: {
                                if expandedActionIDs.contains(row.id) { expandedActionIDs.remove(row.id) }
                                else { expandedActionIDs.insert(row.id) }
                            },
                            onChangeAction: {
                                replaceActionID = row.action.id
                                parentID = nil
                                toElse = false
                                appState.showingAddAction = true
                            },
                            onMoveUp: { appState.moveAction(in: trigger, action: row.action, offset: -1) },
                            onMoveDown: { appState.moveAction(in: trigger, action: row.action, offset: 1) },
                            onDuplicate: { appState.duplicateAction(in: trigger, action: row.action) },
                            onDelete: { appState.removeAction(from: trigger, action: row.action) },
                            onToggleEnable: {
                                var updated = row.action
                                updated.isEnabled.toggle()
                                appState.updateAction(in: trigger, action: updated)
                            },
                            onCopy: { ActionClipboard.copied = row.action },
                            onAddInside: {
                                parentID = row.id
                                toElse = false
                                replaceActionID = nil
                                appState.showingAddAction = true
                            },
                            onAddElse: {
                                parentID = row.id
                                toElse = true
                                replaceActionID = nil
                                appState.showingAddAction = true
                            }
                        )
                    }
                    Button { addAction() } label: {
                        Label("Add Action", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
                    .padding(.top, 12)
                }
            }

            if let testResult {
                Label(testResult, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addAction() {
        parentID = nil
        toElse = false
        replaceActionID = nil
        appState.showingAddAction = true
    }
}

// MARK: - Native list row

private struct GestureSummaryRow: View {
    let trigger: Trigger
    let onToggle: (Bool) -> Void
    @State private var isFlashing = false

    private var tint: Color {
        switch trigger.input.category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AOMIconTile(systemImage: trigger.input.category.iconName, tint: tint, size: 26)
                .opacity(trigger.isEnabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(trigger.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(trigger.actions.first.map {
                    $0.displayName + (trigger.actions.count > 1 ? " · +\(trigger.actions.count - 1)" : "")
                } ?? "No actions yet")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("\(trigger.displayName) enabled")
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.green.opacity(isFlashing ? 0.18 : 0))
                .padding(-4)
        )
        .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
            let flashing = id == trigger.id
            if isFlashing != flashing { isFlashing = flashing }
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.3)), value: isFlashing)
        .accessibilityElement(children: .combine)
    }
}
