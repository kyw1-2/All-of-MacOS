import AppKit
import Charts
import SwiftUI

// MARK: - Workspace

/// The Workspace (docs/design-3.3.6.md b.12): status first, then enough real
/// content to use a 1320×820 window.
///
/// 1. Status header: one sentence that says whether AOM is working (running,
///    paused or needs a permission) with real counts, one action and the
///    permission chips. A recording in progress adds a strip under it.
///    First-run setup is a card below it: progress, the three steps side by
///    side with their buttons, Show the Tour and Skip.
/// 2. Needs attention, only when something needs you: Fix now → Upcoming →
///    Suggestions, one sentence and one verb button per row.
/// 3. Module tiles (Reminders/Passwords style): name, status line, one
///    control, and the live count; clicking a tile opens its page.
/// 4. Quick actions: capture, record, copy text, clipboard history and the
///    automations you pinned, as launch tiles.
/// 5. Overview: recent activity (View All opens Insights), Today (actions,
///    captures and copies today and over the last 7 days) and This Mac (CPU,
///    memory, disk, battery from the System Tools monitor).
///
/// Every value comes from state the app already publishes (AppState and the
/// module services); every control calls the same code as its page.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    private let stats = GestureStatistics.shared
    @StateObject private var activity = WorkspaceValueProjection(statistics: GestureStatistics.shared)
    @State private var hasFired = GestureStatistics.shared.totalFired > 0
    @State private var windowVisible = false
    @State private var weekCache = WorkspaceWeekCache()
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var recording = ScreenRecordingService.shared
    private let audio = AppAudioMixerService.shared
    @StateObject private var audioDisplay = WorkspaceValueProjection(audio: AppAudioMixerService.shared)
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
    /// The setup steps are open until the first step is done, then fold into
    /// one line with the next step's button; "Show/Hide Steps" overrides that
    /// for the rest of the session.
    @State private var setupExpandedChoice: Bool?
    @State private var dismissedSuggestions: Set<String> = []
    @State private var showsAllAttention = false
    /// What this page shows and in which order (design-3.4.0 b.15).
    @ObservedObject private var layout = AOMWorkspaceLayout.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @State private var showsCustomize = false
    /// The Productivity modules' `attention` lines, polled with the rest of
    /// the status so a module's countdown never redraws the whole page.
    @State private var moduleAttention: [AOMModule: String] = [:]

    static let maximumContentWidth: CGFloat = AOMSize.contentMaxWidth
    static let attentionLimit = 3
    static let recentLimit = 5

    private var triggers: [Trigger] { appState.currentPreset.triggers }
    private var pinned: [Trigger] { triggers.filter(\.isFavorite) }

    /// When each trigger last ran, from the statistics log. Inputs record
    /// their display name (the unnamed trigger's input name) when they fire.
    private var lastRuns: [UUID: Date] {
        var latestByInput: [String: Date] = [:]
        for event in activity.value {
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
                // Status and anything that asks for you span the page.
                hero(snapshot)
                if snapshot.showsSetup {
                    setupCard(snapshot)
                }
                if !snapshot.attention.isEmpty {
                    needsAttention(snapshot.attention)
                }
                // Dashboard: what you operate on the left, what happened on
                // the right rail (Xcode Organizer, Activity summary), so the
                // whole state reads in one screen at the default window size.
                if usesRail {
                    HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) { mainColumn(snapshot) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        overviewRail(snapshot)
                            .frame(width: Self.railWidth)
                    }
                } else {
                    mainColumn(snapshot)
                    overview(snapshot)
                }
            }
            .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: WorkspaceGridWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(WorkspaceGridWidthKey.self) { width in
                if abs(width - contentWidth) > 1 { contentWidth = width }
            }
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.top, AOMSpace.pageTop)
            .padding(.bottom, AOMSpace.x6)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
        .aomScrollEdge()
        .background(AOMColor.pageBackground)
        .navigationTitle("Workspace")
        .toolbar {
            // View options, then the page's one primary action (b.3).
            ToolbarItem(placement: .primaryAction) {
                Button { showsCustomize = true } label: {
                    Label("Customize Workspace", systemImage: "slider.horizontal.3")
                }
                .help("Choose and order what Workspace shows")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: newAutomation) {
                    Label("New Automation", systemImage: "plus")
                }
                .help("New Automation (⌘N)")
            }
        }
        .sheet(isPresented: $showsCustomize) {
            WorkspaceCustomizeSheet(layout: layout)
        }
        .onAppear(perform: openRequestedCustomize)
        .onChange(of: layout.customizeRequested) { _, _ in openRequestedCustomize() }
        // ⌘N and ⌘F work from the Workspace too: they open the Automation page.
        .focusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { appState.selectedMainTab = .gestures },
            newTrigger: newAutomation))
        .onReceive(stats.$totalFired.map { $0 > 0 }.removeDuplicates()) { hasFired = $0 }
        .aomOnWindowVisibilityChange { windowVisible = $0 }
        .task(id: windowVisible) {
            guard windowVisible else { return }
            // Isolated previews only (`--aom-preview-panel-appearance`).
            AOMFeaturePreview.applyPanelAppearance()
            while !Task.isCancelled {
                await refreshStatus()
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
            }
        }
        .aomToast(toast)
    }

    /// Polled state that nothing publishes (permissions, Paste's shortcut,
    /// the timed pause, the title-bar snap switch, the output device).
    private func refreshStatus() async {
        let current = AOMPermission.required.map { ($0, AOMPermissionCache.status($0)) }
        if current.map(\.0) != permissions.map(\.0) || current.map(\.1) != permissions.map(\.1) { permissions = current }
        let shortcut = ClipboardShortcuts.shared.shortcut(for: .history)
        // LaunchServices, other apps' preferences and HAL reads can block.
        // Snapshot the MainActor-only shortcut before dispatching the reads.
        let external = await Task.detached(priority: .utility) {
            let conflict = ShortcutConflicts.clipboardHistoryConflict(shortcut: shortcut)
            let currentID = AudioOutputService.currentDeviceID()
            let device = AudioOutputService.devices().first { $0.id == currentID }?.name
            return (conflict, device)
        }.value
        guard !Task.isCancelled else { return }
        if external.0 != shortcutConflict { shortcutConflict = external.0 }
        if external.1 != outputDevice { outputDevice = external.1 }
        let suppression = TriggerSuppression.shared
        let paused = suppression.isPaused
        if paused != suppressionPaused { suppressionPaused = paused }
        let description = paused ? suppression.statusDescription : nil
        if description != suppressionDescription { suppressionDescription = description }
        let titleBar = UserDefaults.standard.bool(forKey: TitleBarWindowSnap.enabledKey)
        if titleBar != titleBarSnapOn { titleBarSnapOn = titleBar }
        var attention: [AOMModule: String] = [:]
        for status in AOMModuleStatusBoard.all {
            if let text = status.attention, !text.isEmpty { attention[status.module] = text }
        }
        if attention != moduleAttention { moduleAttention = attention }
    }

    /// Hides one part, tile or quick action as an undoable step, with Undo in
    /// the toast (HIG Undo and redo; no confirmation for undoable actions).
    private func hide(_ id: String, name: String, title: String) {
        let before = layout.state
        layout.change("Hide \(name)", undoManager: undoManager) { $0.setHidden(id, true) }
        toast.show("\(title) hidden from Workspace", action: { [undoManager] in
            if let undoManager, undoManager.canUndo { undoManager.undo() } else { layout.restore(before) }
        })
    }

    private func openRequestedCustomize() {
        guard layout.customizeRequested else { return }
        layout.customizeRequested = false
        showsCustomize = true
    }

    private func move(_ kind: WorkspaceQuickActionKind, by offset: Int) {
        layout.change("Move Quick Action", undoManager: undoManager) { $0.move(kind, by: offset) }
    }

    private func move(_ kind: WorkspaceQuickActionKind, before target: WorkspaceQuickActionKind) {
        layout.change("Move Quick Action", undoManager: undoManager) { $0.move(kind, before: target) }
    }

    /// The items every tile's context menu ends with.
    @ViewBuilder
    private func tileMenu(_ module: AOMModule) -> some View {
        Divider()
        Button("Hide from Workspace") {
            hide(AOMWorkspaceLayout.tileID(module), name: "Tile", title: module.title)
        }
        Button("Customize Workspace…") { showsCustomize = true }
    }

    private func newAutomation() {
        appState.selectedMainTab = .gestures
        appState.showingAddTrigger = true
    }

    // MARK: Layout

    static let railWidth: CGFloat = 300
    /// The right rail needs the module grid to keep two columns beside it.
    private var usesRail: Bool { contentWidth >= 720 + Self.railWidth + AOMSpace.sectionGap }
    /// Width of the column the module grid and utilities sit in.
    private var mainWidth: CGFloat { usesRail ? contentWidth - Self.railWidth - AOMSpace.sectionGap : contentWidth }

    @ViewBuilder
    private func mainColumn(_ snapshot: WorkspaceSnapshot) -> some View {
        if layout.shows(.tools) {
            toolModules(snapshot)
        }
        if layout.shows(.productivity) {
            productivityModules
        }
        if layout.shows(.quickActions) {
            quickActions
        }
        utilities
    }

    /// Today, This Mac and Recent activity stacked in the rail.
    @ViewBuilder
    private func overviewRail(_ snapshot: WorkspaceSnapshot) -> some View {
        let parts = [AOMWorkspaceLayout.Part.today, .thisMac, .recent].filter(layout.shows)
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            ForEach(parts) { part in
                overviewCard(part, snapshot)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ snapshot: WorkspaceSnapshot) -> some View {
        WorkspaceHero(state: snapshot.hero, chips: snapshot.chips) {
            heroAction(snapshot.hero)
        } strip: {
            if recording.isRecording { recordingStrip }
        }
    }

    // Small buttons like the rest of the page: the hero is a status line,
    // not a billboard.
    @ViewBuilder
    private func heroAction(_ state: WorkspaceHeroState) -> some View {
        switch state {
        case .running:
            Button { appState.toggleGlobalEnabled() } label: {
                Label("Pause AOM", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)
            .help("Pause every gesture, shortcut, snap and clipboard capture")
        case .paused:
            Button(action: resumeAOM) {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        case .blocked(let permission, _):
            Button("Allow \(permission.shortTitle)…") { _ = permission.openSettings() }
                .buttonStyle(.borderedProminent)
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
                .font(AOMFont.caption.monospacedDigit())
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
        .padding(.horizontal, AOMSpace.x2)
        .frame(minHeight: AOMSize.rowStandard + AOMSpace.x0_5)
        // Concentric with the hero card around it.
        .background(AOMTone.recording.wash(increasedContrast: false),
                    in: RoundedRectangle(cornerRadius: AOMRadius.concentric(AOMRadius.card, inset: AOMSpace.x2),
                                         style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording, \(Self.elapsed(recording.elapsedSeconds))")
    }

    static func elapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func setupCard(_ snapshot: WorkspaceSnapshot) -> some View {
        let accessibility = snapshot.status(.accessibility)
        let screen = snapshot.status(.screenRecording)
        let steps = [
            WorkspaceSetupItem(number: 1, title: "Allow Accessibility",
                               detail: "Lets gestures and shortcuts move windows and press keys.",
                               done: accessibility == .granted, actionTitle: "Allow…") {
                _ = AOMPermission.accessibility.openSettings()
            },
            WorkspaceSetupItem(number: 2, title: "Allow Screen Recording",
                               detail: "Needed only for Capture and Record.",
                               done: screen == .granted, actionTitle: "Allow…") {
                _ = AOMPermission.screenRecording.openSettings()
            },
            WorkspaceSetupItem(number: 3, title: "Create your first automation",
                               detail: "Connect a gesture, key or mouse button to an action.",
                               done: !triggers.isEmpty, actionTitle: "New Automation", action: newAutomation)
        ]
        // The header's prominent "Allow Accessibility…" already asks for step 1;
        // one prominent button per action, so the step's own stays bordered then.
        var heroAsksForNext = false
        if case .blocked(let permission, _) = snapshot.hero, permission == .accessibility, accessibility != .granted {
            heroAsksForNext = true
        }
        let anyDone = steps.contains(where: \.done)
        let expanded = Binding(get: { setupExpandedChoice ?? !anyDone }, set: { setupExpandedChoice = $0 })
        return WorkspaceSetupCard(steps: steps, expanded: expanded, prominentNext: !heroAsksForNext,
                                  skip: { withAnimation(AOMMotion.standard) { setupSkipped = true } },
                                  tour: { appState.showTutorialRequested = true })
    }

    // MARK: Needs attention

    private func needsAttention(_ items: [WorkspaceAttention]) -> some View {
        let shown = showsAllAttention ? items : Array(items.prefix(Self.attentionLimit))
        return AOMSection("Needs attention", detail: "\(items.count)") {
            if items.count > Self.attentionLimit {
                // The same quiet link as "View All ›"; the count is already beside the title.
                AOMCardLink(showsAllAttention ? "Show Less" : "Show All",
                            symbol: showsAllAttention ? "chevron.up" : "chevron.down") {
                    withAnimation(AOMMotion.standard) { showsAllAttention.toggle() }
                }
            }
        } content: {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                WorkspaceAttentionRow(item: item, showsDivider: index > 0) {
                    withAnimation(AOMMotion.standard) { _ = dismissedSuggestions.insert(item.id) }
                }
            }
        }
        .accessibilityLabel("Needs attention")
    }

    /// Fix now → Upcoming → Suggestions (d.3). The permission the hero's
    /// primary action already fixes, and what the setup strip already asks
    /// for, are not repeated here.
    fileprivate func attentionItems(hero: WorkspaceHeroState, setup: Bool) -> [WorkspaceAttention] {
        var items: [WorkspaceAttention] = []
        let missing = permissions.filter { $0.1 == .denied || $0.1 == .notDetermined }.map(\.0)
        for permission in missing {
            if case .blocked(let first, _) = hero, first == permission { continue }
            if setup, permission == .accessibility || permission == .screenRecording { continue }
            items.append(WorkspaceAttention(id: "permission.\(permission.rawValue)", kind: .fixNow, tone: .warning,
                                            text: permission.attentionSentence,
                                            actionTitle: "Allow…") { _ = permission.openSettings() })
        }
        for module in AOMModule.allCases {
            guard let text = moduleAttention[module] else { continue }
            items.append(WorkspaceAttention(id: "module.\(module.rawValue)", kind: .fixNow, tone: .warning,
                                            text: "\(module.title): \(text)",
                                            actionTitle: "Open \(module.title)") { appState.selectedMainTab = module.tab })
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
        if !setup && triggers.isEmpty {
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

    static let toolModuleList: [AOMModule] = [.automation, .tiling, .capture, .clipboard, .audio, .systemTools]
    static let productivityModuleList: [AOMModule] = [.folderRules, .textActions, .files, .focus]

    /// Module rows in one frosted pane, two columns when there is room.
    private func moduleGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let columns = mainWidth >= 720 ? 2 : 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.x1, alignment: .top),
                                        count: columns),
                         alignment: .leading, spacing: 0, content: content)
            .padding(AOMSpace.x1)
            .aomCard(padding: 0)
    }

    private func toolModules(_ snapshot: WorkspaceSnapshot) -> some View {
        let shown = Self.toolModuleList.filter(layout.shows)
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Tools", detail: "\(toolsOnCount) of \(Self.toolModuleList.count) on")
            if shown.isEmpty {
                hiddenTilesRow("Every Tools tile is hidden.")
            } else {
                moduleGrid {
                    ForEach(shown) { module in
                        tile(module, snapshot)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    /// Folder Rules, Text Actions, Files and Focus, each drawn from the live
    /// status its module publishes on `AOMModuleStatusBoard`.
    private var productivityModules: some View {
        let shown = Self.productivityModuleList.filter(layout.shows)
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            WorkspaceProductivityTitle()
            if shown.isEmpty {
                hiddenTilesRow("Every Productivity tile is hidden.")
            } else {
                moduleGrid {
                    ForEach(shown) { module in
                        if let status = AOMModuleStatusBoard.status(for: module) {
                            AOMModuleStatusTile(status: status, open: { appState.selectedMainTab = module.tab }) {
                                tileMenu(module)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Productivity")
    }

    private func hiddenTilesRow(_ message: String) -> some View {
        AOMInlineEmpty(symbol: "eye.slash", message: message, actionTitle: "Customize…") { showsCustomize = true }
            .aomCard(padding: 0)
    }

    /// Measured width of the content column (drives the grid and the
    /// overview's column count).
    @State private var contentWidth: CGFloat = 1000

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? noun : noun + "s"
    }

    @ViewBuilder
    private func tile(_ module: AOMModule, _ snapshot: WorkspaceSnapshot) -> some View {
        let globalPaused = !appState.globalEnabled
        switch module {
        case .automation:
            let enabled = triggers.filter(\.isEnabled).count
            let latest = snapshot.lastRun
            AOMModuleTile(.automation,
                          metric: "\(triggers.count)", unit: Self.plural(triggers.count, "automation"),
                          status: globalPaused ? "Paused" : (triggers.isEmpty ? "Create one to start"
                              : "\(enabled) on" + (latest.map { " · last run \(AOMRelativeTime.string($0).lowercased())" } ?? "")),
                          statusTone: globalPaused ? .neutral : nil,
                          active: !globalPaused && enabled > 0,
                          open: { appState.selectedMainTab = .gestures }) {
                if triggers.isEmpty {
                    Button("Create…", action: newAutomation).buttonStyle(.bordered)
                } else {
                    WorkspaceTileChevron()
                }
            } menu: {
                Button("New Automation", action: newAutomation)
                tileMenu(.automation)
            }
        case .tiling:
            let zones = appState.effectiveSnapZones.filter(\.isEnabled).count
            let drag = appState.currentPreset.snappingEnabled
            let parts = [drag ? "Drag to snap" : nil, titleBarSnapOn ? "title-bar swipes" : nil].compactMap { $0 }
            AOMModuleTile(.tiling,
                          metric: "\(zones)", unit: Self.plural(zones, "snap area"),
                          status: globalPaused ? "Paused" : (parts.isEmpty ? "Off — windows move freely" : parts.joined(separator: " · ") + " on"),
                          statusTone: globalPaused ? .neutral : nil,
                          active: !globalPaused && (drag || titleBarSnapOn),
                          open: { appState.selectedMainTab = .snapping }) {
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                     set: { appState.setSnappingEnabled($0) }))
                    .disabled(globalPaused)
                    .help("Drag to Snap: place windows by dragging them to an edge, corner or snap area")
            } menu: {
                if !globalPaused {
                    Button(drag ? "Turn Off Drag to Snap" : "Turn On Drag to Snap") { appState.setSnappingEnabled(!drag) }
                }
                tileMenu(.tiling)
            }
        case .capture:
            let today = Calendar.current.startOfDay(for: Date())
            let count = history.entries.filter { $0.capturedAt >= today }.count
            let needsSetup = snapshot.status(.screenRecording) != .granted && snapshot.status(.screenRecording) != nil
            AOMModuleTile(.capture,
                          metric: "\(count)", unit: count == 1 ? "capture today" : "captures today",
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
                        .buttonStyle(.bordered)
                        .help("Allow Screen Recording in System Settings")
                } else {
                    Button { CaptureCoordinator.shared.captureArea() } label: {
                        Label("Capture Area", systemImage: "viewfinder")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Capture Area" + (captureKeys(.captureArea).map { " (\($0))" } ?? ""))
                }
            } menu: {
                if !needsSetup && !recording.isRecording {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                    Button("Record Screen") { recording.toggleRecording() }
                }
                tileMenu(.capture)
            }
        case .clipboard:
            let count = clipboard.entries.count
            let pinnedCount = clipboard.entries.filter { !$0.pinboardIDs.isEmpty }.count
            let saving = !clipboard.paused && !globalPaused
            AOMModuleTile(.clipboard,
                          metric: clipboard.isLoading && count == 0 ? "…" : count.formatted(),
                          unit: clipboard.isLoading && count == 0 ? "unlocking history" : Self.plural(count, "item"),
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
            } menu: {
                Button("Show Clipboard Shelf") { ClipboardPanelController.shared.show() }
                if !globalPaused {
                    Button(clipboard.paused ? "Resume Clipboard History" : "Pause Clipboard History") {
                        if clipboard.paused { clipboard.resume() } else { clipboard.pause() }
                    }
                }
                tileMenu(.clipboard)
            }
        case .audio:
            let custom = audioDisplay.value.customApps
            let detail = [outputDevice.map { "Output: \($0)" }, audio.eqEnabled ? "EQ \(audio.eqPreset)" : nil].compactMap { $0 }
            AOMModuleTile(.audio,
                          // The switch says on or off; the figure is the
                          // per-app settings, kept while App Audio is off.
                          metric: "\(custom)",
                          unit: custom == 1 ? "app setting" : "app settings",
                          status: !audio.isSupported ? "Needs macOS 14.2 or later"
                              : (audio.soundEnabled ? (detail.isEmpty ? "Per-app volume and effects" : detail.joined(separator: " · "))
                                 : "Apps play directly"),
                          statusTone: audio.soundEnabled ? nil : .neutral,
                          active: audio.soundEnabled,
                          open: openAudio) {
                Toggle("App Audio", isOn: Binding(get: { audio.soundEnabled }, set: { audio.soundEnabled = $0 }))
                    .disabled(!audio.isSupported)
                    .help(audio.soundEnabled ? "Turn off per-app volume and effects" : "Turn on per-app volume and effects")
            } menu: {
                if audio.isSupported {
                    Button(audio.soundEnabled ? "Turn Off App Audio" : "Turn On App Audio") { audio.soundEnabled.toggle() }
                }
                tileMenu(.audio)
            }
        case .folderRules, .textActions, .files, .focus:
            if let status = AOMModuleStatusBoard.status(for: module) {
                AOMModuleStatusTile(status: status, open: { appState.selectedMainTab = module.tab })
            }
        case .systemTools:
            AOMModuleTile(.systemTools,
                          metric: "\(SystemToolsInventory.count)", unit: "tools",
                          status: keepAwake.isActive ? "Keep Awake \(keepAwake.remainingDescription ?? "on")"
                              : SystemToolsInventory.subtitle,
                          statusTone: keepAwake.isActive ? .info : nil,
                          active: true,
                          open: { appState.selectedMainTab = .tools }) {
                WorkspaceTileChevron()
            } menu: {
                tileMenu(.systemTools)
            }
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


    /// Launch tiles (Shortcuts gallery, Control Center): the built-in actions
    /// in the order chosen in Customize Workspace, then the automations you
    /// pinned. Drag a tile onto another to move it; the context menu moves
    /// and removes it too; every change is undoable.
    private var quickActions: some View {
        let kinds = layout.visibleQuickActions
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Quick actions", detail: pinned.isEmpty ? nil : "\(pinned.count) pinned") {
                AOMCardLink("Customize", symbol: nil) { showsCustomize = true }
            }
            if kinds.isEmpty && pinned.isEmpty {
                hiddenTilesRow("Every quick action is hidden.")
            } else {
                // Round buttons straight on the glass, Control Center style.
                AOMGlassGroup {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMSize.quickActionCell), spacing: AOMSpace.x2, alignment: .top)],
                          alignment: .leading, spacing: AOMSpace.x4) {
                    ForEach(kinds) { kind in
                        quickActionTile(kind)
                    }
                    ForEach(pinned) { trigger in
                        let canRun = trigger.isEnabled && !trigger.actions.isEmpty && !trigger.aomTypesText
                        WorkspaceQuickAction(trigger.displayName, symbol: canRun ? "bolt.fill" : "bolt",
                                             active: canRun,
                                             keys: { if case .keyboardShortcut(let shortcut) = trigger.input { return shortcut.displayString }; return nil }(),
                                             running: runStates[trigger.id] == .running,
                                             help: canRun ? "Run “\(trigger.displayName)”" : "Open “\(trigger.displayName)” in Automation") {
                            if canRun { run(trigger) } else { open(trigger) }
                        }
                        .contextMenu {
                            if canRun { Button("Run") { run(trigger) } }
                            Button("Open in Automation") { open(trigger) }
                            Divider()
                            Button("Unpin from Workspace") { appState.toggleFavorite(trigger) }
                        }
                    }
                }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    // MARK: Utilities: the deeper settings, one click away

    private struct UtilityLink: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    private func openSettingsTarget(_ target: String) {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .aomShowSettingsCategory, object: target)
        }
    }

    private var utilityLinks: [UtilityLink] {
        [
            UtilityLink(id: "hyperKey", title: "Hyper Key & Remaps", detail: "Caps Lock as ⌃⌥⌘⇧, key remaps",
                        symbol: "command.square") { openSettingsTarget("automation") },
            UtilityLink(id: "inputSources", title: "Input Sources", detail: "Switch Korean and English by app",
                        symbol: "globe") { openSettingsTarget("general") },
            UtilityLink(id: "linkRules", title: "Browser Links", detail: "Route URLs, strip tracking tags",
                        symbol: "arrow.triangle.branch") { openSettingsTarget("sheet:linkRules") },
            UtilityLink(id: "floatingWidgets", title: "Floating Menus", detail: "Palettes and screen widgets",
                        symbol: "menubar.rectangle") { FloatingMenuController.shared.edit() },
            UtilityLink(id: "snapZones", title: "Snap Zones", detail: "Drop areas and display layouts",
                        symbol: "rectangle.split.3x3") { appState.selectedMainTab = .snapping },
            UtilityLink(id: "clickHints", title: "Click Hints", detail: "Click anything from the keyboard",
                        symbol: "keyboard") { appState.selectedMainTab = .textActions },
            UtilityLink(id: "audioMixer", title: "Audio Mixer", detail: "Per-app volume and EQ",
                        symbol: "slider.vertical.3") { AppAudioMixerService.shared.showPanel() },
            UtilityLink(id: "globalShortcuts", title: "Shortcuts", detail: "Capture, clipboard and tool keys",
                        symbol: "keyboard.badge.ellipsis") { openSettingsTarget("shortcuts") }
        ]
    }

    /// One card of plain rows, two columns wide (System Settings' grouped
    /// rows): a monochrome glyph, the name, a short detail and a chevron.
    private var utilities: some View {
        let links = utilityLinks
        let columns = mainWidth >= 720 ? 2 : 1
        return VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle("Utilities")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.x1), count: columns),
                      alignment: .leading, spacing: 0) {
                ForEach(links) { link in
                    Button(action: link.action) {
                        HStack(spacing: AOMSpace.x3) {
                            Image(systemName: link.symbol)
                                .font(AOMFont.body)
                                .foregroundStyle(AOMColor.textSecondary)
                                .frame(width: AOMIcon.row)
                            Text(link.title)
                                .foregroundStyle(AOMColor.text)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text(link.detail)
                                .font(AOMFont.callout)
                                .foregroundStyle(AOMColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: AOMSpace.x2)
                            Image(systemName: "chevron.right")
                                .font(AOMFont.caption.weight(.semibold))
                                .foregroundStyle(AOMColor.textTertiary)
                        }
                        .padding(.horizontal, AOMSpace.x3)
                        .frame(minHeight: AOMSize.rowStandard)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AOMRowButtonStyle())
                    .help("\(link.title): \(link.detail)")
                }
            }
            .padding(AOMSpace.x1)
            .aomCard(padding: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utilities")
    }

    private func quickActionTile(_ kind: WorkspaceQuickActionKind) -> some View {
        let recordingNow = kind == .recordScreen && recording.isRecording
        return WorkspaceQuickActionCell(kind: kind, recording: recordingNow,
                                        accepts: { $0 != kind },
                                        drop: { dragged in move(dragged, before: kind) }) {
            kind.run()
        }
        .contextMenu {
            Button(recordingNow ? "Stop Recording" : "Run") { kind.run() }
            Button("Open \(kind.module.title)") { appState.selectedMainTab = kind.module.tab }
            Divider()
            if layout.canMove(kind, by: -1) { Button("Move Left") { move(kind, by: -1) } }
            if layout.canMove(kind, by: 1) { Button("Move Right") { move(kind, by: 1) } }
            Button("Remove from Quick Actions") { hide(kind.layoutID, name: "Quick Action", title: kind.title) }
            Button("Customize Workspace…") { showsCustomize = true }
        }
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

    // MARK: Overview: recent activity, today, this Mac

    /// Three equal cards in one row at the default window size (Food Truck
    /// dashboard, Xcode Organizer), two columns with activity underneath in
    /// narrower windows, one column below that.
    @ViewBuilder
    private func overview(_ snapshot: WorkspaceSnapshot) -> some View {
        let parts = [AOMWorkspaceLayout.Part.recent, .today, .thisMac].filter(layout.shows)
        if parts.count == 3 && contentWidth >= 960 {
            HStack(alignment: .top, spacing: AOMSpace.tileGap) {
                ForEach(parts) { part in
                    overviewCard(part, snapshot).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if parts.count == 3 && contentWidth >= 600 {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                HStack(alignment: .top, spacing: AOMSpace.tileGap) {
                    todayCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                    thisMacCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                recentActivity(snapshot.recent)
            }
        } else if parts.count == 2 && contentWidth >= 600 {
            HStack(alignment: .top, spacing: AOMSpace.tileGap) {
                ForEach(parts) { part in
                    overviewCard(part, snapshot).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if !parts.isEmpty {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                ForEach(parts) { part in overviewCard(part, snapshot) }
            }
        }
    }

    @ViewBuilder
    private func overviewCard(_ part: AOMWorkspaceLayout.Part, _ snapshot: WorkspaceSnapshot) -> some View {
        switch part {
        case .recent: recentActivity(snapshot.recent)
        case .today: todayCard
        case .thisMac: thisMacCard
        default: EmptyView()
        }
    }

    private func recentActivity(_ events: [WorkspaceActivity]) -> some View {
        AOMSectionCard("Recent activity", fillsHeight: true, contentPadding: 0, accessory: {
            AOMCardLink("View All") { appState.selectedMainTab = .insights }
        }) {
            if events.isEmpty {
                WorkspaceEmptyCard(symbol: "clock.arrow.circlepath", title: "No activity yet",
                                   message: "Automations you run, captures and copies appear here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        WorkspaceActivityRow(event: event, showsDivider: index > 0)
                    }
                }
                .padding(.vertical, AOMSpace.x1)
            }
        }
        .accessibilityLabel("Recent activity")
    }

    // MARK: Today

    /// Counts from the logs AOM already keeps: fired automations
    /// (GestureStatistics), captures (CaptureHistory) and copies
    /// (ClipboardStore), for today and each of the last seven days.
    fileprivate func week(now: Date = Date()) -> [WorkspaceDay] {
        weekCache.days(actions: activity.value.map(\.timestamp),
                       captures: history.entries.map(\.capturedAt),
                       copies: clipboard.entries.map(\.lastCopiedAt), now: now)
    }

    private var todayCard: some View {
        let days = week()
        let today = days.last ?? WorkspaceDay(date: Date(), actions: 0, captures: 0, copies: 0)
        let total = days.reduce(0) { $0 + $1.total }
        return AOMSectionCard("Today", fillsHeight: true, contentPadding: AOMSpace.cardPadding, accessory: {
            AOMCardLink("Insights") { appState.selectedMainTab = .insights }
        }) {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                HStack(alignment: .top, spacing: AOMSpace.x3) {
                    ForEach(WorkspaceDay.Kind.allCases) { kind in
                        WorkspaceFigure(value: today.count(kind), label: kind.title, hue: kind.hue)
                    }
                }
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    Text(total == 0 ? "Last 7 days" : "Last 7 days · \(total.formatted())")
                        .font(AOMFont.caption.weight(.medium))
                        .foregroundStyle(AOMColor.textSecondary)
                        .monospacedDigit()
                    WorkspaceWeekChart(days: days)
                        .equatable()
                        .frame(height: 96)
                }
            }
        }
    }

    // MARK: This Mac

    private var thisMacCard: some View {
        WorkspaceSystemCard { appState.selectedMainTab = .tools }
    }

    // MARK: Recent activity

    fileprivate func recentEvents() -> [WorkspaceActivity] {
        var events: [WorkspaceActivity] = []
        let byInput = Dictionary(triggers.map { ($0.input.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        for (offset, event) in activity.value.suffix(Self.recentLimit).reversed().enumerated() {
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
        !setupSkipped && triggers.isEmpty && history.entries.isEmpty && !hasFired
    }
    fileprivate var moduleOnCount: Int {
        toolsOnCount + AOMModuleStatusBoard.all.filter { $0.isOn == true }.count
    }
    /// The six Tools modules that are on (System Tools is always available).
    fileprivate var toolsOnCount: Int {
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
    fileprivate var automationsOnCount: Int { triggers.filter(\.isEnabled).count }
    fileprivate var lastActionDate: Date? {
        [lastRuns.values.max(), history.entries.first?.capturedAt, clipboard.entries.first?.lastCopiedAt]
            .compactMap { $0 }.max()
    }
}

// MARK: - Snapshot

/// Everything one render needs, computed once per body.
private struct WorkspaceSnapshot {
    let hero: WorkspaceHeroState
    /// First-run setup strip (under the status line, not instead of it).
    let showsSetup: Bool
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
        if let first = blocking.first {
            // Count what the chips under the title and the sidebar badge count
            // (every required permission still missing), not only the blocking two.
            let missing = permissions.filter { $0.1 == .denied || $0.1 == .notDetermined }.count
            state = .blocked(first, count: max(missing, blocking.count))
        } else if home.isPaused {
            state = .paused(detail: home.pauseDetail)
        } else {
            state = .running(on: home.moduleOnCount, total: AOMModule.allCases.count,
                             automations: home.automationsOnCount, last: home.lastActionDate)
        }
        hero = state
        showsSetup = home.isFreshSetup
        attention = home.attentionItems(hero: state, setup: showsSetup)
        recent = home.recentEvents()
        lastRun = home.lastActionDateForAutomation
    }

    func status(_ permission: AOMPermission) -> AOMPermissionStatus? { statuses[permission] }
}

extension AOMHomeView {
    fileprivate var lastActionDateForAutomation: Date? { lastRuns.values.max() }
}

/// The status line's states (d.2; there is no observable "helper stopped"
/// state). First-run setup is a separate strip since 3.3.5.
enum WorkspaceHeroState: Equatable {
    case running(on: Int, total: Int, automations: Int, last: Date?)
    case paused(detail: String?)
    case blocked(AOMPermission, count: Int)

    var tone: AOMTone {
        switch self {
        case .running: return .success
        case .paused: return .neutral
        case .blocked: return .warning
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    var sentence: String {
        switch self {
        case .running: return "AOM is running"
        case .paused: return "AOM is paused"
        case .blocked(_, let count): return count == 1 ? "AOM needs 1 permission" : "AOM needs \(count) permissions"
        }
    }

    func detail(now: Date = Date()) -> String {
        switch self {
        case .running(let on, let total, let automations, let last):
            let counts = "\(on) of \(total) modules on · \(automations) automation\(automations == 1 ? "" : "s") on"
            return last.map { "\(counts) · last action \(AOMRelativeTime.string($0, now: now).lowercased())" } ?? counts
        case .paused(let detail):
            return detail ?? "Gestures, shortcuts and snapping are off until you resume."
        case .blocked(let permission, _):
            return permission == .accessibility
                ? "Gestures, shortcuts and window actions can't run until Accessibility is allowed."
                : "Keyboard shortcuts can't be detected until Input Monitoring is allowed."
        }
    }
}

// MARK: - Hero view

/// The status header (design-3.3.6 b.12): a 40 pt squircle in the state's
/// tone, the sentence in Title 2, the detail in Body, the permission chips,
/// and the one action at the trailing edge. Plain on the canvas while AOM is
/// running; a light tinted card when it is paused or needs a permission
/// (HIG Boxes: a box only when it says something).
private struct WorkspaceHero<Action: View, Strip: View>: View {
    let state: WorkspaceHeroState
    let chips: [(AOMPermission, AOMPermissionStatus)]
    @ViewBuilder var action: Action
    @ViewBuilder var strip: Strip

    init(state: WorkspaceHeroState, chips: [(AOMPermission, AOMPermissionStatus)],
         @ViewBuilder action: () -> Action, @ViewBuilder strip: () -> Strip) {
        self.state = state
        self.chips = chips
        self.action = action()
        self.strip = strip()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(alignment: .center, spacing: AOMSpace.x3) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        HStack(alignment: .center, spacing: Self.dotGap) {
                            statusDot
                            Text(state.sentence)
                                .font(AOMFont.pageTitle)
                                .foregroundStyle(AOMColor.text)
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            // Running needs no pill; only a state that asks for something gets one.
                            if state.tone != .success {
                                AOMStatusPill(state.tone == .warning ? "Action Needed" : "Standby", tone: state.tone)
                            }
                        }
                        Text(state.detail(now: context.date))
                            .font(AOMFont.callout)
                            .foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            // Under the sentence, not the dot: the dot and its gap.
                            .padding(.leading, Self.dotSize + Self.dotGap)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action
                    .fixedSize()
            }
            if chips.contains(where: { $0.1 == .denied || $0.1 == .notDetermined }) {
                WorkspacePermissionChips(chips: chips)
            }
            strip
        }
        // A pane like the others: its content inset by the pane padding, so
        // the dot and chips start on the same line as the setup card's text.
        .padding(AOMSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aomGlassPanel()
        .aomAnimation(.standard, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status: \(state.sentence)")
    }

    /// The state as one dot before the sentence (green running, grey
    /// paused, orange when something needs you); the words carry the meaning.
    private static var dotSize: CGFloat { AOMSpace.x2 }
    private static var dotGap: CGFloat { AOMSpace.x2 }

    private var statusDot: some View {
        Circle()
            .fill(state.tone.color)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .accessibilityHidden(true)
    }
}

// MARK: - Setup card

/// One first-run step.
struct WorkspaceSetupItem: Identifiable {
    var id: Int { number }
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    let actionTitle: String
    let action: () -> Void
}

/// First-run setup (HIG Onboarding: short, optional, teach by doing): a
/// header with determinate progress, Show the Tour and Skip, then the three
/// steps side by side, each with its real button. The next step's button is
/// the prominent one. "Hide Steps" folds it to the header and the next step.
private struct WorkspaceSetupCard: View {
    let steps: [WorkspaceSetupItem]
    @Binding var expanded: Bool
    var prominentNext = true
    let skip: () -> Void
    let tour: () -> Void

    private var doneCount: Int { steps.filter(\.done).count }
    private var next: WorkspaceSetupItem? { steps.first { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                AOMDivider()
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { AOMDivider(axis: .vertical).padding(.vertical, AOMSpace.x3) }
                        WorkspaceSetupStep(item: step, isNext: step.number == next?.number, prominent: prominentNext)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .aomCard(padding: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set up AOM, \(doneCount) of \(steps.count) done")
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text("Set up AOM")
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                HStack(spacing: AOMSpace.x2) {
                    ProgressView(value: Double(doneCount), total: Double(max(1, steps.count)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 96)
                        .accessibilityHidden(true)
                    Text(expanded || next == nil ? "\(doneCount) of \(steps.count) done · about a minute"
                         : "\(doneCount) of \(steps.count) done · Next: \(next?.title ?? "")")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            if let next, !expanded {
                if prominentNext {
                    Button(next.actionTitle, action: next.action).buttonStyle(.borderedProminent).help(next.detail)
                } else {
                    Button(next.actionTitle, action: next.action).buttonStyle(.bordered).help(next.detail)
                }
            }
            Button("Show the Tour", action: tour)
                .buttonStyle(.link)
                .help("A short tour of the main window. Help › Show Welcome Again opens it later.")
            Button("Skip", action: skip)
                .buttonStyle(.bordered)
                .help("Hide setup. Help › Show Welcome Again opens the tour.")
            AOMCardLink(expanded ? "Hide Steps" : "Show Steps", symbol: expanded ? "chevron.up" : "chevron.down") {
                withAnimation(AOMMotion.standard) { expanded.toggle() }
            }
        }
        .padding(.horizontal, AOMSpace.cardPadding)
        .padding(.vertical, AOMSpace.x3)
    }
}

/// One setup step as a column: number (or check) and title, the one-line
/// reason, then its button at the bottom so the three buttons line up.
private struct WorkspaceSetupStep: View {
    let item: WorkspaceSetupItem
    let isNext: Bool
    var prominent = true

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                ZStack {
                    Circle().fill(item.done ? AOMColor.success : (isNext ? AOMColor.accent : AOMColor.sunken))
                    if item.done {
                        Image(systemName: "checkmark").font(AOMFont.caption.weight(.bold)).foregroundStyle(.white)
                    } else {
                        Text("\(item.number)").font(AOMFont.caption.weight(.semibold))
                            .foregroundStyle(isNext ? Color.white : AOMColor.textSecondary)
                    }
                }
                .frame(width: AOMIcon.row + AOMSpace.x0_5, height: AOMIcon.row + AOMSpace.x0_5)
                .accessibilityHidden(true)
                // Two lines in narrow windows instead of a truncated title.
                Text(item.title)
                    .font(AOMFont.headline)
                    .foregroundStyle(item.done ? AOMColor.textSecondary : AOMColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.detail)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if item.done {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.successText)
                    .frame(minHeight: AOMIcon.hitArea - AOMSpace.x0_5)
            } else if isNext && prominent {
                Button(item.actionTitle, action: item.action).buttonStyle(.borderedProminent)
            } else {
                Button(item.actionTitle, action: item.action).buttonStyle(.bordered)
            }
        }
        .padding(AOMSpace.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(item.number): \(item.title)\(item.done ? ", done" : "")")
    }
}

/// One chip per permission AOM uses: glyph, name, state. A missing one opens
/// the right System Settings pane; when everything is allowed, one chip says
/// so. Wraps in narrow windows.
private struct WorkspacePermissionChips: View {
    let chips: [(AOMPermission, AOMPermissionStatus)]

    var body: some View {
        let missing = chips.filter { $0.1 == .denied || $0.1 == .notDetermined }
        if missing.isEmpty {
            AOMStatusPill("All permissions allowed", tone: .success, symbol: "checkmark.circle.fill")
        } else {
            WorkspaceFlowRow(spacing: AOMSpace.x2) {
                ForEach(chips, id: \.0) { permission, status in
                    chip(permission, status: status)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ permission: AOMPermission, status: AOMPermissionStatus) -> some View {
        if status == .granted || status == .manualReview {
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
    let showsDivider: Bool
    let dismiss: () -> Void

    private var symbol: String {
        switch item.kind {
        case .fixNow: return item.tone == .danger ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        case .upcoming: return "clock.fill"
        case .suggestion: return "lightbulb"
        }
    }

    /// Only problems take a status colour; a suggestion or a reminder is
    /// secondary text, so the one real warning stands out.
    private var tint: Color {
        switch item.kind {
        case .fixNow: return item.tone.color
        case .upcoming, .suggestion: return AOMColor.textSecondary
        }
    }

    var body: some View {
        // A grouped-form row: Body glyph and sentence, one regular button,
        // 44 pt tall, the divider starting under the text.
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol)
                .font(AOMFont.body)
                .foregroundStyle(tint)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            Text(item.text)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(item.actionTitle, action: item.action)
                .buttonStyle(.bordered)
            if item.kind == .suggestion {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea - AOMSpace.x1, height: AOMIcon.hitArea - AOMSpace.x1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.rowDouble)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        }
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
            .font(AOMFont.body.weight(.semibold))
            .foregroundStyle(AOMColor.textTertiary)
            // Trailing, so the chevron ends on the same line as the switches
            // and buttons in the module rows' control slot.
            .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea, alignment: .trailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A launch tile (Shortcuts gallery, Control Center): a 28 pt monochrome
/// mark, the name in Body and the shortcut under it like a menu's
/// key equivalent. Beside each other when the cell is wide enough, the glyph
/// over the name in narrow windows (five per row either way). A tile whose
/// action is running (a recording, a focus session) pulses its glyph.
private struct WorkspaceQuickAction: View {
    let title: String
    let symbol: String
    var active = true
    var keys: String?
    var running = false
    var live = false
    var help: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String, active: Bool = true, keys: String? = nil, running: Bool = false,
         live: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.active = active
        self.keys = keys
        self.running = running
        self.live = live
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                badge
                Text(title)
                    .font(AOMFont.caption.weight(.medium))
                    .foregroundStyle(active ? AOMColor.text : AOMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let keys {
                    Text(keys)
                        .font(AOMFont.badge)
                        .foregroundStyle(AOMColor.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help.map { keys == nil ? $0 : "\($0) (\(keys!))" } ?? (keys.map { "\(title) (\($0))" } ?? title))
        .accessibilityLabel(title)
        .accessibilityHint(keys.map { "Shortcut \($0)" } ?? "")
        .accessibilityAddTraits(live ? .updatesFrequently : [])
    }

    /// The round glass button: system Liquid Glass on macOS 26+, a frosted
    /// pane before. A running action (recording, focus) fills with the accent.
    private var badge: some View {
        ZStack {
            if running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(live ? Color.white : (active ? AOMColor.text : AOMColor.textTertiary))
                    .symbolEffect(.pulse, options: .repeating, isActive: live && !reduceMotion)
            }
        }
        .frame(width: AOMSize.quickActionButton, height: AOMSize.quickActionButton)
        .aomRoundGlass(tint: live ? AOMColor.accent : nil)
    }
}

/// A built-in quick action on Workspace: the tile, its live state (the
/// focus session from `AOMModuleStatusBoard`, observed here so a countdown
/// redraws one tile, not the page), and drag to reorder: drop another quick
/// action on it to put that one in front (an accent ring while it hovers).
private struct WorkspaceQuickActionCell: View {
    let kind: WorkspaceQuickActionKind
    var recording = false
    let accepts: (WorkspaceQuickActionKind) -> Bool
    let drop: (WorkspaceQuickActionKind) -> Void
    let action: () -> Void
    @State private var targeted = false

    init(kind: WorkspaceQuickActionKind, recording: Bool, accepts: @escaping (WorkspaceQuickActionKind) -> Bool,
         drop: @escaping (WorkspaceQuickActionKind) -> Void, action: @escaping () -> Void) {
        self.kind = kind
        self.recording = recording
        self.accepts = accepts
        self.drop = drop
        self.action = action
    }

    var body: some View {
        let focusing = kind == .focusSession && FocusModule.isSessionActive
        WorkspaceQuickAction(recording ? "Stop Recording" : kind.title,
                             symbol: recording ? "stop.fill" : kind.symbol,
                             keys: kind.shortcut,
                             live: recording || focusing,
                             help: recording ? "Stops the screen recording" : kind.help,
                             action: action)
            .aomDropTarget(targeted, radius: AOMRadius.card)
            .draggable(kind.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(WorkspaceQuickActionKind.init(rawValue:)), accepts(dragged) else {
                    return false
                }
                drop(dragged)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// "Productivity  n of 4 on", observing the four modules' status objects so
/// the count stays live without redrawing the whole page.
private struct WorkspaceProductivityTitle: View {
    @ObservedObject private var folderRules = AOMModuleStatusBoard.folderRules
    @ObservedObject private var textActions = AOMModuleStatusBoard.textActions
    @ObservedObject private var files = AOMModuleStatusBoard.files
    @ObservedObject private var focus = AOMModuleStatusBoard.focus

    var body: some View {
        let statuses = [folderRules, textActions, files, focus]
        let on = statuses.filter { $0.isOn == true }.count
        let switchable = statuses.filter { $0.isOn != nil }.count
        AOMSectionTitle("Productivity", detail: switchable == 0 ? nil : "\(on) of \(switchable) on")
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
    var showsDivider = true
    @State private var hovering = false

    var body: some View {
        Button(action: event.open) {
            HStack(spacing: AOMSpace.x2) {
                AOMModuleBadge(event.module, size: AOMIcon.row)
                Text(event.title)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AOMSpace.x2)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AOMRelativeTime.string(event.date, now: context.date))
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(minHeight: AOMSize.rowStandard)
            .background(hovering ? AOMColor.sunken.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        }
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

/// An empty card's content (design-3.3.6 b.9): a hierarchical glyph, a
/// Headline and one Body sentence, centred in the space the card has.
private struct WorkspaceEmptyCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol)
                .font(.system(size: AOMIcon.tileGlyph + AOMSpace.x2))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AOMColor.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(AOMFont.headline)
                .foregroundStyle(AOMColor.text)
            Text(message)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AOMSpace.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 160)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today

/// One day of AOM activity for the Today card and its chart.
struct WorkspaceDay: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case actions, captures, copies
        var id: String { rawValue }
        var title: String {
            switch self {
            case .actions: return "Actions"
            case .captures: return "Captures"
            case .copies: return "Copies"
            }
        }
        var module: AOMModule {
            switch self {
            case .actions: return .automation
            case .captures: return .capture
            case .copies: return .clipboard
            }
        }
        var hue: Color { module.hue }
    }

    let date: Date
    let actions: Int
    let captures: Int
    let copies: Int
    var id: Date { date }
    var total: Int { actions + captures + copies }

    func count(_ kind: Kind) -> Int {
        switch kind {
        case .actions: return actions
        case .captures: return captures
        case .copies: return copies
        }
    }
}

/// A big figure over its label with the hue dot that keys the chart.
private struct WorkspaceFigure: View {
    let value: Int
    let label: String
    let hue: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
            Text(value.formatted())
                .font(AOMFont.metricLarge)
                .foregroundStyle(value == 0 ? AOMColor.textSecondary : AOMColor.text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: AOMSpace.x1) {
                Circle().fill(hue).frame(width: AOMIcon.dot, height: AOMIcon.dot)
                Text(label)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) today: \(value)")
    }
}

/// Seven stacked bars (actions, captures, copies), starting at zero with
/// weekday labels and at most three grid lines (HIG Charts); today's label
/// is bold. A quiet sentence replaces the empty plot.
private struct WorkspaceWeekChart: View, Equatable {
    let days: [WorkspaceDay]

    var body: some View {
        let peak = days.map(\.total).max() ?? 0
        let today = days.last?.date
        Chart {
            ForEach(days) { day in
                ForEach(WorkspaceDay.Kind.allCases) { kind in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Count", day.count(kind)),
                            width: .ratio(0.55))
                        .foregroundStyle(by: .value("Kind", kind.title))
                }
            }
        }
        .chartForegroundStyleScale(domain: WorkspaceDay.Kind.allCases.map(\.title),
                                   range: WorkspaceDay.Kind.allCases.map(\.hue))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(4, peak))
        .chartXAxis {
            AxisMarks(values: days.map(\.date)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(AOMFont.caption.weight(date == today ? .bold : .regular))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel().font(AOMFont.caption)
            }
        }
        .overlay {
            if peak == 0 {
                Text("Nothing this week yet")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x1)
                    .background(AOMColor.overlaySurface, in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days")
        .accessibilityValue(days.map { day in
            "\(day.date.formatted(.dateTime.weekday(.wide))): \(day.actions) actions, \(day.captures) captures, \(day.copies) copies"
        }.joined(separator: "; "))
    }
}

// MARK: - This Mac

/// Keep two-second monitor publications inside this card. Observing the
/// monitor at Workspace root also rebuilt every tile and seven-day chart,
/// even when the user had hidden the This Mac card.
private struct WorkspaceSystemCard: View {
    let openTools: () -> Void
    @StateObject private var system = SystemStatusMonitor()
    var body: some View {
        AOMSectionCard("This Mac", fillsHeight: true, contentPadding: 0, accessory: {
            AOMCardLink("System Tools", action: openTools)
        }) {
            VStack(spacing: 0) {
                let cpu = system.cpuPercent
                WorkspaceGaugeRow(symbol: "cpu", title: "CPU",
                                  value: cpu.map { "\(Int($0.rounded()))%" } ?? "…",
                                  fraction: cpu.map { $0 / 100 },
                                  tone: (cpu ?? 0) > 85 ? .warning : nil, showsDivider: false)
                if let memory = system.memory {
                    WorkspaceGaugeRow(symbol: "memorychip", title: "Memory",
                                      value: "\(SystemStatus.memorySize(memory.used)) of \(SystemStatus.memorySize(memory.total))",
                                      fraction: memory.total > 0 ? Double(memory.used) / Double(memory.total) : nil,
                                      tone: (memory.pressureLevel ?? 1) > 1 ? .warning : nil)
                }
                if let disk = system.disk {
                    WorkspaceGaugeRow(symbol: "internaldrive", title: "Disk",
                                      value: "\(SystemStatus.size(disk.available)) free of \(SystemStatus.size(disk.total))",
                                      fraction: disk.total > 0 ? Double(disk.total - disk.available) / Double(disk.total) : nil,
                                      tone: disk.total > 0 && Double(disk.available) / Double(disk.total) < 0.1 ? .warning : nil)
                }
                if let battery = system.battery {
                    WorkspaceGaugeRow(symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                                      title: "Battery",
                                      value: "\(battery.percent)%" + (battery.isCharging ? " · Charging" : (battery.onPower ? " · Power adapter" : "")),
                                      fraction: Double(battery.percent) / 100,
                                      tone: !battery.onPower && battery.percent <= 15 ? .warning : .success)
                } else if !system.hasBattery {
                    WorkspaceGaugeRow(symbol: "powerplug", title: "Power", value: "Power adapter", fraction: nil, tone: nil)
                }
            }
            .padding(.vertical, AOMSpace.x1)
        }
        .accessibilityLabel("This Mac")
        .aomOnWindowVisibilityChange { visible in
            if visible { system.start() } else { system.stop() }
        }
        .onDisappear { system.stop() }
    }
}

/// A LabeledContent-style row (System Settings › About) with a continuous
/// capacity bar under it (HIG Gauges; Storage and Disk Utility): green,
/// accent or orange by meaning, never colour alone.
private struct WorkspaceGaugeRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    let tone: AOMTone?
    var showsDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: symbol)
                    .font(AOMFont.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
                Text(title)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                Spacer(minLength: AOMSpace.x2)
                if tone == .warning {
                    Image(systemName: AOMTone.warning.symbol)
                        .imageScale(.small)
                        .foregroundStyle(AOMColor.warning)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(AOMFont.body.monospacedDigit())
                    .foregroundStyle(tone == .warning ? AOMColor.warningText : AOMColor.textSecondary)
                    .lineLimit(1)
            }
            if let fraction {
                WorkspaceCapacityBar(fraction: fraction, color: tone == .warning ? AOMColor.warning
                                                                : (tone == .success ? AOMColor.success : AOMColor.accent))
                    .padding(.leading, AOMIcon.row + AOMSpace.x2)
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMSize.rowDouble, alignment: .center)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value + (tone == .warning ? ", needs attention" : ""))
    }
}

private struct WorkspaceCapacityBar: View {
    let fraction: Double
    let color: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AOMColor.track)
                Capsule().fill(color)
                    .frame(width: max(AOMIcon.dot, proxy.size.width * min(1, max(0, fraction))))
            }
            .overlay { if contrast == .increased { Capsule().strokeBorder(AOMColor.strongLine, lineWidth: 1) } }
        }
        .frame(height: AOMIcon.dot)
        .aomAnimation(.standard, value: fraction)
        .accessibilityHidden(true)
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

}

// MARK: - Shared row components

/// A 3.4 module's tile, drawn from the live `AOMModuleStatus` the module
/// publishes: its count, one status line, and its switch when it has one.
/// The context menu has Turn On/Off (when the module has a switch) and the
/// caller's items (Hide from Workspace, Customize Workspace…).
struct AOMModuleStatusTile<MenuItems: View>: View {
    @ObservedObject var status: AOMModuleStatus
    let open: () -> Void
    @ViewBuilder var menuItems: MenuItems

    init(status: AOMModuleStatus, open: @escaping () -> Void, @ViewBuilder menu: () -> MenuItems) {
        self.status = status
        self.open = open
        self.menuItems = menu()
    }

    var body: some View {
        // With a switch, a tile without a count shows no figure: the switch
        // already says on or off. A module with neither a count nor an on/off
        // state (Files, an idle Focus) shows none either — its status line
        // says what it does; a lone "…" read as a broken value.
        let hasSwitch = status.isOn != nil && status.setOn != nil
        let metric = status.count.map { $0.formatted() }
            ?? (hasSwitch ? "" : (status.isOn == false ? "Off" : (status.isOn == true ? "On" : "")))
        AOMModuleTile(status.module,
                      metric: metric,
                      unit: status.count == nil ? nil : status.unit,
                      status: status.attention ?? status.detail,
                      statusTone: status.attention != nil ? .warning : (status.isOn == false ? .neutral : nil),
                      active: status.isOn ?? true,
                      open: open) {
            if let isOn = status.isOn, let setOn = status.setOn {
                Toggle(status.module.title, isOn: Binding(get: { isOn }, set: { setOn($0) }))
                    .help(isOn ? "Turn off \(status.module.title)" : "Turn on \(status.module.title)")
            } else {
                WorkspaceTileChevron()
            }
        } menu: {
            if let isOn = status.isOn, let setOn = status.setOn {
                Button(isOn ? "Turn Off \(status.module.title)" : "Turn On \(status.module.title)") { setOn(!isOn) }
            }
            menuItems
        }
    }
}

extension AOMModuleStatusTile where MenuItems == EmptyView {
    init(status: AOMModuleStatus, open: @escaping () -> Void) {
        self.init(status: status, open: open, menu: { EmptyView() })
    }
}
