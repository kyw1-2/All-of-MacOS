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
    /// 6.2: a new key, so the wider default reaches people who had the old one.
    @AppStorage("AOMAutomationListWidth.v2") private var listWidth: Double = AOMSize.listColumnIdeal
    @AppStorage("AOMAutomationTableWidth") private var tableWidth: Double = 560
    @State private var showingGroupsEditor = false
    @State private var showingBrowseActions = false
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var searchPresented = false
    @FocusState private var listFocused: Bool
    @State private var runStates: [UUID: AOMRunState] = [:]
    /// 7.0: the steps drawn as a recipe (kept per Mac).
    @AppStorage("AOMAutomationShowsRecipe") private var showsRecipe = false
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var showOptions = false
    @State private var showInputSettings = false
    /// 6.1 (Codex review): what you opened in each automation's editor,
    /// restored when you come back to it instead of a rule (≤ 6 steps all
    /// open, 7+ all closed) that flipped between the 6th and 7th step.
    @State private var editorMemory: [UUID: EditorMemory] = [:]

    private struct EditorMemory {
        var steps: Set<UUID> = []
        var input = false
        var options = false
    }
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
    /// The step whose options the inspector shows (kept across resizes).
    @State private var inspectedStepID: UUID?

    private static var stepInspectorRange: ClosedRange<Double> {
        Double(AOMSize.inspectorWidth.lowerBound)...Double(AOMSize.inspectorWidth.upperBound)
    }

    /// Whether the step inspector is on screen now.
    private var stepInspectorShown: Bool {
        showsStepInspector && arrangement.showsInspectorBeside && selectedTrigger != nil
    }
    /// The editor title reads as a heading, so it edits on click — a hoverable
    /// text field this large would put the I-beam over the whole header.
    @State private var editingName = false
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
            return trigger.displayName.lowercased().contains(query)
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

    /// 6.2 header: title and count, search with the scope at its end, and
    /// the input kinds as a category bar (AutomationListHeader.swift).
    private var listHeader: some View {
        let triggers = appState.currentPreset.triggers
        var scopes = [
            AutomationScopeChoice(kind: .all, title: "All apps", count: triggers.count),
            AutomationScopeChoice(kind: .everywhere, title: "Every app",
                                  count: triggers.filter { $0.activationGroupID == nil && ($0.appBundleID?.isEmpty ?? true) }.count)
        ]
        for target in appState.currentPreset.appTargets where !target.isGlobal {
            let count = triggers.filter { $0.activationGroupID == nil && $0.appBundleID == target.bundleID }.count
            scopes.append(AutomationScopeChoice(kind: .app(target.id), title: target.name, count: count, bundleID: target.bundleID))
        }
        for group in appState.currentPreset.activationGroups {
            scopes.append(AutomationScopeChoice(kind: .group(group.id), title: group.name,
                                                count: triggers.filter { $0.activationGroupID == group.id }.count))
        }
        let scoped = scopedTriggers
        let inputs = TriggerCategory.allCases.map { category in
            AutomationInputChoice(category: category, title: Self.shortTitle(category),
                                  symbol: category == .all ? "square.grid.2x2.fill" : AddTriggerSheet.railSymbol(category),
                                  count: category == .all ? scoped.count : scoped.filter { $0.input.category == category }.count)
        }
        let kind: AutomationScopeChoice.Kind = {
            switch scopeTab {
            case .all: return .all
            case .everywhere: return .everywhere
            case .app(let id): return .app(id)
            case .group(let id): return .group(id)
            }
        }()
        return AutomationListHeader(
            total: scoped.count, query: $searchQuery, focusRequest: $searchPresented,
            scopes: scopes, scope: kind,
            selectScope: { choice in
                switch choice {
                case .all: selectScope(.all)
                case .everywhere: selectScope(.everywhere)
                case .app(let id): selectScope(.app(id))
                case .group(let id): selectScope(.group(id))
                }
            },
            inputs: inputs, input: $selectedDeviceCategory,
            editGroups: { showingGroupsEditor = true })
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
            // 6.2: the search moved into the list's header, beside its scope.
            toolbarContent
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
            syncExpandedEditorState()
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
        .onChange(of: expandedActionIDs) { _, _ in rememberEditorState() }
        .onChange(of: showInputSettings) { _, _ in rememberEditorState() }
        .onChange(of: showOptions) { _, _ in rememberEditorState() }
        .onChange(of: appState.selectedTrigger?.id) { _, _ in
            syncExpandedEditorState()
            applyPreviewEditorHook()
            reconcileInspectedStep(resetToFirst: true)
        }
        .onChange(of: selectedTrigger.map { ActionTree.rows($0.actions).map(\.id) } ?? []) { _, _ in
            reconcileInspectedStep(resetToFirst: false)
        }
        // D05: ⌫ goes through the same check as the bar's Delete.
        .aomPageDeleteCommand {
            if let id = appState.selectedTrigger?.id, let trigger = actionable(id) { delete(trigger) }
        }
        // 6.0: the selected automation and what can be done to it, in the
        // action bar (Test ⌘↩ is the primary).
        .aomBarContext(id: BarContextKey(trigger: selectedTrigger,
                                         running: selectedTrigger.map { runStates[$0.id] == .running } ?? false)) { barContext() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showingGroupsEditor = true
            } label: {
                Label("Groups", systemImage: "square.stack.3d.up")
            }
            .help("Edit Activation Groups")
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Table", systemImage: "tablecells").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
            .help("Show as a list or a sortable table")
            Button {
                withAnimation(AOMMotion.panel) { showsStepInspector.toggle() }
            } label: {
                Label(showsStepInspector ? "Hide Step Inspector" : "Show Step Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(showsStepInspector
                  ? "Hide the step inspector; options open in each step's card (⌥⌘I)"
                  : "Show the selected step's options beside the editor when the window has room (⌥⌘I)")
            Menu {
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
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Actions, floating menus and presets")
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

    /// D12: the inspected step follows the automation (its first step when
    /// another automation is selected) and never points at a step that was
    /// deleted; a step that still exists stays inspected.
    private func reconcileInspectedStep(resetToFirst: Bool) {
        let ids = selectedTrigger.map { ActionTree.rows($0.actions).map(\.id) } ?? []
        let next = AOMStableSelection.reconcile(resetToFirst ? nil : inspectedStepID, visible: ids, autoSelectFirst: true)
        if next != inspectedStepID { inspectedStepID = next }
    }

    /// Both arrangements in one hierarchy (D03): the list keeps its place
    /// (only its width changes, and it is hidden while the editor fills a
    /// narrow window), so its scroll position and selection survive a resize
    /// across the threshold and going Back from the editor.
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
            if showsEditor {
                editorPane(compact: compact).frame(maxWidth: .infinity)
            }
            if stepInspectorShown, let trigger = selectedTrigger {
                AOMResizeDivider(width: $stepInspectorWidth, range: Self.stepInspectorRange, paneEdge: .trailing,
                                 displayed: inspectorShown, maximum: inspectorRoom)
                stepInspector(trigger)
                    .frame(width: inspectorShown)
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Step Inspector")
            }
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

    /// Workbench 2 (D03, D05): a visible selection stays. Switching scope or
    /// input (or arriving) highlights the first automation; while a search is
    /// typed, an automation the search hides leaves nothing selected, so ⌘↩
    /// and ⌫ never move to a different automation.
    private func reconcileSelection() {
        let visible = filteredTriggers
        let searching = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let next = AOMStableSelection.reconcile(appState.selectedTrigger?.id, visible: visible.map(\.id),
                                                autoSelectFirst: !searching)
        guard next != appState.selectedTrigger?.id else { return }
        appState.selectedTrigger = next.flatMap { id in visible.first { $0.id == id } }
        appState.selectedAction = nil
    }

    /// The automation a bar button may act on: still in the preset and still
    /// one of the rows on screen (not hidden by the search since).
    private func actionable(_ id: UUID) -> Trigger? {
        guard AOMStableSelection.actionTarget(id, visible: filteredTriggers.map(\.id)) != nil else { return nil }
        return latest(id)
    }

    /// Summary first (6.1): an automation opens with its steps as one-line
    /// summaries and its input and options folded, unless you had opened
    /// them before; a single-step automation opens its one step.
    private func syncExpandedEditorState() {
        guard let trigger = selectedTrigger else {
            expandedActionIDs.removeAll()
            showInputSettings = false
            showOptions = false
            return
        }
        if let memory = editorMemory[trigger.id] {
            let live = Set(ActionTree.rows(trigger.actions).map(\.id))
            expandedActionIDs = memory.steps.intersection(live)
            showInputSettings = memory.input
            showOptions = memory.options
        } else {
            let allRows = ActionTree.rows(trigger.actions)
            expandedActionIDs = allRows.count == 1 ? Set(allRows.map(\.id)) : []
            showInputSettings = false
            showOptions = false
        }
    }

    private func rememberEditorState() {
        guard let id = selectedTrigger?.id else { return }
        editorMemory[id] = EditorMemory(steps: expandedActionIDs, input: showInputSettings, options: showOptions)
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
                            remove: selectedTrigger.map { trigger in { delete(trigger) } }) {
                if let trigger = selectedTrigger {
                    Button("Duplicate") { duplicate(trigger) }
                    Button(trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace") { appState.toggleFavorite(trigger) }
                    Divider()
                }
                Button("Import Preset…") { appState.presentPresetImport() }
                Button("Export Preset…") { appState.presentPresetExport() }
                Divider()
                Button("Edit Activation Groups…") { showingGroupsEditor = true }
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(current) { trigger in
                        AutomationListRow(trigger: trigger, isSelected: selectedID == trigger.id,
                                          lastRun: stats.lastFired(trigger.input.displayName),
                                          scope: scope(trigger),
                                          setEnabled: { appState.setTriggerEnabled($0, triggerID: trigger.id) })
                            .equatable()
                            .modifier(FiredFlash(triggerID: trigger.id))
                            .id(trigger.id)
                            .onTapGesture { selection.wrappedValue = trigger.id; listFocused = true }
                            .contextMenu { triggerMenu(trigger) }
                    }
                }
                .padding(.horizontal, AOMSpace.x2)
                .padding(.vertical, AOMSpace.x1)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { moveSelection(1, in: current, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1, in: current, proxy: proxy); return .handled }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: nil) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automations")
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
    @ViewBuilder private func triggerMenu(_ trigger: Trigger) -> some View {
        if !trigger.actions.isEmpty, ActionTree.problem(trigger.actions) == nil {
            Button("Test") { test(trigger) }
        }
        Button(trigger.isEnabled ? "Turn Off" : "Turn On") { appState.toggleTrigger(trigger) }
        Button(trigger.isFavorite ? "Unpin from Workspace" : "Pin to Workspace") { appState.toggleFavorite(trigger) }
        Button("Duplicate") { duplicate(trigger) }
        Divider()
        Button("Delete", role: .destructive) { delete(trigger) }
    }

    private struct BarContextKey: Equatable {
        var id: UUID?
        var enabled = false
        var favorite = false
        var runnable = false
        var name = ""
        var running = false
        var steps = 0
        init(trigger: Trigger?, running: Bool = false) {
            self.running = running
            steps = trigger?.actions.count ?? 0
            id = trigger?.id
            enabled = trigger?.isEnabled ?? false
            favorite = trigger?.isFavorite ?? false
            runnable = trigger.map { !$0.actions.isEmpty && ActionTree.problem($0.actions) == nil } ?? false
            name = trigger?.displayName ?? ""
        }
    }

    /// 7.16 (GPT V02): the bar's buttons keep only the automation's id and
    /// look it up when pressed, so an edit since the bar was built (a changed
    /// step, a rename) is what runs, and a deleted one does nothing.
    private func latest(_ id: UUID) -> Trigger? {
        appState.currentPreset.triggers.first { $0.id == id }
    }

    private func barContext() -> AOMBarContext? {
        guard let trigger = selectedTrigger else { return nil }
        let id = trigger.id
        let hue = AOMModule.automation.hue
        var actions: [AOMBarAction] = []
        if !trigger.actions.isEmpty, ActionTree.problem(trigger.actions) == nil {
            actions.append(AOMBarAction(id: "auto.test", title: runStates[trigger.id] == .running ? "Running…" : "Run",
                                        identity: AOMIdentity(symbol: "play.fill", color: hue),
                                        run: { if let now = actionable(id), !now.actions.isEmpty, ActionTree.problem(now.actions) == nil { test(now) } },
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
        let wasSelected = appState.selectedTrigger?.id == saved.id
        let state = appState
        let revert: @MainActor () -> Void = {
            guard !state.currentPreset.triggers.contains(where: { $0.id == saved.id }) else { return }
            state.currentPreset.triggers.insert(saved, at: min(index, state.currentPreset.triggers.count))
            state.selectedTrigger = state.currentPreset.triggers.first { $0.id == saved.id }
            state.save()
        }
        AOMUndo.perform("Delete Automation", undoManager: undoManager, perform: {
            state.removeTrigger(saved)
            // Selection moves to the neighbouring row (#97).
            if wasSelected, let next { state.selectedTrigger = state.currentPreset.triggers.first { $0.id == next.id } }
        }, revert: revert)
        let manager = undoManager
        toast.show("Deleted “\(saved.displayName)”", action: {
            if let manager, manager.canUndo, manager.undoActionName == "Delete Automation" { manager.undo() } else { revert() }
        })
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
                        .aomShortcut("[")
                    }
                    editorHeader(current)
                    editorStatus(current)
                    whenSection(current)
                    doSection(current)
                    optionsSection(current)
                }
                .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.pageTop)
                .padding(.bottom, AOMSpace.x8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
            .background(AOMPageTint())
            .id(current.id)
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
    private func editorHeader(_ trigger: Trigger) -> some View {
        HStack(spacing: AOMSpace.x3) {
            // 6.0: the input's mark and a summary line under the name, so the
            // header says what this automation is before any section is read.
            AOMAppIcon(AOMIdentity(symbol: AOMTriggerGlyph.symbol(name: trigger.input.displayName, category: trigger.input.category), color: AOMModule.automation.hue),
                       size: 36, active: trigger.isEnabled)
            VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: AOMSpace.x1) {
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
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            appScopePicker(trigger)
                .controlSize(.regular)
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
        .help("Where this automation runs. App-specific automations override groups; groups override Every app.")
    }

    /// When: the input as one row in an opaque card; Edit Input opens the
    /// input's own settings as groups inside the same card.
    private func whenSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
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
                    Button(showInputSettings ? "Close" : "Edit Input") {
                        withAnimation(AOMMotion.panel) { showInputSettings.toggle() }
                    }
                    .help(showInputSettings ? "Hide input settings" : "Change the input and its settings")
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .frame(minHeight: AOMSize.rowDetail + AOMSpace.x2)
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
                    Button { test(trigger) } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .disabled(runState == .running || ActionTree.problem(trigger.actions) != nil)
                    .help(ActionTree.problem(trigger.actions) ?? "Runs these steps now, for real (⌘↩)")
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
                    onRun: { test(trigger) },
                    onAddStep: { addAction() },
                    scrolls: false)
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
        ActionCardView(
            action: row.action,
            index: index + 1,
            depth: row.depth,
            isElse: row.isElse,
            // D12: with the step inspector on screen the chevron opens the
            // step there instead of expanding the card.
            isExpanded: !stepInspectorShown && expandedActionIDs.contains(row.id),
            trigger: trigger,
            keyboardMonitor: appState.keyboardMonitor,
            onToggleExpand: {
                if stepInspectorShown {
                    inspectedStepID = row.id
                } else if expandedActionIDs.contains(row.id) { expandedActionIDs.remove(row.id) }
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
            },
            isInspected: stepInspectorShown && inspectedStepID == row.id
        )
    }

    /// A value-bound trigger drives its value and never runs its steps
    /// (SystemTriggerMonitor / TrackpadMonitor), so the steps say so.
    private var valueBindingNotice: some View {
        AOMNotice(.info, "Actions don't run while a value binding is on.") {
            Button("Show Binding") { withAnimation(AOMMotion.panel) { showOptions = true } }
        }
    }

    /// Options: one disclosure row in its own section (e.1 "Advanced"), naming
    /// what is inside for this input; the groups open in the same card.
    private func optionsSection(_ trigger: Trigger) -> some View {
        AOMSection("Options",
                   help: "How this automation runs. Only the settings that apply to its input are shown.") {
            AOMDisclosureRows("Advanced", detail: Self.optionsSummary(trigger), isExpanded: $showOptions) {
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

    /// Runs the automation's actions for real (not a dry run), with the
    /// latest saved version of it — the bar's ⌘↩ may hold an older copy —
    /// and never twice at once.
    private func test(_ stale: Trigger) {
        guard runStates[stale.id] != .running else { return }
        guard let trigger = latest(stale.id), !trigger.actions.isEmpty,
              ActionTree.problem(trigger.actions) == nil else { return }
        runStates[trigger.id] = .running
        let name = trigger.displayName
        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                      triggerID: trigger.id) { ok in
            DispatchQueue.main.async {
                runStates[trigger.id] = ok ? .succeeded(Date()) : .failed(Date())
                // A failed test says so where you are, not only in the title's status.
                if !ok { toast.show("“\(name)” didn't finish. A step failed or was stopped.", tone: .danger) }
            }
        }
    }

    private func addAction() {
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
