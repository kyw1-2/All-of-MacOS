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
            // Scope rows highlight only while a specific scope is chosen.
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

    @AppStorage("AOMSidebarAppsExpanded") private var appsExpanded = true
    @AppStorage("AOMSidebarGroupsExpanded") private var groupsExpanded = true

    private func hubRow(_ tab: AOMMainTab, badge: Int? = nil) -> some View {
        Label {
            Text(tab.title).font(.system(size: 13, weight: .medium))
        } icon: {
            Image(systemName: tab.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tab.accentColor)
                .frame(width: 24, height: 28)
        }
        .badge(badge ?? 0)
        .tag(Destination.hub(tab))
        .help("\(tab.subtitle) (⌘\((AOMMainTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
    }

    var body: some View {
        let counts = AOMSidebarSummary(triggers: appState.currentPreset.triggers)
        List(selection: selection) {
            Section {
                hubRow(.home)
                hubRow(.insights)
            }
            Section("Automation") {
                hubRow(.gestures, badge: counts.enabled)
                hubRow(.snapping)
            }
            Section("Media") {
                hubRow(.capture)
                hubRow(.clipboard)
            }
            Section("Applications", isExpanded: $appsExpanded) {
                Label {
                    Text("All Applications")
                } icon: {
                    AOMIconTile(systemImage: "globe", tint: .gray, size: 22)
                }
                .badge(counts.global)
                .tag(Destination.allApps)
                ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { app in
                    Label {
                        Text(app.name).lineLimit(1)
                    } icon: {
                        AOMSidebarAppIcon(app: app)
                    }
                    .badge(counts.applications[app.bundleID ?? ""] ?? 0)
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
            Section("Activation Groups", isExpanded: $groupsExpanded) {
                ForEach(appState.currentPreset.activationGroups) { group in
                    Label {
                        Text(group.name).lineLimit(1)
                            .foregroundStyle(group.isEnabled ? .primary : .secondary)
                    } icon: {
                        AOMIconTile(systemImage: group.isEnabled ? "square.stack.3d.up.fill" : "pause.fill",
                                    tint: group.isEnabled ? .teal : .gray, size: 22)
                    }
                    .badge(counts.groups[group.id] ?? 0)
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
        .aomSidebarMaterial()
        .safeAreaInset(edge: .top, spacing: 0) { identity }
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

    private var identity: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("All of MacOS").font(.headline)
                Text(appState.currentPreset.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 18)
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
        .overlay(alignment: .top) { Divider().opacity(0.35) }
    }
}

/// Resolve application artwork once per visible row rather than on every
/// hover, selection or preset publication. The task follows profile identity.
private struct AOMSidebarAppIcon: View {
    let app: AppTarget
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "app").foregroundStyle(.secondary) }
        }
        .frame(width: 22, height: 22)
        .task(id: app.bundleID) { icon = app.icon }
        .accessibilityHidden(true)
    }
}
