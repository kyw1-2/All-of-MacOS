import SwiftUI

struct ActionCardView: View {
    let action: TriggerAction
    let index: Int
    let depth: Int
    let isElse: Bool
    let isExpanded: Bool
    let trigger: Trigger
    @ObservedObject var keyboardMonitor: KeyboardMonitor
    let onToggleExpand: () -> Void
    let onChangeAction: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onToggleEnable: () -> Void
    var onCopy: () -> Void = {}
    var onAddInside: () -> Void = {}
    var onAddElse: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header
            HStack(spacing: 8) {
                // Step Badge
                Text("\(index)")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                if isElse {
                    Text("ELSE")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }

                Image(systemName: action.actionType.iconName)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(categoryColor)
                    .frame(width: 36, height: 36)
                    .background(categoryColor.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(action.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(action.isEnabled ? Color.primary : Color.secondary)
                            .lineLimit(1)


                    }
                    if let detail = actionDetail {
                        Text(detail)
                            .font(AOMType.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Menu {
                    Button("Change Action…", action: onChangeAction)
                    if action.actionType.canContainChildren {
                        Button(action.actionType == .toggleOnOff ? "Add to On…" : "Add Inside…", action: onAddInside)
                    }
                    if action.actionType.canContainElseChildren {
                        Button(action.actionType == .toggleOnOff ? "Add to Off…" : "Add to Else…", action: onAddElse)
                    }
                    Divider()
                    Button("Move Up", action: onMoveUp)
                    Button("Move Down", action: onMoveDown)
                    Button("Copy", action: onCopy)
                    Button("Duplicate", action: onDuplicate)
                    Button(action.isEnabled ? "Disable" : "Enable", action: onToggleEnable)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Action options")
                .accessibilityLabel("Options for \(action.displayName)")
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide options" : "Show options")
                .accessibilityLabel(isExpanded ? "Collapse action options" : "Expand action options")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if isExpanded {
                Divider()
                // In-place parameter configuration view!
                ActionConfigView(keyboardMonitor: keyboardMonitor, trigger: trigger, action: action)
                    .padding(16)
            }
        }
        .aomCardStyle(.paper, padding: 0, elevated: false)
        .padding(.leading, CGFloat(depth * 14))
        .opacity(action.isEnabled ? 1 : 0.6)
        .animation(AOMMotion.panel, value: isExpanded)
    }

    private var categoryColor: Color {
        switch action.actionType.category {
        case .windowManagement: return .blue
        case .keyboardActions: return .orange
        case .mouseActions: return .indigo
        case .scriptExecution: return .purple
        case .applicationControl: return .pink
        case .systemActions: return .gray
        case .mediaControls: return .red
        case .screenCapture: return .orange
        case .clipboard: return .indigo
        case .workflow, .controlFlow: return .green
        case .spacesMissionControl: return .cyan
        case .utilityActions: return .teal
        }
    }

    private var actionDetail: String? {
        switch action.actionType {
        case .actionGroup: return "\(action.parameters.children?.count ?? 0) actions"
        case .ifElse: return "THEN \(action.parameters.children?.count ?? 0) / ELSE \(action.parameters.elseChildren?.count ?? 0)"
        case .setVariable: return "\(action.parameters.variableName ?? "") = \(action.parameters.variableValue ?? "")"
        case .customSnapWindow: return "\(Int((action.parameters.snapWidth ?? 0.5) * 100))% × \(Int((action.parameters.snapHeight ?? 1) * 100))%"
        case .wait: return "\(action.parameters.waitMs ?? 250) ms"
        case .typeText: return "\(action.parameters.text?.count ?? 0) characters"
        case .runAppleScript, .runShellScript: return "\(action.parameters.scriptContent?.utf8.count ?? 0) bytes · timeout \(action.parameters.scriptTimeoutSeconds ?? 30)s"
        case .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
            return action.parameters.applicationName
        case .openURL: return action.parameters.url
        case .captureArea: return "drag a region"
        case .captureFullscreen: return "pointer display"
        case .captureWindow: return "choose from list"
        case .captureWindowUnderCursor: return "window under pointer"
        case .capturePreviousArea: return CaptureSettings.lastArea.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "no previous area"
        case .captureScrolling: return "stitch a scrolling region"
        case .captureAllDisplays: return "every display"
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: return "OCR to clipboard"
        case .captureSelfTimer: return "\(action.parameters.selfTimerSeconds ?? 5) s delay"
        case .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
             .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
            return CaptureHistory.shared.mostRecent?.displayName ?? "no capture yet"
        default: return ActionSummary.detail(action)
        }
    }
}

struct ActionRow: View {
    let action: TriggerAction

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.actionType.iconName)
                .frame(width: 20)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if (action.parameters.repeatCount ?? 1) > 1 || !(action.parameters.onlyAppBundleID ?? "").isEmpty {
                    Text("Repeat ×\(action.parameters.repeatCount ?? 1)\((action.parameters.onlyAppBundleID ?? "").isEmpty ? "" : " · conditional")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let detail = actionDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !action.isEnabled {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(action.isEnabled ? 1 : 0.5)
    }

    private var actionDetail: String? {
        switch action.actionType {
        case .actionGroup: return "\(action.parameters.children?.count ?? 0) actions"
        case .ifElse: return "THEN \(action.parameters.children?.count ?? 0) / ELSE \(action.parameters.elseChildren?.count ?? 0)"
        case .setVariable: return "\(action.parameters.variableName ?? "") = \(action.parameters.variableValue ?? "")"
        case .customSnapWindow: return "\(Int((action.parameters.snapWidth ?? 0.5) * 100))% × \(Int((action.parameters.snapHeight ?? 1) * 100))%"
        case .wait: return "\(action.parameters.waitMs ?? 250) ms"
        case .typeText: return "\(action.parameters.text?.count ?? 0) characters"
        case .runAppleScript, .runShellScript: return "\(action.parameters.scriptContent?.utf8.count ?? 0) bytes · timeout \(action.parameters.scriptTimeoutSeconds ?? 30)s"
        case .launchApplication, .quitApplication, .forceQuitApplication, .hideApplication, .toggleApplication:
            return action.parameters.applicationName
        case .openURL: return action.parameters.url
        case .captureArea: return "drag a region"
        case .captureFullscreen: return "pointer display"
        case .captureWindow: return "choose from list"
        case .captureWindowUnderCursor: return "window under pointer"
        case .capturePreviousArea: return CaptureSettings.lastArea.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "no previous area"
        case .captureScrolling: return "stitch a scrolling region"
        case .captureAllDisplays: return "every display"
        case .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: return "OCR to clipboard"
        case .captureSelfTimer: return "\(action.parameters.selfTimerSeconds ?? 5) s delay"
        case .annotateLastCapture, .pinLastCapture, .copyLastCapture, .saveLastCapture,
             .ocrLastCapture, .openCaptureHistory, .unpinAllCaptures, .toggleCaptureOverlay:
            return CaptureHistory.shared.mostRecent?.displayName ?? "no capture yet"
        default: return ActionSummary.detail(action)
        }
    }
}

struct AddActionSheet: View {
    var parentID: UUID? = nil
    var toElse = false
    var replaceActionID: UUID? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// "Favorites & Recent" first, then the categories, like BTT's selector.
    private enum Section: Hashable {
        case quick
        case category(ActionCategory)
    }
    private let store = ActionPickerStore()
    @State private var section: Section
    @State private var searchText = ""
    @State private var favorites: [ActionType]
    @State private var recents: [ActionType]

    init(parentID: UUID? = nil, toElse: Bool = false, replaceActionID: UUID? = nil) {
        self.parentID = parentID; self.toElse = toElse; self.replaceActionID = replaceActionID
        let store = ActionPickerStore()
        let hasQuick = !store.favorites.isEmpty || !store.recents.isEmpty
        _section = State(initialValue: hasQuick ? .quick : .category(.windowManagement))
        _favorites = State(initialValue: store.favorites)
        _recents = State(initialValue: store.recents)
    }

    private var hidden: Set<ActionType> { [.toggleDoNotDisturb] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(replaceActionID != nil ? "Change Action" : (parentID == nil ? "Add Action" : "Add Action Inside"))
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Close without adding")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search actions by name or what they do…", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search actions")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.bottom, 10)

            HSplitView {
                List(selection: Binding<Section?>(get: { section }, set: { if let value = $0 { section = value; searchText = "" } })) {
                    sidebarRow("Favorites & Recent", icon: "star", selected: section == .quick).tag(Section.quick)
                    ForEach(ActionCategory.allCases) { category in
                        sidebarRow(category.rawValue, icon: category.iconName, selected: section == .category(category))
                            .tag(Section.category(category))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if !searchText.isEmpty {
                            let found = ActionSearch.results(for: searchText, in: ActionType.allCases.filter { !hidden.contains($0) })
                            if found.isEmpty {
                                emptyNote("No action matches “\(searchText)”. Try a verb (click, scroll, speak) or an app area (window, space, volume).")
                            }
                            ForEach(found) { row($0, showsCategory: true) }
                        } else if section == .quick {
                            heading("Favorite Actions")
                            if favorites.isEmpty { emptyNote("Click the star next to any action to keep it here.") }
                            ForEach(favorites) { row($0) }
                            heading("Recently Used")
                            if recents.isEmpty { emptyNote("Actions you add show up here.") }
                            ForEach(recents) { row($0) }
                        } else if case .category(let category) = section {
                            ForEach(ActionType.actionsForCategory(category).filter { !hidden.contains($0) }) { row($0) }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: 420)

            Divider()

            HStack {
                if replaceActionID == nil {
                    Menu("Sequence Templates") {
                        Button("Next display → maximize") { addTemplate([.moveWindowNextMonitor, .maximizeWindow], name: "Move and maximize") }
                        Button("Activate app → wait → maximize") { addTemplate([.activateApplication, .wait, .maximizeWindow], name: "Open workspace") }
                        Button("Shortcut → wait → shortcut") { addTemplate([.sendKeyStroke, .wait, .sendKeyStroke], name: "Keyboard sequence") }
                    }
                    .help("Add several steps at once")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720)
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).accessibilityAddTraits(.isHeader)
    }
    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func row(_ type: ActionType, showsCategory: Bool = false) -> some View {
        let isFavorite = favorites.contains(type)
        return HStack(spacing: 6) {
            Button { addAction(type) } label: {
                HStack(spacing: 10) {
                    Image(systemName: type.iconName)
                        .font(.system(size: 14))
                        .frame(width: 22)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.rawValue).font(.system(size: 13, weight: .medium))
                        Text(type.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if showsCategory || !type.parameterHint.isEmpty {
                            Text([showsCategory ? type.category.rawValue : nil, type.parameterHint.isEmpty ? nil : "Options: " + type.parameterHint]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(type.rawValue)
            .accessibilityHint(type.description)

            Button {
                store.toggleFavorite(type)
                favorites = store.favorites
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorite Actions" : "Add to Favorite Actions")
            .accessibilityLabel(isFavorite ? "Remove \(type.rawValue) from favorites" : "Add \(type.rawValue) to favorites")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addTemplate(_ types: [ActionType], name: String) {
        guard let trigger = appState.selectedTrigger else { return }
        var group = TriggerAction(actionType: .actionGroup); group.parameters.label = name
        group.parameters.children = types.map { type in
            var value = TriggerAction(actionType: type)
            if type == .maximizeWindow, types.contains(.activateApplication) { value.parameters.useCurrentWindow = true }
            if type == .wait { value.parameters.waitMs = 300 }
            return value
        }
        appState.addAction(to: trigger, action: group, parentID: parentID); dismiss()
    }

    private func addAction(_ actionType: ActionType) {
        guard let trigger = appState.selectedTrigger else { return }
        store.recordUse(actionType)

        if let replaceID = replaceActionID,
           var target = ActionTree.rows(trigger.actions).first(where: { $0.id == replaceID })?.action {
            target.actionType = actionType
            target.parameters = actionType.defaultParameters
            appState.updateAction(in: trigger, action: target)
            dismiss()
            return
        }

        let action = TriggerAction(actionType: actionType, parameters: actionType.defaultParameters)
        appState.addAction(to: trigger, action: action, parentID: parentID, toElse: toElse)
        dismiss()
    }
}
