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
    @State private var searchPresented = false
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
    /// The editor title reads as a heading, so it edits on click — a hoverable
    /// text field this large would put the I-beam over the whole header.
    @State private var editingName = false
    @FocusState private var nameFieldFocused: Bool

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
        .searchable(text: $searchQuery, isPresented: $searchPresented, placement: .toolbar, prompt: "Search names or actions")
        .toolbar { toolbarContent }
        // File ▸ New Automation (⌘N) and Edit ▸ Search Automations (⌘F) act on
        // this page; the toolbar help promises ⌘N.
        .focusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { searchPresented = true },
            newTrigger: { presentAddTrigger(selectedDeviceCategory) }))
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
            applyPreviewEditorHook()
        }
        .onChange(of: filteredTriggers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: appState.selectedTrigger?.id) { _, _ in
            expandedActionIDs.removeAll()
            showInputSettings = selectedTrigger?.actions.isEmpty == true
            showOptions = false
            applyPreviewEditorHook()
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
            AutomationStatusNotice()
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
                // e.1: section title → card → footer, 24 pt apart.
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
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
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.x4)
                .padding(.bottom, AOMSpace.x8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AOMColor.canvas)
            .id(current.id)
        } else {
            ContentUnavailableView("No Automation Selected", systemImage: "bolt",
                                   description: Text("Select an automation to edit what starts it and what it does."))
        }
    }

    /// Name, App scope, Enabled — and the item menu.
    private func editorHeader(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                if editingName {
                    TextField("Name", text: Binding(
                        get: { trigger.name },
                        set: { value in var updated = trigger; updated.name = value; appState.updateTrigger(updated) }),
                              prompt: Text(trigger.input.displayName).foregroundStyle(AOMColor.text))
                        .textFieldStyle(.plain)
                        .font(AOMFont.title)
                        .focused($nameFieldFocused)
                        .onSubmit { editingName = false }
                        .onExitCommand { editingName = false }
                        .help("Name (optional). Unnamed automations are titled by their input.")
                        .accessibilityLabel("Name")
                        .onChange(of: trigger.id) { _, _ in editingName = false }
                } else {
                    Text(trigger.name.isEmpty ? trigger.input.displayName : trigger.name)
                        .font(AOMFont.title)
                        .foregroundStyle(trigger.name.isEmpty ? AOMColor.textSecondary : AOMColor.text)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingName = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFieldFocused = true }
                        }
                        .help("Click to rename")
                        .accessibilityLabel("Name, \(trigger.displayName). Click to rename.")
                        .onChange(of: trigger.id) { _, _ in editingName = false }
                }
                Menu { triggerMenu(trigger) } label: {
                    Image(systemName: "ellipsis.circle").font(AOMFont.section.weight(.regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pin, duplicate or delete")
                .accessibilityLabel("More for \(trigger.displayName)")
            }
            HStack(spacing: AOMSpace.x4) {
                HStack(spacing: AOMSpace.x2) {
                    Text("Applies to").font(AOMFont.body).foregroundStyle(AOMColor.textSecondary)
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

    /// When: the input as one row in an opaque card; Edit Input opens the
    /// input's own settings as groups inside the same card.
    private func whenSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("When", help: "The input that starts this automation. Edit Input changes it and its own settings; Options tune how it runs.")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AOMSpace.x3) {
                    AOMModuleBadge(symbol: trigger.input.category.iconName, hue: nil, size: AOMIcon.tileBadge)
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        Text(trigger.input.category.rawValue)
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        if case .keyboardShortcut(let shortcut) = trigger.input {
                            AOMShortcutKeys(shortcut: shortcut)
                        } else {
                            Text(trigger.input.displayName).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if trigger.requiredModifiers != nil {
                            Text("With \(trigger.modifierLabel.isEmpty ? "no modifiers" : trigger.modifierLabel)")
                                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        }
                    }
                    Spacer(minLength: AOMSpace.x2)
                    Button(showInputSettings ? "Done" : "Edit Input") {
                        withAnimation(AOMMotion.panel) { showInputSettings.toggle() }
                    }
                    .controlSize(.small)
                    .help(showInputSettings ? "Hide input settings" : "Change the input and its settings")
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x3)
                .frame(minHeight: AOMSize.rowDetail)
                if showInputSettings {
                    // Its groups draw their own hairline above.
                    TriggerConfigView(trigger: trigger, part: .input)
                        .id(trigger.id)
                }
            }
            .aomCard(padding: 0)
        }
    }

    /// Then: the steps in order, as cards joined by arrows; Test and its
    /// last result sit at the trailing end of the section title.
    private func doSection(_ trigger: Trigger) -> some View {
        let rows = ActionTree.rows(trigger.actions)
        let runState = runStates[trigger.id] ?? .idle
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Then", detail: rows.isEmpty ? nil : "\(rows.count) step\(rows.count == 1 ? "" : "s")",
                            help: "The steps run in order, top to bottom. Test runs them now; each step's options open from its chevron.") {
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
            if trigger.valueBinding != nil, ContinuousValueBinding.supports(trigger.input) {
                valueBindingNotice
            }
            if rows.isEmpty {
                AOMSection {
                    Button { addAction() } label: {
                        HStack(spacing: AOMSpace.x3) {
                            Image(systemName: "plus.circle.fill")
                                .font(AOMFont.section)
                                .foregroundStyle(.tint)
                                .frame(width: AOMIcon.tileBadge)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                                Text("Add the first action").font(AOMFont.bodyEmphasis).foregroundStyle(AOMColor.text)
                                Text("Shortcuts, window moves, app launches, scripts, captures and more.")
                                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: AOMSpace.x2)
                            Image(systemName: "chevron.right")
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, AOMSpace.rowInset)
                        .frame(minHeight: AOMSize.rowDetail)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.card))
                    .accessibilityLabel("Add the first action")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            // Centred under the step numbers of the cards it joins.
                            Image(systemName: "arrow.down")
                                .font(AOMFont.badge)
                                .foregroundStyle(AOMColor.textTertiary)
                                .frame(width: AOMIcon.row, height: AOMSpace.x5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AOMSpace.rowInset + CGFloat(row.depth) * AOMSpace.x5)
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

    /// A value-bound trigger drives its value and never runs its steps
    /// (SystemTriggerMonitor / TrackpadMonitor), so the steps say so.
    private var valueBindingNotice: some View {
        AOMNotice(.info, "Actions don't run while a value binding is on.",
                  detail: "The input sets the bound value instead. Turn the binding off in Options to run these steps again.") {
            Button("Show Binding") { withAnimation(AOMMotion.panel) { showOptions = true } }
        }
    }

    /// Options: one disclosure row in its own section (e.1 "Advanced"), naming
    /// what is inside for this input; the groups open in the same card.
    private func optionsSection(_ trigger: Trigger) -> some View {
        AOMSection("Options",
                   help: "How this automation runs. Only the settings that apply to its input are shown.") {
            AOMDisclosureRows(Self.optionsSummary(trigger), isExpanded: $showOptions) {
                TriggerConfigView(trigger: trigger, part: .options)
                    .id(trigger.id)
            }
        }
    }

    /// "Execution, modifiers, sensitivity and value binding" for what applies.
    static func optionsSummary(_ trigger: Trigger) -> String {
        let category = trigger.input.category
        var parts = ["Execution"]
        if category == .trackpad || category == .normalMouse { parts.append("modifiers") }
        if category == .trackpad { parts.append("sensitivity") }
        if ContinuousValueBinding.supports(trigger.input) { parts.append("value binding") }
        guard parts.count > 1, let last = parts.popLast() else { return parts.joined() }
        return parts.joined(separator: ", ") + " and " + last
    }

    /// Isolated UI previews can open the editor's input settings, options and
    /// first step (`--aom-preview-editor-open`), so the inner editors can be
    /// reviewed in screenshots.
    private func applyPreviewEditorHook() {
        guard PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-editor-open"),
              let trigger = selectedTrigger else { return }
        showInputSettings = true
        showOptions = true
        if let first = ActionTree.rows(trigger.actions).first { expandedActionIDs = [first.id] }
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
    /// No automations in this scope yet: the d.9 header says so, then one
    /// section of input kinds to start from (e.5; a chooser rather than one
    /// button, because the input decides everything that follows).
    private var onboardingView: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader("No automations in \(scopeTitle) yet", module: .automation,
                          subtitle: "Choose what starts one, then add the actions it runs. You can change both later.")
            AOMSection("Start with",
                       footer: "\(AOMPaletteShortcut.current(appState.currentPreset).displayString) finds any action, automation or setting.") {
                let choices: [(TriggerCategory, String, String)] = [
                    (.trackpad, "Trackpad Gesture", "Swipes, taps, pinches, TipTap and edge slides"),
                    (.keyboard, "Keyboard Shortcut", "Shortcuts, key sequences and typed words"),
                    (.normalMouse, "Mouse Button", "Extra buttons and clicks with modifiers"),
                    (.drawings, "Drawing", "Draw a shape with the pointer to run actions"),
                    (.otherTriggers, "Other Trigger", "App launch, Wi-Fi, battery, displays and timers")
                ]
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button { presentAddTrigger(choice.0) } label: {
                        HStack(spacing: AOMSpace.x3) {
                            AOMModuleBadge(symbol: choice.0.iconName, hue: AOMModule.automation.hue, size: AOMIcon.tileBadge)
                            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                                Text(choice.1).font(AOMFont.body).foregroundStyle(AOMColor.text)
                                Text(choice.2).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            }
                            Spacer(minLength: AOMSpace.x2)
                            Image(systemName: "chevron.right")
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textTertiary)
                        }
                        .padding(.horizontal, AOMSpace.x4)
                        .frame(minHeight: AOMSize.rowDetail)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AOMRowButtonStyle(radius: 0))
                    .accessibilityLabel("\(choice.1): \(choice.2)")
                    if index < choices.count - 1 { AOMDivider().padding(.leading, AOMSpace.x4 + AOMIcon.tileBadge + AOMSpace.x3) }
                }
            }
        }
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
