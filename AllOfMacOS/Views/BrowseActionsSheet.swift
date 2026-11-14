import SwiftUI

/// The one action picker: categories in a sidebar, action names in the list,
/// and the selected action's one-line description plus Add (or Create
/// Automation) at the bottom. It serves the editor (Add Action, Change Action,
/// Add Inside) and the Automation toolbar's Browse Actions….
///
/// Configuration creates a disabled draft when no automation is selected, so
/// opening a feature never executes a destructive or input-producing action in
/// the currently focused app.
struct BrowseActionsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var parentID: UUID? = nil
    var toElse = false
    var replaceActionID: UUID? = nil

    /// "Favorites & Recent" first, then the categories, like BTT's selector.
    private enum Section: Hashable {
        case quick
        case category(ActionCategory)
    }

    private let store = ActionPickerStore()
    @State private var section: Section
    @State private var query = ""
    @State private var selection: ActionType?

    private static let hidden: Set<ActionType> = [.toggleDoNotDisturb]

    init(parentID: UUID? = nil, toElse: Bool = false, replaceActionID: UUID? = nil) {
        self.parentID = parentID
        self.toElse = toElse
        self.replaceActionID = replaceActionID
        let store = ActionPickerStore()
        let hasQuick = !store.favorites.isEmpty || !store.recents.isEmpty
        _section = State(initialValue: hasQuick ? .quick : .category(.windowManagement))
    }

    private var title: String {
        if replaceActionID != nil { return "Change Action" }
        if parentID != nil { return "Add Action Inside" }
        return "Browse Actions"
    }

    /// Actions in the current sidebar section, filtered by the search field.
    private var visible: [ActionType] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ type: ActionType) -> Bool {
            words.allSatisfy { type.searchText.localizedStandardContains($0) }
        }
        switch section {
        case .quick:
            if !words.isEmpty { return ActionSearch.results(for: query, in: ActionType.allCases.filter { !Self.hidden.contains($0) }) }
            return store.favorites + store.recents.filter { !store.favorites.contains($0) }
        case .category(let category):
            let types = ActionType.actionsForCategory(category).filter { !Self.hidden.contains($0) }
            return words.isEmpty ? types : types.filter(matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                sidebar
                actionList
            }
            .frame(height: AOMEditorSize.actionPicker.height)
            AOMDivider()
            footer
        }
        .frame(width: AOMEditorSize.actionPicker.width)
        .onAppear { selection = visible.first }
        .onChange(of: section) { _, _ in query = ""; selection = visible.first }
        .onChange(of: query) { _, _ in selection = visible.first }
    }

    private var header: some View {
        VStack(spacing: AOMSpace.x3) {
            HStack {
                Text(title)
                    .font(AOMFont.title)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AOMFont.title.weight(.regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close without adding")
                .accessibilityLabel("Close")
            }
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "magnifyingglass").foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                TextField("Search actions", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search actions")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: AOMSize.rowStandard - AOMSpace.x1)
            .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        }
        .padding(.horizontal, AOMSpace.x5)
        .padding(.top, AOMSpace.x4)
        .padding(.bottom, AOMSpace.x3)
    }

    private var sidebar: some View {
        List(selection: Binding<Section?>(get: { section }, set: { if let value = $0 { section = value } })) {
            Label("Favorites & Recent", systemImage: "star").tag(Section.quick)
            ForEach(ActionCategory.allCases) { category in
                Label(category.rawValue, systemImage: category.iconName)
                    .tag(Section.category(category))
            }
        }
        .listStyle(.sidebar)
        .frame(width: AOMEditorSize.actionPickerSidebar)
    }

    private var actionList: some View {
        Group {
            if visible.isEmpty {
                AOMEmptyState(query.isEmpty ? "No Actions" : "No Matches", systemImage: "magnifyingglass", message: "")
            } else {
                List(selection: Binding<ActionType?>(get: { selection }, set: { selection = $0 })) {
                    ForEach(visible, id: \.self) { type in
                        Text(type.rawValue)
                            .font(AOMFont.body)
                            .tag(type)
                            .contextMenu {
                                Button(store.isFavorite(type) ? "Remove from Favorites" : "Add to Favorites") {
                                    store.toggleFavorite(type)
                                }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: ActionType.self) { _ in
                    EmptyView()
                } primaryAction: { types in
                    if let type = types.first { commit(type) }
                }
                .accessibilityLabel("Actions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: AOMSpace.x3) {
            Text(selection?.description ?? "")
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(commitTitle) {
                if let selection { commit(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(.horizontal, AOMSpace.x5)
        .padding(.vertical, AOMSpace.x4)
    }

    /// "Add" with an automation in front, otherwise a draft automation.
    private var commitTitle: String {
        appState.selectedTrigger == nil ? "Create Automation" : "Add"
    }

    private func commit(_ type: ActionType) {
        store.recordUse(type)
        guard let trigger = appState.selectedTrigger else {
            appState.createDraft(for: type)
            dismiss()
            return
        }
        if let replaceID = replaceActionID,
           var target = ActionTree.rows(trigger.actions).first(where: { $0.id == replaceID })?.action {
            target.actionType = type
            target.parameters = type.defaultParameters
            appState.updateAction(in: trigger, action: target)
        } else {
            let action = TriggerAction(actionType: type, parameters: type.defaultParameters)
            appState.addAction(to: trigger, action: action, parentID: parentID, toElse: toElse)
        }
        dismiss()
    }
}

extension AppState {
    /// A disabled draft automation that holds `type`, ready to configure.
    @MainActor func createDraft(for type: ActionType) {
        var trigger = Trigger(name: type.rawValue, input: .namedTrigger("draft-" + UUID().uuidString))
        var action = TriggerAction(actionType: type)
        action.parameters = type.defaultParameters
        trigger.actions = [action]
        trigger.isEnabled = false
        selectedActivationGroupID = nil
        selectedAppTarget = .allApps
        selectedTriggerCategory = .all
        addTrigger(trigger)
        selectedAction = action
        selectedMainTab = .gestures
    }
}
