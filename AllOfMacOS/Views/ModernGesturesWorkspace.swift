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
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)

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
        .onAppear { reconcileSelection() }
        .onChange(of: filteredTriggers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: appState.selectedTrigger?.id) { _, _ in
            expandedActionIDs.removeAll()
            testResult = nil
            showTriggerOptions = false
        }
    }

    private func reconcileSelection() {
        if !filteredTriggers.contains(where: { $0.id == appState.selectedTrigger?.id }) {
            appState.selectedTrigger = filteredTriggers.first
            appState.selectedAction = nil
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
                List(selection: Binding<UUID?>(
                    get: { appState.selectedTrigger?.id },
                    set: { id in
                        appState.selectedTrigger = filteredTriggers.first { $0.id == id }
                        appState.selectedAction = nil
                    }
                )) {
                    ForEach(filteredTriggers) { trigger in
                        GestureSummaryRow(trigger: trigger)
                            .tag(trigger.id)
                            .contextMenu {
                                Button("Duplicate") { appState.addTrigger(TriggerClipboard.duplicate(trigger)) }
                                Button(trigger.isEnabled ? "Disable" : "Enable") { appState.toggleTrigger(trigger) }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if appState.selectedTrigger?.id == trigger.id { appState.selectedTrigger = nil }
                                    appState.removeTrigger(trigger)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollIndicators(.hidden)
                .accessibilityLabel("Gestures")
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
                        appState.selectedActivationGroupID = nil
                        appState.selectedAppTarget = .allApps
                    } label: {
                        Label("Global Gestures", systemImage: "globe")
                    }
                    if !appState.currentPreset.appTargets.isEmpty {
                        Divider()
                        ForEach(appState.currentPreset.appTargets) { target in
                            Button {
                                appState.selectedActivationGroupID = nil
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
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
                .menuStyle(.borderlessButton)
                .tint(.primary)
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

            Picker("Device", selection: $selectedDeviceCategory) {
                Text("All").tag(TriggerCategory.all)
                Text("Trackpad").tag(TriggerCategory.trackpad)
                Text("Keys").tag(TriggerCategory.keyboard)
                Text("Mouse").tag(TriggerCategory.normalMouse)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.background.opacity(0.25))
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
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Trigger Info Card
                        triggerHeaderCard(trigger)

                        // 2. Connected Action Sequence (Shortcuts Style)
                        actionSequenceSection(trigger)
                    }
                    .padding(24)
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
                Image(systemName: trigger.input.category.iconName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 36)

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
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("Workflow name", text: Binding(
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

        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private func actionSequenceSection(_ trigger: Trigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Actions · \(trigger.actions.count)", systemImage: "bolt")
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
                                    .fill(Color(nsColor: .separatorColor))
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

                    Button {
                        parentID = nil
                        toElse = false
                        replaceActionID = nil
                        appState.showingAddAction = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                            Text("Add Action")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 12)
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

// MARK: - Native list content

private struct GestureSummaryRow: View {
    let trigger: Trigger

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trigger.input.category.iconName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(trigger.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if trigger.isFavorite { Image(systemName: "pin.fill").font(.caption2) }
                }
                Text(trigger.actions.first.map {
                    $0.displayName + (trigger.actions.count > 1 ? " · \(trigger.actions.count) actions" : "")
                } ?? "No actions")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !trigger.isEnabled {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Disabled")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
