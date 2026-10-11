import SwiftUI
import UniformTypeIdentifiers

struct AppSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAppPicker = false
    @State private var showingSnapZones = false
    @State private var showingProfiles = false
    @State private var showingWindowLayouts = false
    @State private var editingGroup: ActivationGroup?
    @State private var pendingDeletionID: UUID?
    @State private var confirmGroupDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("APPLICATIONS", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { showingAppPicker = true } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.plain).help("Add an application")
                            .accessibilityLabel("Add Application")
                    }
                    .popover(isPresented: $showingAppPicker) {
                        AppPickerView { app in
                            appState.addAppTarget(app)
                            showingAppPicker = false
                        }.frame(width: 320, height: 380)
                    }
                    ForEach(appState.currentPreset.appTargets) { app in
                        Button {
                            appState.selectedActivationGroupID = nil
                            appState.selectedAppTarget = app
                            appState.selectedTrigger = nil
                            appState.selectedAction = nil
                            appState.showStatistics = false
                        } label: {
                            HStack(spacing: 9) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                                else { Image(systemName: app.isGlobal ? "globe" : "app").frame(width: 20) }
                                Text(app.name).lineLimit(1).font(.subheadline.weight(.medium))
                                Spacer(minLength: 1)
                                if appState.selectedActivationGroupID == nil && appState.selectedAppTarget.id == app.id {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(appState.selectedActivationGroupID == nil && appState.selectedAppTarget.id == app.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .contextMenu { if !app.isGlobal { Button("Remove Application", role: .destructive) { appState.removeAppTarget(app) } } }
                    }
                    Divider().padding(.vertical, 3)
                    HStack {
                        Label("ACTIVATION GROUPS", systemImage: "square.stack.3d.up")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { editingGroup = ActivationGroup(name: "New Group") } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.plain).help("Create an activation group")
                            .accessibilityLabel("Create Activation Group")
                    }
                    if appState.currentPreset.activationGroups.isEmpty {
                        Button { editingGroup = ActivationGroup(name: "New Group") } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Create a Group", systemImage: "plus").font(.subheadline.weight(.medium))
                                Text("Choose apps once, then share their gestures.").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    ForEach(appState.currentPreset.activationGroups) { group in
                        HStack(spacing: 4) {
                            Button {
                                appState.selectedActivationGroupID = group.id
                                appState.selectedTrigger = nil
                                appState.selectedAction = nil
                                appState.showStatistics = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 16))
                                        .foregroundStyle(.tint).frame(width: 21)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("\(group.appliesToAllApps ? "All apps" : "\(group.includedBundleIDs.count) apps")  ·  \(appState.currentPreset.triggers.filter { $0.activationGroupID == group.id }.count) gestures")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if !group.isEnabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 9)
                                .background(appState.selectedActivationGroupID == group.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                            Toggle("Enable \(group.name)", isOn: Binding(get: { group.isEnabled }, set: { value in
                                var edited = group; edited.isEnabled = value; appState.updateActivationGroup(edited)
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Button { editingGroup = group } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Edit \(group.name)").accessibilityLabel("Edit Activation Group \(group.name)")
                        }
                        .contextMenu {
                            Button("Edit Group") { editingGroup = group }
                            Button("Delete Group and Triggers", role: .destructive) {
                                pendingDeletionID = group.id
                                confirmGroupDeletion = true
                            }
                        }
                    }
                    .sheet(item: $editingGroup) { group in
                        ActivationGroupEditorSheet(group: group) { saved in
                            if appState.currentPreset.activationGroups.contains(where: { $0.id == saved.id }) { appState.updateActivationGroup(saved) }
                            else { appState.addActivationGroup(saved) }
                        }
                    }
                    Divider().padding(.vertical, 3)
                    HStack {
                        Label("DRAG-TO-SNAP", systemImage: "rectangle.on.rectangle.angled")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Window snapping", isOn: Binding(get: { appState.currentPreset.snappingEnabled }, set: { appState.setSnappingEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("Enable Drag to Snap")
                    }
                    // Integrated Window Management & Snap Tools
                    VStack(spacing: 4) {
                        Button { showingSnapZones = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "rectangle.split.2x2")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Snap Zones")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(appState.snapStatus)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Set Up Window Snapping")

                        Button { showingProfiles = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "display.2")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Display Profiles")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(appState.activeSnapProfile?.name ?? "Default layout")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)

                        Button { showingWindowLayouts = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "macwindow.on.rectangle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Saved Windows")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Layouts & Undo")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(12)
            }
            .sheet(isPresented: $showingSnapZones) {
                CustomSnapZonesEditor(preset: appState.currentPreset, profile: appState.activeSnapProfile)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showingProfiles) { SnapProfilesEditor().environmentObject(appState) }
            .sheet(isPresented: $showingWindowLayouts) { WindowLayoutsEditor() }
            .confirmationDialog("Delete group and all its triggers?", isPresented: $confirmGroupDeletion) {
                Button("Delete Group and Triggers", role: .destructive) {
                    if let id = pendingDeletionID { appState.removeActivationGroup(id) }
                    pendingDeletionID = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletionID = nil }
            } message: { Text("The group's triggers will be deleted; global and app-specific gestures remain unchanged.") }
            Divider()
            // Statistics Button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.showStatistics.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.blue, .purple, .pink, .orange],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                    Text("Statistics")
                        .foregroundColor(appState.showStatistics ? .primary : .secondary)
                    Spacer()
                    if appState.showStatistics {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(appState.showStatistics ? appState.accentColorChoice.color.opacity(0.15) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.top, 6)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("PRESETS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Label(appState.currentPreset.name, systemImage: "tray.full").font(.subheadline).lineLimit(2)
                HStack {
                    Button("Import…") { appState.presentPresetImport() }
                    Button("Export…") { appState.presentPresetExport() }
                }.controlSize(.small)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            // Accent Color Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Accent Color")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    ForEach(AccentColorChoice.allCases) { choice in
                        Circle()
                            .fill(choice.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: appState.accentColorChoice == choice ? 2 : 0)
                            )
                            .shadow(color: appState.accentColorChoice == choice ? choice.color.opacity(0.6) : .clear, radius: 3)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    appState.accentColorChoice = choice
                                    UserDefaults.standard.set(choice.rawValue, forKey: "AOMAccentColor")
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Sidebar reads as the window material with a thin divider, the way
        // System Settings' own source list does.
        .background(.background.opacity(0.22))
    }
}

struct AppTargetRow: View {
    let app: AppTarget

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: app.isGlobal ? "globe" : "app")
                    .frame(width: 20, height: 20)
            }
            Text(app.name)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct AppPickerView: View {
    let onSelect: (AppTarget) -> Void
    @State private var searchText = ""
    @State private var runningApps: [AppTarget] = []

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Application")
                .font(.headline)
                .padding()

            TextField("Search apps...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List(filteredApps) { app in
                Button(action: { onSelect(app) }) {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        Text(app.name)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { loadRunningApps() }
    }

    private var filteredApps: [AppTarget] {
        if searchText.isEmpty { return runningApps }
        return runningApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppTarget? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }
                return AppTarget(
                    id: UUID(),
                    bundleID: bundleID,
                    name: name,
                    iconPath: app.bundleURL?.path
                )
            }
            .sorted { $0.name < $1.name }
        runningApps = apps
    }
}


/// Application-first group setup. New groups are saved only when Save is pressed.
struct ActivationGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ActivationGroup
    @State private var searchText = ""
    @State private var advancedBundleID = ""
    @State private var showAdvanced = false
    @State private var selectionMode = 0
    private let onSave: (ActivationGroup) -> Void

    init(group: ActivationGroup, onSave: @escaping (ActivationGroup) -> Void) {
        _draft = State(initialValue: group)
        _selectionMode = State(initialValue: group.appliesToAllApps ? 1 : 0)
        self.onSave = onSave
    }
    private var choices: [AppTarget] {
        var ids = Set(draft.includedBundleIDs + draft.excludedBundleIDs)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { ids.insert(id) }
        }
        return ids.map { id in
            AppTarget(id: UUID(), bundleID: id, name: appName(id), iconPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path)
        }.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(searchText) }
         .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var selectedIDs: [String] {
        selectionMode == 0 ? draft.includedBundleIDs : draft.excludedBundleIDs
    }
    private func toggle(_ bundleID: String) {
        if selectionMode == 0 {
            if draft.includedBundleIDs.contains(bundleID) { draft.includedBundleIDs.removeAll { $0 == bundleID } }
            else if draft.includedBundleIDs.count < 128 {
                draft.includedBundleIDs.append(bundleID); draft.excludedBundleIDs.removeAll { $0 == bundleID }
            }
        } else {
            if draft.excludedBundleIDs.contains(bundleID) { draft.excludedBundleIDs.removeAll { $0 == bundleID } }
            else if draft.excludedBundleIDs.count < 128 {
                draft.excludedBundleIDs.append(bundleID); draft.includedBundleIDs.removeAll { $0 == bundleID }
            }
        }
    }
    private func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
    }
    private func icon(_ bundleID: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "app")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activation Group").font(.title2.bold())
                    Text("One gesture set for the apps you choose.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: $draft.isEnabled).toggleStyle(.switch)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("GROUP NAME").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("e.g. Browsers", text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("APPLIES TO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Scope", selection: $draft.appliesToAllApps) {
                            Text("Selected apps").tag(false)
                            Text("All apps").tag(true)
                        }.pickerStyle(.radioGroup).labelsHidden()
                            .onChange(of: draft.appliesToAllApps) { _, all in selectionMode = all ? 1 : 0 }
                        Text(draft.appliesToAllApps ? "Works everywhere except excluded apps." : "Only included apps activate this group.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("Override global gestures", isOn: $draft.disableGlobalTriggers)
                    Text("When this group is active, skip All Apps bindings. App-specific bindings keep priority.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Label(draft.isEnabled ? "Group enabled" : "Group paused", systemImage: draft.isEnabled ? "checkmark.circle" : "pause.circle")
                        .font(.callout.weight(.medium))
                    if !draft.appliesToAllApps && draft.includedBundleIDs.isEmpty {
                        Label("Choose at least one included app to activate this group.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.frame(width: 210, height: 360)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Applications").font(.headline)
                        Spacer()
                        if !draft.appliesToAllApps {
                            Picker("App list", selection: $selectionMode) {
                                Text("Include (\(draft.includedBundleIDs.count))").tag(0)
                                Text("Exclude (\(draft.excludedBundleIDs.count))").tag(1)
                            }.pickerStyle(.segmented).frame(width: 220)
                        } else { Text("\(draft.excludedBundleIDs.count) exclusions").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(selectionMode == 0 ? "Checked apps share this group's gestures." : "Checked apps never activate this group.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Search applications", text: $searchText).textFieldStyle(.roundedBorder)
                        Button("Browse…", action: chooseApps)
                    }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(choices, id: \.bundleID) { app in
                                if let id = app.bundleID {
                                    Button { toggle(id) } label: {
                                        HStack(spacing: 10) {
                                            icon(id).resizable().frame(width: 24, height: 24)
                                            Text(app.name).font(.callout).lineLimit(1)
                                            Spacer()
                                            Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedIDs.contains(id) ? Color.accentColor : .secondary)
                                        }.padding(9).contentShape(Rectangle())
                                            .background(selectedIDs.contains(id) ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).help(id)
                                }
                            }
                            if choices.isEmpty { Text("No matching apps. Use Browse to add an installed application.").foregroundStyle(.secondary).padding() }
                        }
                    }.frame(height: 245).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    DisclosureGroup("Add by bundle identifier", isExpanded: $showAdvanced) {
                        HStack {
                            TextField("com.example.app", text: $advancedBundleID).textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let id = advancedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !id.isEmpty && id.count <= 256 && !selectedIDs.contains(id) { toggle(id) }
                                advancedBundleID = ""
                            }.disabled(advancedBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 6)
                    }.font(.caption)
                }.frame(width: 390)
            }.padding(20)
            Divider()
            HStack {
                Text(draft.appliesToAllApps ? "All apps · \(draft.excludedBundleIDs.count) exceptions" : "\(draft.includedBundleIDs.count) included · \(draft.excludedBundleIDs.count) excluded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Group") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.count > 128)
            }.padding(16)
        }.frame(width: 690)
    }
    private func chooseApps() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier, !selectedIDs.contains(id) { toggle(id) }
            }
        }
    }

}

/// Two-step visual snapping editor. Save is atomic; Cancel discards draft zones.
struct CustomSnapZonesEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var zones: [CustomSnapZone]
    @State private var selectedID: UUID?
    @State private var enabled: Bool
    @State private var requiresOption: Bool
    @State private var showsPreview: Bool
    @State private var lastSet: String = "Custom"
    @State private var previousZones: [CustomSnapZone]?
    let profileID: UUID?
    let profileName: String
    init(preset: Preset, profile: SnapLayoutProfile? = nil) {
        let zones = profile?.zones ?? preset.customSnapZones
        _lastSet = State(initialValue: CustomSnapZone.Collection.allCases.first {
            $0.layouts.count == zones.count && Set($0.replacing(zones).map(\.id)) == Set(zones.map(\.id))
        }?.rawValue ?? "Custom")
        _zones = State(initialValue: zones)
        _selectedID = State(initialValue: zones.first?.id)
        _enabled = State(initialValue: preset.snappingEnabled)
        _requiresOption = State(initialValue: profile?.requiresOption ?? preset.snappingRequiresOption)
        _showsPreview = State(initialValue: profile?.showsPreview ?? preset.snappingShowsPreview)
        profileID = profile?.id; profileName = profile?.name ?? "Default layout"
    }
    private func applyCollection(_ collection: CustomSnapZone.Collection) {
        previousZones = zones
        zones = collection.replacing(zones)
        selectedID = zones.first?.id; lastSet = collection.rawValue
    }
    private var selection: Binding<CustomSnapZone>? {
        guard let id = selectedID, let index = zones.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { zones[index] }, set: { zones[index] = $0 })
    }
    private func newZone(_ layout: CustomSnapZone.Layout) {
        guard zones.count < 32 else { return }
        let zone = layout.zone()
        zones.append(zone)
        selectedID = zone.id; lastSet = "Custom"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag-to-Snap Window Layouts").font(.title2.bold())
                    Text("Drag a window by its title bar into a highlighted area → release to resize.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(CustomSnapZone.Layout.allCases) { layout in
                        Button { newZone(layout) } label: { Label(layout.rawValue, systemImage: layout.symbol) }
                    }
                } label: { Label("Add Layout", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(zones.count >= 32)
            }
            HStack(spacing: 16) {
                Toggle("Enable snapping", isOn: $enabled).toggleStyle(.switch)
                Toggle("Require Option ⌥", isOn: $requiresOption)
                Toggle("Show preview", isOn: $showsPreview)
                Spacer()
                Menu("Replace Set: " + lastSet) {
                    ForEach(CustomSnapZone.Collection.allCases) { collection in
                        Button("\(collection.rawValue) · \(collection.layouts.count) layouts") { applyCollection(collection) }
                    }
                }
            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editing: " + profileName).font(.subheadline.bold())
                    Text("Running now: " + appState.snapStatus).font(.caption).foregroundStyle(.secondary)
                    Text(enabled ? "After Save: \(zones.filter(\.isEnabled).count) layouts enabled. AOM must also be on." : "After Save: OFF. Individual selections are remembered; no areas are monitored.")
                        .font(.caption).foregroundStyle(enabled ? Color.secondary : Color.orange)
                }
                Spacer()
                if let previousZones {
                    Button("Undo Set Change") { zones = previousZones; self.previousZones = nil; selectedID = zones.first?.id; lastSet = "Custom" }
                }
            }
            Text("Replace Set replaces this list (3 / 9 / 16). Apply with Save Changes. Drag a title bar into an area; Esc cancels.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 17) {
                VStack(spacing: 9) {
                    Text("LAYOUTS IN THIS SET").font(.caption.bold()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity,alignment: .leading)
                    Button("Select All Layouts") { for index in zones.indices { zones[index].isEnabled = true } }
                        .buttonStyle(.bordered).disabled(zones.isEmpty)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(zones) { zone in
                                Button { selectedID = zone.id } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: zone.isEnabled ? "macwindow.on.rectangle" : "pause.circle")
                                            .font(.system(size: 20))
                                        VStack(alignment: .leading,spacing: 2) {
                                            Text(zone.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text("\(Int(zone.targetWidth*100))% × \(Int(zone.targetHeight*100))%")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedID == zone.id { Image(systemName: "checkmark.circle.fill") }
                                    }
                                    .padding(10)
                                    .background(selectedID == zone.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }.padding(2)
                    }.frame(width: 195, height: 330)
                }
                if let selected = selection {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView { SnapZoneDetailEditor(zone: selected).padding(3) }.frame(height: 365)
                        HStack {
                            Spacer()
                            Button("Duplicate") {
                                guard var zone = zones.first(where: { $0.id == selectedID }) else { return }
                                zone.id = UUID(); zone.name += " Copy"
                                zones.append(zone); selectedID = zone.id
                            }.disabled(zones.count >= 32)
                            Button("Delete Zone", role: .destructive) {
                                zones.removeAll { $0.id == selectedID }
                                selectedID = zones.first?.id
                            }
                        }
                    }.frame(width: 760)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Choose your first window layout").font(.title3.weight(.semibold))
                        Text("Select a layout. Set where to drop the window and where it should land. Then save.")
                            .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button { applyCollection(.complete) } label: {
                            Label("Use Complete Set · 16 layouts", systemImage: "checkmark.circle.fill")
                        }.buttonStyle(.borderedProminent)
                        Text("Changes apply when you save.").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())], spacing: 12) {
                            ForEach([CustomSnapZone.Layout.leftHalf, .rightHalf, .maximize, .topLeft, .centerThird, .nextDisplay]) { layout in
                                Button { newZone(layout) } label: {
                                    VStack(spacing: 9) {
                                        Image(systemName: layout.symbol).font(.system(size: 28))
                                        Text(layout.rawValue).font(.subheadline.weight(.medium))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 93)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(25)
                    .frame(width: 760, height: 365)
                }
            }
            Divider()
            HStack {
                Text("\(zones.count) layouts · changes apply only after Save")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Changes") {
                    appState.updateSnapSettings(zones: zones, enabled: enabled, requiresOption: requiresOption,
                        showsPreview: showsPreview, profileID: profileID)
                    dismiss()
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!zones.allSatisfy(\.isValid))
            }
        }.padding(21).frame(width: 1035)
    }
}

/// Interactive display mock: drag rectangle to position, corner grip to resize.
private struct SnapZoneCanvas: View {
    @Binding var zone: CustomSnapZone
    let destination: Bool
    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?
    private var rect: CGRect {
        CGRect(x: destination ? zone.targetX : zone.hotX,
               y: destination ? zone.targetY : zone.hotY,
               width: destination ? zone.targetWidth : zone.hotWidth,
               height: destination ? zone.targetHeight : zone.hotHeight)
    }
    private func set(_ rect: CGRect) {
        if destination {
            zone.targetX = rect.minX; zone.targetY = rect.minY
            zone.targetWidth = rect.width; zone.targetHeight = rect.height
        } else {
            zone.hotX = rect.minX; zone.hotY = rect.minY
            zone.hotWidth = rect.width; zone.hotHeight = rect.height
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let frame = rect
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .textBackgroundColor))
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(.red.opacity(0.65)).frame(width: 7, height: 7)
                        Circle().fill(.yellow.opacity(0.65)).frame(width: 7, height: 7)
                        Circle().fill(.green.opacity(0.65)).frame(width: 7, height: 7)
                        Spacer()
                        Text("DISPLAY PREVIEW").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 23)
                    Rectangle().fill(.secondary.opacity(0.12)).frame(height: 1)
                    Spacer()
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.30))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .overlay(alignment: .center) {
                        VStack(spacing: 4) {
                            Image(systemName: destination ? "macwindow" : "cursorarrow.rays")
                                .font(.system(size: 18))
                            Text(destination ? "WINDOW" : "DROP HERE")
                                .font(.system(size: 9, weight: .bold))
                        }.foregroundStyle(Color.accentColor).allowsHitTesting(false)
                    }
                    .frame(width: geometry.size.width * frame.width,
                           height: geometry.size.height * frame.height)
                    .position(x: geometry.size.width * frame.midX, y: geometry.size.height * frame.midY)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStart == nil { dragStart = frame }
                            guard let base = dragStart else { return }
                            let x = min(1-base.width, max(0, base.minX + value.translation.width/geometry.size.width))
                            let y = min(1-base.height, max(0, base.minY + value.translation.height/geometry.size.height))
                            set(CGRect(x: x, y: y, width: base.width, height: base.height))
                        }.onEnded { _ in dragStart = nil })
                Circle().fill(Color.accentColor)
                    .frame(width: 21,height: 21)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10,weight: .bold)).foregroundStyle(.white))
                    .position(x: geometry.size.width * frame.maxX, y: geometry.size.height * frame.maxY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeStart == nil { resizeStart = frame }
                            guard let base = resizeStart else { return }
                            let width = min(1-base.minX,max(0.05,base.width+value.translation.width/geometry.size.width))
                            let height = min(1-base.minY,max(0.05,base.height+value.translation.height/geometry.size.height))
                            set(CGRect(x: base.minX,y: base.minY,width: width,height: height))
                        }.onEnded { _ in resizeStart = nil })
            }
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.secondary.opacity(0.25)))
        }
    }
}

private struct SnapZoneDetailEditor: View {
    @Binding var zone: CustomSnapZone
    @State private var mode = 0
    @State private var showPrecision = false
    private func configure(x: Double,y: Double,width: Double,height: Double) {
        if mode == 0 {
            zone.hotX=x; zone.hotY=y; zone.hotWidth=width; zone.hotHeight=height
        } else {
            zone.targetX=x; zone.targetY=y; zone.targetWidth=width; zone.targetHeight=height
        }
    }
    private func preciseValue(_ key: WritableKeyPath<CustomSnapZone, Double>) -> Binding<Double> {
        Binding(get: { zone[keyPath: key] }, set: { val in
            var candidate = zone
            candidate[keyPath: key] = val
            if candidate.isValid { zone = candidate }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Zone name", text: $zone.name).font(.title3).textFieldStyle(.roundedBorder)
                Toggle("Enabled", isOn: $zone.isEnabled).toggleStyle(.switch)
            }
            Text("Move the colored rectangles, or use the ready-made positions below.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("1 · WHERE TO DROP", systemImage: "cursorarrow.rays")
                        .font(.caption.weight(.bold))
                    SnapZoneCanvas(zone: $zone, destination: false)
                        .frame(height: 208)
                        .accessibilityLabel("Drop area preview. Drag to position, use corner to resize.")
                    HStack(spacing: 5) {
                        Button("Top-left") { mode = 0; configure(x: 0,y: 0,width: 0.15,height: 0.15) }
                        Button("Top-right") { mode = 0; configure(x: 0.85,y: 0,width: 0.15,height: 0.15) }
                        Button("Bottom-right") { mode = 0; configure(x: 0.85,y: 0.85,width: 0.15,height: 0.15) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Text("Release the dragged window inside this area.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Label("2 · WHERE IT MOVES", systemImage: "macwindow")
                        .font(.caption.weight(.bold))
                    SnapZoneCanvas(zone: $zone, destination: true)
                        .frame(height: 208)
                        .accessibilityLabel("Window destination preview. Drag to position, use corner to resize.")
                    HStack(spacing: 5) {
                        Button("Left ½") { mode = 1; configure(x: 0,y: 0,width: 0.5,height: 1) }
                        Button("Right ½") { mode = 1; configure(x: 0.5,y: 0,width: 0.5,height: 1) }
                        Button("Full") { mode = 1; configure(x: 0,y: 0,width: 1,height: 1) }
                        Button("Center") { mode = 1; configure(x: 0.2,y: 0.13,width: 0.6,height: 0.74) }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Text("The window is resized to this target after release.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            Picker("Target display", selection: $zone.targetDisplay) {
                Text("Display under pointer").tag("pointer")
                Text("Window's current display").tag("current")
                Text("Main display").tag("primary")
                Text("Next display").tag("next")
            }
            Divider()
            Picker("Fine tune", selection: $mode) {
                Text("Drop area coordinates").tag(0)
                Text("Window target coordinates").tag(1)
            }.pickerStyle(.segmented)
            DisclosureGroup("Precise coordinates", isExpanded: $showPrecision) {
                VStack(spacing: 5) {
                    ForEach(["X", "Y", "Width", "Height"], id: \.self) { title in
                        HStack {
                            Text(title).frame(width: 52, alignment: .leading)
                            let key: WritableKeyPath<CustomSnapZone, Double> = {
                                switch (mode,title) {
                                case (0,"X"): return \.hotX
                                case (0,"Y"): return \.hotY
                                case (0,"Width"): return \.hotWidth
                                case (0,_): return \.hotHeight
                                case (1,"X"): return \.targetX
                                case (1,"Y"): return \.targetY
                                case (1,"Width"): return \.targetWidth
                                default: return \.targetHeight
                                }
                            }()
                            Slider(value: preciseValue(key), in: 0...1, step: 0.01)
                            Text("\(Int(zone[keyPath: key]*100))%")
                                .monospacedDigit().frame(width: 42)
                        }
                    }
                }.padding(.vertical, 8)
            }
            if !zone.isValid {
                Label("Keep the rectangles inside the screen and at least 5% wide/tall.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}


struct SnapProfilesEditor: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display Profiles").font(.title2.bold())
            Toggle("Switch layouts automatically when displays change", isOn: Binding(
                get: { appState.currentPreset.automaticSnapProfiles }, set: { appState.setAutomaticSnapProfiles($0) }))
            Text("Connected: \(appState.displayIDs.count) displays · Active: \(appState.activeSnapProfile?.name ?? "Default layout")")
                .font(.subheadline)
            Text("Save the current layouts for these exact displays. Unrecognized configurations use the default layout. The master snapping switch is always respected.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Profile name (e.g. MacBook / Desk)", text: $name)
                Button("Save for These Displays") {
                    message = appState.saveDisplayProfile(name: name) ? "Profile saved. Edit its areas in Window Snapping." : "Enter a name and connect an available display."
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Saving again for the same displays updates that profile.").font(.caption).foregroundStyle(.secondary)
            List(appState.currentPreset.snapProfiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name).bold()
                        Text("\(profile.displayIDs.count) displays · \(profile.zones.count) layouts").font(.caption)
                    }
                    Spacer()
                    if appState.activeSnapProfile?.id == profile.id { Text("Active").foregroundStyle(.green) }
                    Button("Remove") { appState.removeDisplayProfile(profile.id) }
                }
            }.frame(height: 230)
            Text(message).font(.caption)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 640)
    }
}

struct WindowLayoutsEditor: View {
    @ObservedObject private var manager = WindowManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved Window Layouts").font(.title2.bold())
                Spacer()
                Button("Undo Last Placement") { manager.undoLastPlacement { _ in } }
                    .disabled(manager.historyCount == 0 || manager.layoutBusy)
            }
            Text("Save visible normal windows, then restore their positions together. Closed or ambiguous windows and disconnected displays are skipped. Undo lasts until AOM quits.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Layout name", text: $name)
                Button("Save Current Windows") { _ = manager.saveLayout(name: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.layoutBusy)
            }
            Text("Saving with an existing name updates that layout.").font(.caption).foregroundStyle(.secondary)
            List(manager.layouts) { layout in
                HStack {
                    Text(layout.name).bold()
                    Text("\(layout.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") { manager.restoreLayout(name: layout.name) { _ in } }
                    Button("Remove") { manager.removeLayout(layout.id) }
                }.disabled(manager.layoutBusy)
            }.frame(height: 230)
            Text(manager.lastLayoutResult).font(.caption)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 680)
    }
}
