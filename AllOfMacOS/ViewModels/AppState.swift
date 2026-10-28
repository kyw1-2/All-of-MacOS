import Foundation
import SwiftUI
import Combine

enum AccentColorChoice: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, cyan
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.192, green: 0.510, blue: 0.965)
        case .purple: return Color(red: 0.68, green: 0.32, blue: 0.88)
        case .pink: return Color(red: 1.0, green: 0.18, blue: 0.47)
        case .red: return Color(red: 1.0, green: 0.23, blue: 0.19)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .yellow: return Color(red: 1.0, green: 0.80, blue: 0.0)
        case .green: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .cyan: return Color(red: 0.20, green: 0.68, blue: 0.90)
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var currentPreset: Preset
    @Published var selectedAppTarget: AppTarget
    @Published var selectedActivationGroupID: UUID?
    @Published var triggerSearch = ""
    @Published var triggerSortMode: TriggerSortMode = .manual
    @Published var selectedTriggerCategory: TriggerCategory = .all
    @Published var selectedTrigger: Trigger?
    @Published var selectedAction: TriggerAction?
    @Published var isRecordingShortcut: Bool = false
    @Published var showingAddTrigger: Bool = false
    @Published var showingAddAction: Bool = false
    @Published var showingAddApp: Bool = false
    /// The command palette over the main window (View ▸ Search…, sidebar search).
    @Published var showingCommandPalette = false
    @Published var selectedMainTab: AOMMainTab = .home {
        didSet {
            if selectedMainTab == .insights && !showStatistics {
                showStatistics = true
            } else if selectedMainTab != .insights && showStatistics {
                showStatistics = false
            }
        }
    }
    @Published var showStatistics: Bool = false {
        didSet {
            if showStatistics && selectedMainTab != .insights {
                selectedMainTab = .insights
            } else if !showStatistics && selectedMainTab == .insights {
                selectedMainTab = .gestures
            }
        }
    }
    @Published var showTutorialRequested: Bool = false
    @Published var globalEnabled: Bool = AutomationGate.isOn
    @Published var accentColorChoice: AccentColorChoice = {
        if let raw = UserDefaults.standard.string(forKey: "AOMAccentColor"),
           let choice = AccentColorChoice(rawValue: raw) {
            return choice
        }
        return .blue
    }()

    @Published private(set) var displayIDs = DisplayTopology.currentIDs
    @Published private(set) var snapMonitoring = false
    private var screenObserver: NSObjectProtocol?
    private var shortcutObservers: [NSObjectProtocol] = []
    private var screenRefresh: DispatchWorkItem?
    private var bindings: [String: MonitorBindings] = [:]
    private var snapSettings: SnapMonitorSettings?
    var activeSnapProfile: SnapLayoutProfile? {
        currentPreset.automaticSnapProfiles ? DisplayTopology.matching(currentPreset.snapProfiles, ids: displayIDs) : nil
    }
    var effectiveSnapZones: [CustomSnapZone] { activeSnapProfile?.zones ?? currentPreset.customSnapZones }
    var snapStatus: String {
        if !globalEnabled { return "Paused — AOM is off" }
        if !currentPreset.snappingEnabled { return "Off — layouts saved, not listening" }
        if effectiveSnapZones.allSatisfy({ !$0.isEnabled }) { return "On — no layouts enabled" }
        return snapMonitoring ? "Listening · \(effectiveSnapZones.filter(\.isEnabled).count) active layouts" : "Not listening — check Accessibility"
    }
    private let presetManager = PresetManager()
    let keyboardMonitor = KeyboardMonitor()
    private let trackpadMonitor = TrackpadMonitor()
    private let mouseButtonMonitor = MouseButtonMonitor()
    private let snapZoneMonitor = CustomSnapZoneMonitor()
    private let drawingMonitor = DrawingGestureMonitor()
    private let systemTriggerMonitor = SystemTriggerMonitor()
    let updateChecker = UpdateChecker()
    private let permissionWatchdog = PermissionWatchdog()

    init() {
        let preset = PresetManager.loadPreset() ?? Preset(name: "Master Preset", isMaster: true)
        self.currentPreset = preset
        self.selectedAppTarget = preset.appTargets.first ?? .allApps
        NSLog("[AOM] Loaded preset with %d triggers", preset.triggers.count)
        // Create a backup on startup so there's always a recent copy
        if preset.triggers.count > 0 {
            presetManager.save(preset)
        }
        // Isolated UI previews can open on a given page (`--aom-preview-tab <1-8>`,
        // sidebar order), so screens are reviewed without driving the window with key events.
        if PresetManager.isUIPreview, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--aom-preview-tab"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let number = Int(ProcessInfo.processInfo.arguments[index + 1]), AOMMainTab.allCases.indices.contains(number - 1) {
            selectedMainTab = AOMMainTab.allCases[number - 1]
        }
        if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-palette") {
            showingCommandPalette = true
        }
        // Schedule monitor start for next runloop iteration (self must be fully initialized first)
        // Skip automatic monitoring when running inside the unit-test host
        guard NSClassFromString("XCTestCase") == nil, !PresetManager.isUIPreview else { return }
        // Re-register every event tap once Accessibility is granted again, so gestures
        // resume without an app restart.
        permissionWatchdog.onRecovered = { [weak self] in
            self?.refreshMonitors(force: true)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenRefresh?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.displayIDs = DisplayTopology.currentIDs
                    self.refreshMonitors()
                }
                self.screenRefresh = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
            }
        }
        for name in [ClipboardShortcuts.didChange, Notification.Name("AOMCaptureShortcutsDidChange"),
                     TitleBarWindowSnap.hotkeysDidChange] {
            shortcutObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.keyboardMonitor.registerTriggers(self.globalEnabled ? self.currentPreset.triggers.filter(\.isEnabled) : [], groups: self.currentPreset.activationGroups)
                }
            })
        }
        // The title-bar snap, top-bar Space swipe and Dock pinch read the
        // trackpad stream even with no trackpad trigger. When a setting flips
        // whether anything needs that stream, re-register so the hardware
        // starts or stops now rather than at the next launch.
        shortcutObservers.append(NotificationCenter.default.addObserver(forName: .aomSettingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrackpadLayersIfNeeded() }
        })
        DispatchQueue.main.async {
            self.permissionWatchdog.start()
            self.startMonitoring()
        }
    }

    func startMonitoring() {
        NSLog("[AOM] startMonitoring called")
        refreshMonitors()
    }

    /// Last known answer to "does anything besides trackpad triggers need the
    /// trackpad stream?", so unrelated setting changes cost nothing.
    private var trackpadLayersNeeded: Bool?

    func refreshTrackpadLayersIfNeeded() {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        let needed = TrackpadUtilityGestures.shared.anyLayerEnabled
        guard needed != trackpadLayersNeeded else { return }
        trackpadLayersNeeded = needed
        trackpadMonitor.registerTriggers(globalEnabled ? currentPreset.triggers.filter(\.isEnabled) : [],
                                         groups: currentPreset.activationGroups)
    }

    /// Scope remains independent from the selected category. `All` is a view
    /// over the same persisted triggers, never a separate trigger scope.
    func triggers(in category: TriggerCategory) -> [Trigger] {
        currentPreset.overviewTriggers(for: selectedAppTarget,
                                       groupID: selectedActivationGroupID,
                                       category: category)
    }
    var currentTriggers: [Trigger] { triggers(in: selectedTriggerCategory) }

    var isSearchingTriggers: Bool { !triggerSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayedTriggers: [Trigger] {
        let source = isSearchingTriggers ? currentPreset.triggers.filter {
            TriggerListQuery.matches($0, query: triggerSearch, preset: currentPreset)
        } : currentTriggers
        return TriggerListQuery.sorted(source, mode: triggerSortMode)
    }
    func canMoveTrigger(_ trigger: Trigger, offset: Int) -> Bool {
        !isSearchingTriggers && triggerSortMode == .manual && currentPreset.canMoveTrigger(trigger.id, offset: offset)
    }
    func moveTrigger(_ trigger: Trigger, offset: Int) {
        guard canMoveTrigger(trigger, offset: offset), currentPreset.moveTrigger(trigger.id, offset: offset) else { return }
        selectedTrigger = currentPreset.triggers.first { $0.id == trigger.id }; save()
    }
    func toggleFavorite(_ trigger: Trigger) {
        guard var latest = currentPreset.triggers.first(where: { $0.id == trigger.id }) else { return }
        latest.isFavorite.toggle(); updateTrigger(latest)
    }
    func presentPresetExport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = currentPreset.name + ".json"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.exportPreset(to: url) }
        }
    }
    func presentPresetImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.reviewCompatiblePresetImport(from: url) }
        }
    }

    // MARK: - App Target Management

    func addAppTarget(_ app: AppTarget) {
        if !currentPreset.appTargets.contains(where: { $0.bundleID == app.bundleID }) {
            currentPreset.appTargets.append(app)
            save()
        }
    }

    func removeAppTarget(_ app: AppTarget) {
        guard !app.isGlobal else { return }
        currentPreset.appTargets.removeAll { $0.id == app.id }
        currentPreset.triggers.removeAll { $0.appBundleID == app.bundleID }
        if selectedAppTarget.id == app.id {
            selectedAppTarget = .allApps
        }
        save()
    }

    // MARK: - Conditional Activation Groups

    func addActivationGroup(name: String) -> UUID {
        let group = ActivationGroup(name: name)
        currentPreset.activationGroups.append(group)
        save()
        return group.id
    }

    func addActivationGroup(_ group: ActivationGroup) {
        guard !currentPreset.activationGroups.contains(where: { $0.id == group.id }) else { return }
        currentPreset.activationGroups.append(group)
        selectedActivationGroupID = group.id
        save()
    }

    func updateActivationGroup(_ group: ActivationGroup) {
        guard let index = currentPreset.activationGroups.firstIndex(where: { $0.id == group.id }) else { return }
        currentPreset.activationGroups[index] = group
        save()
    }

    func removeActivationGroup(_ id: UUID) {
        currentPreset.activationGroups.removeAll { $0.id == id }
        // Never promote group-only shortcuts into global shortcuts on deletion.
        // Delete their group membership by deleting the bound triggers, explicitly.
        currentPreset.triggers.removeAll { $0.activationGroupID == id }
        if selectedActivationGroupID == id { selectedActivationGroupID = nil }
        selectedTrigger = nil; selectedAction = nil
        save()
    }

    // MARK: - Custom Snap Zones

    func setSnappingEnabled(_ enabled: Bool) {
        if enabled && activeSnapProfile == nil && currentPreset.customSnapZones.isEmpty {
            currentPreset.customSnapZones = CustomSnapZone.Collection.complete.addingMissing(to: [])
        }
        currentPreset.snappingEnabled = enabled
        save()
    }
    func updateSnapSettings(zones: [CustomSnapZone], enabled: Bool, requiresOption: Bool, showsPreview: Bool, profileID: UUID? = nil) {
        guard zones.count <= 32, Set(zones.map(\.id)).count == zones.count, zones.allSatisfy(\.isValid) else { return }
        if let profileID {
            guard let index = currentPreset.snapProfiles.firstIndex(where: { $0.id == profileID }) else { return }
            currentPreset.snapProfiles[index].zones = zones
            currentPreset.snapProfiles[index].requiresOption = requiresOption
            currentPreset.snapProfiles[index].showsPreview = showsPreview
        } else {
            currentPreset.customSnapZones = zones
            currentPreset.snappingRequiresOption = requiresOption
            currentPreset.snappingShowsPreview = showsPreview
        }
        currentPreset.snappingEnabled = enabled
        save()
    }
    func updateSnapZones(_ zones: [CustomSnapZone]) {
        guard zones.count <= 32, Set(zones.map(\.id)).count == zones.count,
              zones.allSatisfy(\.isValid) else { return }
        currentPreset.customSnapZones = zones
        save()
    }

    @discardableResult
    func saveDisplayProfile(name: String) -> Bool {
        let ids = DisplayTopology.currentIDs
        var profile = SnapLayoutProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), displayIDs: ids,
            zones: effectiveSnapZones, requiresOption: activeSnapProfile?.requiresOption ?? currentPreset.snappingRequiresOption,
            showsPreview: activeSnapProfile?.showsPreview ?? currentPreset.snappingShowsPreview)
        guard profile.isValid else { return false }
        if let index = currentPreset.snapProfiles.firstIndex(where: { $0.displayIDs.sorted() == ids }) {
            profile.id = currentPreset.snapProfiles[index].id
            currentPreset.snapProfiles[index] = profile
        } else {
            guard currentPreset.snapProfiles.count < 16 else { return false }
            currentPreset.snapProfiles.append(profile)
        }
        currentPreset.automaticSnapProfiles = true; displayIDs = ids; save(); return true
    }
    func removeDisplayProfile(_ id: UUID) { currentPreset.snapProfiles.removeAll { $0.id == id }; save() }
    func setAutomaticSnapProfiles(_ enabled: Bool) { currentPreset.automaticSnapProfiles = enabled; save() }

    // MARK: - Trigger Management

    func addTrigger(_ trigger: Trigger) {
        currentPreset.addTrigger(trigger)
        selectedTrigger = currentPreset.triggers.first { $0.id == trigger.id }
        save()
    }

    func removeTrigger(_ trigger: Trigger) {
        currentPreset.removeTrigger(id: trigger.id)
        if selectedTrigger?.id == trigger.id {
            selectedTrigger = nil
            selectedAction = nil
        }
        save()
    }

    func updateTrigger(_ trigger: Trigger) {
        currentPreset.updateTrigger(trigger)
        selectedTrigger = trigger
        save()
    }

    func toggleTrigger(_ trigger: Trigger) {
        var updated = trigger
        updated.isEnabled.toggle()
        updateTrigger(updated)
    }

    /// Sets a trigger's enabled state by id, for callers that hold the id rather
    /// than the value — the status menu is rebuilt per open, so it cannot keep a
    /// `Trigger` across clicks. An unknown id is ignored rather than creating a
    /// trigger, since the menu may have been built before a preset change.
    func setTriggerEnabled(_ enabled: Bool, triggerID: UUID) {
        guard var trigger = currentPreset.triggers.first(where: { $0.id == triggerID }),
              trigger.isEnabled != enabled else { return }
        trigger.isEnabled = enabled
        updateTrigger(trigger)
    }

    // MARK: - Action Management

    private func latest(_ trigger: Trigger) -> Trigger { currentPreset.triggers.first { $0.id == trigger.id } ?? trigger }

    func addAction(to trigger: Trigger, action: TriggerAction, parentID: UUID? = nil, toElse: Bool = false) {
        var updated = latest(trigger)
        if let parentID {
            guard ActionTree.edit(&updated.actions, id: parentID, change: { list, i in
                guard list[i].actionType.canContainChildren else { return }
                if toElse && list[i].actionType.canContainElseChildren {
                    list[i].parameters.elseChildren = (list[i].parameters.elseChildren ?? []) + [action]
                } else {
                    list[i].parameters.children = (list[i].parameters.children ?? []) + [action]
                }
            }) else { return }
        } else { updated.actions.append(action) }
        guard ActionTree.problem(updated.actions) == nil else { return }
        updateTrigger(updated); selectedAction = action
    }

    func removeAction(from trigger: Trigger, action: TriggerAction) {
        var updated = latest(trigger)
        _ = ActionTree.edit(&updated.actions, id: action.id) { list, i in list.remove(at: i) }
        updateTrigger(updated)
        if let selected = selectedAction, !ActionTree.rows(updated.actions).contains(where: { $0.id == selected.id }) { selectedAction = nil }
    }

    func updateAction(in trigger: Trigger, action: TriggerAction) {
        var updated = latest(trigger)
        _ = ActionTree.edit(&updated.actions, id: action.id) { list, i in list[i] = action }
        updateTrigger(updated); selectedAction = action
    }

    func duplicateAction(in trigger: Trigger, action: TriggerAction) {
        var updated = latest(trigger); let copy = ActionTree.duplicate(action)
        _ = ActionTree.edit(&updated.actions, id: action.id) { list, i in list.insert(copy, at: i + 1) }
        guard ActionTree.problem(updated.actions) == nil else { return }
        updateTrigger(updated); selectedAction = copy
    }

    func moveAction(in trigger: Trigger, action: TriggerAction, offset: Int) {
        var updated = latest(trigger)
        _ = ActionTree.edit(&updated.actions, id: action.id) { list, i in
            let destination = i + offset
            if list.indices.contains(destination) { list.swapAt(i, destination) }
        }
        updateTrigger(updated)
    }

    func reparentAction(in trigger: Trigger, action: TriggerAction, parentID: UUID?) {
        if let parentID, ActionTree.rows([action]).contains(where: { $0.id == parentID }) { return }
        var updated = latest(trigger)
        guard ActionTree.edit(&updated.actions, id: action.id, change: { list, i in list.remove(at: i) }) else { return }
        if let parentID {
            guard ActionTree.edit(&updated.actions, id: parentID, change: { list, i in
                guard list[i].actionType.canContainChildren else { return }
                list[i].parameters.children = (list[i].parameters.children ?? []) + [action]
            }) else { return }
        } else { updated.actions.append(action) }
        guard ActionTree.problem(updated.actions) == nil else { return }
        updateTrigger(updated); selectedAction = action
    }

    func moveActions(in trigger: Trigger, from source: IndexSet, to destination: Int) {
        var updated = latest(trigger); updated.actions.move(fromOffsets: source, toOffset: destination); updateTrigger(updated)
    }

    // MARK: - Monitor Registration

    func toggleGlobalEnabled() {
        globalEnabled.toggle()
        if !globalEnabled { ActionExecutor.cancelAllSequences() }
        UserDefaults.standard.set(globalEnabled, forKey: AutomationGate.masterSwitchKey)
        refreshMonitors()
        // With no trackpad triggers the bindings above do not change, but the
        // gesture layers must still release (or re-acquire) the hardware.
        refreshTrackpadLayersIfNeeded()
        TitleBarWindowSnap.shared.refreshEnabled()
    }

    func refreshMonitors(force: Bool = false) {
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { return }
        if globalEnabled { ClipboardStore.shared.start() } else { ClipboardStore.shared.stop() }
        let all = globalEnabled ? currentPreset.triggers.filter(\.isEnabled) : []
        let groups = currentPreset.activationGroups
        func changed(_ key: String, _ category: TriggerCategory? = nil) -> Bool {
            let value = MonitorBindings(all, groups: groups, category: category)
            let needsUpdate = force || bindings[key] != value
            bindings[key] = value
            return needsUpdate
        }
        if changed("actions") { ActionExecutor.registerTriggers(all, groups: groups) }
        if changed("keyboard", .keyboard) { keyboardMonitor.registerTriggers(all, groups: groups) }
        if changed("trackpad", .trackpad) {
            trackpadMonitor.registerTriggers(all, groups: groups)
            trackpadLayersNeeded = TrackpadUtilityGestures.shared.anyLayerEnabled
        }
        if changed("mouse", .normalMouse) { mouseButtonMonitor.registerTriggers(all, groups: groups) }
        if changed("drawing", .drawings) { drawingMonitor.registerTriggers(all, groups: groups) }
        if changed("system", .otherTriggers) { systemTriggerMonitor.registerTriggers(all, groups: groups) }
        let snap = SnapMonitorSettings(zones: globalEnabled && currentPreset.snappingEnabled ? effectiveSnapZones : [],
            requiresOption: activeSnapProfile?.requiresOption ?? currentPreset.snappingRequiresOption,
            showsPreview: activeSnapProfile?.showsPreview ?? currentPreset.snappingShowsPreview, displayIDs: displayIDs)
        if force || snapSettings != snap {
            snapZoneMonitor.registerZones(snap.zones, requiresOption: snap.requiresOption, showsPreview: snap.showsPreview)
            snapSettings = snap
        }
        snapMonitoring = snapZoneMonitor.isMonitoring
    }

    deinit {
        for observer in shortcutObservers { NotificationCenter.default.removeObserver(observer) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenRefresh?.cancel()
        // A debounced save must not outlive its state: it would land later
        // and overwrite whatever another owner wrote since (seen between test
        // cases sharing the isolated preset file).
        presetManager.flushPendingWrites()
    }

    // MARK: - Persistence

    func save() {
        refreshMonitors()
        presetManager.scheduleSave(currentPreset)
    }

    func flushPendingWrites() { presetManager.flushPendingWrites() }

    /// The last preset save failure, nil once a save succeeds.
    var lastPresetSaveError: String? { presetManager.lastPersistError }

    /// How an export, import or restore went.
    enum PresetOperationStyle: Equatable {
        case success
        /// It worked, and the user has to do something (relaunch).
        case actionNeeded
        case failure
    }

    /// Export, import and restore report their outcome; until 3.3.1 a
    /// failure only reached the console (audit 2026-10-28 F07). A failure or
    /// an instruction is an alert; a plain success is a HUD notice long
    /// enough to read.
    var presetOperationReporter: (_ title: String, _ detail: String, _ style: PresetOperationStyle) -> Void = { title, detail, style in
        guard !PresetManager.isRunningTests else { return }
        guard style != .success else {
            GestureHUD.shared.show(title: title, detail: detail)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = style == .failure ? .warning : .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @discardableResult
    func exportPreset(to url: URL) -> Bool {
        do {
            try presetManager.exportPreset(currentPreset, to: url)
            presetOperationReporter("Preset Exported", url.lastPathComponent, .success)
            return true
        } catch {
            presetOperationReporter("Could Not Export the Preset", error.localizedDescription, .failure)
            return false
        }
    }

    @discardableResult
    func importPreset(from url: URL) -> Bool {
        let failure = "Could Not Import the Preset"
        let preset: Preset
        do { preset = try presetManager.importPreset(from: url) }
        catch {
            presetOperationReporter(failure, error.localizedDescription, .failure)
            return false
        }
        guard let kept = replaceCurrentPreset(with: preset, reason: "before-import", rollingBackup: true, failure: failure) else {
            return false
        }
        presetOperationReporter("Preset Imported",
                                "What it replaced is kept in Settings › Backups as \(kept.lastPathComponent).", .success)
        return true
    }

    /// Restores a rolling backup or a safety snapshot as the current preset,
    /// optionally with the settings saved alongside it.
    ///
    /// Everything is read before anything changes: until the review of
    /// 3.3.1 the restored preset was saved first, which wrote a rolling
    /// backup that pruned the oldest one, so restoring the oldest backup of a
    /// full set deleted it, and its settings, before they were read. Now the
    /// preset and settings are read into memory, the current automations and
    /// settings are kept as a `-before-restore` snapshot (nothing is replaced
    /// if that fails, and the chosen backup is never pruned to make room),
    /// and the restored preset is saved without a rolling backup of its own.
    @discardableResult
    func restorePresetBackup(_ url: URL, includeSettings: Bool = false, defaults: UserDefaults = .standard) -> Bool {
        let failure = "Could Not Restore the Backup"
        let preset: Preset
        do { preset = try presetManager.importPreset(from: url) }
        catch {
            presetOperationReporter(failure, "\(error.localizedDescription) Nothing was changed.", .failure)
            return false
        }
        var settings: PresetManager.SettingsSnapshot?
        if includeSettings {
            guard let read = PresetManager.readSettings(fromFile: PresetManager.settingsURL(forBackup: url)) else {
                presetOperationReporter(failure, "This backup has no readable settings file. Nothing was changed.", .failure)
                return false
            }
            settings = read
        }
        guard let kept = replaceCurrentPreset(with: preset, reason: "before-restore", rollingBackup: false,
                                              failure: failure, settings: defaults, protecting: url) else { return false }
        guard let settings else {
            presetOperationReporter("Backup Restored",
                                    "What it replaced is kept in Settings › Backups as \(kept.lastPathComponent).", .success)
            return true
        }
        let applied = settings.apply(to: defaults)
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        let count = applied.set + applied.removed
        presetOperationReporter("Backup Restored",
                                "Automations and \(count) setting\(count == 1 ? "" : "s") restored. What they replaced, "
                                + "automations and settings, is kept in Settings › Backups as \(kept.lastPathComponent).\n\n"
                                + "Quit and reopen All of MacOS so every part uses the restored settings. "
                                + "Whether automation is paused is not part of a backup and did not change.", .actionNeeded)
        return true
    }

    /// Keeps the current preset and settings as a safety snapshot, then makes
    /// `preset` current. Returns the snapshot; nothing is replaced, and nil
    /// is returned, when the snapshot cannot be written.
    private func replaceCurrentPreset(with preset: Preset, reason: String, rollingBackup: Bool, failure: String,
                                      settings defaults: UserDefaults = .standard, protecting: URL? = nil) -> URL? {
        guard let kept = presetManager.snapshotBeforeReplacing(currentPreset, reason: reason, settings: defaults,
                                                               protecting: protecting) else {
            presetOperationReporter(failure, "A copy of the current automations could not be kept in the backup folder "
                                    + "(\(PresetManager.backupDirectory.path)), so nothing was changed.", .failure)
            return nil
        }
        ActionExecutor.cancelAllSequences()
        currentPreset = preset
        presetManager.save(preset, createBackup: rollingBackup && PresetManager.backupsEnabled)
        refreshMonitors()
        selectedAppTarget = preset.appTargets.first ?? .allApps
        selectedTrigger = nil
        selectedAction = nil
        selectedActivationGroupID = nil
        if let error = presetManager.lastPersistError {
            presetOperationReporter(failure, "The preset is active but could not be saved: \(error)", .failure)
            return nil
        }
        return kept
    }
}
