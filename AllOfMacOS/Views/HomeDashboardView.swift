import AppKit
import SwiftUI

// MARK: - Workspace

/// The Workspace (ux-refs-3.3.3 §d.1–d.5): status first.
///
/// 1. Hero: one sentence that says whether AOM is working (running, paused,
///    needs a permission, or first-run setup), one primary action and the
///    permission chips. A recording in progress adds a strip under it.
/// 2. Needs attention, only when something needs you: Fix now → Upcoming →
///    Suggestions, one sentence and one verb button per row.
/// 3. Module tiles: one live value, one status line and one control each;
///    clicking a tile opens its page.
/// 4. Quick actions: capture, record, copy text, clipboard history and the
///    automations you pinned.
/// 5. Recent activity: the last runs, captures and copies; View All opens
///    Insights.
///
/// Every value comes from state the app already publishes (AppState and the
/// module services); every control calls the same code as its page.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var stats = GestureStatistics.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var recording = ScreenRecordingService.shared
    @ObservedObject private var audio = AppAudioMixerService.shared
    @ObservedObject private var keepAwake = KeepAwakeService.shared
    @StateObject private var toast = AOMToastModel()
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?
    @State private var suppressionPaused = false
    @State private var suppressionDescription: String?
    @State private var titleBarSnapOn = false
    @State private var outputDevice: String?
    @State private var runStates: [UUID: AOMRunState] = [:]
    /// "Skip for Now" on the setup checklist lives in scene storage, not
    /// @State: the page is rebuilt on every tab switch, and a skipped setup
    /// must not come back when you return to Workspace. Dismissed suggestions
    /// stay session-only.
    @SceneStorage("workspace.setupSkipped") private var setupSkipped = false
    @State private var dismissedSuggestions: Set<String> = []
    @State private var showsAllAttention = false

    static let maximumContentWidth: CGFloat = AOMSize.contentMaxWidth
    static let attentionLimit = 3
    static let recentLimit = 5

    private var triggers: [Trigger] { appState.currentPreset.triggers }
    private var pinned: [Trigger] { triggers.filter(\.isFavorite) }

    /// When each trigger last ran, from the statistics log. Inputs record
    /// their display name (the unnamed trigger's input name) when they fire.
    private var lastRuns: [UUID: Date] {
        var latestByInput: [String: Date] = [:]
        for event in stats.events where event.fired {
            if (latestByInput[event.gesture] ?? .distantPast) < event.timestamp { latestByInput[event.gesture] = event.timestamp }
        }
        var result: [UUID: Date] = [:]
        for trigger in triggers {
            if let date = latestByInput[trigger.input.displayName] { result[trigger.id] = date }
        }
        return result
    }

    var body: some View {
        let snapshot = WorkspaceSnapshot(home: self)
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                hero(snapshot)
                if !snapshot.attention.isEmpty {
                    needsAttention(snapshot.attention)
                }
                modules(snapshot)
                quickActions
                recentActivity(snapshot.recent)
            }
            .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.top, AOMSpace.x4)
            .padding(.bottom, AOMSpace.x8)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
        .aomScrollEdge()
        .background(AOMColor.canvas)
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newAutomation) {
                    Label("New Automation", systemImage: "plus")
                }
                .help("New Automation (⌘N)")
            }
        }
        // ⌘N and ⌘F work from the Workspace too: they open the Automation page.
        .focusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { appState.selectedMainTab = .gestures },
            newTrigger: newAutomation))
        .task {
            while !Task.isCancelled {
                refreshStatus()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .aomToast(toast.message)
    }

    /// Polled state that nothing publishes (permissions, Paste's shortcut,
    /// the timed pause, the title-bar snap switch, the output device).
    private func refreshStatus() {
        let current = AOMPermission.required.map { ($0, $0.status) }
        if current.map(\.0) != permissions.map(\.0) || current.map(\.1) != permissions.map(\.1) { permissions = current }
        let conflict = ShortcutConflicts.clipboardHistoryConflict()
        if conflict != shortcutConflict { shortcutConflict = conflict }
        let suppression = TriggerSuppression.shared
        let paused = suppression.isPaused
        if paused != suppressionPaused { suppressionPaused = paused }
        let description = paused ? suppression.statusDescription : nil
        if description != suppressionDescription { suppressionDescription = description }
        let titleBar = UserDefaults.standard.bool(forKey: TitleBarWindowSnap.enabledKey)
        if titleBar != titleBarSnapOn { titleBarSnapOn = titleBar }
        let currentID = AudioOutputService.currentDeviceID()
        let device = AudioOutputService.devices().first { $0.id == currentID }?.name
        if device != outputDevice { outputDevice = device }
    }

    private func newAutomation() {
        appState.selectedMainTab = .gestures
        appState.showingAddTrigger = true
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ snapshot: WorkspaceSnapshot) -> some View {
        WorkspaceHero(state: snapshot.hero, chips: snapshot.chips, toast: toast) {
            heroAction(snapshot.hero)
        } strip: {
            if recording.isRecording { recordingStrip }
        } checklist: {
            if case .setup = snapshot.hero { setupChecklist(snapshot) }
        }
    }

    @ViewBuilder
    private func heroAction(_ state: WorkspaceHeroState) -> some View {
        switch state {
        case .running:
            Button { appState.toggleGlobalEnabled() } label: {
                Label("Pause AOM", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Pause every gesture, shortcut, snap and clipboard capture")
        case .paused:
            Button(action: resumeAOM) {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .blocked(let permission, _):
            Button("Allow \(permission.shortTitle)…") { _ = permission.openSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .setup:
            Button("Skip for Now") { withAnimation(AOMMotion.standard) { setupSkipped = true } }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private func resumeAOM() {
        if !appState.globalEnabled { appState.toggleGlobalEnabled() }
        if suppressionPaused { TriggerSuppression.shared.resume(); suppressionPaused = false }
    }

    private var recordingStrip: some View {
        HStack(spacing: AOMSpace.x2) {
            WorkspaceRecordingGlyph(paused: recording.isPaused)
            Text(recording.isPaused ? "Recording paused" : "Recording screen")
                .font(AOMFont.bodyEmphasis)
            Text(Self.elapsed(recording.elapsedSeconds))
                .font(AOMFont.body.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
            Spacer(minLength: AOMSpace.x2)
            Button(recording.isPaused ? "Resume" : "Pause") { recording.togglePause() }
                .buttonStyle(.bordered)
            Button {
                Task {
                    _ = try? await recording.stopRecording()
                    toast.show("Recording saved")
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AOMColor.recording)
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(minHeight: AOMSize.rowDetail - AOMSpace.x1)
        .background(AOMTone.recording.wash(increasedContrast: false), in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording, \(Self.elapsed(recording.elapsedSeconds))")
    }

    static func elapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private func setupChecklist(_ snapshot: WorkspaceSnapshot) -> some View {
        let accessibility = snapshot.status(.accessibility)
        let screen = snapshot.status(.screenRecording)
        VStack(spacing: 0) {
            WorkspaceSetupStep(number: 1, title: "Allow Accessibility",
                               detail: "Lets gestures and shortcuts move windows and press keys.",
                               done: accessibility == .granted) {
                Button("Allow…") { _ = AOMPermission.accessibility.openSettings() }
            }
            WorkspaceSetupStep(number: 2, title: "Allow Screen Recording",
                               detail: "Needed only for Capture and Record.",
                               done: screen == .granted) {
                Button("Allow…") { _ = AOMPermission.screenRecording.openSettings() }
            }
            WorkspaceSetupStep(number: 3, title: "Create your first automation",
                               detail: "Connect a gesture, key or mouse button to an action.",
                               done: !triggers.isEmpty) {
                Button("New Automation", action: newAutomation)
            }
        }
        .background(AOMColor.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        HStack(spacing: AOMSpace.x2) {
            Button("Show the Tour") { appState.showTutorialRequested = true }
                .buttonStyle(.link)
            Text("You can reopen it from Help › Show Welcome Again.")
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
        }
    }

    // MARK: Needs attention

    private func needsAttention(_ items: [WorkspaceAttention]) -> some View {
        let shown = showsAllAttention ? items : Array(items.prefix(Self.attentionLimit))
        return AOMSection("Needs attention", detail: "\(items.count)") {
            if items.count > Self.attentionLimit {
                Button(showsAllAttention ? "Show Less" : "Show All (\(items.count))") {
                    withAnimation(AOMMotion.standard) { showsAllAttention.toggle() }
                }
                .buttonStyle(.link)
                .font(AOMFont.callout)
            }
        } content: {
            ForEach(shown) { item in
                WorkspaceAttentionRow(item: item) {
                    withAnimation(AOMMotion.standard) { _ = dismissedSuggestions.insert(item.id) }
                }
            }
        }
        .accessibilityLabel("Needs attention")
    }

    /// Fix now → Upcoming → Suggestions (d.3). The permission the hero's
    /// primary action already fixes is not repeated here.
    fileprivate func attentionItems(hero: WorkspaceHeroState) -> [WorkspaceAttention] {
        var items: [WorkspaceAttention] = []
        let missing = permissions.filter { $0.1 == .denied || $0.1 == .notDetermined }.map(\.0)
        for permission in missing {
            if case .blocked(let first, _) = hero, first == permission { continue }
            if case .setup = hero, permission == .accessibility || permission == .screenRecording { continue }
            items.append(WorkspaceAttention(id: "permission.\(permission.rawValue)", kind: .fixNow, tone: .warning,
                                            text: permission.attentionSentence,
                                            actionTitle: "Allow…") { _ = permission.openSettings() })
        }
        if let conflict = shortcutConflict {
            let alternative = ShortcutConflicts.alternativeHistoryShortcut
            items.append(WorkspaceAttention(
                id: "conflict.history", kind: .fixNow, tone: .warning,
                text: "\(conflict.shortcut.displayString) is also used by \(conflict.appName). Clipboard History may not open with it.",
                actionTitle: "Use \(alternative.displayString)") {
                    ClipboardShortcuts.shared.setShortcut(alternative, for: .history)
                    shortcutConflict = nil
                })
        }
        if let warning = clipboard.storageWarning {
            items.append(WorkspaceAttention(id: "clipboard.storage", kind: .fixNow, tone: .danger,
                                            text: "Clipboard history isn't being saved. \(warning)",
                                            actionTitle: "Try Again") { Task { await clipboard.recoverStorage() } })
        }
        if clipboard.paused && clipboard.pauseRemainingSeconds > 0 {
            let minutes = max(1, Int((Double(clipboard.pauseRemainingSeconds) / 60).rounded(.up)))
            items.append(WorkspaceAttention(id: "clipboard.timedPause", kind: .upcoming, tone: .info,
                                            text: "Clipboard history resumes in \(minutes) min.",
                                            actionTitle: "Resume Now") { clipboard.resume() })
        }
        if keepAwake.isActive, let ends = keepAwake.endsAt {
            items.append(WorkspaceAttention(id: "keepAwake.ends", kind: .upcoming, tone: .info,
                                            text: "Keep Awake ends at \(ends.formatted(date: .omitted, time: .shortened)).",
                                            actionTitle: "Turn Off") { keepAwake.stop() })
        }
        if case .setup = hero {} else if triggers.isEmpty {
            items.append(WorkspaceAttention(id: "suggest.automation", kind: .suggestion, tone: .info,
                                            text: "No automations yet. Connect a gesture, key or mouse button to an action.",
                                            actionTitle: "New Automation", action: newAutomation))
        }
        if !appState.currentPreset.snappingEnabled && !titleBarSnapOn {
            items.append(WorkspaceAttention(id: "suggest.tiling", kind: .suggestion, tone: .info,
                                            text: "Window Tiling is off. Turn on Drag to Snap to place windows by dragging them to an edge.",
                                            actionTitle: "Turn On") { appState.setSnappingEnabled(true) })
        }
        return items
            .filter { $0.kind != .suggestion || !dismissedSuggestions.contains($0.id) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: Modules

    private func modules(_ snapshot: WorkspaceSnapshot) -> some View {
        // Three columns at the default window size (two rows of three), two
        // in narrow windows or beside the diagnostics drawer.
        let columns = gridWidth >= 3 * AOMSize.tileMin + 2 * AOMSpace.tileGap ? 3 : 2
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Modules")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.tileGap, alignment: .top), count: columns),
                      alignment: .leading, spacing: AOMSpace.tileGap) {
                ForEach(AOMModule.allCases) { module in
                    tile(module, snapshot)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: WorkspaceGridWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(WorkspaceGridWidthKey.self) { width in
                if abs(width - gridWidth) > 1 { gridWidth = width }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modules")
    }

    @State private var gridWidth: CGFloat = 900
    static let tileHeight: CGFloat = 128

    @ViewBuilder
    private func tile(_ module: AOMModule, _ snapshot: WorkspaceSnapshot) -> some View {
        let globalPaused = !appState.globalEnabled
        switch module {
        case .automation:
            let enabled = triggers.filter(\.isEnabled).count
            let latest = snapshot.lastRun
            AOMModuleTile(.automation,
                          value: triggers.isEmpty ? "No automations yet" : "\(triggers.count) automation\(triggers.count == 1 ? "" : "s")",
                          status: globalPaused ? "Paused" : (triggers.isEmpty ? "Create one to get started"
                              : "\(enabled) on" + (latest.map { " · last run \(AOMRelativeTime.string($0).lowercased())" } ?? "")),
                          statusTone: globalPaused ? .neutral : nil,
                          active: !globalPaused && enabled > 0,
                          open: { appState.selectedMainTab = .gestures }) {
                if triggers.isEmpty {
                    Button("Create…", action: newAutomation).buttonStyle(.bordered).controlSize(.small)
                } else {
                    WorkspaceTileChevron()
                }
            }
            .frame(height: Self.tileHeight)
        case .tiling:
            let zones = appState.effectiveSnapZones.filter(\.isEnabled).count
            let drag = appState.currentPreset.snappingEnabled
            let parts = [drag ? "Drag to snap" : nil, titleBarSnapOn ? "title-bar swipes" : nil].compactMap { $0 }
            AOMModuleTile(.tiling,
                          value: "\(zones) snap area\(zones == 1 ? "" : "s")",
                          status: globalPaused ? "Paused" : (parts.isEmpty ? "Off — windows move freely" : parts.joined(separator: " · ") + " on"),
                          statusTone: globalPaused ? .neutral : nil,
                          active: !globalPaused && (drag || titleBarSnapOn),
                          open: { appState.selectedMainTab = .snapping }) {
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                     set: { appState.setSnappingEnabled($0) }))
                    .disabled(globalPaused)
                    .help("Drag to Snap: place windows by dragging them to an edge, corner or snap area")
            }
            .frame(height: Self.tileHeight)
        case .capture:
            let today = Calendar.current.startOfDay(for: Date())
            let count = history.entries.filter { $0.capturedAt >= today }.count
            let needsSetup = snapshot.status(.screenRecording) != .granted && snapshot.status(.screenRecording) != nil
            AOMModuleTile(.capture,
                          value: "\(count) today",
                          status: recording.isRecording ? "Recording · \(Self.elapsed(recording.elapsedSeconds))"
                              : (needsSetup ? "Needs Screen Recording"
                                 : (history.entries.first.map { "Last: \($0.kind.displayName) · \(AOMRelativeTime.string($0.capturedAt).lowercased())" }
                                    ?? "No captures yet")),
                          statusTone: recording.isRecording ? .recording : (needsSetup ? .warning : nil),
                          active: !needsSetup,
                          running: recording.isRecording,
                          open: { appState.selectedMainTab = .capture }) {
                if recording.isRecording {
                    Button {
                        Task { _ = try? await recording.stopRecording(); toast.show("Recording saved") }
                    } label: { Label("Stop Recording", systemImage: "stop.fill") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .help("Stop Recording")
                } else if needsSetup {
                    Button("Set Up…") { _ = AOMPermission.screenRecording.openSettings() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { CaptureCoordinator.shared.captureArea() } label: {
                        Label("Capture Area", systemImage: "viewfinder")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Capture Area" + (captureKeys(.captureArea).map { " (\($0))" } ?? ""))
                }
            }
            .frame(height: Self.tileHeight)
        case .clipboard:
            let count = clipboard.entries.count
            let pinnedCount = clipboard.entries.filter { !$0.pinboardIDs.isEmpty }.count
            let saving = !clipboard.paused && !globalPaused
            AOMModuleTile(.clipboard,
                          value: clipboard.isLoading && count == 0 ? "Unlocking…" : "\(count.formatted()) item\(count == 1 ? "" : "s")",
                          status: globalPaused ? "Paused with AOM"
                              : (clipboard.paused ? (clipboard.pauseRemainingSeconds > 0 ? "Paused · resumes soon" : "Paused")
                                 : "Saving history" + (pinnedCount > 0 ? " · \(pinnedCount) pinned" : "")),
                          statusTone: saving ? nil : .neutral,
                          active: saving,
                          open: { appState.selectedMainTab = .clipboard }) {
                Toggle("Save clipboard history", isOn: Binding(get: { !clipboard.paused },
                                                               set: { $0 ? clipboard.resume() : clipboard.pause() }))
                    .disabled(globalPaused)
                    .help(clipboard.paused ? "Resume clipboard history" : "Stop saving what you copy until you resume")
            }
            .frame(height: Self.tileHeight)
        case .audio:
            let custom = audio.apps.filter(audio.hasCustomSettings).count
            AOMModuleTile(.audio,
                          value: !audio.soundEnabled ? "Off"
                              : (custom > 0 ? "\(custom) app setting\(custom == 1 ? "" : "s")"
                                 : (audio.eqEnabled ? "EQ \(audio.eqPreset)" : "On")),
                          status: !audio.isSupported ? "Needs macOS 14.2 or later"
                              : (audio.soundEnabled ? (outputDevice.map { "Output: \($0)" } ?? "Per-app volume and effects")
                                 : "Apps play directly"),
                          statusTone: audio.soundEnabled ? nil : .neutral,
                          active: audio.soundEnabled,
                          open: openAudio) {
                Toggle("App Audio", isOn: $audio.soundEnabled)
                    .disabled(!audio.isSupported)
                    .help(audio.soundEnabled ? "Turn off per-app volume and effects" : "Turn on per-app volume and effects")
            }
            .frame(height: Self.tileHeight)
        case .systemTools:
            AOMModuleTile(.systemTools,
                          value: keepAwake.isActive ? "Keeping awake" : "12 tools",
                          status: keepAwake.isActive ? "Keep Awake \(keepAwake.remainingDescription ?? "on")"
                              : "Finder, PDF, media and cleanup",
                          active: true,
                          open: { appState.selectedMainTab = .tools }) {
                WorkspaceTileChevron()
            }
            .frame(height: Self.tileHeight)
        }
    }

    private func openAudio() {
        UserDefaults.standard.set("Mixer", forKey: "AOMAudioWorkspaceSection")
        appState.selectedMainTab = .audio
    }

    private func captureKeys(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    // MARK: Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Quick actions")
            WorkspaceFlowRow(spacing: AOMSpace.tileGap) {
                WorkspaceQuickAction("Capture Area", symbol: "viewfinder", keys: captureKeys(.captureArea)) {
                    CaptureCoordinator.shared.captureArea()
                }
                WorkspaceQuickAction("Capture Window", symbol: "macwindow", keys: captureKeys(.captureWindow)) {
                    CaptureCoordinator.shared.captureWindowInteractive()
                }
                WorkspaceQuickAction(recording.isRecording ? "Stop Recording" : "Record Screen",
                                     symbol: recording.isRecording ? "stop.circle" : "record.circle",
                                     keys: captureKeys(.recordScreen)) {
                    recording.toggleRecording()
                }
                WorkspaceQuickAction("Copy Text", symbol: "text.viewfinder", keys: captureKeys(.ocr)) {
                    CaptureCoordinator.shared.captureText()
                }
                WorkspaceQuickAction("Clipboard History", symbol: "doc.on.clipboard",
                                     keys: ClipboardShortcuts.shared.shortcut(for: .history)?.displayString) {
                    ClipboardPanelController.shared.show()
                }
                ForEach(pinned) { trigger in
                    let canRun = trigger.isEnabled && !trigger.actions.isEmpty && !trigger.aomTypesText
                    WorkspaceQuickAction(trigger.displayName, symbol: canRun ? "bolt.fill" : "bolt",
                                         keys: { if case .keyboardShortcut(let shortcut) = trigger.input { return shortcut.displayString }; return nil }(),
                                         running: runStates[trigger.id] == .running,
                                         help: canRun ? "Run “\(trigger.displayName)”" : "Open “\(trigger.displayName)” in Automation") {
                        if canRun { run(trigger) } else { open(trigger) }
                    }
                    .contextMenu {
                        Button("Open in Automation") { open(trigger) }
                        Button("Unpin from Workspace") { appState.toggleFavorite(trigger) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    private func run(_ trigger: Trigger) {
        runStates[trigger.id] = .running
        ActionExecutor.executeActions(trigger.actions, fromTrackpad: trigger.input.category == .trackpad,
                                      triggerID: trigger.id) { ok in
            DispatchQueue.main.async {
                runStates[trigger.id] = ok ? .succeeded(Date()) : .failed(Date())
                toast.show(ok ? "Ran “\(trigger.displayName)”" : "“\(trigger.displayName)” failed or was stopped")
            }
        }
    }

    private func open(_ trigger: Trigger) {
        appState.selectedTrigger = trigger
        appState.selectedActivationGroupID = trigger.activationGroupID
        if trigger.activationGroupID == nil {
            if let bundle = trigger.appBundleID, !bundle.isEmpty,
               let target = appState.currentPreset.appTargets.first(where: { $0.bundleID == bundle }) {
                appState.selectedAppTarget = target
            } else {
                appState.selectedAppTarget = .allApps
            }
        }
        appState.selectedMainTab = .gestures
    }

    // MARK: Recent activity

    private func recentActivity(_ events: [WorkspaceActivity]) -> some View {
        AOMSection("Recent activity") {
            AOMCardLink("View All") { appState.selectedMainTab = .insights }
        } content: {
            if events.isEmpty {
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: "clock")
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row)
                        .accessibilityHidden(true)
                    Text("Actions you run appear here.")
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .frame(minHeight: AOMSize.rowStandard + AOMSpace.x2)
            } else {
                ForEach(events) { event in
                    WorkspaceActivityRow(event: event)
                }
            }
        }
        .accessibilityLabel("Recent activity")
    }

    fileprivate func recentEvents() -> [WorkspaceActivity] {
        var events: [WorkspaceActivity] = []
        let byInput = Dictionary(triggers.map { ($0.input.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        for (offset, event) in stats.events.suffix(64).reversed().enumerated() where event.fired {
            let trigger = byInput[event.gesture]
            let title = trigger.map { "Ran “\($0.displayName)”" } ?? "Ran \(event.gesture)"
            var menu: [(String, () -> Void)] = []
            if let trigger { menu.append(("Open in Automation", { open(trigger) })) }
            events.append(WorkspaceActivity(id: "run.\(offset).\(event.timestamp.timeIntervalSince1970)", module: .automation,
                                            title: title, date: event.timestamp,
                                            open: { if let trigger { open(trigger) } else { appState.selectedMainTab = .gestures } },
                                            menu: menu))
            if events.count >= Self.recentLimit { break }
        }
        for entry in history.entries.prefix(Self.recentLimit) {
            let verb = entry.kind == .videoRecording ? "Recorded" : "Captured"
            events.append(WorkspaceActivity(id: "capture.\(entry.id)", module: .capture,
                                            title: "\(verb) \(entry.displayName)", date: entry.capturedAt,
                                            open: { CaptureItemActions.edit(entry) },
                                            menu: [("Copy", { CaptureItemActions.copy(entry); toast.show("Copied capture") }),
                                                   ("Edit", { CaptureItemActions.edit(entry) }),
                                                   ("Show in Capture", { appState.selectedMainTab = .capture })],
                                            openLabel: "Edit"))
        }
        for entry in clipboard.entries.prefix(Self.recentLimit) {
            let source = entry.sourceName.map { " from \($0)" } ?? ""
            events.append(WorkspaceActivity(id: "clip.\(entry.id)", module: .clipboard,
                                            title: "Copied “\(entry.title.prefix(48))”\(source)", date: entry.lastCopiedAt,
                                            open: { copy(entry) },
                                            menu: [("Copy Again", { copy(entry) }),
                                                   ("Show in Clipboard", { appState.selectedMainTab = .clipboard })],
                                            openLabel: "Copy"))
        }
        return Array(events.sorted { $0.date > $1.date }.prefix(Self.recentLimit))
    }

    private func copy(_ entry: ClipboardEntry) {
        Task {
            do {
                _ = try await clipboard.writeAsync(entryIDs: [entry.id], plainText: false, playSound: true)
                toast.show("Copied “\(entry.title.prefix(40))”")
            } catch {
                toast.show("Could not copy: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Snapshot inputs

    fileprivate var permissionStatuses: [(AOMPermission, AOMPermissionStatus)] { permissions }
    fileprivate var isPaused: Bool { !appState.globalEnabled || suppressionPaused }
    fileprivate var pauseDetail: String? { suppressionDescription }
    fileprivate var isFreshSetup: Bool {
        !setupSkipped && triggers.isEmpty && history.entries.isEmpty && stats.totalFired == 0
    }
    fileprivate var moduleOnCount: Int {
        let enabled = appState.globalEnabled
        var count = 0
        if enabled && triggers.contains(where: \.isEnabled) { count += 1 }
        if enabled && (appState.currentPreset.snappingEnabled || titleBarSnapOn) { count += 1 }
        if permissions.first(where: { $0.0 == .screenRecording })?.1 == .granted { count += 1 }
        if enabled && !clipboard.paused { count += 1 }
        if audio.soundEnabled { count += 1 }
        count += 1 // System Tools are always available.
        return count
    }
    fileprivate var lastActionDate: Date? {
        [lastRuns.values.max(), history.entries.first?.capturedAt, clipboard.entries.first?.lastCopiedAt]
            .compactMap { $0 }.max()
    }
}

// MARK: - Snapshot

/// Everything one render needs, computed once per body.
private struct WorkspaceSnapshot {
    let hero: WorkspaceHeroState
    let chips: [(AOMPermission, AOMPermissionStatus)]
    let attention: [WorkspaceAttention]
    let recent: [WorkspaceActivity]
    let lastRun: Date?
    private let statuses: [AOMPermission: AOMPermissionStatus]

    @MainActor
    init(home: AOMHomeView) {
        let permissions = home.permissionStatuses
        statuses = Dictionary(permissions.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        chips = permissions
        let blocking = permissions
            .filter { ($0.0 == .accessibility || $0.0 == .inputMonitoring) && ($0.1 == .denied || $0.1 == .notDetermined) }
            .map(\.0)
        let state: WorkspaceHeroState
        if home.isFreshSetup {
            state = .setup
        } else if let first = blocking.first {
            // Count what the chips under the title and the sidebar badge count
            // (every required permission still missing), not only the blocking two.
            let missing = permissions.filter { $0.1 == .denied || $0.1 == .notDetermined }.count
            state = .blocked(first, count: max(missing, blocking.count))
        } else if home.isPaused {
            state = .paused(detail: home.pauseDetail)
        } else {
            state = .running(on: home.moduleOnCount, total: AOMModule.allCases.count, last: home.lastActionDate)
        }
        hero = state
        attention = home.attentionItems(hero: state)
        recent = home.recentEvents()
        lastRun = home.lastActionDateForAutomation
    }

    func status(_ permission: AOMPermission) -> AOMPermissionStatus? { statuses[permission] }
}

extension AOMHomeView {
    fileprivate var lastActionDateForAutomation: Date? { lastRuns.values.max() }
}

/// The hero's five states (d.2; there is no observable "helper stopped" state).
enum WorkspaceHeroState: Equatable {
    case running(on: Int, total: Int, last: Date?)
    case paused(detail: String?)
    case blocked(AOMPermission, count: Int)
    case setup

    var tone: AOMTone {
        switch self {
        case .running: return .success
        case .paused: return .neutral
        case .blocked: return .warning
        case .setup: return .info
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .setup: return "sparkles"
        }
    }

    var sentence: String {
        switch self {
        case .running: return "AOM is running"
        case .paused: return "AOM is paused"
        case .blocked(_, let count): return count == 1 ? "AOM needs 1 permission" : "AOM needs \(count) permissions"
        case .setup: return "Set up AOM"
        }
    }

    func detail(now: Date = Date()) -> String {
        switch self {
        case .running(let on, let total, let last):
            let modules = "\(on) of \(total) modules on"
            return last.map { "\(modules) · last action \(AOMRelativeTime.string($0, now: now).lowercased())" } ?? modules
        case .paused(let detail):
            return detail ?? "Gestures, shortcuts and snapping are off until you resume."
        case .blocked(let permission, _):
            return permission == .accessibility
                ? "Gestures, shortcuts and window actions can't run until Accessibility is allowed."
                : "Keyboard shortcuts can't be detected until Input Monitoring is allowed."
        case .setup:
            return "Three short steps, about a minute."
        }
    }
}

// MARK: - Hero view

private struct WorkspaceHero<Action: View, Strip: View, Checklist: View>: View {
    let state: WorkspaceHeroState
    let chips: [(AOMPermission, AOMPermissionStatus)]
    @ObservedObject var toast: AOMToastModel
    @ViewBuilder var action: Action
    @ViewBuilder var strip: Strip
    @ViewBuilder var checklist: Checklist
    @Environment(\.colorSchemeContrast) private var contrast

    init(state: WorkspaceHeroState, chips: [(AOMPermission, AOMPermissionStatus)], toast: AOMToastModel,
         @ViewBuilder action: () -> Action, @ViewBuilder strip: () -> Strip, @ViewBuilder checklist: () -> Checklist) {
        self.state = state
        self.chips = chips
        self.toast = toast
        self.action = action()
        self.strip = strip()
        self.checklist = checklist()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            HStack(alignment: .top, spacing: AOMSpace.x4) {
                Image(systemName: state.symbol)
                    .font(.system(size: AOMIcon.hero + 6, weight: .regular))
                    .symbolRenderingMode(state == .setup ? .hierarchical : .palette)
                    .foregroundStyle(state == .setup ? AnyShapeStyle(AOMColor.accent) : AnyShapeStyle(Color.white),
                                     AnyShapeStyle(state.tone.color))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: AOMIcon.hero + 12, height: AOMIcon.hero + 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    Text(state.sentence)
                        .font(AOMFont.hero)
                        .foregroundStyle(AOMColor.text)
                        .accessibilityAddTraits(.isHeader)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(state.detail(now: context.date))
                            .font(AOMFont.body)
                            .foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !chips.isEmpty, state != .setup {
                        WorkspacePermissionChips(chips: chips)
                            .padding(.top, AOMSpace.x2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action
                    .fixedSize()
            }
            strip
            checklist
        }
        .padding(AOMSpace.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                shape.fill(AOMColor.surface)
                if contrast != .increased {
                    shape.fill(LinearGradient(colors: [state.tone.color.opacity(0.12), state.tone.color.opacity(0.02)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
        .overlay {
            shape.strokeBorder(contrast == .increased ? AOMColor.strongLine : state.tone.color.opacity(0.25),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .aomAnimation(.standard, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status: \(state.sentence)")
    }
}

/// One chip per permission AOM uses: glyph, name, state. A missing one opens
/// the right System Settings pane; when everything is allowed, one chip says so.
private struct WorkspacePermissionChips: View {
    let chips: [(AOMPermission, AOMPermissionStatus)]

    var body: some View {
        let missing = chips.filter { $0.1 == .denied || $0.1 == .notDetermined }
        if missing.isEmpty {
            AOMStatusPill("All permissions allowed", tone: .success, symbol: "checkmark.circle.fill")
        } else {
            WorkspaceFlowRow(spacing: AOMSpace.x2) {
                ForEach(chips, id: \.0) { permission, status in
                    let ok = status == .granted || status == .manualReview
                    if ok {
                        AOMStatusPill(permission.shortTitle, tone: .success, symbol: "checkmark.circle.fill")
                    } else {
                        Button { _ = permission.openSettings() } label: {
                            AOMStatusPill(permission.shortTitle, tone: .warning, symbol: "exclamationmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Allow \(permission.title) in System Settings")
                        .accessibilityLabel("\(permission.title), not allowed")
                        .accessibilityHint("Opens System Settings")
                    }
                }
            }
        }
    }
}

/// Lays out chips left to right, wrapping onto new lines.
private struct WorkspaceFlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct WorkspaceRecordingGlyph: View {
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let image = Image(systemName: paused ? "pause.circle.fill" : "record.circle")
            .foregroundStyle(AOMColor.recording)
            .accessibilityHidden(true)
        if #available(macOS 15.0, *) {
            image.symbolEffect(.breathe, options: .repeating, isActive: !paused && !reduceMotion)
        } else {
            image.symbolEffect(.pulse, options: .repeating, isActive: !paused && !reduceMotion)
        }
    }
}

private struct WorkspaceSetupStep<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var action: Action

    init(number: Int, title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) {
        self.number = number
        self.title = title
        self.detail = detail
        self.done = done
        self.action = action()
    }

    var body: some View {
        HStack(spacing: AOMSpace.x3) {
            ZStack {
                Circle().fill(done ? AOMColor.success : AOMColor.sunken)
                if done {
                    Image(systemName: "checkmark").font(AOMFont.badge.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(AOMFont.callout.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AOMFont.bodyEmphasis).foregroundStyle(done ? AOMColor.textSecondary : AOMColor.text)
                    .strikethrough(done, color: AOMColor.textSecondary)
                Text(detail).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x2)
            if done {
                Text("Done").font(AOMFont.callout).foregroundStyle(AOMColor.successText)
            } else {
                action.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { if number > 1 { AOMRowDivider(inset: AOMSpace.x3 + 24 + AOMSpace.x3) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
    }
}

// MARK: - Needs attention rows

struct WorkspaceAttention: Identifiable {
    enum Kind: Int { case fixNow = 0, upcoming = 1, suggestion = 2 }
    let id: String
    let kind: Kind
    let tone: AOMTone
    let text: String
    let actionTitle: String
    let action: () -> Void
}

private struct WorkspaceAttentionRow: View {
    let item: WorkspaceAttention
    let dismiss: () -> Void

    private var symbol: String {
        switch item.kind {
        case .fixNow: return item.tone == .danger ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        case .upcoming: return "clock.fill"
        case .suggestion: return "lightbulb.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .fixNow: return item.tone.color
        case .upcoming: return AOMColor.accent
        case .suggestion: return Color(nsColor: .systemYellow)
        }
    }

    var body: some View {
        HStack(spacing: AOMSpace.x3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            Text(item.text)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(item.actionTitle, action: item.action)
                .buttonStyle(.bordered)
            if item.kind == .suggestion {
                Button(action: dismiss) {
                    Image(systemName: "xmark").imageScale(.small).foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMSize.rowDetail - AOMSpace.x1)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x1) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tiles and quick actions

private struct WorkspaceGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The control slot of a tile that only opens its page.
private struct WorkspaceTileChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .imageScale(.small)
            .foregroundStyle(AOMColor.textTertiary)
            .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceQuickAction: View {
    let title: String
    let symbol: String
    var keys: String?
    var running = false
    var help: String?
    let action: () -> Void

    init(_ title: String, symbol: String, keys: String? = nil, running: Bool = false, help: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.keys = keys
        self.running = running
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x2) {
                if running {
                    ProgressView().controlSize(.small).frame(width: AOMIcon.row)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: AOMIcon.row)
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                if let keys { AOMKeycap(text: keys).padding(.leading, AOMSpace.x1) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(help ?? (keys.map { "\(title) (\($0))" } ?? title))
        .accessibilityLabel(title)
        .accessibilityHint(keys.map { "Shortcut \($0)" } ?? "")
    }
}

// MARK: - Recent activity rows

struct WorkspaceActivity: Identifiable {
    let id: String
    let module: AOMModule
    let title: String
    let date: Date
    let open: () -> Void
    var menu: [(String, () -> Void)] = []
    var openLabel = "Open"
}

private struct WorkspaceActivityRow: View {
    let event: WorkspaceActivity
    @State private var hovering = false

    var body: some View {
        Button(action: event.open) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: event.module.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
                Text(event.title)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AOMSpace.x3)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AOMRelativeTime.string(event.date, now: context.date))
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textSecondary)
                }
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(minHeight: AOMSize.rowStandard + AOMSpace.x1)
            .background(hovering ? AOMColor.sunken.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .contextMenu {
            Button(event.openLabel, action: event.open)
            ForEach(Array(event.menu.enumerated()), id: \.offset) { _, item in
                Button(item.0, action: item.1)
            }
        }
        .help(event.openLabel == "Open" ? event.title : "\(event.openLabel): \(event.title)")
        .accessibilityLabel("\(event.title), \(AOMRelativeTime.string(event.date))")
        .accessibilityAction(named: event.openLabel, event.open)
    }
}

// MARK: - Permission wording

extension AOMPermission {
    /// Short chip name ("Screen Recording" instead of the full pane title).
    var shortTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        default: return title
        }
    }

    /// One sentence: the problem and its consequence (d.3).
    var attentionSentence: String {
        switch self {
        case .accessibility: return "Accessibility is off. Gestures, shortcuts and window actions can't run."
        case .inputMonitoring: return "Input Monitoring is off. Keyboard shortcuts can't be detected."
        case .screenRecording: return "Screen Recording is off. Capture and Record can't start."
        case .microphone: return "Microphone is off. Recordings can't include your voice."
        default: return "\(title) is off. Some actions may not run."
        }
    }
}

// MARK: - Capture actions shared by Workspace and Capture

@MainActor
enum CaptureItemActions {
    static func copy(_ entry: CaptureHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let fileURL = entry.fileURL {
            pasteboard.writeObjects([fileURL as NSURL])
        }
        let rep = NSBitmapImageRep(cgImage: entry.image)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
    }

    static func edit(_ entry: CaptureHistoryEntry) {
        AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
    }

    /// Drag out the saved file when there is one, else the image itself.
    static func dragProvider(_ entry: CaptureHistoryEntry) -> NSItemProvider {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: NSImage(cgImage: entry.image, size: .zero))
    }

    static func overlayButton(_ symbol: String, _ help: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(role == .destructive ? AOMColor.dangerText : Color.primary)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Shared row components

/// Input category glyph colours shared by gesture rows and icons. Kept quiet:
/// categories are told apart by their symbol; colour stays for status.
enum GestureVisual {
    static func tint(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return AOMModule.automation.hue
        case .keyboard: return AOMModule.automation.hue
        case .normalMouse: return AOMModule.automation.hue
        case .drawings: return AOMModule.automation.hue
        case .otherTriggers: return AOMColor.textSecondary
        case .all: return AOMColor.accent
        }
    }
}
