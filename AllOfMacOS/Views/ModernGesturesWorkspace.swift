import AppKit
import SwiftUI

/// Modern Apple-Native Gestures & Automations Studio.
/// Completely replaces the legacy BTT/GTT multi-pane spreadsheet layout with an
/// Apple Shortcuts-style Master-Detail visual macro builder.
struct ModernGesturesWorkspace: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDeviceCategory: TriggerCategory = .all
    @State private var searchQuery = ""
    @State private var testingTriggerID: UUID?
    @State private var testResult: String?
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var showTriggerOptions = false
    @State private var parentID: UUID?
    @State private var toElse = false
    @State private var replaceActionID: UUID?

    private var filteredTriggers: [Trigger] {
        var triggers = appState.currentPreset.triggers.filter { trigger in
            // Filter by selected app target
            if let targetGroupID = appState.selectedActivationGroupID {
                if trigger.activationGroupID != targetGroupID { return false }
            } else if appState.selectedAppTarget.isGlobal {
                if trigger.activationGroupID != nil || (trigger.appBundleID != nil && !trigger.appBundleID!.isEmpty) {
                    return false
                }
            } else {
                if trigger.activationGroupID != nil || trigger.appBundleID != appState.selectedAppTarget.bundleID {
                    return false
                }
            }

            // Filter by device category
            if selectedDeviceCategory != .all && trigger.input.category != selectedDeviceCategory {
                return false
            }

            // Filter by search query
            if !searchQuery.isEmpty {
                let q = searchQuery.lowercased()
                let matchesName = trigger.displayName.lowercased().contains(q)
                let matchesAction = trigger.actions.contains { $0.displayName.lowercased().contains(q) }
                if !matchesName && !matchesAction { return false }
            }

            return true
        }

        // Keep favorites on top
        triggers.sort { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }
        return triggers
    }

    var body: some View {
        HSplitView {
            // Left Master: Gesture Cards Stream
            gestureCardStream
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            // Right Detail: Visual Shortcuts Action Canvas
            visualWorkflowCanvas
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.18))
        .sheet(isPresented: $appState.showingAddTrigger) {
            AddTriggerSheet(keyboardMonitor: appState.keyboardMonitor, category: selectedDeviceCategory == .all ? .trackpad : selectedDeviceCategory)
        }
        .sheet(isPresented: $appState.showingAddAction) {
            AddActionSheet(parentID: parentID, toElse: toElse, replaceActionID: replaceActionID)
        }
        .onAppear {
            if appState.selectedTrigger == nil {
                appState.selectedTrigger = filteredTriggers.first
            }
        }
    }

    // MARK: - Left Master: Gesture Cards Stream & Header

    private var gestureCardStream: some View {
        VStack(spacing: 0) {
            listHeader
            Divider().opacity(0.4)

            if filteredTriggers.isEmpty {
                emptyTriggersView
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredTriggers) { trigger in
                            let isSelected = appState.selectedTrigger?.id == trigger.id

                            GestureSummaryCard(
                                trigger: trigger,
                                isSelected: isSelected,
                                onSelect: {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        appState.selectedTrigger = trigger
                                        appState.selectedAction = nil
                                    }
                                },
                                onToggleEnabled: {
                                    appState.toggleTrigger(trigger)
                                },
                                onDuplicate: {
                                    appState.addTrigger(TriggerClipboard.duplicate(trigger))
                                },
                                onDelete: {
                                    withAnimation {
                                        if appState.selectedTrigger?.id == trigger.id {
                                            appState.selectedTrigger = nil
                                        }
                                        appState.removeTrigger(trigger)
                                    }
                                }
                            )
                        }
                    }
                    .padding(6)
                }
                .suppressScrollerReservation()
            }
        }
        .background(.background.opacity(0.2))
    }

    private var listHeader: some View {
        VStack(spacing: 8) {
            // Scope & Add Action
            HStack(spacing: 8) {
                Menu {
                    Button {
                        appState.selectedAppTarget = .allApps
                    } label: {
                        Label("Global Gestures", systemImage: "globe")
                    }
                    if !appState.currentPreset.appTargets.isEmpty {
                        Divider()
                        ForEach(appState.currentPreset.appTargets) { target in
                            Button {
                                appState.selectedAppTarget = target
                            } label: {
                                Text(target.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = appState.selectedAppTarget.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: appState.selectedAppTarget.isGlobal ? "globe" : "app.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }

                        Text(appState.selectedAppTarget.isGlobal ? "Global Gestures" : appState.selectedAppTarget.name)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    appState.showingAddTrigger = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("New")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Create a new gesture or shortcut")
            }

            // Compact Search Field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search gestures…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            // Innovative Apple Glass Tag Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    glassFilterTag(title: "All", category: .all, icon: "sparkles")
                    glassFilterTag(title: "Trackpad", category: .trackpad, icon: "hand.tap.fill")
                    glassFilterTag(title: "Keys", category: .keyboard, icon: "keyboard.fill")
                    glassFilterTag(title: "Mouse", category: .normalMouse, icon: "computermouse.fill")
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .suppressScrollerReservation()
            .frame(height: 26)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.background.opacity(0.25))
    }

    private func glassFilterTag(title: String, category: TriggerCategory, icon: String) -> some View {
        let isSelected = selectedDeviceCategory == category
        let count = countForCategory(category)

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                selectedDeviceCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: isSelected ? .bold : .medium))

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func countForCategory(_ category: TriggerCategory) -> Int {
        if category == .all {
            return appState.currentPreset.triggers.count
        }
        return appState.currentPreset.triggers.filter { $0.input.category == category }.count
    }

    private var emptyTriggersView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))

            Text("No Gestures Found")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Click + New Gesture to assign actions to a trackpad, keyboard, or mouse gesture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)

            Button("Add Gesture") {
                appState.showingAddTrigger = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Right Detail: Visual Shortcuts Action Canvas

    private var visualWorkflowCanvas: some View {
        VStack(spacing: 0) {
            if let trigger = appState.selectedTrigger {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Trigger Info Card
                        triggerHeaderCard(trigger)

                        // 2. Connected Action Sequence (Shortcuts Style)
                        actionSequenceSection(trigger)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .suppressScrollerReservation()
            } else {
                emptyCanvasView
            }
        }
        .background(.background.opacity(0.12))
    }

    private func triggerHeaderCard(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(categoryColor(trigger.input.category).opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: trigger.input.category.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(categoryColor(trigger.input.category))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(trigger.input.displayName)
                            .font(.system(size: 15, weight: .bold))

                        if trigger.requiredModifiers != nil {
                            Text(trigger.modifierLabel)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }

                        if trigger.isFavorite {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(trigger.activationGroupID.flatMap { id in
                        appState.currentPreset.activationGroups.first { $0.id == id }?.name
                    }.map { "Group: " + $0 } ?? (trigger.appBundleID ?? "Global (All Applications)"))
                    .font(.caption)
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
            }

            // Custom Workflow Name Field
            HStack(spacing: 8) {
                Text("Workflow Name:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("Optional name (e.g. Snap Window Left)", text: Binding(
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

            // Sensitivity Options Disclosure
            DisclosureGroup(isExpanded: $showTriggerOptions) {
                TriggerConfigView(trigger: trigger)
                    .padding(.top, 8)
            } label: {
                Label("Trigger Sensitivity & Timing", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func actionSequenceSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ACTIONS WORKFLOW (\(trigger.actions.count) STEPS)", systemImage: "bolt.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !trigger.actions.isEmpty {
                    let isTesting = testingTriggerID == trigger.id
                    Button {
                        testingTriggerID = trigger.id
                        testResult = nil
                        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad, triggerID: trigger.id) { ok in
                            testingTriggerID = nil
                            testResult = ok ? "Sequence executed successfully" : "Execution failed or stopped"
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isTesting ? "hourglass" : "play.fill")
                                .font(.system(size: 10))
                            Text(isTesting ? "Running…" : "Test Workflow")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTesting || ActionTree.problem(trigger.actions) != nil)
                }
            }

            let rows = ActionTree.rows(trigger.actions)
            if rows.isEmpty {
                emptyActionsCard(trigger)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            HStack {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.35))
                                    .frame(width: 2, height: 14)
                                    .padding(.leading, 24)
                                Spacer()
                            }
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
                                if expandedActionIDs.contains(row.id) {
                                    expandedActionIDs.remove(row.id)
                                } else {
                                    expandedActionIDs.insert(row.id)
                                }
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

                    // Bottom Attach Button
                    HStack {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 2, height: 14)
                            .padding(.leading, 24)
                        Spacer()
                    }

                    Button {
                        parentID = nil
                        toElse = false
                        replaceActionID = nil
                        appState.showingAddAction = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                            Text("Attach Next Action")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                .foregroundStyle(Color.accentColor.opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }

            if let testResult {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(testResult)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private func emptyActionsCard(_ trigger: Trigger) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("No Actions Attached Yet")
                .font(.headline)

            Text("Choose what happens when this gesture is recognized.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                parentID = nil
                toElse = false
                replaceActionID = nil
                appState.showingAddAction = true
            } label: {
                Label("Attach Action Step", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundStyle(Color.secondary.opacity(0.3))
        )
    }

    private var emptyCanvasView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.4))

            Text("Select a Gesture to Configure Workflow")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)

            Text("Choose any gesture from the left list to view and customize its action sequence, or click + New Gesture to create one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button("Create New Gesture") {
                appState.showingAddTrigger = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func categoryColor(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        default: return .blue
        }
    }
}

// MARK: - Gesture Summary Card (Left Master)

private struct GestureSummaryCard: View {
    let trigger: Trigger
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var actionSummaryText: String {
        if trigger.actions.isEmpty { return "No actions assigned" }
        if trigger.actions.count == 1 { return trigger.actions[0].displayName }
        return "\(trigger.actions[0].displayName) • \(trigger.actions.count) actions"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Category SF Symbol Icon Tile
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor.opacity(trigger.isEnabled ? 0.15 : 0.06))
                        .frame(width: 26, height: 26)

                    Image(systemName: trigger.input.category.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(trigger.isEnabled ? iconColor : Color.secondary.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(trigger.displayName)
                            .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(trigger.isEnabled ? Color.primary : Color.secondary)
                            .lineLimit(1)

                        if trigger.requiredModifiers != nil {
                            Text(trigger.modifierLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }

                        if trigger.isFavorite {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(actionSummaryText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle("Enabled", isOn: Binding(
                    get: { trigger.isEnabled },
                    set: { _ in onToggleEnabled() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.14)
                          : (isHovered ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.04), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Duplicate") { onDuplicate() }
            Button(trigger.isEnabled ? "Disable" : "Enable") { onToggleEnabled() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var iconColor: Color {
        switch trigger.input.category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        default: return .blue
        }
    }
}
