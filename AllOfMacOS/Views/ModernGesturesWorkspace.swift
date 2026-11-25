import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// 6.2: a new key, so the wider default reaches people who had the old one.
    @AppStorage("AOMAutomationListWidth.v2") private var listWidth: Double = AOMSize.listColumnIdeal
    @AppStorage("AOMAutomationTableWidth") private var tableWidth: Double = 560
    @State private var showingGroupsEditor = false
    @State private var showingBrowseActions = false
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var expandedDeviceGroups: Set<String> = []
    @State private var searchPresented = false
    @FocusState private var listFocused: Bool
    @State private var runStates: [AutomationEditorID: AOMRunState] = [:]
    /// 7.0: the steps drawn as a recipe (kept per Mac).
    @AppStorage("AOMAutomationShowsRecipe") private var showsRecipe = false
    @Environment(\.aomPageActivity) private var pageActivity
    @State private var explicitSelection: AutomationEditorID?
    @State private var editorMemory: [AutomationEditorID: AutomationEditorDraft] = [:]
    @State private var stepDragSession = UUID()
    @State private var sortOrder: [KeyPathComparator<Trigger>] = []
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var replaceActionID: UUID?
    @State private var addCategory: TriggerCategory = .trackpad
    @Environment(\.undoManager) private var undoManager
    /// Confirmations with Undo (design-3.4.0 b.5): delete, duplicate, test failures.
    @StateObject private var toast = AOMToastModel()
    /// Narrow windows: whether the editor replaces the list.
    @State private var compactShowsEditor = false
    /// Workbench 2 (D02, D03): the arrangement, from the shared resolver with
    /// the measured width and 20 pt of hysteresis.
    @State private var arrangement: AOMWorkbenchArrangement = .listDetail
    /// D12: list | When → Then | the selected step's options. On by default;
    /// the step inspector only appears where list, editor and inspector fit.
    @AppStorage("AOMAutomationStepInspector") private var showsStepInspector = true
    @AppStorage("AOMAutomationStepInspectorWidth") private var stepInspectorWidth = Double(AOMSize.inspectorIdeal)
    /// The inspector only opens on an explicit step selection.
    private var inspectedStepID: UUID? {
        guard let trigger = selectedTrigger, let id = editorMemory[identity(trigger)]?.inspectedStep,
              ActionTree.rows(trigger.actions).contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private static var stepInspectorRange: ClosedRange<Double> {
        Double(AOMSize.inspectorWidth.lowerBound)...Double(AOMSize.inspectorWidth.upperBound)
    }

    /// Whether the step inspector is on screen now.
    private var stepInspectorShown: Bool {
        showsStepInspector && arrangement.showsInspectorBeside && selectedTrigger != nil
    }
    @FocusState private var nameFieldFocused: Bool

    enum ViewMode: String { case list, table }

    static let tableWidthRange: ClosedRange<Double> = 420...760
    /// The input squircle in the first-run choices and the When card: the
    /// Workspace tile size (design-336 b.7), beside a title over a caption.
    private static let choiceBadge: CGFloat = AOMIcon.tileBadge

    // MARK: Data

    /// 6.1: the list shows every automation by default. "All Applications"
    /// used to mean "only the ones without an app or group" — app-specific
    /// and group automations vanished from the list while the label said
    /// "All". The view filter and the automation's own "Applies to" are now
    /// two different, labelled things.
    @AppStorage("AOMAutomationShowsAll") private var showsAllScopes = true

    /// Triggers in the current view: all of them, or those that apply
    /// everywhere, to one app, or to one group.
    private var scopedTriggers: [Trigger] {
        if showsAllScopes { return appState.currentPreset.triggers }
        return appState.currentPreset.triggers.filter { trigger in
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
            return (Self.deviceGroup(for: trigger)?.lowercased().contains(query) ?? false)
                || trigger.displayName.lowercased().contains(query)
                || trigger.input.displayName.lowercased().contains(query)
                || trigger.actions.contains { $0.displayName.lowercased().contains(query) }
        }
        // Pinned first; otherwise keep the user's manual order.
        triggers.sort { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }
        return triggers
    }

    private var scopeTitle: String {
        if showsAllScopes { return "All automations" }
        if let id = appState.selectedActivationGroupID,
           let group = appState.currentPreset.activationGroups.first(where: { $0.id == id }) { return "Group: " + group.name }
        return appState.selectedAppTarget.isGlobal ? "Every app only" : "Only in " + appState.selectedAppTarget.name
    }

    /// The view tabs over the list: All, Every app, then each app and group
    /// that has automations, with counts.
    private enum ScopeTab: Hashable {
        case all, everywhere, app(UUID), group(UUID)
    }

    private var scopeTab: ScopeTab {
        if showsAllScopes { return .all }
        if let id = appState.selectedActivationGroupID { return .group(id) }
        return appState.selectedAppTarget.isGlobal ? .everywhere : .app(appState.selectedAppTarget.id)
    }

    private func selectScope(_ tab: ScopeTab) {
        switch tab {
        case .all:
            showsAllScopes = true
            appState.selectedActivationGroupID = nil
            appState.selectedAppTarget = .allApps
        case .everywhere:
            showsAllScopes = false
            appState.selectedActivationGroupID = nil
            appState.selectedAppTarget = .allApps
        case .app(let id):
            guard let target = appState.currentPreset.appTargets.first(where: { $0.id == id }) else { return }
            showsAllScopes = false
            appState.selectedActivationGroupID = nil
            appState.selectedAppTarget = target
        case .group(let id):
            showsAllScopes = false
            appState.selectedActivationGroupID = id
        }
    }

    private var listHeader: some View {
        let scoped = scopedTriggers
        let inputs = TriggerCategory.allCases.map { category in
            AutomationInputChoice(category: category, title: Self.shortTitle(category),
                                  symbol: category == .all ? "square.grid.2x2.fill" : AddTriggerSheet.railSymbol(category),
                                  count: category == .all ? scoped.count : scoped.filter { $0.input.category == category }.count)
        }
        return AutomationListHeader(inputs: inputs, input: $selectedDeviceCategory)
    }


    private var rows: [Trigger] {
        let base = filteredTriggers
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    private var selection: Binding<UUID?> {
        Binding(get: { explicitTrigger?.id }, set: { id in
            let trigger = id.flatMap { id in filteredTriggers.first { $0.id == id } }
            explicitSelection = trigger.map(identity)
            appState.selectedTrigger = trigger
            appState.selectedAction = nil
            if trigger != nil { compactShowsEditor = true }
        })
    }

    private var explicitTrigger: Trigger? {
        guard let explicitSelection, explicitSelection.preset == appState.currentPreset.id else { return nil }
        return filteredTriggers.first { $0.id == explicitSelection.trigger }
    }

    /// A preview can follow an external Reveal request or the first visible row,
    /// but never supplies the Delete/Run shortcut's actionable selection.
    private var selectedTrigger: Trigger? {
        let visible = rows
        if let explicitTrigger { return explicitTrigger }
        if let requested = appState.selectedTrigger?.id,
           let trigger = visible.first(where: { $0.id == requested }) { return trigger }
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if viewMode == .list {
            return visible.first { trigger in
                Self.deviceGroup(for: trigger).map { expandedDeviceGroups.contains($0) } ?? true
            }
        }
        return visible.first
    }

    private func identity(_ trigger: Trigger) -> AutomationEditorID {
        AutomationEditorID(preset: appState.currentPreset.id, trigger: trigger.id)
    }

    private func draft(_ trigger: Trigger) -> Binding<AutomationEditorDraft> {
        let id = identity(trigger)
        let steps = ActionTree.rows(trigger.actions)
        let initial = AutomationEditorDraft(expandedSteps: steps.count == 1 ? Set(steps.map(\.id)) : [])
        return Binding(get: { editorMemory[id] ?? initial }, set: { editorMemory[id] = $0 })
    }

    private var subtitle: String {
        scopeTitle
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geometry in
            Group {
                if scopedTriggers.isEmpty {
                    onboardingView
                } else {
                    panes(totalWidth: geometry.size.width)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { updateArrangement(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateArrangement(width) }
            // The table needs more room than the list (420 vs 300 pt).
            .onChange(of: viewMode) { _, _ in updateArrangement(geometry.size.width) }
            .onChange(of: showsStepInspector) { _, _ in updateArrangement(geometry.size.width) }
            .onChange(of: listWidth) { _, _ in updateArrangement(geometry.size.width) }
            .onChange(of: tableWidth) { _, _ in updateArrangement(geometry.size.width) }
        }
        .aomPane()
        .aomToolbarSubtitle(subtitle)
        .aomPageToolbar {
            toolbarContent
            AOMToolbarSearchItem(text: $searchQuery, prompt: "Search automations", focusRequest: $searchPresented)
        }
        // File ▸ New Automation (⌘N) and Edit ▸ Search Automations (⌘F) act on
        // this page while it is selected; the toolbar help promises ⌘N.
        .aomPageFocusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { searchPresented = true },
            newTrigger: { presentAddTrigger(selectedDeviceCategory) }))
        // AppState's sheet flags present only on the selected page.
        .aomPageSheet(isPresented: $appState.showingAddTrigger) {
            AddTriggerSheet(keyboardMonitor: appState.keyboardMonitor, category: addCategory)
        }
        .sheet(isPresented: $showingGroupsEditor) {
            ActivationGroupsEditor().environmentObject(appState)
        }
        .aomPageSheet(isPresented: $appState.showingAddAction) {
            BrowseActionsSheet(parentID: parentID, toElse: toElse, replaceActionID: replaceActionID)
        }
        .sheet(isPresented: $showingBrowseActions) {
            BrowseActionsSheet()
        }
        .aomToast(toast)
        // Automations can change while the page is hidden.
        .aomPageLifecycle(onActivate: reconcileSelection)
        .onAppear {
            seedPreviewAutomations()
            applyPreviewEditorHook()
            let args = ProcessInfo.processInfo.arguments
            if PresetManager.isUIPreview, args.contains("--aom-preview-add-midi-trigger") {
                presentAddTrigger(.otherTriggers)
            }
            // `--aom-preview-add-trigger <trackpad|keyboard|mouse|drawing|other>`
            // opens the New Automation sheet on that input (isolated previews only).
            if PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-add-trigger"),
               args.indices.contains(index + 1) {
                let categories: [String: TriggerCategory] = ["trackpad": .trackpad, "keyboard": .keyboard,
                                                             "mouse": .normalMouse, "drawing": .drawings, "other": .otherTriggers]
                presentAddTrigger(categories[args[index + 1]] ?? .trackpad)
            }
        }
        .onChange(of: filteredTriggers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: appState.currentPreset.id) { _, _ in reconcileSelection() }
        .onChange(of: appState.selectedTrigger?.id) { _, id in
            if id != nil { compactShowsEditor = true }
            applyPreviewEditorHook()
        }
        .onChange(of: selectedTrigger.map { ActionTree.rows($0.actions).map(\.id) } ?? []) { _, ids in
            guard let trigger = selectedTrigger else { return }
            let key = identity(trigger)
            editorMemory[key]?.reconcileSteps(Set(ids))
        }
        .aomPageDeleteCommand {
            if let id = explicitSelection, let trigger = actionable(id) { delete(trigger) }
        }
        .aomBarContext(id: BarContextKey(preset: appState.currentPreset.id, trigger: explicitTrigger,
                                         running: explicitSelection.map { runStates[$0] == .running } ?? false)) { barContext() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Layout", selection: $viewMode) {
                    Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                    Label("Table", systemImage: "tablecells").tag(ViewMode.table)
                }
                Picker("Scope", selection: Binding(get: { scopeTab }, set: selectScope)) {
                    Text("All automations").tag(ScopeTab.all)
                    Text("Every app only").tag(ScopeTab.everywhere)
                    ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { target in
                        Text(target.name).tag(ScopeTab.app(target.id))
                    }
                    ForEach(appState.currentPreset.activationGroups) { group in
                        Text("Group: " + group.name).tag(ScopeTab.group(group.id))
                    }
                }
                Button(showsStepInspector ? "Hide Step Inspector" : "Show Step Inspector", systemImage: "sidebar.trailing") {
                    withAnimation(AOMMotion.panel) { showsStepInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Browse Actions…", systemImage: "square.grid.3x3") { showingBrowseActions = true }
                Button("Floating Menus & Widgets…", systemImage: "menubar.rectangle") {
                    FloatingMenuController.shared.edit()
                }
                Divider()
                Button("Edit Activation Groups…", systemImage: "square.stack.3d.up") { showingGroupsEditor = true }
                Divider()
                Button("Import Preset…", systemImage: "square.and.arrow.down") { appState.presentPresetImport() }
                Button("Export Preset…", systemImage: "square.and.arrow.up") { appState.presentPresetExport() }
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
            .help("Automation layout, scope, inspector and presets")
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

    /// The list column's range and minimum in the current view mode.
    private var listRange: ClosedRange<Double> { viewMode == .table ? Self.tableWidthRange : AOMSize.listColumnRange }

    /// The list's width as drawn beside the editor.
    private func splitListWidth(_ totalWidth: CGFloat) -> CGFloat {
        let stored = viewMode == .table ? tableWidth : listWidth
        let fallback = viewMode == .table ? Self.tableWidthRange.lowerBound : AOMSize.listColumnIdeal
        // D04: the stored width checked and drawn narrower while the editor
        // needs the room; it is only written by dragging, so it comes back.
        return AOMPaneWidth.effective(stored: stored, range: listRange, fallback: fallback, available: totalWidth,
                                      reserved: AOMSize.editorMinimum + AOMWorkbenchPolicy.dividerAllowance)
    }

    /// List and editor side by side while both minimums and the divider fit
    /// (the shared resolver, D02), one at a time below that; the step
    /// inspector beside the editor only while all three fit. Each threshold
    /// needs 20 pt to spare to come back.
    private func updateArrangement(_ width: CGFloat) {
        guard width > 0 else { return }
        let next = AOMWorkbenchArrangement.resolve(
            available: width, listMinimum: CGFloat(listRange.lowerBound), detailMinimum: AOMSize.editorMinimum,
            inspectorMinimum: AOMSize.inspectorWidth.lowerBound, inspectorRequested: showsStepInspector,
            current: arrangement, list: splitListWidth(width))
        if next != arrangement { arrangement = next }
    }

    /// List, editor and selected step are mounted once. A narrow window stacks
    /// an already open inspector below the editor without replacing its form.
    private func panes(totalWidth: CGFloat) -> some View {
        let compact = arrangement == .drillIn
        let showsEditor = !compact || (compactShowsEditor && selectedTrigger != nil)
        let showsList = !compact || !showsEditor
        let splitWidth = splitListWidth(totalWidth)
        let listShown: CGFloat = compact ? (showsList ? totalWidth : 0) : splitWidth
        let inspectorRoom = AOMWorkbenchPolicy.inspectorRoom(available: totalWidth, list: splitWidth,
                                                             detailMinimum: AOMSize.editorMinimum)
        let inspectorShown = AOMPaneWidth.effective(stored: stepInspectorWidth, range: Self.stepInspectorRange,
                                                    fallback: Double(AOMSize.inspectorIdeal),
                                                    available: inspectorRoom, reserved: 0)
        return HStack(spacing: 0) {
            listPane
                .frame(width: listShown)
                .clipped()
                .opacity(showsList ? 1 : 0)
                .allowsHitTesting(showsList)
                .accessibilityHidden(!showsList)
            if !compact {
                AOMResizeDivider(width: viewMode == .table ? $tableWidth : $listWidth, range: listRange, paneEdge: .leading,
                                 displayed: splitWidth,
                                 maximum: totalWidth - AOMSize.editorMinimum - AOMWorkbenchPolicy.dividerAllowance)
            }
            let editorLayout = stepInspectorShown ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            editorLayout {
                editorPane(compact: compact, visible: showsEditor).frame(maxWidth: .infinity)
                Group {
                    if stepInspectorShown, inspectedStepID != nil {
                        AOMResizeDivider(width: $stepInspectorWidth, range: Self.stepInspectorRange, paneEdge: .trailing,
                                         displayed: inspectorShown, maximum: inspectorRoom)
                    } else if showsStepInspector, inspectedStepID != nil {
                        AOMDivider()
                    }
                }
                if showsStepInspector, let trigger = selectedTrigger, let step = inspectedStepID {
                    stepInspector(trigger)
                        .id(AutomationEditorID(preset: trigger.id, trigger: step))
                        .frame(width: stepInspectorShown ? inspectorShown : nil)
                        .frame(maxHeight: stepInspectorShown ? .infinity : 220)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Step Inspector")
                }
            }
            .frame(width: compact ? totalWidth : nil)
            .frame(width: showsEditor ? nil : 0, alignment: .leading)
            .clipped()
            .opacity(showsEditor ? 1 : 0)
            .allowsHitTesting(showsEditor)
            .accessibilityHidden(!showsEditor)
            .disabled(!showsEditor)
        }
    }

    /// D12: the selected step's options, the same `ActionConfigView` the
    /// card expands to, with what the step is and whether it can run above.
    @ViewBuilder private func stepInspector(_ trigger: Trigger) -> some View {
        let rows = ActionTree.rows(trigger.actions)
        AOMInspector {
            if let id = inspectedStepID, let position = rows.firstIndex(where: { $0.id == id }) {
                let action = rows[position].action
                AOMInspectorSection("Step \(position + 1)", showsDivider: false) {
                    AOMInspectorRow("Action", text: action.displayName)
                    AOMInspectorRow("State", text: action.isEnabled ? "On" : "Off — skipped when the automation runs")
                    if rows[position].depth > 0 {
                        AOMInspectorRow("In", text: rows[position].isElse ? "Otherwise branch" : "Branch or group")
                    }
                    if let problem = ActionTree.problem([action]) {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(AOMFont.callout)
                            .foregroundStyle(AOMColor.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                AOMInspectorSection("Options") {
                    ActionConfigView(keyboardMonitor: appState.keyboardMonitor, trigger: trigger, action: action)
                        // Its fields are seeded from the step: a new step, new state.
                        .id(action.id)
                        .padding(.horizontal, -AOMSpace.x3)
                }
            } else {
                AOMInspectorSection("Step", showsDivider: false) {
                    Text(rows.isEmpty ? "Add a step to set its options here."
                                      : "Select a step's chevron to set its options here.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func presentAddTrigger(_ category: TriggerCategory) {
        addCategory = category == .all ? .trackpad : category
        appState.showingAddTrigger = true
    }

    private func reconcileSelection() {
        if let id = explicitSelection, explicitTrigger == nil {
            explicitSelection = nil
            if appState.selectedTrigger?.id == id.trigger { appState.selectedTrigger = nil }
            appState.selectedAction = nil
            if arrangement == .drillIn { compactShowsEditor = false }
        }
        let preset = appState.currentPreset
        let live = Set(preset.triggers.map(\.id))
        editorMemory = editorMemory.filter { $0.key.preset == preset.id && live.contains($0.key.trigger) }
    }

    private func actionable(_ id: AutomationEditorID, fromRow: Bool = false) -> Trigger? {
        guard pageActivity.isActive, id.preset == appState.currentPreset.id,
              fromRow || explicitSelection == id else { return nil }
        return filteredTriggers.first { $0.id == id.trigger }
    }

    // MARK: - List column

    private var listPane: some View {
        VStack(spacing: 0) {
            AutomationStatusNotice()
            listHeader
            listSummary
            AOMDivider()
            if rows.isEmpty {
                if searchQuery.isEmpty {
                    AOMEmptyState("No \(selectedDeviceCategory.rawValue) Automations",
                                  systemImage: selectedDeviceCategory.iconName, message: "") {
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
            // The list's + − ⋯ bar (design-3.4.0 b.2, System Settings #230).
            AOMAddRemoveBar(addLabel: "New Automation", add: { presentAddTrigger(selectedDeviceCategory) },
                            removeLabel: "Delete Automation",
                            remove: explicitSelection.map { id in { if let trigger = actionable(id) { delete(trigger) } } }) {
                if let trigger = explicitTrigger {
                    let id = identity(trigger)
                    Button("Duplicate") { if let current = actionable(id) { duplicate(current) } }
                    Button(trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace") {
                        if let current = actionable(id) { appState.toggleFavorite(current) }
                    }
                    Divider()
                }
                Button("Import Preset…") { appState.presentPresetImport() }
                Button("Export Preset…") { appState.presentPresetExport() }
                Divider()
                Button("Edit Activation Groups…") { showingGroupsEditor = true }
                Button("Add Storage Shortcuts (⌥T / ⌥Y)") { appState.installStorageShortcuts() }
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

    /// The input filter as labelled chips. All categories stay visible so
    /// users can discover Trackpad, Keyboard, Mouse, Drawing and Other
    /// triggers at a glance; the chips carry no counts.
    /// 6.1 (status first): how many are on and how many ran today, above
    /// the rows — DeepSeek's alternative C, so the list answers "is it
    /// working?" without a trip to Insights.
    private var listSummary: some View {
        let on = rows.filter(\.isEnabled).count
        let start = Calendar.current.startOfDay(for: Date())
        let names = Set(rows.map(\.input.displayName))
        let ranToday = AutomationRunsToday.count(GestureStatistics.shared.events, since: start, names: names)
        return HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            Text("\(on) of \(rows.count) on")
            Text("·").foregroundStyle(AOMColor.textTertiary)
            Text(ranToday == 1 ? "1 run today" : "\(ranToday) runs today")
            Spacer(minLength: 0)
        }
        .font(AOMFont.caption.monospacedDigit())
        .foregroundStyle(AOMColor.textSecondary)
        .padding(.horizontal, AOMSpace.rowInset + AOMSpace.x0_5)
        .padding(.bottom, AOMSpace.x1 + AOMSpace.x0_5)
        .accessibilityElement(children: .combine)
    }


    // Presentation only: never combine, rewrite or re-order the underlying triggers.
    static func deviceGroup(for trigger: Trigger) -> String? {
        let name = trigger.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folder = trigger.folder?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if name.hasPrefix("ulanzi ") || name == "ulanzi" || ["ulanzi", "ulanzi deck"].contains(folder) { return "Ulanzi Deck" }
        if name.hasPrefix("ugreen ") || name == "ugreen" || ["ugreen", "ugreen mouse"].contains(folder) { return "UGREEN Mouse" }
        return nil
    }

    private var list: some View {
        let selectedID = appState.selectedTrigger?.id
        let stats = GestureStatistics.shared
        let appNames = Dictionary(appState.currentPreset.appTargets.compactMap { target in
            target.bundleID.map { ($0, target.name) } }, uniquingKeysWith: { first, _ in first })
        let groupNames = Dictionary(appState.currentPreset.activationGroups.map { ($0.id, $0.name) },
                                    uniquingKeysWith: { first, _ in first })
        func scope(_ trigger: Trigger) -> String? {
            if let group = trigger.activationGroupID { return groupNames[group].map { "Group: " + $0 } }
            if let id = trigger.appBundleID, !id.isEmpty { return appNames[id] ?? id }
            return nil
        }
        // 6.2: a custom list — readable rows that never cut the name, a
        // raised selection card, the switch on hover — with ↑↓ and Delete.
        let current = rows
        let groups = Dictionary(grouping: current.filter { Self.deviceGroup(for: $0) != nil },
                                by: { Self.deviceGroup(for: $0) ?? "" })
        let searching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visible = ["Ulanzi Deck", "UGREEN Mouse"].flatMap { group -> [Trigger] in
            guard searching || expandedDeviceGroups.contains(group) else { return [] }
            return groups[group] ?? []
        } + current.filter { Self.deviceGroup(for: $0) == nil }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(["Ulanzi Deck", "UGREEN Mouse"], id: \.self) { group in
                        if let members = groups[group], !members.isEmpty {
                            let expanded = searching || expandedDeviceGroups.contains(group)
                            Button {
                                if searching { return }
                                if expanded {
                                    expandedDeviceGroups.remove(group)
                                    if let selected = explicitTrigger, Self.deviceGroup(for: selected) == group {
                                        selection.wrappedValue = nil
                                    }
                                } else { expandedDeviceGroups.insert(group) }
                            } label: {
                                HStack(spacing: AOMSpace.x2) {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                        .font(AOMFont.caption).frame(width: 12)
                                    Image(systemName: group == "Ulanzi Deck" ? "square.grid.3x3" : "computermouse")
                                    Text(group).font(AOMFont.callout.weight(.semibold))
                                    Spacer()
                                    Text("\(members.filter(\.isEnabled).count)/\(members.count)")
                                        .font(AOMFont.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, AOMSpace.x2).frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(expanded ? "Collapse device automations" : "Expand device automations")
                            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                            if expanded {
                                ForEach(members) { trigger in
                                    automationListRow(trigger, selectedID: selectedID, scope: scope(trigger), stats: stats)
                                        .padding(.leading, AOMSpace.x3)
                                }
                            }
                        }
                    }
                    ForEach(current.filter { Self.deviceGroup(for: $0) == nil }) { trigger in
                        automationListRow(trigger, selectedID: selectedID, scope: scope(trigger), stats: stats)
                    }
                }
                .padding(.horizontal, AOMSpace.x2)
                .padding(.vertical, AOMSpace.x1)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { moveSelection(1, in: visible, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1, in: visible, proxy: proxy); return .handled }
            .onChange(of: selectedID) { _, id in
                if let id {
                    if let trigger = current.first(where: { $0.id == id }), let group = Self.deviceGroup(for: trigger) {
                        expandedDeviceGroups.insert(group)
                    }
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: nil) } }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automations")
    }

    private func automationListRow(_ trigger: Trigger, selectedID: UUID?, scope: String?, stats: GestureStatistics) -> some View {
        AutomationListRow(trigger: trigger, isSelected: selectedID == trigger.id,
                          lastRun: stats.lastFired(trigger.input.displayName), scope: scope,
                          setEnabled: { appState.setTriggerEnabled($0, triggerID: trigger.id) })
            .equatable()
            .modifier(FiredFlash(triggerID: trigger.id))
            .id(trigger.id)
            .onTapGesture { selection.wrappedValue = trigger.id; listFocused = true }
            .contextMenu { triggerMenu(trigger) }
    }

    private func moveSelection(_ step: Int, in list: [Trigger], proxy: ScrollViewProxy) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == appState.selectedTrigger?.id } ?? (step > 0 ? -1 : list.count)
        let next = min(max(index + step, 0), list.count - 1)
        selection.wrappedValue = list[next].id
        proxy.scrollTo(list[next].id, anchor: nil)
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
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category))
                        .foregroundStyle(trigger.isEnabled ? .primary : .secondary)
                        .frame(width: 16)
                        .help(trigger.input.category.rawValue)
                        .accessibilityLabel(trigger.input.category.rawValue)
                    Text(trigger.displayName).foregroundStyle(trigger.isEnabled ? .primary : .secondary)
                    if trigger.isFavorite {
                        Image(systemName: "pin.fill").font(AOMFont.badge).foregroundStyle(.secondary).accessibilityLabel("Pinned")
                    }
                }
                .modifier(FiredFlash(triggerID: trigger.id))
            }
            .width(min: 140, ideal: 180)
            // An unnamed automation is titled by its input; don't repeat it.
            TableColumn("Device") { trigger in
                Text(Self.deviceGroup(for: trigger) ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 76, ideal: 100)
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

    /// Flat, no shortcuts, unavailable items hidden (b.4). Delete doesn't
    /// ask: it undoes (toast Undo, ⌘Z).
    @ViewBuilder private func triggerMenu(_ trigger: Trigger, fromRow: Bool = true) -> some View {
        let id = identity(trigger)
        if !trigger.actions.isEmpty, ActionTree.problem(trigger.actions) == nil {
            Button("Run") { run(id, fromRow: fromRow) }
        }
        Button(trigger.isEnabled ? "Turn Off" : "Turn On") {
            if let current = actionable(id, fromRow: fromRow) { appState.toggleTrigger(current) }
        }
        Button(trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace") {
            if let current = actionable(id, fromRow: fromRow) { appState.toggleFavorite(current) }
        }
        Button("Duplicate") { if let current = actionable(id, fromRow: fromRow) { duplicate(current) } }
        Divider()
        Button("Delete", role: .destructive) { if let current = actionable(id, fromRow: fromRow) { delete(current) } }
    }

    private struct BarContextKey: Equatable {
        var id: UUID?
        var enabled = false
        var favorite = false
        var runnable = false
        var name = ""
        var running = false
        var steps = 0
        let preset: UUID
        init(preset: UUID, trigger: Trigger?, running: Bool = false) {
            self.preset = preset
            self.running = running
            steps = trigger?.actions.count ?? 0
            id = trigger?.id
            enabled = trigger?.isEnabled ?? false
            favorite = trigger?.isFavorite ?? false
            runnable = trigger.map { !$0.actions.isEmpty && ActionTree.problem($0.actions) == nil } ?? false
            name = trigger?.displayName ?? ""
        }
    }

    private func latest(_ id: UUID, presetID: UUID) -> Trigger? {
        AutomationEditorID(preset: presetID, trigger: id).latest(in: appState.currentPreset)
    }

    private func barContext() -> AOMBarContext? {
        guard let id = explicitSelection, let trigger = actionable(id) else { return nil }
        let hue = AOMModule.automation.hue
        var actions: [AOMBarAction] = []
        if !trigger.actions.isEmpty, ActionTree.problem(trigger.actions) == nil {
            actions.append(AOMBarAction(id: "auto.test", title: runStates[id] == .running ? "Running…" : "Run",
                                        identity: AOMIdentity(symbol: "play.fill", color: hue),
                                        run: { run(id) },
                                        key: SwiftUI.KeyboardShortcut(.return, modifiers: .command)))
        }
        actions.append(AOMBarAction(id: "auto.toggle", title: trigger.isEnabled ? "Turn Off" : "Turn On",
                                    identity: AOMIdentity(symbol: trigger.isEnabled ? "pause.fill" : "play.circle", color: hue),
                                    run: { if let now = actionable(id) { appState.toggleTrigger(now) } }))
        actions.append(AOMBarAction(id: "auto.duplicate", title: "Duplicate",
                                    identity: AOMIdentity(symbol: "plus.square.on.square", color: hue),
                                    run: { if let now = actionable(id) { duplicate(now) } }))
        actions.append(AOMBarAction(id: "auto.pin", title: trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace",
                                    identity: AOMIdentity(symbol: trigger.isFavorite ? "pin.slash" : "pin", color: hue),
                                    run: { if let now = actionable(id) { appState.toggleFavorite(now) } }))
        actions.append(AOMBarAction(id: "auto.delete", title: "Delete",
                                    identity: AOMIdentity(symbol: "trash", color: AOMColor.danger),
                                    shortcut: "⌫", run: { if let now = actionable(id) { delete(now) } }))
        return AOMBarContext(title: trigger.displayName, actions: actions)
    }

    private func duplicate(_ trigger: Trigger) {
        let copy = TriggerClipboard.duplicate(trigger)
        appState.addTrigger(copy)
        toast.show("Duplicated “\(trigger.displayName)”")
    }

    /// Deletes without asking; Undo puts the automation back where it was
    /// (same position and order), from the toast or Edit › Undo (#103–#105).
    private func delete(_ trigger: Trigger) {
        guard let index = appState.currentPreset.triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        let saved = appState.currentPreset.triggers[index]
        let visible = rows
        let next = visible.firstIndex { $0.id == saved.id }.flatMap { position -> Trigger? in
            visible.indices.contains(position + 1) ? visible[position + 1] : (position > 0 ? visible[position - 1] : nil)
        }
        let id = identity(saved)
        let wasSelected = selectedTrigger?.id == saved.id
        let state = appState
        let revert: @MainActor () -> Void = {
            guard state.currentPreset.id == id.preset, id.latest(in: state.currentPreset) == nil else { return }
            state.currentPreset.triggers.insert(saved, at: min(index, state.currentPreset.triggers.count))
            state.save()
        }
        AOMUndo.perform("Delete Automation", undoManager: undoManager, perform: {
            guard let live = id.latest(in: state.currentPreset) else { return }
            if explicitSelection == id { explicitSelection = nil }
            state.removeTrigger(live)
            // The neighbouring row is a preview only, never actionable.
            if wasSelected, let next { state.selectedTrigger = state.currentPreset.triggers.first { $0.id == next.id } }
        }, revert: revert)
        let manager = undoManager
        toast.show("Deleted “\(saved.displayName)”", action: {
            if let manager, manager.canUndo, manager.undoActionName == "Delete Automation" { manager.undo() } else { revert() }
        })
    }

    // MARK: - Editor

    @ViewBuilder private func editorPane(compact: Bool, visible: Bool) -> some View {
        if let current = selectedTrigger {
            let memory = draft(current)
            VStack(spacing: 0) {
                if compact {
                    Button {
                        memory.restoreNameFocus.wrappedValue = nameFieldFocused
                        compactShowsEditor = false
                    } label: {
                        Label("All Automations", systemImage: "chevron.left")
                    }
                    .buttonStyle(AOMSoftButtonStyle())
                    .aomShortcut("[")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AOMSpace.pageMargin)
                    .padding(.top, AOMSpace.x2)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                        editorHeader(current, visible: visible).id("header")
                        editorStatus(current).id("status")
                        whenSection(current).id("when")
                        doSection(current).id("then")
                        optionsSection(current).id("options")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
                    .padding(.horizontal, AOMSpace.pageMargin)
                    .padding(.top, AOMSpace.pageTop)
                    .padding(.bottom, AOMSpace.x8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition(id: memory.scrollAnchor)
                .scrollIndicators(.never)
                .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
            }
            .background(AOMPageTint())
            .id(identity(current))
        } else {
            AOMEmptyState("No Automation Selected", systemImage: "bolt",
                          message: "Select an automation to edit what starts it and what it does.")
        }
    }

    /// D14: one state line for the automation — on, off, nothing to do, or
    /// why it can't start or run — instead of the reason being spread over
    /// the input, the steps and the Run button.
    private func editorStatus(_ trigger: Trigger) -> some View {
        let status = AOMAutomationEditorStatus.resolve(
            isEnabled: trigger.isEnabled, stepCount: trigger.actions.count,
            inputProblem: TriggerValidation.problem(for: trigger.input, requiredModifiers: trigger.requiredModifiers),
            stepsProblem: ActionTree.problem(trigger.actions))
        return Label(status.text, systemImage: status.symbol)
            .font(AOMFont.callout)
            .foregroundStyle(status.tone == .warning ? AOMColor.warningText : AOMColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Status: \(status.text)")
    }

    /// Name, App scope, Enabled — and the item menu.
    /// One line: the name (Title 3) on the leading edge, where it applies and
    /// its regular switch (the primary setting, HIG Toggles) on the trailing
    /// edge; the name truncates first.
    private func editorHeader(_ trigger: Trigger, visible: Bool) -> some View {
        let id = identity(trigger)
        let memory = draft(trigger)
        return HStack(spacing: AOMSpace.x3) {
            // 6.0: the input's mark and a summary line under the name, so the
            // header says what this automation is before any section is read.
            AOMAppIcon(AOMIdentity(symbol: AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category), color: AOMModule.automation.hue),
                       size: 36, active: trigger.isEnabled)
            VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: AOMSpace.x1) {
                if memory.name.wrappedValue != nil {
                    TextField("Name", text: Binding(get: { memory.name.wrappedValue ?? "" },
                                                    set: { memory.name.wrappedValue = $0 }),
                              prompt: Text(trigger.input.displayName))
                        .textFieldStyle(.plain)
                        .font(AOMFont.title)
                        .focused($nameFieldFocused)
                        .task(id: visible) {
                            guard visible, memory.restoreNameFocus.wrappedValue else { return }
                            await Task.yield()
                            guard !Task.isCancelled, pageActivity.isActive, selectedTrigger.map(identity) == id,
                                  memory.name.wrappedValue != nil else { return }
                            nameFieldFocused = true
                        }
                        .onSubmit {
                            guard let name = memory.name.wrappedValue, var live = id.latest(in: appState.currentPreset) else { return }
                            memory.name.wrappedValue = nil
                            memory.restoreNameFocus.wrappedValue = false
                            live.name = name
                            appState.updateTrigger(live)
                        }
                        .onExitCommand {
                            memory.name.wrappedValue = nil
                            memory.restoreNameFocus.wrappedValue = false
                        }
                        .help("Press Return to save the name, or Escape to cancel.")
                        .accessibilityLabel("Name")
                } else {
                    Button {
                        memory.name.wrappedValue = trigger.name
                        memory.restoreNameFocus.wrappedValue = true
                    } label: {
                        Text(trigger.name.isEmpty ? trigger.input.displayName : trigger.name)
                            .font(AOMFont.title)
                            .foregroundStyle(trigger.name.isEmpty ? AOMColor.textSecondary : AOMColor.text)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Rename automation")
                    .accessibilityLabel("Rename \(trigger.displayName)")
                }
                Menu { triggerMenu(trigger, fromRow: false) } label: {
                    Image(systemName: "ellipsis.circle").font(AOMFont.title.weight(.regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(AOMColor.textSecondary)
                .fixedSize()
                .help("Pin, duplicate or delete")
                .accessibilityLabel("More for \(trigger.displayName)")
            }
            Text(editorSummary(trigger))
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
            }
            // 7.19: the name keeps room for a few words before anything beside it.
            .frame(minWidth: 180, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            appScopePicker(trigger)
                .controlSize(.regular)
                .labelsHidden()
            Toggle("Enabled", isOn: Binding(get: { trigger.isEnabled },
                                            set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
                .help(trigger.isEnabled ? "Turn this automation off" : "Turn this automation on")
        }
        .padding(.bottom, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
    }

    /// "Trackpad · 2 steps · On" under the editor's title.
    private func editorSummary(_ trigger: Trigger) -> String {
        let steps = trigger.actions.count
        let all = ActionTree.rows(trigger.actions).count
        var parts = [trigger.input.category.rawValue,
                     steps == 1 ? "1 step" : "\(steps) steps"]
        if all > steps { parts[1] += " (\(all) in all)" }
        parts.append(trigger.isEnabled ? "On" : "Off")
        if trigger.isFavorite { parts.append("Pinned") }
        return parts.joined(separator: " · ")
    }

    /// Where this automation works. Changing it moves the list's scope along,
    /// so the automation stays selected.
    private func appScopePicker(_ trigger: Trigger) -> some View {
        Picker(selection: Binding<String>(
            get: {
                if let id = trigger.activationGroupID { return "group:" + id.uuidString }
                return trigger.appBundleID.flatMap { $0.isEmpty ? nil : "app:" + $0 } ?? "global"
            },
            set: { value in
                guard var latest = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }) else { return }
                if value.hasPrefix("group:"), let id = UUID(uuidString: String(value.dropFirst(6))) {
                    latest.activationGroupID = id
                    latest.appBundleID = nil
                    if !showsAllScopes { appState.selectedActivationGroupID = id }
                } else {
                    latest.activationGroupID = nil
                    latest.appBundleID = value == "global" ? nil : String(value.dropFirst(4))
                    if !showsAllScopes {
                        appState.selectedActivationGroupID = nil
                        appState.selectedAppTarget = value == "global" ? .allApps
                            : appState.currentPreset.appTargets.first { $0.bundleID == latest.appBundleID } ?? .allApps
                    }
                }
                appState.updateTrigger(latest)
                appState.selectedTrigger = latest
            })) {
            Text("Every app").tag("global")
            ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { target in
                if let bundleID = target.bundleID { Text("Only in " + target.name).tag("app:" + bundleID) }
            }
            ForEach(appState.currentPreset.activationGroups) { group in
                Text("Group: " + group.name).tag("group:" + group.id.uuidString)
            }
        } label: {
            Text("Applies to")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Applies to")
        .help("Where this automation runs. App-specific automations override groups; groups override Every app.")
    }

    /// When: the input as one row in an opaque card; Edit Input opens the
    /// input's own settings as groups inside the same card.
    private func whenSection(_ trigger: Trigger) -> some View {
        let input = draft(trigger).showsInput
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("When", help: "The input that starts this automation. Edit Input changes it and its own settings; Options tune how it runs.")
            VStack(alignment: .leading, spacing: 0) {
                // The input as a settings row with a squircle (System Settings,
                // Shortcuts): its kind over the input itself and its modifiers.
                HStack(spacing: AOMSpace.x3) {
                    AOMModuleBadge(symbol: trigger.input.category.iconName, size: Self.choiceBadge,
                                   active: trigger.isEnabled)
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        Text(trigger.input.category.rawValue)
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: AOMSpace.x2) {
                            if case .keyboardShortcut(let shortcut) = trigger.input {
                                AOMShortcutKeys(shortcut: shortcut)
                            } else {
                                Text(trigger.input.displayName).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(trigger.input.displayName)
                            }
                            if trigger.requiredModifiers != nil {
                                Text("with \(trigger.modifierLabel.isEmpty ? "no modifiers" : trigger.modifierLabel)")
                                    .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: AOMSpace.x2)
                    Button(input.wrappedValue ? "Close" : "Edit Input") {
                        withAnimation(AOMMotion.panel) { input.wrappedValue.toggle() }
                    }
                    .buttonStyle(AOMSoftButtonStyle())
                    .help(input.wrappedValue ? "Hide input settings" : "Change the input and its settings")
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .frame(minHeight: AOMSize.rowDetail + AOMSpace.x2)
                if input.wrappedValue {
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
        let id = identity(trigger)
        let runState = runStates[id] ?? .idle
        let canRun = explicitSelection == id && runState != .running && ActionTree.problem(trigger.actions) == nil
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Then",
                            help: "The steps run in order, top to bottom. Test runs them now; each step's options open from its chevron.") {
                // 7.0: the same steps as a WHEN → IF → DO recipe (Shortcuts, Hazel).
                if !rows.isEmpty {
                    Picker("View", selection: $showsRecipe) {
                        Text("Steps").tag(false)
                        Text("Recipe").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Recipe: when, if and then on one spine, with branches and the last run")
                }
                AOMRunStatusView(state: runState)
                if !trigger.actions.isEmpty {
                    Button { run(id) } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(AOMSoftButtonStyle())
                    .disabled(!canRun)
                    .help(ActionTree.problem(trigger.actions) ?? "Runs these steps now, for real (⌘↩)")
                }
            }
            if trigger.valueBinding != nil, ContinuousValueBinding.supports(trigger.input) {
                valueBindingNotice(trigger)
            }
            if rows.isEmpty {
                AOMSection {
                    Button { addAction(for: id) } label: {
                        HStack(spacing: AOMSpace.x3) {
                            Image(systemName: "plus.circle.fill")
                                .font(AOMFont.title)
                                .foregroundStyle(.tint)
                                .frame(width: Self.choiceBadge)
                                .accessibilityHidden(true)
                            Text("Add Action").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                            Spacer(minLength: AOMSpace.x2)
                            Image(systemName: "chevron.right")
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, AOMSpace.rowInset)
                        .padding(.vertical, AOMSpace.x2)
                        .frame(minHeight: AOMSize.rowDetail + AOMSpace.x2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.card))
                    .accessibilityLabel("Add Action")
                }
            } else if showsRecipe {
                AOMAutomationRecipeCanvas(
                    triggerName: trigger.name.isEmpty ? trigger.input.displayName : trigger.name,
                    triggerSymbol: AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category),
                    scopeLabel: recipeScope(trigger),
                    conditionChips: recipeConditions(trigger),
                    steps: Self.recipeSteps(trigger.actions, runState: runState),
                    onRun: { run(id) },
                    onAddStep: { addAction(for: id) },
                    scrolls: false,
                    canRun: canRun && !trigger.actions.isEmpty)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            // Centred under the step numbers of the cards it joins.
                            Image(systemName: "arrow.down")
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textTertiary)
                                .frame(width: AOMIcon.row, height: AOMSpace.x5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AOMSpace.rowInset + CGFloat(row.depth) * AOMSpace.x5)
                                .accessibilityHidden(true)
                        }
                        AutomationStepDropTarget(payload: stepPayload(id, step: row.id), onDrop: { payload, after in
                            dropStep(payload, onto: row.id, after: after, in: id)
                        }) {
                            actionCard(row: row, index: index, trigger: trigger)
                        }
                    }
                }
                Button { addAction(for: id) } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .buttonStyle(AOMTintedButtonStyle())
                .help("Add a step at the end")
            }
        }
    }

    /// Where the recipe runs: everywhere, one app or a group.
    private func recipeScope(_ trigger: Trigger) -> String {
        if let id = trigger.appBundleID, !id.isEmpty {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        }
        return trigger.activationGroupID == nil ? "Everywhere" : "App group"
    }

    /// The IF strip: what has to hold before the steps run.
    private func recipeConditions(_ trigger: Trigger) -> [String] {
        var chips: [String] = []
        if let modifiers = trigger.requiredModifiers, modifiers != 0 {
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            let keys = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { flags.contains($0.0) }.map(\.1).joined()
            chips.append(keys.isEmpty ? "With modifiers" : "Holding \(keys)")
        }
        if trigger.delayBeforeTriggeringMs > 0 { chips.append("After \(trigger.delayBeforeTriggeringMs) ms") }
        if trigger.pressCount > 1 { chips.append("Pressed twice") }
        if trigger.repeatWhileHeld { chips.append("Repeats while held") }
        return chips
    }

    /// Pure: the steps as the recipe's cards, branches nested, numbered in
    /// order, the last run's result on every enabled card.
    static func recipeSteps(_ actions: [TriggerAction], runState: AOMRunState) -> [AOMRecipeStepViewModel] {
        var counter = 0
        func build(_ list: [TriggerAction]) -> [AOMRecipeStepViewModel] {
            list.map { action in
                counter += 1
                let status: AOMStepRunStatus
                switch runState {
                case .idle: status = .idle
                case .running: status = action.isEnabled ? .running : .idle
                case .succeeded: status = action.isEnabled ? .succeeded : .idle
                case .failed: status = action.isEnabled ? .failed("This run stopped with an error") : .idle
                }
                let index = counter
                let branch = action.actionType == .ifElse || action.actionType == .actionGroup
                let summary = action.parameters.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AOMRecipeStepViewModel(
                    id: action.id, index: index, title: action.displayName,
                    subtitle: (summary?.isEmpty == false ? summary : nil) ?? (action.isEnabled ? nil : "Off"),
                    symbol: action.actionType.iconName, isEnabled: action.isEnabled, runStatus: status,
                    isBranchContainer: branch,
                    thenChildren: build(action.parameters.children ?? []),
                    elseChildren: build(action.parameters.elseChildren ?? []))
            }
        }
        return build(actions)
    }

    private func actionCard(row: ActionTree.Row, index: Int, trigger: Trigger) -> some View {
        let id = identity(trigger)
        let memory = draft(trigger)
        let inspected = showsStepInspector && inspectedStepID == row.id
        func step(_ action: (Trigger, TriggerAction) -> Void) {
            guard let live = actionable(id), let step = ActionTree.rows(live.actions).first(where: { $0.id == row.id }) else { return }
            action(live, step.action)
        }
        func browse(parent: UUID? = nil, alternate: Bool = false, replace: UUID? = nil) {
            step { live, _ in
                appState.selectedTrigger = live
                parentID = parent
                toElse = alternate
                replaceActionID = replace
                appState.showingAddAction = true
            }
        }
        return ActionCardView(
            action: row.action, index: index + 1, depth: row.depth, isElse: row.isElse,
            isExpanded: !inspected && memory.expandedSteps.wrappedValue.contains(row.id),
            trigger: trigger, keyboardMonitor: appState.keyboardMonitor,
            onToggleExpand: {
                step { _, _ in
                    if showsStepInspector {
                        memory.inspectedStep.wrappedValue = inspected ? nil : row.id
                    } else if memory.expandedSteps.wrappedValue.contains(row.id) {
                        memory.expandedSteps.wrappedValue.remove(row.id)
                    } else {
                        memory.expandedSteps.wrappedValue.insert(row.id)
                    }
                }
            },
            onChangeAction: { browse(replace: row.id) },
            onMoveUp: { reorderSteps(in: id) { AutomationStepOrder.move($0, source: row.id, offset: -1) } },
            onMoveDown: { reorderSteps(in: id) { AutomationStepOrder.move($0, source: row.id, offset: 1) } },
            onDuplicate: { step { appState.duplicateAction(in: $0, action: $1) } },
            onDelete: { step { appState.removeAction(from: $0, action: $1) } },
            onToggleEnable: {
                step { live, action in
                    var changed = action
                    changed.isEnabled.toggle()
                    appState.updateAction(in: live, action: changed)
                }
            },
            onCopy: { step { _, action in ActionClipboard.copied = action } },
            onAddInside: { browse(parent: row.id) },
            onAddElse: { browse(parent: row.id, alternate: true) },
            isInspected: inspected
        )
        .disabled(explicitSelection != id)
    }

    private func stepPayload(_ id: AutomationEditorID, step: UUID) -> String {
        "\(stepDragSession.uuidString):\(id.preset.uuidString):\(id.trigger.uuidString):\(step.uuidString)"
    }

    private func dropStep(_ payload: String, onto target: UUID, after: Bool, in id: AutomationEditorID) -> Bool {
        let parts = payload.split(separator: ":")
        guard parts.count == 4, let source = UUID(uuidString: String(parts[3])),
              payload == stepPayload(id, step: source) else { return false }
        return reorderSteps(in: id) { AutomationStepOrder.move($0, source: source, target: target, after: after) }
    }

    @discardableResult
    private func reorderSteps(in id: AutomationEditorID, move: ([TriggerAction]) -> [TriggerAction]?) -> Bool {
        guard let current = actionable(id), let reordered = move(current.actions) else { return false }
        let state = appState
        let original = current.actions
        func apply(_ steps: [TriggerAction], replacing expected: [TriggerAction]) {
            guard var latest = id.latest(in: state.currentPreset), latest.actions == expected else { return }
            latest.actions = steps
            // Do not change another automation's selection while undoing.
            state.currentPreset.updateTrigger(latest)
            if state.selectedTrigger?.id == latest.id { state.selectedTrigger = latest }
            state.save()
        }
        AOMUndo.perform("Reorder Steps", undoManager: undoManager,
                        perform: { apply(reordered, replacing: original) },
                        revert: { apply(original, replacing: reordered) })
        return true
    }

    /// A value-bound trigger drives its value and never runs its steps
    /// (SystemTriggerMonitor / TrackpadMonitor), so the steps say so.
    private func valueBindingNotice(_ trigger: Trigger) -> some View {
        let options = draft(trigger).showsOptions
        return AOMNotice(.info, "Actions don't run while a value binding is on.") {
            Button("Show Binding") { withAnimation(AOMMotion.panel) { options.wrappedValue = true } }
        }
    }

    /// Options: one disclosure row in its own section (e.1 "Advanced"), naming
    /// what is inside for this input; the groups open in the same card.
    private func optionsSection(_ trigger: Trigger) -> some View {
        AOMSection("Options",
                   help: "How this automation runs. Only the settings that apply to its input are shown.") {
            AOMDisclosureRows("Advanced", detail: Self.optionsSummary(trigger), isExpanded: draft(trigger).showsOptions) {
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
        let memory = draft(trigger)
        memory.showsInput.wrappedValue = true
        memory.showsOptions.wrappedValue = true
        if let first = ActionTree.rows(trigger.actions).first { memory.expandedSteps.wrappedValue = [first.id] }
    }

    private func seedPreviewAutomations() {
        guard AOMWorkbenchPreviewData.enabled, appState.currentPreset.triggers.isEmpty else { return }
        appState.currentPreset.triggers = AOMWorkbenchPreviewData.automations()
        // Keep the actual page layout and selection policy in the snapshot.
        // An optional explicit recipe preview gives nested steps coverage too.
        if ProcessInfo.processInfo.arguments.contains("--aom-preview-editor-open"),
           let first = appState.currentPreset.triggers.first { selection.wrappedValue = first.id }
    }

    /// All Run entry points validate the current preset and the latest saved
    /// actions at execution, never the value captured by an older menu.
    private func run(_ id: AutomationEditorID, fromRow: Bool = false) {
        guard !PresetManager.isUIPreview, actionable(id, fromRow: fromRow) != nil,
              runStates[id] != .running, let trigger = latest(id.trigger, presetID: id.preset),
              !trigger.actions.isEmpty, ActionTree.problem(trigger.actions) == nil else { return }
        runStates[id] = .running
        let name = trigger.displayName
        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                      triggerID: trigger.id) { ok in
            DispatchQueue.main.async {
                runStates[id] = ok ? .succeeded(Date()) : .failed(Date())
                if !ok, pageActivity.isActive, latest(id.trigger, presetID: id.preset) != nil {
                    toast.show("“\(name)” didn't finish. A step failed or was stopped.", tone: .danger)
                }
            }
        }
    }

    private func addAction(for id: AutomationEditorID) {
        guard let live = actionable(id) else { return }
        appState.selectedTrigger = live
        parentID = nil
        toElse = false
        replaceActionID = nil
        appState.showingAddAction = true
    }

    // MARK: - Onboarding (no automations in this scope)

    /// Nothing in this scope yet (5.0): the page's mark, one sentence and the
    /// five input kinds as cards — BetterTouchTool's trigger categories made
    /// visible, so the first automation starts from "what do I press?".
    private var onboardingView: some View {
        ScrollView {
            VStack(spacing: AOMSpace.x5) {
                AOMEmptyState("Make your first automation",
                              systemImage: "bolt.fill",
                              message: "Pick what you press, swipe or draw. Then choose what it runs — an app, a shortcut, a window move or a script.") {
                    Button("New Automation") { presentAddTrigger(.trackpad) }
                        .aomShortcut("n")
                }
                .frame(maxHeight: 220)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: AOMSpace.x3)], spacing: AOMSpace.x3) {
                    ForEach(TriggerCategory.inputCategories) { category in
                        AutomationInputCard(category: category, title: Self.shortTitle(category)) {
                            presentAddTrigger(category)
                        }
                    }
                }
                .frame(maxWidth: AOMSize.readableWidth)
            }
            .padding(AOMSpace.pageMargin)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One input kind on the empty Automation page: its mark, its name and
/// what it listens to.
private struct AutomationInputCard: View {
    let category: TriggerCategory
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var detail: String {
        switch category {
        case .trackpad: return "Taps, swipes, pinches and clicks"
        case .keyboard: return "Shortcuts and key sequences"
        case .normalMouse: return "Buttons on any mouse"
        case .drawings: return "Shapes you draw with the pointer"
        case .otherTriggers: return "Schedules, apps, power and sleep"
        case .all: return ""
        }
    }

    private var symbol: String {
        switch category {
        case .trackpad: return "hand.point.up.left.fill"
        case .keyboard: return "keyboard.fill"
        case .normalMouse: return "computermouse.fill"
        case .drawings: return "scribble.variable"
        case .otherTriggers: return "sparkles"
        case .all: return "square.grid.2x2.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x3) {
                // 7.14: each input kind as a tinted squircle (BTT's input tabs, Shortcuts' gallery).
                AOMAppIcon(AOMIdentity(symbol: symbol, color: AOMModule.automation.hue), size: AOMIcon.tileMark + 4)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(title).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                    Text(detail).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(hovering ? AOMColor.accent : AOMColor.textTertiary)
            }
            .padding(AOMSpace.x3)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(hovering ? AOMColor.surfaceHover : AOMColor.surface,
                        in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                    .strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .help("New \(title) automation")
        .accessibilityLabel("New \(title) automation")
        .accessibilityHint(detail)
    }
}

/// Briefly highlights a row when its automation fires.
private struct FiredFlash: ViewModifier {
    let triggerID: UUID
    @State private var flashing = false
    /// A hidden page does not flash (read, not observed).
    @Environment(\.aomPageActivity) private var pageActivity
    func body(content: Content) -> some View {
        content
            .background(AOMTheme.positive.opacity(flashing ? 0.18 : 0), in: RoundedRectangle(cornerRadius: AOMRadius.control))
            .onReceive(LiveTouchState.shared.$lastFiredTriggerID.removeDuplicates()) { id in
                let value = pageActivity.isActive && id == triggerID
                if flashing != value { flashing = value }
            }
            .animation(AOMDesign.animation(.easeOut(duration: 0.3)), value: flashing)
    }
}


/// "N runs today" over the list (6.5): counted once per change of the event
/// log, the day or the listed inputs instead of on every render of the list.
enum AutomationRunsToday {
    private struct Key: Equatable {
        let count: Int
        let last: Date?
        let start: Date
        let names: Set<String>
    }
    nonisolated(unsafe) private static var memo: (key: Key, value: Int)?

    /// Pure apart from the memo.
    static func count(_ events: [GestureEvent], since start: Date, names: Set<String>) -> Int {
        let key = Key(count: events.count, last: events.last?.timestamp, start: start, names: names)
        if let memo, memo.key == key { return memo.value }
        let value = events.reduce(into: 0) { count, event in
            if event.fired, event.timestamp >= start, names.contains(event.gesture) { count += 1 }
        }
        memo = (key, value)
        return value
    }
}
