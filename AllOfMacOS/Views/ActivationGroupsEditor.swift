import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits Conditional Activation Groups: which apps a group covers and, after
/// BetterTouchTool, when it is active (time, power, displays, an app's
/// window). Automations join a group from the editor's "Applies to" menu.
struct ActivationGroupsEditor: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var pendingDeletion: ActivationGroup?

    private var groups: [ActivationGroup] { appState.currentPreset.activationGroups }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(AOMType.rowTitle)
                                    .foregroundStyle(group.isEnabled ? AOMTheme.text : AOMTheme.textTertiary)
                                Text(Self.scopeSummary(group))
                                    .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                            }
                            .tag(group.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                    AOMDivider()
                    HStack(spacing: 4) {
                        Button { add() } label: { Image(systemName: "plus") }.help("New Group")
                        Button { pendingDeletion = groups.first { $0.id == selectedID } } label: { Image(systemName: "minus") }
                            .disabled(selectedID == nil).help("Delete Group")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 220)
                AOMDivider(axis: .vertical)
                Group {
                    if let index = groups.firstIndex(where: { $0.id == selectedID }) {
                        ActivationGroupForm(group: Binding(
                            get: { appState.currentPreset.activationGroups[index] },
                            set: { appState.updateActivationGroup($0) }),
                            triggerCount: appState.currentPreset.triggers.filter { $0.activationGroupID == groups[index].id }.count)
                        .id(groups[index].id)
                    } else {
                        AOMEmptyState("No Group Selected", systemImage: "square.stack.3d.up",
                                      message: "A group shares automations across several apps and can be limited to certain times, power states or display setups.") {
                            Button("New Group") { add() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            AOMDivider()
            HStack {
                Text("Automations join a group from “Applies to” in the Automation editor.")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 580)
        .onAppear { selectedID = selectedID ?? appState.selectedActivationGroupID ?? groups.first?.id }
        .confirmationDialog("Delete “\(pendingDeletion?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Group and Its Automations", role: .destructive) {
                if let group = pendingDeletion { appState.removeActivationGroup(group.id) }
                selectedID = groups.first?.id
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Automations that apply only to this group are deleted with it; they never become global.")
        }
    }

    private func add() {
        let id = appState.addActivationGroup(name: "New Group")
        selectedID = id
    }

    static func scopeSummary(_ group: ActivationGroup) -> String {
        var parts = [group.appliesToAllApps ? "All apps" : "\(group.includedBundleIDs.count) app\(group.includedBundleIDs.count == 1 ? "" : "s")"]
        if let conditions = group.conditions, !conditions.isEmpty { parts.append(conditions.summary) }
        if !group.isEnabled { parts.insert("Off", at: 0) }
        return parts.joined(separator: " · ")
    }
}

/// One group's settings, as a grouped form.
private struct ActivationGroupForm: View {
    @Binding var group: ActivationGroup
    let triggerCount: Int

    private var conditions: Binding<ActivationConditions> {
        Binding(get: { group.conditions ?? ActivationConditions() },
                set: { group.conditions = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $group.name)
                Toggle("Enabled", isOn: $group.isEnabled)
                LabeledContent("Automations") { Text("\(triggerCount)").foregroundStyle(.secondary) }
            }
            Section {
                Toggle("All applications", isOn: $group.appliesToAllApps)
                if !group.appliesToAllApps {
                    AppListEditor(title: "Applications", bundleIDs: $group.includedBundleIDs)
                }
                AppListEditor(title: "Except", bundleIDs: $group.excludedBundleIDs)
                Toggle("Turn off global automations while this group is active", isOn: $group.disableGlobalTriggers)
            } header: {
                Text("Apps")
            } footer: {
                Text("App-specific automations win over groups; groups win over All Applications.")
                    .font(AOMType.caption).foregroundStyle(.secondary)
            }
            Section {
                ConditionsForm(conditions: conditions)
            } header: {
                Text("Only When")
            } footer: {
                Text(conditions.wrappedValue.isEmpty ? "No conditions: active whenever one of its apps is frontmost."
                     : "Active only while all of these hold: \(conditions.wrappedValue.summary).")
                    .font(AOMType.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConditionsForm: View {
    @Binding var conditions: ActivationConditions

    private var timeEnabled: Binding<Bool> {
        Binding(get: { conditions.timeWindow != nil },
                set: { conditions.timeWindow = $0 ? TriggerTimeWindow(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1080) : nil })
    }

    var body: some View {
        Toggle("Days and times", isOn: timeEnabled)
        if let window = conditions.timeWindow {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    let on = window.weekdays.contains(day)
                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                        get: { on },
                        set: { value in
                            var next = window
                            next.weekdays = value ? Array(Set(next.weekdays + [day])).sorted() : next.weekdays.filter { $0 != day }
                            conditions.timeWindow = next
                        }))
                    .toggleStyle(.button)
                }
            }
            HStack {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
        }
        Picker("Power", selection: Binding(get: { conditions.powerSource ?? "" },
                                          set: { conditions.powerSource = $0.isEmpty ? nil : $0 })) {
            Text("Any").tag("")
            Text("On Power Adapter").tag("ac")
            Text("On Battery").tag("battery")
        }
        Picker("Displays", selection: Binding(get: { displayChoice },
                                             set: { applyDisplayChoice($0) })) {
            Text("Any number").tag(0)
            Text("Built-in or one display").tag(1)
            Text("Two or more displays").tag(2)
        }
        Picker("While an app has a window", selection: Binding(get: { conditions.requiresWindowOfBundleID ?? "" },
                                                              set: { conditions.requiresWindowOfBundleID = $0.isEmpty ? nil : $0 })) {
            Text("No requirement").tag("")
            ForEach(Self.runningApps(including: conditions.requiresWindowOfBundleID), id: \.bundleID) { app in
                Text(app.name).tag(app.bundleID)
            }
        }
    }

    private var displayChoice: Int {
        switch (conditions.minimumDisplayCount, conditions.maximumDisplayCount) {
        case (nil, 1?): return 1
        case (2?, nil): return 2
        default: return 0
        }
    }

    private func applyDisplayChoice(_ choice: Int) {
        conditions.minimumDisplayCount = choice == 2 ? 2 : nil
        conditions.maximumDisplayCount = choice == 1 ? 1 : nil
    }

    private func minuteBinding(_ key: WritableKeyPath<TriggerTimeWindow, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = conditions.timeWindow?[keyPath: key] ?? 0
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            guard var window = conditions.timeWindow else { return }
            window[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            conditions.timeWindow = window
        })
    }

    static func runningApps(including bundleID: String?) -> [(name: String, bundleID: String)] {
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
        if let bundleID, !bundleID.isEmpty, !apps.contains(where: { $0.1 == bundleID }) { apps.append((bundleID, bundleID)) }
        return Array(Dictionary(apps.map { ($0.1, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, bundleID: $0.1) }
    }
}

/// A list of apps by bundle ID with add (Applications folder) and remove.
private struct AppListEditor: View {
    let title: String
    @Binding var bundleIDs: [String]

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 6) {
                        if let icon = AppMetadataCache.shared.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(Self.name(bundleID)).lineLimit(1)
                        Button { bundleIDs.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove \(Self.name(bundleID))")
                    }
                }
                Button("Add App…") { addApps() }
            }
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        bundleIDs = Array(NSOrderedSet(array: bundleIDs + added)) as? [String] ?? bundleIDs
    }

    static func name(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
