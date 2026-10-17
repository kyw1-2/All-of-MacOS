import AppKit
import SwiftUI

/// Native source list: pages, application profiles and activation groups.
/// Every row is a real selectable List row, so keyboard navigation, focus
/// rings and selection highlighting come from the system.
struct ModernSidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAppPicker = false
    @State private var editingGroup: ActivationGroup?
    @State private var groupPendingDeletion: ActivationGroup?
    @Environment(\.openSettings) private var openSettingsAction

    private enum Destination: Hashable {
        case hub(AOMMainTab)
        case allApps
        case profile(UUID)
        case group(UUID)
    }

    private var selection: Binding<Destination?> {
        Binding(get: {
            guard appState.selectedMainTab == .gestures else { return .hub(appState.selectedMainTab) }
            if let id = appState.selectedActivationGroupID { return .group(id) }
            if !appState.selectedAppTarget.isGlobal { return .profile(appState.selectedAppTarget.id) }
            return .hub(.gestures)
        }, set: { destination in
            guard let destination else { return }
            switch destination {
            case .hub(let tab):
                appState.selectedMainTab = tab
            case .allApps:
                selectScope(group: nil, app: .allApps)
            case .profile(let id):
                guard let app = appState.currentPreset.appTargets.first(where: { $0.id == id }) else { return }
                selectScope(group: nil, app: app)
            case .group(let id):
                selectScope(group: id, app: appState.selectedAppTarget)
            }
        })
    }

    private func selectScope(group: UUID?, app: AppTarget) {
        appState.selectedActivationGroupID = group
        appState.selectedAppTarget = app
        appState.selectedTrigger = nil
        appState.selectedAction = nil
        appState.selectedMainTab = .gestures
    }

    private func triggerCount(app: AppTarget? = nil, group: UUID? = nil) -> Int {
        appState.currentPreset.triggers.filter { trigger in
            if let group { return trigger.activationGroupID == group }
            guard trigger.activationGroupID == nil else { return false }
            if let app, !app.isGlobal { return trigger.appBundleID == app.bundleID }
            return trigger.appBundleID?.isEmpty ?? true
        }.count
    }

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                ForEach(AOMMainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.iconName)
                        .tag(Destination.hub(tab))
                }
            }
            Section("Applications") {
                Label("All Applications", systemImage: "globe")
                    .badge(triggerCount())
                    .tag(Destination.allApps)
                ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { app in
                    Label {
                        Text(app.name).lineLimit(1)
                    } icon: {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app")
                        }
                    }
                    .badge(triggerCount(app: app))
                    .tag(Destination.profile(app.id))
                    .contextMenu {
                        Button("Remove Application Profile", role: .destructive) {
                            appState.removeAppTarget(app)
                        }
                    }
                }
                Button { showingAppPicker = true } label: {
                    Label("Add Application…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Section("Activation Groups") {
                ForEach(appState.currentPreset.activationGroups) { group in
                    Label {
                        Text(group.name).lineLimit(1)
                            .foregroundStyle(group.isEnabled ? .primary : .secondary)
                    } icon: {
                        Image(systemName: group.isEnabled ? "square.stack.3d.up.fill" : "pause.circle")
                    }
                    .badge(triggerCount(group: group.id))
                    .tag(Destination.group(group.id))
                    .contextMenu {
                        Button("Edit Group…") { editingGroup = group }
                        Button(group.isEnabled ? "Disable Group" : "Enable Group") {
                            var edited = group
                            edited.isEnabled.toggle()
                            appState.updateActivationGroup(edited)
                        }
                        Divider()
                        Button("Delete Group…", role: .destructive) { groupPendingDeletion = group }
                    }
                }
                Button { editingGroup = ActivationGroup(name: "New Group") } label: {
                    Label("New Group…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Share one set of gestures across several apps")
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .popover(isPresented: $showingAppPicker) {
            AppPickerView { app in
                appState.addAppTarget(app)
                showingAppPicker = false
            }
            .frame(width: 320, height: 380)
        }
        .sheet(item: $editingGroup) { group in
            ActivationGroupEditorSheet(group: group) { saved in
                if appState.currentPreset.activationGroups.contains(where: { $0.id == saved.id }) {
                    appState.updateActivationGroup(saved)
                } else {
                    appState.addActivationGroup(saved)
                }
            }
        }
        .confirmationDialog("Delete “\(groupPendingDeletion?.name ?? "")” and its gestures?",
                            isPresented: Binding(get: { groupPendingDeletion != nil },
                                                 set: { if !$0 { groupPendingDeletion = nil } })) {
            Button("Delete Group and Gestures", role: .destructive) {
                if let group = groupPendingDeletion {
                    if appState.selectedActivationGroupID == group.id { appState.selectedActivationGroupID = nil }
                    appState.removeActivationGroup(group.id)
                }
                groupPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { groupPendingDeletion = nil }
        } message: {
            Text("Global and app-specific gestures are not affected.")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { appState.toggleGlobalEnabled() } label: {
                HStack(spacing: 6) {
                    Circle().fill(appState.globalEnabled ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(appState.globalEnabled ? "Automation Active" : "Automation Paused")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(appState.globalEnabled ? "Pause all gestures and shortcuts" : "Resume all gestures and shortcuts")
            .accessibilityLabel(appState.globalEnabled ? "Automation active. Pause" : "Automation paused. Resume")
            Spacer()
            Button { openSettingsAction() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
