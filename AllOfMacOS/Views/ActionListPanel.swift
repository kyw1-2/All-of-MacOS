import SwiftUI

/// One step of an automation as an opaque card: a row in the shared row
/// style (step number, monochrome glyph, name over one line of detail, item
/// menu, disclosure chevron), and the step's options as groups inside the
/// same card when it is expanded.
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
            header
            if isExpanded {
                // In-place parameter configuration; its groups draw their own
                // hairline above, so it needs no divider of its own.
                ActionConfigView(keyboardMonitor: keyboardMonitor, trigger: trigger, action: action)
            }
        }
        .aomCard(padding: 0)
        .padding(.leading, CGFloat(depth) * AOMSpace.x5)
        .opacity(action.isEnabled ? 1 : 0.55)
        .animation(AOMMotion.panel, value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x2) {
            // Step number, centred under the arrows that join the cards.
            Text("\(index)")
                .font(AOMFont.badge.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AOMIcon.row)
                .accessibilityLabel("Step \(index)")

            if isElse {
                AOMStatusPill("Else", tone: .neutral, symbol: "arrow.triangle.branch")
            }

            Image(systemName: action.actionType.iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(action.displayName)
                    .font(AOMFont.bodyEmphasis)
                    .foregroundStyle(action.isEnabled ? AOMColor.text : AOMColor.textSecondary)
                    .lineLimit(1)
                if let detail = actionDetail {
                    Text(detail)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: AOMSpace.x2)

            if !action.isEnabled {
                AOMStatusPill("Off", tone: .neutral)
            }

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
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(AOMColor.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide options" : "Show options")
            .accessibilityLabel(isExpanded ? "Collapse action options" : "Expand action options")
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .frame(minHeight: actionDetail == nil ? AOMSize.rowStandard : AOMSize.rowDetail)
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
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

/// An action as a list row (the shared `AOMListRow`).
struct ActionRow: View {
    let action: TriggerAction

    var body: some View {
        AOMListRow(action.displayName, detail: detail, dimmed: !action.isEnabled) {
            Image(systemName: action.actionType.iconName)
        } trailing: {
            if !action.isEnabled {
                Image(systemName: "eye.slash")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityLabel("Disabled")
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if (action.parameters.repeatCount ?? 1) > 1 || !(action.parameters.onlyAppBundleID ?? "").isEmpty {
            parts.append("Repeat ×\(action.parameters.repeatCount ?? 1)\((action.parameters.onlyAppBundleID ?? "").isEmpty ? "" : " · conditional")")
        }
        if let actionDetail { parts.append(actionDetail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                    .font(AOMFont.pageStatus)
                    .foregroundStyle(AOMColor.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary) }
                    .buttonStyle(.plain)
                    .help("Close without adding")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.top, AOMSpace.x3)
            .padding(.bottom, AOMSpace.x2)

            HStack(spacing: AOMSpace.x1) {
                Image(systemName: "magnifyingglass").foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                TextField("Search actions by name or what they do…", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search actions")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary) }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(AOMSpace.x2)
            .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .padding(.horizontal, AOMSpace.x4)
            .padding(.bottom, AOMSpace.x3)

            HSplitView {
                List(selection: Binding<Section?>(get: { section }, set: { if let value = $0 { section = value; searchText = "" } })) {
                    sidebarRow("Favorites & Recent", icon: "star", selected: section == .quick).tag(Section.quick)
                    ForEach(ActionCategory.allCases) { category in
                        sidebarRow(category.rawValue, icon: category.iconName, selected: section == .category(category))
                            .tag(Section.category(category))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: AOMEditorSize.actionPickerSidebar)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !searchText.isEmpty {
                            let found = ActionSearch.results(for: searchText, in: ActionType.allCases.filter { !hidden.contains($0) })
                            if found.isEmpty {
                                emptyNote("No action matches “\(searchText)”. Try a verb (click, scroll, speak) or an app area (window, space, volume).")
                            }
                            ForEach(found) { row($0, showsCategory: true) }
                        } else if section == .quick {
                            heading("Favorite actions")
                            if favorites.isEmpty { emptyNote("Click the star next to any action to keep it here.") }
                            ForEach(favorites) { row($0) }
                            heading("Recently used")
                            if recents.isEmpty { emptyNote("Actions you add show up here.") }
                            ForEach(recents) { row($0) }
                        } else if case .category(let category) = section {
                            ForEach(ActionType.actionsForCategory(category).filter { !hidden.contains($0) }) { row($0) }
                        }
                    }
                    .padding(AOMSpace.x2)
                }
            }
            .frame(height: AOMEditorSize.actionPicker.height)

            AOMDivider()

            HStack {
                if replaceActionID == nil {
                    Menu("Sequence Templates") {
                        Button("Next display → maximize") { addTemplate([.moveWindowNextMonitor, .maximizeWindow], name: "Move and maximize") }
                        Button("Activate app → wait → maximize") { addTemplate([.activateApplication, .wait, .maximizeWindow], name: "Open workspace") }
                        Button("Shortcut → wait → shortcut") { addTemplate([.sendKeyStroke, .wait, .sendKeyStroke], name: "Keyboard sequence") }
                    }
                    .fixedSize()
                    .help("Add several steps at once")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AOMSpace.x3)
        }
        .frame(width: AOMEditorSize.actionPicker.width)
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: icon)
                .foregroundStyle(selected ? AOMColor.accent : AOMColor.textSecondary)
                .frame(width: AOMIcon.row)
            Text(title).font(selected ? AOMFont.bodyEmphasis : AOMFont.body)
        }
    }
    /// A group label in the result list: sentence case, never tracked caps (e.10).
    private func heading(_ title: String) -> some View {
        Text(title)
            .aomSectionCaps()
            .padding(.horizontal, AOMSpace.x3)
            .padding(.top, AOMSpace.x3)
            .padding(.bottom, AOMSpace.x1)
            .accessibilityAddTraits(.isHeader)
    }
    private func emptyNote(_ text: String) -> some View {
        AOMEditorNote(text)
            .padding(.horizontal, AOMSpace.x3)
            .padding(.vertical, AOMSpace.x1)
    }

    private func row(_ type: ActionType, showsCategory: Bool = false) -> some View {
        let isFavorite = favorites.contains(type)
        return HStack(spacing: AOMSpace.x2) {
            Button { addAction(type) } label: {
                HStack(alignment: .top, spacing: AOMSpace.x3) {
                    Image(systemName: type.iconName)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row)
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        Text(type.rawValue).font(AOMFont.body).foregroundStyle(AOMColor.text)
                        Text(type.description).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(2)
                        if showsCategory || !type.parameterHint.isEmpty {
                            Text([showsCategory ? type.category.rawValue : nil, type.parameterHint.isEmpty ? nil : "Options: " + type.parameterHint]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AOMSpace.x2)
                .padding(.vertical, AOMSpace.x2)
                .contentShape(Rectangle())
            }
            .buttonStyle(AOMRowButtonStyle())
            .accessibilityLabel(type.rawValue)
            .accessibilityHint(type.description)

            Button {
                store.toggleFavorite(type)
                favorites = store.favorites
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? AOMColor.accent : AOMColor.textSecondary)
                    .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorite Actions" : "Add to Favorite Actions")
            .accessibilityLabel(isFavorite ? "Remove \(type.rawValue) from favorites" : "Add \(type.rawValue) to favorites")
        }
        .padding(.trailing, AOMSpace.x1)
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
