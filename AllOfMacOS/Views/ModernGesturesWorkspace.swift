import AppKit
import SwiftUI

/// Automation cards with inline search and filters, an optional sortable table,
/// and the selected workflow in a trailing editor.
struct ModernGesturesWorkspace: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("AOMAutomationCompactTable") private var tableLayout = true
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var testingTriggerID: UUID?
    @State private var testResult: String?
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var showTriggerOptions = false
    @State private var sortOrder: [KeyPathComparator<Trigger>] = []
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var replaceActionID: UUID?
    @State private var addCategory: TriggerCategory = .trackpad
    @State private var pendingDeletion: Trigger?
    @AppStorage("AOMGesturesInspectorShown") private var showsInspector = true
    @AppStorage("AOMGesturesInspectorWidth") private var inspectorWidth: Double = 320

    /// The editor's resizable width, and the share of the sheet it may take.
    static let inspectorWidthRange: ClosedRange<Double> = 280...480
    static let inspectorMaximumShare: CGFloat = 0.45

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

    private var rows: [Trigger] {
        let base = filteredTriggers
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    private var selection: Binding<UUID?> {
        Binding(get: { appState.selectedTrigger?.id }, set: { id in
            appState.selectedTrigger = id.flatMap { id in appState.currentPreset.triggers.first { $0.id == id } }
            appState.selectedAction = nil
            if id != nil, !showsInspector { showsInspector = true }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMPageHeader("Automations", subtitle: "Shortcuts, gestures and workflows.",
                          systemImage: "bolt", tint: AOMTheme.blue) {
                Menu {
                    ForEach(TriggerCategory.inputCategories) { category in
                        Button { presentAddTrigger(category) } label: { Label(category.rawValue, systemImage: category.iconName) }
                    }
                } label: { Label("New Automation", systemImage: "plus") }
                primaryAction: { presentAddTrigger(selectedDeviceCategory) }
            }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    AOMSearchField(prompt: "Search names or actions", text: $searchQuery)
                    scopeMenu.fixedSize()
                    Button { tableLayout.toggle() } label: {
                        Image(systemName: tableLayout ? "square.grid.2x2" : "list.bullet")
                    }.help(tableLayout ? "Show cards" : "Show table")
                    Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
                        .help(showsInspector ? "Hide inspector" : "Show inspector")
                }
                .buttonStyle(AOMToolbarButtonStyle())
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(TriggerCategory.allCases) { category in
                                AOMUnderlineTab(title: "\(category == .all ? "All inputs" : category.rawValue)  \(count(category))",
                                                selected: selectedDeviceCategory == category) {
                                    selectedDeviceCategory = category
                                }
                            }
                        }
                    }
                    Text("\(rows.count) items").font(.system(size: 12)).foregroundStyle(AOMTheme.textTertiary).fixedSize()
                }
                .overlay(alignment: .bottom) { AOMTheme.divider.opacity(0.5).frame(height: 0.5) }
            }
            // One sheet: the list and, behind a draggable hairline, the
            // selected automation's editor. (SwiftUI's `.inspector` would
            // become a full-height window column and cover the navigation row.)
            GeometryReader { geometry in
                let editorWidth = min(CGFloat(inspectorWidth),
                                      max(CGFloat(Self.inspectorWidthRange.lowerBound) - 20,
                                          geometry.size.width * Self.inspectorMaximumShare))
                HStack(spacing: 0) {
                    Group {
                        if scopedTriggers.isEmpty { onboardingView }
                        else if rows.isEmpty { ContentUnavailableView.search(text: searchQuery) }
                        else if tableLayout { table.scrollContentBackground(.hidden).padding(.vertical, 4) }
                        else { cards }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsInspector {
                        AOMResizeDivider(width: $inspectorWidth, range: Self.inspectorWidthRange)
                        inspectorContent
                            .frame(width: editorWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .aomCardStyle(.paper, radius: 22, padding: 0)
            .animation(AOMDesign.animation(), value: showsInspector)
        }
        .padding(.horizontal, AOMTheme.pagePadding)
        .padding(.top, AOMTheme.pagePadding)
        .padding(.bottom, 24)
        .background(AOMWorkspaceBackground())
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
        .onDeleteCommand { if let trigger = appState.selectedTrigger { pendingDeletion = trigger } }
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

    private var cards: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(rows) { trigger in
                    gestureCard(trigger)
                }
            }
            .padding(14)
        }
        .suppressScrollerReservation()
    }

    private func gestureCard(_ trigger: Trigger) -> some View {
        let selected = appState.selectedTrigger?.id == trigger.id
        return HStack(spacing: 14) {
            Button { selection.wrappedValue = trigger.id } label: {
                HStack(spacing: 14) {
                    AOMIconTile(systemImage: trigger.input.category.iconName,
                                tint: trigger.isEnabled ? GestureVisual.tint(trigger.input.category) : .gray, size: 30)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Text(trigger.displayName).font(.aomLabel(12.5)).foregroundStyle(AOMTheme.text).lineLimit(1)
                            if trigger.isFavorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(AOMTheme.blue) }
                        }
                        Text(trigger.actionSummary).font(.aomBody(12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(2)
                        Text(trigger.input.displayName).font(.aomCaption(11)).foregroundStyle(AOMTheme.blue)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled },
                set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Enable \(trigger.displayName)")
            Menu { triggerMenu(trigger) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .accessibilityLabel("Options for \(trigger.displayName)")
        }
        .padding(12)
        // Grey wells on the white sheet; the selection is an accent edge.
        .background(selected ? AOMTheme.blue.opacity(0.08) : AOMTheme.cardAlt,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AOMTheme.blue.opacity(0.7) : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contextMenu { triggerMenu(trigger) }
        .modifier(FiredFlash(triggerID: trigger.id))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("On") { trigger in
                Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                                                          set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(trigger.isEnabled ? "Turn off" : "Turn on")
            }
            .width(30)
            TableColumn("Name", value: \.displayName) { trigger in
                HStack(spacing: 8) {
                    // The glyph carries the input type (the filter tabs above
                    // sort by it), so the table needs no separate Type column.
                    Image(systemName: trigger.input.category.iconName)
                        .foregroundStyle(trigger.isEnabled ? GestureVisual.tint(trigger.input.category) : .secondary)
                        .frame(width: 18)
                        .help(trigger.input.category.rawValue)
                        .accessibilityLabel(trigger.input.category.rawValue)
                    Text(trigger.displayName).foregroundStyle(trigger.isEnabled ? .primary : .secondary)
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned")
                    }
                }
                .modifier(FiredFlash(triggerID: trigger.id))
            }
            .width(min: 150, ideal: 190)
            TableColumn("Trigger", value: \.input.displayName) { trigger in
                Text(trigger.requiredModifiers != nil ? "\(trigger.modifierLabel) \(trigger.input.displayName)" : trigger.input.displayName)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Actions", value: \.actionSummary) { trigger in
                Text(trigger.actionSummary).foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let trigger = appState.currentPreset.triggers.first(where: { $0.id == id }) {
                triggerMenu(trigger)
            }
        } primaryAction: { ids in
            if ids.first != nil { showsInspector = true }
        }
        .accessibilityLabel("Gestures")
    }

    // MARK: - Inspector

    @ViewBuilder private var inspectorContent: some View {
        if let trigger = appState.selectedTrigger,
           let current = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    inspectorHeader(current).padding(16)
                    AOMDivider()
                    actionSequenceSection(current).padding(16)
                    AOMDivider()
                    triggerInspector(current).padding(16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        } else {
            ContentUnavailableView("No Gesture Selected", systemImage: "sidebar.trailing",
                                   description: Text("Select a gesture to edit its actions."))
        }
    }

    private func inspectorHeader(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: trigger.input.category.iconName,
                             tint: trigger.isEnabled ? GestureVisual.tint(trigger.input.category) : AOMTheme.textTertiary,
                             size: 32, filled: trigger.isEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trigger.input.displayName).font(AOMType.rowTitle).foregroundStyle(AOMTheme.text).lineLimit(2)
                    Text(scopeDescription(trigger)).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled },
                                                set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Menu { triggerMenu(trigger) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pin, duplicate or delete")
                    .accessibilityLabel("Options for \(trigger.displayName)")
            }
            TextField("Name (optional)", text: Binding(
                get: { trigger.name },
                set: { value in var updated = trigger; updated.name = value; appState.updateTrigger(updated) }))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private func triggerMenu(_ trigger: Trigger) -> some View {
        Button(trigger.isFavorite ? "Unpin from Top" : "Pin to Top") { appState.toggleFavorite(trigger) }
        Button("Duplicate") { appState.addTrigger(TriggerClipboard.duplicate(trigger)) }
        Button(trigger.isEnabled ? "Disable" : "Enable") { appState.toggleTrigger(trigger) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = trigger }
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
                Text(scopeTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which app or group these gestures apply to")
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

    private func scopeDescription(_ trigger: Trigger) -> String {
        if let id = trigger.activationGroupID,
           let name = appState.currentPreset.activationGroups.first(where: { $0.id == id })?.name { return "Group · \(name)" }
        if let bundle = trigger.appBundleID, !bundle.isEmpty {
            return appState.currentPreset.appTargets.first { $0.bundleID == bundle }?.name ?? bundle
        }
        return "All Applications"
    }

    private func triggerInspector(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The input type the old Details box listed, as the caption.
            AOMSectionHeader("Trigger", systemImage: "hand.point.up.left",
                             caption: trigger.input.category == .all ? "Any input" : trigger.input.category.rawValue)
            DisclosureGroup(isExpanded: $showTriggerOptions) {
                TriggerConfigView(trigger: trigger)
                    .padding(.top, 8)
            } label: {
                Label("Sensitivity & Timing", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .aomCardStyle(.well, radius: 12, padding: 12)
        }
    }

    private func actionSequenceSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Actions", systemImage: "bolt.fill",
                             caption: "Run top to bottom") {
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
                Button { addAction() } label: { Image(systemName: "plus") }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Add an action")
                    .accessibilityLabel("Add Action")
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

// MARK: - Table helpers

private extension Trigger {
    var actionSummary: String {
        guard let first = actions.first?.displayName else { return "No actions" }
        return actions.count > 1 ? "\(first) +\(actions.count - 1)" : first
    }
}

/// Briefly highlights a row when its gesture fires.
private struct FiredFlash: ViewModifier {
    let triggerID: UUID
    @State private var flashing = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .background(Color.green.opacity(flashing ? 0.25 : 0), in: RoundedRectangle(cornerRadius: 4))
            .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
                let value = id == triggerID
                if flashing != value { flashing = value }
            }
            .animation(AOMDesign.animation(.easeOut(duration: 0.3)), value: flashing)
    }
}
