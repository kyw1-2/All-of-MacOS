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
                                            },
                                            onCopy: {
                                                ActionClipboard.copied = row.action
                                                testResult = "Copied “\(row.action.displayName)”"
                                            },
                                            onAddInside: {
                                                parentID = row.id; toElse = false; replaceActionID = nil
                                                appState.showingAddAction = true
                                            },
                                            onAddElse: {
                                                parentID = row.id; toElse = true; replaceActionID = nil
                                                appState.showingAddAction = true
                                            }
                                        )
                                        .draggable(row.id.uuidString)
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let text = items.first, let dragged = UUID(uuidString: text),
                                                  var updated = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }) else { return false }
                                            guard ActionTree.move(&updated.actions, id: dragged, before: row.id),
                                                  ActionTree.problem(updated.actions) == nil else { return false }
                                            appState.updateTrigger(updated)
                                            return true
                                        }
                                    }

                                    // Add Additional Action
                                    HStack(spacing: 8) {
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
                                        .help("Choose an action to add at the end of this trigger")

                                        if ActionClipboard.copied != nil {
                                            Button {
                                                if let copy = ActionClipboard.pasteCopy() {
                                                    appState.addAction(to: trigger, action: copy)
                                                    testResult = "Pasted “\(copy.displayName)”"
                                                }
                                            } label: {
                                                Label("Paste Action", systemImage: "doc.on.clipboard")
                                                    .padding(.vertical, 8)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.regular)
                                            .help("Paste the copied action at the end of this trigger")
                                        }
                                    }
                                    .padding(.top, 4)
                                    // Dropping on this strip moves a dragged action to the end of the list.
                                    Color.clear.frame(height: 10)
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let text = items.first, let dragged = UUID(uuidString: text),
                                                  var updated = appState.currentPreset.triggers.first(where: { $0.id == trigger.id }),
                                                  ActionTree.moveToEnd(&updated.actions, id: dragged) else { return false }
                                            appState.updateTrigger(updated)
                                            return true
                                        }
                                        .accessibilityHidden(true)
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
    var onCopy: () -> Void = {}
    var onAddInside: () -> Void = {}
    var onAddElse: () -> Void = {}

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
                    if action.actionType.canContainChildren {
                        Button(action: onAddInside) {
                            Image(systemName: "plus.circle").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(action.actionType == .toggleOnOff ? "Add an action to the ON list"
                              : action.actionType == .ifElse ? "Add an action to THEN" : "Add an action inside")
                        .accessibilityLabel(action.actionType == .toggleOnOff ? "Add action to ON list"
                                            : action.actionType == .ifElse ? "Add action to THEN" : "Add action inside \(action.displayName)")
                    }
                    if action.actionType.canContainElseChildren {
                        Button(action: onAddElse) {
                            Image(systemName: "plus.circle.fill").font(.caption).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(action.actionType == .toggleOnOff ? "Add an action to the OFF list" : "Add an action to ELSE")
                        .accessibilityLabel(action.actionType == .toggleOnOff ? "Add action to OFF list" : "Add action to ELSE")
                    }

                    Button(action: onChangeAction) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Change this action type")
                    .accessibilityLabel("Change action type")

                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Move up")
                    .accessibilityLabel("Move action up")

                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Move down")
                    .accessibilityLabel("Move action down")

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy action (then use Paste Action)")
                    .accessibilityLabel("Copy action")

                    Button(action: onDuplicate) {
                        Image(systemName: "plus.square.on.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Duplicate action")
                    .accessibilityLabel("Duplicate action")

                    Button(action: onToggleEnable) {
                        Image(systemName: action.isEnabled ? "eye" : "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(action.isEnabled ? Color.secondary : Color.orange)
                    }
                    .buttonStyle(.plain)
                    .help(action.isEnabled ? "Disable this step without deleting it" : "Enable this step")
                    .accessibilityLabel(action.isEnabled ? "Disable action" : "Enable action")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete action")
                    .accessibilityLabel("Delete action")

                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    .help(isExpanded ? "Hide options" : "Show options")
                    .accessibilityLabel(isExpanded ? "Collapse action options" : "Expand action options")
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

                ScrollView {
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
