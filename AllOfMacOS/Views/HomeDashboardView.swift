import AppKit
import SwiftUI

// MARK: - Workspace

/// The Workspace: today on this Mac, one card per tool.
///
/// Problems that need you (permissions, a paused engine, a taken shortcut,
/// clipboard storage) and work in progress (a running recording) sit on top
/// only while they exist. Below, each tool shows its live state and its one
/// everyday action — capture modes and the latest shots, the newest clipboard
/// items, your pinned or recent automations, and how windows snap — with a
/// link into the full page. Counts are one line at the bottom; the figures
/// live in Insights. (Things "Today", CleanMyMac's tool tiles, Raycast's root
/// favourites; WWDC25 "Design foundations": where am I, what can I do.)
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var stats = GestureStatistics.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var recording = ScreenRecordingService.shared
    @ObservedObject private var audio = AppAudioMixerService.shared
    @StateObject private var toast = AOMToastModel()
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?
    @State private var runStates: [UUID: AOMRunState] = [:]

    /// Two card columns from this width.
    static let wideWidth: CGFloat = 760
    static let maximumContentWidth: CGFloat = AOMSize.contentMaxWidth
    static let rowsPerSection = 4

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
        let lastRuns = lastRuns
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideWidth
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.m) {
                    notices
                    audioQuickBar
                    if wide {
                        Grid(alignment: .topLeading, horizontalSpacing: AOMSpace.m, verticalSpacing: AOMSpace.m) {
                            GridRow {
                                captureCard
                                clipboardCard
                            }
                            GridRow {
                                automationCard(lastRuns: lastRuns)
                                tilingCard
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        captureCard
                        clipboardCard
                        automationCard(lastRuns: lastRuns)
                        tilingCard
                    }
                    summaryLine
                }
                .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
                .padding(.horizontal, wide ? AOMSpace.l : AOMSpace.m)
                .padding(.top, AOMSpace.m)
                .padding(.bottom, AOMSpace.l)
                // Fill the window: on a wide layout the 2×2 grid stretches to
                // the viewport so the cards use the space instead of leaving a
                // large void below (the "wasted space" fix).
                .frame(maxWidth: .infinity, minHeight: wide ? geometry.size.height : nil, alignment: .top)
            }
        }
        .navigationTitle("Workspace")
        .navigationSubtitle(subtitle(lastRuns: lastRuns))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.selectedMainTab = .gestures
                    appState.showingAddTrigger = true
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
                .help("New Automation (⌘N)")
            }
        }
        // ⌘N and ⌘F work from the Workspace too: they open the Automation page
        // (the help text above promised ⌘N, but the command was disabled here).
        .focusedSceneValue(\.triggerEditorCommands, TriggerEditorCommandActions(
            search: { appState.selectedMainTab = .gestures },
            newTrigger: {
                appState.selectedMainTab = .gestures
                appState.showingAddTrigger = true
            }))
        .task {
            while !Task.isCancelled {
                let current = AOMPermission.required.map { ($0, $0.status) }
                if current.map(\.1) != permissions.map(\.1) { permissions = current }
                let conflict = ShortcutConflicts.clipboardHistoryConflict()
                if conflict != shortcutConflict { shortcutConflict = conflict }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .aomToast(toast.message)
    }

    private func subtitle(lastRuns: [UUID: Date]) -> String {
        let date = Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard appState.globalEnabled else { return "\(date) · Automation paused" }
        var parts = [date]
        if let latest = lastRuns.values.max() { parts.append("last run \(AOMRelativeTime.string(latest).lowercased())") }
        return parts.joined(separator: " · ")
    }

    // MARK: Notices (only when something needs you)

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }

    @ViewBuilder private var notices: some View {
        let missing = missingPermissions
        if recording.isRecording || !appState.globalEnabled || !missing.isEmpty || shortcutConflict != nil
            || clipboard.storageWarning != nil {
            VStack(spacing: AOMSpace.xs) {
                if recording.isRecording {
                    AOMNotice(.error, recording.isPaused ? "Recording paused" : "Recording your screen",
                              detail: Self.elapsed(recording.elapsedSeconds)) {
                        Button(recording.isPaused ? "Resume" : "Pause") { recording.togglePause() }
                        Button("Stop") {
                            Task {
                                _ = try? await recording.stopRecording()
                                toast.show("Recording saved")
                            }
                        }
                        .buttonStyle(AOMTintedButtonStyle(tint: AOMTheme.danger))
                    }
                }
                if !appState.globalEnabled {
                    AOMNotice(.warning, "Automation is paused",
                              detail: "Gestures and shortcuts pass straight through to your apps.") {
                        Button("Resume") { appState.toggleGlobalEnabled() }.buttonStyle(AOMTintedButtonStyle())
                    }
                }
                if let first = missing.first {
                    AOMNotice(.error, "\(ListFormatter.localizedString(byJoining: missing.map(\.title))) \(missing.count == 1 ? "is" : "are") off",
                              detail: "Gestures, shortcuts and Type Text can't run until AOM is allowed.") {
                        Button("Open System Settings…") { _ = first.openSettings() }.buttonStyle(AOMTintedButtonStyle())
                    }
                }
                if let conflict = shortcutConflict {
                    AOMNotice(.warning, "\(conflict.shortcut.displayString) is also used by \(conflict.appName)",
                              detail: "The clipboard shelf may not open with it.") {
                        Button("Use \(ShortcutConflicts.alternativeHistoryShortcut.displayString)") {
                            ClipboardShortcuts.shared.setShortcut(ShortcutConflicts.alternativeHistoryShortcut, for: .history)
                            shortcutConflict = nil
                        }
                        .buttonStyle(AOMTintedButtonStyle())
                    }
                }
                if let warning = clipboard.storageWarning {
                    AOMNotice(.warning, "Clipboard history isn't being saved", detail: warning) {
                        Button("Try Again") { Task { await clipboard.recoverStorage() } }.buttonStyle(AOMTintedButtonStyle())
                    }
                }
            }
        }
    }

    static func elapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Capture

    private func captureKeys(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    private var captureCard: some View {
        let latest = history.entries.first.map { "last \(AOMRelativeTime.string($0.capturedAt).lowercased())" }
        return AOMSectionCard("Capture", fillsHeight: true, symbol: "camera.viewfinder", tint: AOMMainTab.capture.accentColor,
                              detail: history.entries.isEmpty ? nil : latest) {
            AOMCardLink("Library") { appState.selectedMainTab = .capture }
        } content: {
            VStack(alignment: .leading, spacing: AOMSpace.s) {
                HStack(spacing: 2) {
                    AOMModeButton("Area", symbol: "viewfinder", shortcut: captureKeys(.captureArea), compact: true) {
                        CaptureCoordinator.shared.captureArea()
                    }
                    AOMModeButton("Window", symbol: "macwindow", shortcut: captureKeys(.captureWindow), compact: true) {
                        CaptureCoordinator.shared.captureWindowInteractive()
                    }
                    AOMModeButton("Full Screen", symbol: "menubar.dock.rectangle", shortcut: captureKeys(.captureFullscreen), compact: true) {
                        CaptureCoordinator.shared.captureFullscreen()
                    }
                    AOMModeButton("Text", symbol: "text.viewfinder", shortcut: captureKeys(.ocr), compact: true) {
                        CaptureCoordinator.shared.captureText()
                    }
                    AOMModeButton(recording.isRecording ? "Recording" : "Record", symbol: "record.circle",
                                  tint: AOMTheme.danger, shortcut: captureKeys(.recordScreen), compact: true) {
                        recording.promptAndStartRecording()
                    }
                    .disabled(recording.isRecording)
                }
                .padding(.horizontal, -AOMSpace.xxs)
                if history.entries.isEmpty {
                    Text("Your screenshots and recordings appear here, ready to copy, edit or drag into any app.")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: AOMSpace.xs) {
                        ForEach(history.entries.prefix(3)) { entry in
                            HomeCaptureThumb(entry: entry) {
                                CaptureItemActions.copy(entry)
                                toast.show("Copied capture")
                            }
                        }
                        ForEach(0..<max(0, 3 - min(3, history.entries.count)), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: Clipboard

    private var clipboardCard: some View {
        let count = clipboard.entries.count
        return AOMSectionCard("Clipboard", fillsHeight: true, symbol: "doc.on.clipboard", tint: AOMMainTab.clipboard.accentColor,
                              detail: count == 0 ? nil : "\(count.formatted()) item\(count == 1 ? "" : "s")") {
            AOMCardLink("Library") { appState.selectedMainTab = .clipboard }
        } content: {
            if clipboard.isLoading && clipboard.entries.isEmpty {
                Text("Unlocking clipboard history…").font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
            } else if clipboard.entries.isEmpty {
                Text(clipboard.paused ? "Clipboard history is paused. Nothing you copy is kept until you resume."
                     : "Copied text, links, images and files appear here — searchable and kept on this Mac.")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let entries = Array(clipboard.entries.prefix(Self.rowsPerSection))
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HomeClipboardRow(entry: entry) { copy(entry) }
                        if index < entries.count - 1 { AOMDivider().padding(.leading, 38) }
                    }
                }
                .padding(.horizontal, -AOMSpace.xs)
            }
        } footer: {
            AOMCardFooter {
                Button { ClipboardPanelController.shared.show() } label: {
                    Label("Open Shelf", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .buttonStyle(AOMTintedButtonStyle())
                if let keys = ClipboardShortcuts.shared.shortcut(for: .history)?.displayString {
                    AOMKeycap(text: keys)
                }
            } trailing: {
                Button(clipboard.paused ? "Resume" : "Pause") {
                    if clipboard.paused { clipboard.resume() } else { clipboard.pause() }
                }
                .buttonStyle(.borderless)
                .font(AOMType.caption)
                .help(clipboard.paused ? "Resume clipboard history" : "Stop recording what you copy until you resume")
            }
        }
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

    // MARK: Automation

    private func automationCard(lastRuns: [UUID: Date]) -> some View {
        let on = triggers.filter(\.isEnabled).count
        return AOMSectionCard("Automation", fillsHeight: true, symbol: "bolt", tint: AOMMainTab.gestures.accentColor,
                              detail: triggers.isEmpty ? nil : "\(on) of \(triggers.count) on") {
            AOMCardLink("All") { appState.selectedMainTab = .gestures }
        } content: {
            if triggers.isEmpty {
                Text("Connect a trackpad gesture, a key or a mouse button to the actions you repeat.")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let rows = automationRows(lastRuns: lastRuns)
                VStack(alignment: .leading, spacing: 4) {
                    if rows.title != "Automations" { Text(rows.title).aomSectionCaps() }
                    VStack(spacing: 0) {
                        ForEach(Array(rows.triggers.enumerated()), id: \.element.id) { index, trigger in
                            HomeAutomationRow(trigger: trigger, lastRun: lastRuns[trigger.id],
                                              runState: runStates[trigger.id] ?? .idle) { run(trigger) }
                            if index < rows.triggers.count - 1 { AOMDivider().padding(.leading, 38) }
                        }
                    }
                    .padding(.horizontal, -AOMSpace.xs)
                }
            }
        } footer: {
            AOMCardFooter {
                Button {
                    appState.selectedMainTab = .gestures
                    appState.showingAddTrigger = true
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
                .buttonStyle(AOMTintedButtonStyle())
            } trailing: {
                if pinned.isEmpty && !triggers.isEmpty {
                    Text("Pin from ⋯ to keep one here")
                        .font(AOMType.micro).foregroundStyle(AOMTheme.textTertiary).lineLimit(1)
                }
            }
        }
    }

    /// Pinned first; then what ran most recently; without history, the
    /// enabled automations stand in.
    private func automationRows(lastRuns: [UUID: Date]) -> (title: String, triggers: [Trigger]) {
        if !pinned.isEmpty { return ("Pinned", Array(pinned.prefix(Self.rowsPerSection))) }
        let recent = triggers
            .filter { lastRuns[$0.id] != nil }
            .sorted { (lastRuns[$0.id] ?? .distantPast) > (lastRuns[$1.id] ?? .distantPast) }
        if !recent.isEmpty { return ("Recently Used", Array(recent.prefix(Self.rowsPerSection))) }
        return ("Automations", Array(triggers.sorted { $0.isEnabled && !$1.isEnabled }.prefix(Self.rowsPerSection)))
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

    // MARK: Window Tiling

    private var tilingCard: some View {
        let zones = appState.effectiveSnapZones.filter(\.isEnabled)
        let shown = Array(zones.prefix(8))
        return AOMSectionCard("Window Tiling", fillsHeight: true, symbol: "rectangle.split.2x2", tint: AOMMainTab.snapping.accentColor,
                              detail: "\(zones.count) snap zone\(zones.count == 1 ? "" : "s")") {
            AOMCardLink("Layouts") { appState.selectedMainTab = .snapping }
        } content: {
            VStack(alignment: .leading, spacing: AOMSpace.s) {
                HStack(spacing: AOMSpace.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drag to Snap").font(AOMType.rowTitle)
                        Text(appState.currentPreset.snappingEnabled
                             ? (appState.currentPreset.snappingRequiresOption ? "Hold ⌥ while dragging a window to an edge or zone"
                                : "Drag a window to an edge, corner or zone")
                             : "Off — windows move freely")
                            .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: AOMSpace.xs)
                    Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                         set: { appState.setSnappingEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if !shown.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMSpace.xs), count: 4),
                              spacing: AOMSpace.xs) {
                        ForEach(shown) { zone in
                            AOMLayoutDiagram(zone: zone, highlighted: appState.currentPreset.snappingEnabled)
                                .frame(maxWidth: 76)
                                .help(zone.name)
                        }
                    }
                    .opacity(appState.currentPreset.snappingEnabled ? 1 : 0.55)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Snap zones: \(shown.map(\.name).joined(separator: ", "))")
                }
            }
        }
    }

    // MARK: Audio

    private var audioQuickBar: some View {
        HStack(spacing: AOMSpace.s) {
            Image(systemName: "waveform").foregroundStyle(AOMMainTab.audio.accentColor)
                .accessibilityHidden(true)
            Text("Audio").font(AOMType.headline)
            Text(!audio.soundEnabled ? "Off" : (audio.allAppsBoostEnabled ? "Boost on" : "Boost off"))
                .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            if audio.eqEnabled {
                Text("EQ: \(audio.eqPreset)").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.xs)
            AOMCardLink("Open Mixer") {
                UserDefaults.standard.set("Mixer", forKey: "AOMAudioWorkspaceSection")
                appState.selectedMainTab = .audio
            }
        }
        .padding(.horizontal, AOMSpace.m).padding(.vertical, AOMSpace.s)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
        .overlay(RoundedRectangle(cornerRadius: AOMRadius.card).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
    }

    // MARK: Summary

    private var summaryLine: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let runsToday = stats.events.filter { $0.fired && $0.timestamp >= today }.count
        let capturesToday = history.entries.filter { $0.capturedAt >= today }.count
        let parts = [
            "\(runsToday.formatted()) run\(runsToday == 1 ? "" : "s") today",
            "\(capturesToday) capture\(capturesToday == 1 ? "" : "s") today",
            "\(stats.totalFired.formatted()) runs recorded"
        ]
        return HStack(spacing: AOMSpace.xs) {
            Text(parts.joined(separator: " · "))
                .font(AOMType.caption)
                .foregroundStyle(AOMTheme.textTertiary)
                .lineLimit(1)
            Button("Insights") { appState.selectedMainTab = .insights }
                .buttonStyle(.link)
                .font(AOMType.caption)
        }
        .padding(.top, AOMSpace.xxs)
        .padding(.horizontal, AOMSpace.xxs)
    }
}

// MARK: - Rows and tiles

/// A Workspace automation row: open on click, run on hover (never for Type
/// Text, which could type a stored password into the focused field).
private struct HomeAutomationRow: View {
    @EnvironmentObject var appState: AppState
    let trigger: Trigger
    let lastRun: Date?
    let runState: AOMRunState
    let onRun: () -> Void
    @State private var hovering = false

    private var canRun: Bool { trigger.isEnabled && !trigger.actions.isEmpty && !trigger.aomTypesText }

    var body: some View {
        AOMAutomationRow(trigger: trigger) {
            if runState == .running {
                ProgressView().controlSize(.mini)
            } else if hovering && canRun {
                Button(action: onRun) {
                    Label("Run", systemImage: "play.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Run now")
            } else if let lastRun {
                Text(AOMRelativeTime.string(lastRun))
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, AOMSpace.xs)
        .background(hovering ? AOMTheme.cardAlt : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .contextMenu {
            Button("Open in Automation") { open() }
            if canRun { Button("Run Now", action: onRun) }
            Divider()
            Button(trigger.isFavorite ? "Unpin" : "Pin to Workspace") { appState.toggleFavorite(trigger) }
            Button(trigger.isEnabled ? "Turn Off" : "Turn On") { appState.toggleTrigger(trigger) }
        }
        .accessibilityAction(named: "Open in Automation") { open() }
        // The Run button only appears on hover; VoiceOver and keyboard users
        // reach the same command here.
        .accessibilityAction(named: "Run Now") { if canRun { onRun() } }
        .help("Open \(trigger.displayName)")
    }

    private func open() {
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
}

private struct HomeClipboardRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        AOMListRow(entry.title,
                   detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · ")) {
            Image(systemName: entry.kind.symbol).font(.system(size: 12, weight: .medium))
        } trailing: {
            if hovering {
                Image(systemName: "doc.on.doc").font(.system(size: 11.5)).foregroundStyle(AOMTheme.textSecondary)
                    .accessibilityHidden(true)
            } else if !entry.pinboardIDs.isEmpty {
                Image(systemName: "pin.fill").font(AOMType.micro).foregroundStyle(AOMTheme.textSecondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.horizontal, AOMSpace.xs)
        .background(hovering ? AOMTheme.cardAlt : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .help("Copy “\(entry.title.prefix(60))”")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy", onCopy)
    }
}

/// A capture thumbnail: copy and edit on hover, drag out anywhere, double-click to edit.
private struct HomeCaptureThumb: View {
    let entry: CaptureHistoryEntry
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            AOMTheme.cardAlt
            Image(nsImage: entry.thumbnail)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .padding(4)
            if entry.kind == .videoRecording {
                Image(systemName: "play.circle.fill").font(.system(size: 20)).foregroundStyle(.white, .black.opacity(0.45))
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? AOMTheme.blue.opacity(0.8) : AOMTheme.hairline, lineWidth: hovering ? 1.5 : 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                HStack(spacing: 4) {
                    CaptureItemActions.overlayButton("doc.on.doc", "Copy", action: onCopy)
                    CaptureItemActions.overlayButton("pencil", "Edit") { CaptureItemActions.edit(entry) }
                }
                .padding(5)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(AOMMotion.quick, value: hovering)
        .onTapGesture(count: 2) { CaptureItemActions.edit(entry) }
        .onDrag { CaptureItemActions.dragProvider(entry) }
        .help("\(entry.displayName) · \(AOMRelativeTime.string(entry.capturedAt)) — drag to use, double-click to edit")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.displayName), \(AOMRelativeTime.string(entry.capturedAt))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy", onCopy)
        .accessibilityAction(named: "Edit") { CaptureItemActions.edit(entry) }
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Shared row components

/// Category colours shared by gesture rows and icons.
enum GestureVisual {
    static func tint(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return AOMTheme.cyan
        case .keyboard: return AOMTheme.orange
        case .normalMouse: return AOMTheme.indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return AOMTheme.blue
        }
    }
}
