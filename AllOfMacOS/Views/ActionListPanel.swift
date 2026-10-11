import SwiftUI

struct ActionInspectorPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var copiedAction: TriggerAction?
    @State private var testing = false
    @State private var testResult = ""
    @State private var showTriggerOptions = false
    @State private var replaceActionID: UUID?
    @State private var expandedActionIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Inspector Header
            HStack(spacing: 8) {
                Text("Action & Details")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trigger = appState.selectedTrigger, !trigger.actions.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            testing = true
                            testResult = ""
                            ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad, triggerID: trigger.id) { ok in
                                testing = false
                                testResult = ok ? "Completed" : "Stopped or failed"
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: testing ? "hourglass" : "play.fill")
                                    .font(.caption2)
                                Text(testing ? "Running…" : "Test")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(testing || ActionTree.problem(trigger.actions) != nil)
                        .help("Test this trigger's action sequence")

                        if testing {
                            Button("Stop") {
                                ActionExecutor.cancelSequence(trigger.id)
                                testing = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let trigger = appState.selectedTrigger {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. TRIGGER HEADER & QUICK CONFIG (BTT Style)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: trigger.input.category.iconName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(trigger.input.displayName)
                                            .font(.system(size: 14, weight: .bold))
                                        if trigger.requiredModifiers != nil {
                                            Text(trigger.modifierLabel)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(trigger.activationGroupID.flatMap { id in
                                        appState.currentPreset.activationGroups.first { $0.id == id }?.name
                                    }.map { "Group: " + $0 } ?? (trigger.appBundleID ?? "Global (All Apps)"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Toggle("Enabled", isOn: Binding(
                                    get: { trigger.isEnabled },
                                    set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(trigger.isEnabled ? "Disable this trigger" : "Enable this trigger")
                            }

                            // Custom trigger name
                            HStack(spacing: 6) {
                                Text("Name:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Optional custom name (e.g. Switch Desktop)", text: Binding(
                                    get: { trigger.name },
                                    set: { newName in
                                        var updated = trigger
                                        updated.name = newName
                                        appState.updateTrigger(updated)
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            }

                            // Collapsible sensitivity & advanced trigger options
                            DisclosureGroup(isExpanded: $showTriggerOptions) {
                                TriggerConfigView(trigger: trigger)
                                    .padding(.top, 6)
                            } label: {
                                Label("Trigger Options & Sensitivity", systemImage: "slider.horizontal.3")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                        // 2. ASSIGNED ACTIONS SEQUENCE
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("ASSIGNED ACTIONS", systemImage: "bolt.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !trigger.actions.isEmpty {
                                    Text("\(trigger.actions.count) step\(trigger.actions.count == 1 ? "" : "s")")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            let rows = ActionTree.rows(trigger.actions)
                            if rows.isEmpty {
                                // Empty state: BTT Assign Action
                                VStack(spacing: 10) {
                                    Image(systemName: "plus.square.dashed")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                    Text("No action assigned to this trigger")
                                        .font(.subheadline.weight(.medium))
                                    Text("Choose what happens when this gesture is recognized.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button {
                                        parentID = nil
                                        toElse = false
                                        replaceActionID = nil
                                        appState.showingAddAction = true
                                    } label: {
                                        Label("Assign Action to Trigger", systemImage: "plus")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .padding(.top, 4)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(20)
                                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(.secondary.opacity(0.35)))
                            } else {
                                // Actions list
                                VStack(spacing: 8) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                        let isSingle = rows.count == 1
                                        let isExpanded = isSingle || expandedActionIDs.contains(row.id) || (appState.selectedAction?.id == row.action.id)

                                        ActionCardView(
                                            action: row.action,
                                            index: index + 1,
                                            depth: row.depth,
                                            isElse: row.isElse,
                                            isExpanded: isExpanded,
                                            trigger: trigger,
                                            keyboardMonitor: appState.keyboardMonitor,
                                            onToggleExpand: {
                                                if expandedActionIDs.contains(row.id) {
                                                    expandedActionIDs.remove(row.id)
                                                } else {
                                                    expandedActionIDs.insert(row.id)
                                                }
                                                appState.selectedAction = row.action
                                            },
                                            onChangeAction: {
                                                replaceActionID = row.action.id
                                                appState.showingAddAction = true
                                            },
                                            onMoveUp: {
                                                appState.moveAction(in: trigger, action: row.action, offset: -1)
                                            },
                                            onMoveDown: {
                                                appState.moveAction(in: trigger, action: row.action, offset: 1)
                                            },
                                            onDuplicate: {
                                                appState.duplicateAction(in: trigger, action: row.action)
                                            },
                                            onDelete: {
                                                appState.removeAction(from: trigger, action: row.action)
                                            },
                                            onToggleEnable: {
                                                var updated = row.action
                                                updated.isEnabled.toggle()
                                                appState.updateAction(in: trigger, action: updated)
                                            }
                                        )
                                    }

                                    // Add Additional Action
                                    Button {
                                        parentID = nil
                                        toElse = false
                                        replaceActionID = nil
                                        appState.showingAddAction = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "plus.circle.fill")
                                            Text("Attach Additional Action")
                                                .font(.subheadline.weight(.medium))
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .padding(.top, 4)
                                }
                            }
                        }

                        if let problem = ActionTree.problem(trigger.actions) {
                            Text(problem).font(.caption).foregroundStyle(.red).padding(6)
                        }

                        if !testResult.isEmpty {
                            HStack {
                                Image(systemName: "info.circle")
                                Text(testResult)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(14)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.22))
        .sheet(isPresented: $appState.showingAddAction) {
            AddActionSheet(parentID: parentID, toElse: toElse, replaceActionID: replaceActionID)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Trigger Selected")
                .font(.headline)
            Text("Select a gesture or shortcut on the left to configure its actions, or click + Add Trigger below the list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

typealias ActionListPanel = ActionInspectorPanel

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header
            HStack(spacing: 8) {
                // Step Badge
                Text("\(index)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary.opacity(0.8), in: Circle())

                if isElse {
                    Text("ELSE")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }

                Image(systemName: action.actionType.iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(action.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(action.isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if let detail = actionDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Header buttons
                HStack(spacing: 5) {
                    Button(action: onChangeAction) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Change this action type")

                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Move up")

                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Move down")

                    Button(action: onDuplicate) {
                        Image(systemName: "plus.square.on.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Duplicate action")

                    Button(action: onToggleEnable) {
                        Image(systemName: action.isEnabled ? "eye" : "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(action.isEnabled ? Color.secondary : Color.orange)
                    }
                    .buttonStyle(.plain)
                    .help(action.isEnabled ? "Disable" : "Enable")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete action")

                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if isExpanded {
                Divider()
                // In-place parameter configuration view!
                ActionConfigView(keyboardMonitor: keyboardMonitor, trigger: trigger, action: action)
                    .padding(10)
            }
        }
        .padding(.leading, CGFloat(depth * 14))
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(isExpanded ? 0.15 : 0.06), lineWidth: 1))
        .opacity(action.isEnabled ? 1 : 0.6)
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
        default: return nil
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
        default: return nil
        }
    }
}

struct AddActionSheet: View {
    var parentID: UUID? = nil
    var toElse = false
    var replaceActionID: UUID? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: ActionCategory = .windowManagement
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(replaceActionID != nil ? "Change Action" : (parentID == nil ? "Add Action" : "Add Action to Group"))
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.bottom, 10)

            HSplitView {
                // Category list
                List(ActionCategory.allCases, selection: $selectedCategory) { category in
                    HStack(spacing: 7) {
                        Image(systemName: category.iconName)
                            .font(.system(size: 13))
                            .foregroundStyle(selectedCategory == category ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(category.rawValue)
                            .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                    }
                    .tag(category)
                }
                .listStyle(.sidebar)
                .frame(width: 190)

                // Action list for selected category
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredActions) { actionType in
                            HStack(spacing: 10) {
                                Image(systemName: actionType.iconName)
                                    .font(.system(size: 14))
                                    .frame(width: 22)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(actionType.rawValue)
                                        .font(.system(size: 13, weight: .medium))
                                    if !searchText.isEmpty {
                                        Text(actionType.category.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .onTapGesture { addAction(actionType) }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: 380)

            Divider()

            HStack {
                if replaceActionID == nil {
                    Menu("Sequence Templates") {
                        Button("Next display → maximize") { addTemplate([.moveWindowNextMonitor, .maximizeWindow], name: "Move and maximize") }
                        Button("Activate app → wait → maximize") { addTemplate([.activateApplication, .wait, .maximizeWindow], name: "Open workspace") }
                        Button("Shortcut → wait → shortcut") { addTemplate([.sendKeyStroke, .wait, .sendKeyStroke], name: "Keyboard sequence") }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 600)
    }

    private var filteredActions: [ActionType] {
        if searchText.isEmpty {
            return ActionType.actionsForCategory(selectedCategory).filter { $0 != .toggleDoNotDisturb }
        }
        // Search across ALL categories when there's a search query
        return ActionType.allCases.filter { $0 != .toggleDoNotDisturb && $0.rawValue.localizedCaseInsensitiveContains(searchText) }
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

        if let replaceID = replaceActionID,
           var target = ActionTree.rows(trigger.actions).first(where: { $0.id == replaceID })?.action {
            target.actionType = actionType
            target.parameters = ActionParameters()
            if actionType == .setVariable {
                target.parameters.variableName = "state"; target.parameters.variableValue = "on"
            }
            if actionType == .ifElse {
                target.parameters.variableName = "state"
                target.parameters.conditionValue = "on"
            }
            appState.updateAction(in: trigger, action: target)
            dismiss()
            return
        }

        var action = TriggerAction(actionType: actionType)
        if actionType == .setVariable {
            action.parameters.variableName = "state"; action.parameters.variableValue = "on"
        }
        if actionType == .ifElse {
            action.parameters.variableName = "state"
            action.parameters.conditionValue = "on"
        }
        appState.addAction(to: trigger, action: action, parentID: parentID, toElse: toElse)
        dismiss()
    }
}
