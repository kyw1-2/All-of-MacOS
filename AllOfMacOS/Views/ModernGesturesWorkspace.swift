import AppKit
import SwiftUI

/// Automation: find → select → edit, left to right.
///
/// The list column (or a sortable table) shows each automation once: its
/// title, what it does with the key value, its keys, pin and switch. The
/// editor takes the rest of the window and reads top to bottom in the order
/// you think about a workflow — Name, App scope and Enabled; When; Do;
/// Options — after Apple Shortcuts. Scope, view and search sit in the
/// toolbar; the input filter heads the list it filters. Narrow windows show
/// the list or the editor, never three cramped columns.
struct ModernGesturesWorkspace: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("AOMAutomationViewMode") private var viewMode = ViewMode.list
    @AppStorage("AOMAutomationListWidth") private var listWidth: Double = AOMSize.listColumnIdeal
    @AppStorage("AOMAutomationTableWidth") private var tableWidth: Double = 560
    @State private var showingGroupsEditor = false
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var runStates: [UUID: AOMRunState] = [:]
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var showOptions = false
    @State private var showInputSettings = false
    @State private var sortOrder: [KeyPathComparator<Trigger>] = []
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var replaceActionID: UUID?
    @State private var addCategory: TriggerCategory = .trackpad
    @State private var pendingDeletion: Trigger?
    /// Narrow windows: whether the editor replaces the list.
    @State private var compactShowsEditor = false

    enum ViewMode: String { case list, table }

    static let tableWidthRange: ClosedRange<Double> = 420...760

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
        // Pinned first; otherwise keep the user's manual order.
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

    private var rows: [Trigger] {
        let base = filteredTriggers
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    private var selection: Binding<UUID?> {
        Binding(get: { appState.selectedTrigger?.id }, set: { id in
            appState.selectedTrigger = id.flatMap { id in appState.currentPreset.triggers.first { $0.id == id } }
            appState.selectedAction = nil
            if id != nil { compactShowsEditor = true }
        })
    }

    private var selectedTrigger: Trigger? {
        guard let id = appState.selectedTrigger?.id else { return nil }
        return appState.currentPreset.triggers.first { $0.id == id }
    }

    private var subtitle: String {
        let scoped = scopedTriggers
        return "\(scopeTitle) · \(scoped.filter(\.isEnabled).count) of \(scoped.count) on"
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < CGFloat(AOMSize.listColumnRange.lowerBound) + AOMSize.editorMinimum
            Group {
                if scopedTriggers.isEmpty {
                    onboardingView
                } else if compact {
                    if compactShowsEditor, selectedTrigger != nil {
                        editorPane(compact: true)
                    } else {
                        listPane
                    }
                } else {
                    split(totalWidth: geometry.size.width)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aomPane()
        .navigationTitle("Automation")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search names or actions")
        .toolbar { toolbarContent }
        .sheet(isPresented: $appState.showingAddTrigger) {
            AddTriggerSheet(keyboardMonitor: appState.keyboardMonitor, category: addCategory)
        }
        .sheet(isPresented: $showingGroupsEditor) {
            ActivationGroupsEditor().environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingAddAction) {
            AddActionSheet(parentID: parentID, toElse: toElse, replaceActionID: replaceActionID)
        }
        .confirmationDialog("Delete “\(pendingDeletion?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Automation", role: .destructive) {
                if let trigger = pendingDeletion {
                    if appState.selectedTrigger?.id == trigger.id { appState.selectedTrigger = nil }
                    appState.removeTrigger(trigger)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The automation and its actions are removed from this preset.")
        }
        .onAppear {
            reconcileSelection()
            showInputSettings = selectedTrigger?.actions.isEmpty == true
        }
        .onChange(of: filteredTriggers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: appState.selectedTrigger?.id) { _, _ in
            expandedActionIDs.removeAll()
            showInputSettings = selectedTrigger?.actions.isEmpty == true
            showOptions = false
        }
        .onDeleteCommand { if let trigger = selectedTrigger { pendingDeletion = trigger } }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            scopeMenu
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Table", systemImage: "tablecells").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
            .help("Show as a list or a sortable table")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(TriggerCategory.inputCategories) { category in
                    Button { presentAddTrigger(category) } label: { Label(category.rawValue, systemImage: category.iconName) }
                }
            } label: {
                Label("New Automation", systemImage: "plus")
            } primaryAction: {
                presentAddTrigger(selectedDeviceCategory)
            }
            .help("New Automation (⌘N)")
        }
    }

    private func split(totalWidth: CGFloat) -> some View {
        let stored = viewMode == .table ? tableWidth : listWidth
        let range = viewMode == .table ? Self.tableWidthRange : AOMSize.listColumnRange
        let width = min(CGFloat(stored), max(CGFloat(range.lowerBound), totalWidth - AOMSize.editorMinimum))
        return HStack(spacing: 0) {
            listPane.frame(width: width)
            AOMResizeDivider(width: viewMode == .table ? $tableWidth : $listWidth, range: range, paneEdge: .leading)
            editorPane(compact: false).frame(maxWidth: .infinity)
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

    // MARK: - List column

    private var listPane: some View {
        VStack(spacing: 0) {
            filterBar
            AOMDivider()
            if rows.isEmpty {
                if searchQuery.isEmpty {
                    AOMEmptyState("No \(selectedDeviceCategory.rawValue) Automations", systemImage: selectedDeviceCategory.iconName,
                                  message: "Nothing in \(scopeTitle) uses this input yet.") {
                        Button("New Automation") { presentAddTrigger(selectedDeviceCategory) }
                        Button("Show All Inputs") { selectedDeviceCategory = .all }
                    }
                } else {
                    ContentUnavailableView.search(text: searchQuery)
                }
            } else if viewMode == .table {
                table
            } else {
                list
            }
        }
    }

    private static func shortTitle(_ category: TriggerCategory) -> String {
        switch category {
        case .all: return "All"
        case .normalMouse: return "Mouse"
        case .drawings: return "Drawing"
        case .otherTriggers: return "Other"
        default: return category.rawValue
        }
    }

    /// The input filter as labelled chips with their counts; inputs nothing
    /// uses are left out (the selected one always stays).
    private var filterBar: some View {
        let items = TriggerCategory.allCases.compactMap { category -> AOMScopeItem<TriggerCategory>? in
            let number = count(category)
            guard category == .all || number > 0 || category == selectedDeviceCategory else { return nil }
            return AOMScopeItem(id: category, title: Self.shortTitle(category),
                                symbol: category == .all ? nil : category.iconName, count: number)
        }
        return AOMScopeBar(items: items, selection: $selectedDeviceCategory, accessibilityLabel: "Input")
            .padding(.horizontal, AOMSpace.s)
            .frame(height: 42)
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(rows) { trigger in
                AOMAutomationRow(trigger: trigger, rendersSelection: true)
                    .modifier(FiredFlash(triggerID: trigger.id))
                    .tag(trigger.id)
                    .contextMenu { triggerMenu(trigger) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, AOMSize.listRowDouble)
        .accessibilityLabel("Automations")
    }

    private var table: some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("On") { trigger in
                Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                                                          set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(trigger.isEnabled ? "Turn off" : "Turn on")
            }
            .width(28)
            TableColumn("Name", value: \.displayName) { trigger in
                HStack(spacing: 7) {
                    Image(systemName: trigger.input.category.iconName)
                        .foregroundStyle(trigger.isEnabled ? GestureVisual.tint(trigger.input.category) : .secondary)
                        .frame(width: 16)
                        .help(trigger.input.category.rawValue)
                        .accessibilityLabel(trigger.input.category.rawValue)
                    Text(trigger.displayName).foregroundStyle(trigger.isEnabled ? .primary : .secondary)
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("Pinned")
                    }
                }
                .modifier(FiredFlash(triggerID: trigger.id))
            }
            .width(min: 140, ideal: 180)
            // An unnamed automation is titled by its input; don't repeat it.
            TableColumn("Input", value: \.input.displayName) { trigger in
                Text(trigger.aomHasCustomName
                     ? (trigger.requiredModifiers != nil ? "\(trigger.modifierLabel) \(trigger.input.displayName)" : trigger.input.displayName)
                     : "—")
                    .foregroundStyle(trigger.aomHasCustomName ? .secondary : .tertiary)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Does", value: \.aomActionSummary) { trigger in
                Text(trigger.aomActionSummary).foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let trigger = appState.currentPreset.triggers.first(where: { $0.id == id }) {
                triggerMenu(trigger)
            }
        } primaryAction: { ids in
            if ids.first != nil { compactShowsEditor = true }
        }
        .accessibilityLabel("Automations")
    }

    @ViewBuilder private func triggerMenu(_ trigger: Trigger) -> some View {
        Button(trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace") { appState.toggleFavorite(trigger) }
        Button("Duplicate") { appState.addTrigger(TriggerClipboard.duplicate(trigger)) }
        Button(trigger.isEnabled ? "Turn Off" : "Turn On") { appState.toggleTrigger(trigger) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = trigger }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Show automations for", selection: Binding<String>(
                get: {
                    if let id = appState.selectedActivationGroupID { return "group:" + id.uuidString }
                    return appState.selectedAppTarget.isGlobal ? "global" : "app:" + appState.selectedAppTarget.id.uuidString
                },
                set: { value in
                    if value == "global" {
                        appState.selectedActivationGroupID = nil
                        appState.selectedAppTarget = .allApps
                    } else if value.hasPrefix("group:"), let id = UUID(uuidString: String(value.dropFirst(6))) {
                        appState.selectedActivationGroupID = id
                    } else if value.hasPrefix("app:"),
                              let target = appState.currentPreset.appTargets.first(where: { "app:" + $0.id.uuidString == value }) {
                        appState.selectedActivationGroupID = nil
                        appState.selectedAppTarget = target
                    }
                })) {
                Label("All Applications", systemImage: "globe").tag("global")
                let apps = appState.currentPreset.appTargets.filter { !$0.isGlobal }
                if !apps.isEmpty {
                    Section("Applications") {
                        ForEach(apps) { target in Text(target.name).tag("app:" + target.id.uuidString) }
                    }
                }
                if !appState.currentPreset.activationGroups.isEmpty {
                    Section("Activation Groups") {
                        ForEach(appState.currentPreset.activationGroups) { group in
                            Text(group.name).tag("group:" + group.id.uuidString)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Activation Groups…") { showingGroupsEditor = true }
        } label: {
            Label(scopeTitle, systemImage: appState.selectedActivationGroupID != nil ? "square.stack.3d.up"
                  : appState.selectedAppTarget.isGlobal ? "globe" : "app")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Show automations for one app or activation group")
    }

    // MARK: - Editor

    @ViewBuilder private func editorPane(compact: Bool) -> some View {
        if let current = selectedTrigger {
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.l) {
                    if compact {
                        Button { compactShowsEditor = false } label: {
                            Label("All Automations", systemImage: "chevron.left")
                        }
                        .buttonStyle(.link)
                        .keyboardShortcut("[", modifiers: .command)
                    }
                    editorHeader(current)
                    whenSection(current)
                    doSection(current)
                    optionsSection(current)
                }
                .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
                .padding(.horizontal, AOMSpace.l)
                .padding(.top, AOMSpace.l)
                .padding(.bottom, AOMSpace.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AOMTheme.workspace)
            .id(current.id)
        } else {
            ContentUnavailableView("No Automation Selected", systemImage: "bolt",
                                   description: Text("Select an automation to edit what starts it and what it does."))
        }
    }

    /// Name, App scope, Enabled — and the item menu.
    private func editorHeader(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            HStack(spacing: AOMSpace.s - 2) {
                TextField("Name", text: Binding(
                    get: { trigger.name },
                    set: { value in var updated = trigger; updated.name = value; appState.updateTrigger(updated) }),
                          prompt: Text(trigger.input.displayName).foregroundStyle(AOMTheme.text))
                    .textFieldStyle(.plain)
                    .font(AOMType.title1)
                    .tracking(-0.3)
                    .help("Name (optional). Unnamed automations are titled by their input.")
                    .accessibilityLabel("Name")
                Menu { triggerMenu(trigger) } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pin, duplicate or delete")
                .accessibilityLabel("More for \(trigger.displayName)")
            }
            HStack(spacing: AOMSpace.l) {
                HStack(spacing: AOMSpace.xs) {
                    Text("Applies to").font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
                    appScopePicker(trigger)
                }
                Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled },
                                                set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    /// Where this automation works. Changing it moves the list's scope along,
    /// so the automation stays selected.
    private func appScopePicker(_ trigger: Trigger) -> some View {
        Picker("Applies to", selection: Binding<String>(
            get: {
                if let id = trigger.activationGroupID { return "group:" + id.uuidString }
                return trigger.appBundleID.flatMap { $0.isEmpty ? nil : "app:" + $0 } ?? "global"
            },
            set: { value in
                guard var latest = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }) else { return }
                if value.hasPrefix("group:"), let id = UUID(uuidString: String(value.dropFirst(6))) {
                    latest.activationGroupID = id
                    latest.appBundleID = nil
                    appState.selectedActivationGroupID = id
                } else {
                    latest.activationGroupID = nil
                    latest.appBundleID = value == "global" ? nil : String(value.dropFirst(4))
                    appState.selectedActivationGroupID = nil
                    appState.selectedAppTarget = value == "global" ? .allApps
                        : appState.currentPreset.appTargets.first { $0.bundleID == latest.appBundleID } ?? .allApps
                }
                appState.updateTrigger(latest)
                appState.selectedTrigger = latest
            })) {
            Text("All Applications").tag("global")
            ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { target in
                if let bundleID = target.bundleID { Text(target.name).tag("app:" + bundleID) }
            }
            ForEach(appState.currentPreset.activationGroups) { group in
                Text("Group: " + group.name).tag("group:" + group.id.uuidString)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("App-specific automations override groups; groups override All Applications.")
    }

    private func whenSection(_ trigger: Trigger) -> some View {
        let tint = GestureVisual.tint(trigger.input.category)
        return VStack(alignment: .leading, spacing: AOMSpace.xs) {
            workflowHeading("When", detail: "The input that starts this workflow")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AOMSpace.s) {
                    Image(systemName: trigger.input.category.iconName)
                        .font(.system(size: 19, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .frame(width: 40, height: 40)
                        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AOMRadius.tile, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trigger.input.category.rawValue)
                            .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                        if case .keyboardShortcut(let shortcut) = trigger.input {
                            AOMShortcutKeys(shortcut: shortcut)
                        } else {
                            Text(trigger.input.displayName).font(AOMType.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if trigger.requiredModifiers != nil {
                            Text("With \(trigger.modifierLabel.isEmpty ? "no modifiers" : trigger.modifierLabel)")
                                .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(showInputSettings ? "Done" : "Edit Input") {
                        withAnimation(AOMMotion.panel) { showInputSettings.toggle() }
                    }
                    .controlSize(.small)
                    .help(showInputSettings ? "Hide input settings" : "Change the input and its settings")
                }
                .padding(AOMSpace.s + 2)
                if showInputSettings {
                    AOMDivider()
                    TriggerConfigView(trigger: trigger, part: .input)
                        .id(trigger.id)
                        .padding(AOMSpace.m)
                }
            }
            .aomCardStyle(.paper, padding: 0, elevated: false)
        }
    }

    private func workflowHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.xs) {
            Text(title).font(AOMType.title3)
            Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary).lineLimit(1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func doSection(_ trigger: Trigger) -> some View {
        let rows = ActionTree.rows(trigger.actions)
        let runState = runStates[trigger.id] ?? .idle
        return VStack(alignment: .leading, spacing: AOMSpace.xs) {
            HStack(alignment: .center, spacing: AOMSpace.xs) {
                workflowHeading("Then", detail: rows.isEmpty ? "What it does"
                                : "\(rows.count) step\(rows.count == 1 ? "" : "s"), in order")
                Spacer(minLength: AOMSpace.xs)
                AOMRunStatusView(state: runState)
                if !trigger.actions.isEmpty {
                    Button { test(trigger) } label: {
                        Label("Test", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .disabled(runState == .running || ActionTree.problem(trigger.actions) != nil)
                    .help(ActionTree.problem(trigger.actions) ?? "Run this workflow now")
                }
            }
            if rows.isEmpty {
                Button { addAction() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.tint)
                        Text("Add the first action").font(AOMType.bodyEmphasis)
                        Text("Shortcuts, window moves, app launches, scripts, captures and more.")
                            .font(AOMType.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous)
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
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AOMTheme.textTertiary)
                                .frame(width: 18, height: 22)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 14 + CGFloat(row.depth) * 14)
                                .accessibilityHidden(true)
                        }
                        actionCard(row: row, index: index, trigger: trigger)
                    }
                }
                Button { addAction() } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .buttonStyle(AOMTintedButtonStyle())
                .help("Add a step at the end")
            }
        }
    }

    private func actionCard(row: ActionTree.Row, index: Int, trigger: Trigger) -> some View {
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

    private func optionsSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $showOptions) {
                TriggerConfigView(trigger: trigger, part: .options)
                    .id(trigger.id)
                    .padding(.top, AOMSpace.xs)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.xs) {
                    Text("Options").font(AOMType.headline).foregroundStyle(AOMTheme.text)
                    Text("Execution, modifiers and sensitivity").font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(AOMMotion.panel) { showOptions.toggle() } }
            }
        }
        .padding(AOMSpace.s + 2)
        .aomCardStyle(.paper, padding: 0, elevated: false)
    }

    private func test(_ trigger: Trigger) {
        runStates[trigger.id] = .running
        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                      triggerID: trigger.id) { ok in
            DispatchQueue.main.async { runStates[trigger.id] = ok ? .succeeded(Date()) : .failed(Date()) }
        }
    }

    private func addAction() {
        parentID = nil
        toElse = false
        replaceActionID = nil
        appState.showingAddAction = true
    }

    // MARK: - Onboarding (no automations in this scope)

    /// No automations in this scope yet: what can start one, as a short
    /// menu of inputs (Keyboard Maestro's New Macro choices), never a blank page.
    private var onboardingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.m) {
                VStack(alignment: .leading, spacing: AOMSpace.xs) {
                    Text("Create the first automation for \(scopeTitle)")
                        .font(AOMType.title1).tracking(-0.3)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose what starts it, then add the actions it runs. You can change both later.")
                        .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
                }
                VStack(spacing: 0) {
                    let choices: [(TriggerCategory, String, String)] = [
                        (.trackpad, "Trackpad Gesture", "Swipes, taps, pinches, TipTap and edge slides"),
                        (.keyboard, "Keyboard Shortcut", "Shortcuts, key sequences and typed words"),
                        (.normalMouse, "Mouse Button", "Extra buttons and clicks with modifiers"),
                        (.drawings, "Drawing", "Draw a shape with the pointer to run actions"),
                        (.otherTriggers, "Other Trigger", "App launch, Wi-Fi, battery, displays and timers")
                    ]
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Button { presentAddTrigger(choice.0) } label: {
                            HStack(spacing: AOMSpace.s) {
                                Image(systemName: choice.0.iconName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(GestureVisual.tint(choice.0).gradient,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.1).font(AOMType.headline).foregroundStyle(AOMTheme.text)
                                    Text(choice.2).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                                }
                                Spacer(minLength: AOMSpace.xs)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AOMTheme.textTertiary)
                            }
                            .padding(.horizontal, AOMSpace.s)
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.tile))
                        .accessibilityLabel("\(choice.1): \(choice.2)")
                        if index < choices.count - 1 { AOMDivider().padding(.leading, 54) }
                    }
                }
                .padding(AOMSpace.xxs)
                .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
                Text("Tip: \(AOMPaletteShortcut.current(appState.currentPreset).displayString) finds any action, automation or setting.")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, AOMSpace.xl)
            .padding(.vertical, AOMSpace.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AOMTheme.workspace)
    }
}

/// Briefly highlights a row when its automation fires.
private struct FiredFlash: ViewModifier {
    let triggerID: UUID
    @State private var flashing = false
    func body(content: Content) -> some View {
        content
            .background(AOMTheme.positive.opacity(flashing ? 0.18 : 0), in: RoundedRectangle(cornerRadius: AOMRadius.control))
            .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
                let value = id == triggerID
                if flashing != value { flashing = value }
            }
            .animation(AOMDesign.animation(.easeOut(duration: 0.3)), value: flashing)
    }
}
