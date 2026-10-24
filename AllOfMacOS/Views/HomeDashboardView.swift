import AppKit
import SwiftUI

// MARK: - Workspace

/// The Workspace: what you do every day, first.
///
/// Problems that need you (permissions, paused engine, a taken shortcut,
/// clipboard storage) appear at the top only while they exist. Then the three
/// everyday entry points, your pinned and recently used automations, and the
/// latest captures and clipboard items. Counts are one line at the bottom;
/// the full figures live in Insights. (Things for structure, TDS ListRow for
/// rows, Linear for visual weight.)
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var stats = GestureStatistics.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @StateObject private var toast = AOMToastModel()
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?
    @State private var runStates: [UUID: AOMRunState] = [:]

    /// Below this width the recent column moves under the automations.
    static let wideWidth: CGFloat = 820
    static let maximumContentWidth: CGFloat = 1120
    static let rowsPerSection = 6

    private var triggers: [Trigger] { appState.currentPreset.triggers }
    private var pinned: [Trigger] { triggers.filter(\.isFavorite) }

    /// When each trigger last ran, from the statistics log (trackpad inputs
    /// record their gesture name, which is the unnamed trigger's input name).
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
                VStack(alignment: .leading, spacing: AOMSpace.l) {
                    notices
                    quickActions
                    if wide {
                        HStack(alignment: .top, spacing: AOMSpace.xl) {
                            automations(lastRuns: lastRuns)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            recent
                                .frame(width: min(380, max(300, geometry.size.width * 0.36)), alignment: .topLeading)
                        }
                    } else {
                        automations(lastRuns: lastRuns)
                        recent
                    }
                    summaryLine
                }
                .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
                .padding(.horizontal, wide ? AOMSpace.xl : AOMSpace.l)
                .padding(.top, AOMSpace.l)
                .padding(.bottom, AOMSpace.xl)
                .frame(maxWidth: .infinity)
            }
        }
        .aomPane()
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
        let on = triggers.filter(\.isEnabled).count
        var parts = [date, "\(on) of \(triggers.count) on"]
        if let latest = lastRuns.values.max() { parts.append("last run \(AOMRelativeTime.string(latest).lowercased())") }
        return parts.joined(separator: " · ")
    }

    // MARK: Notices (only when something is wrong)

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }

    @ViewBuilder private var notices: some View {
        let missing = missingPermissions
        if !appState.globalEnabled || !missing.isEmpty || shortcutConflict != nil || clipboard.storageWarning != nil {
            VStack(spacing: AOMSpace.xs) {
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

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: AOMSpace.xs) {
            HomeQuickButton(title: "Capture Area", symbol: "viewfinder",
                            shortcut: CaptureShortcuts.shared.shortcut(for: .captureArea)) {
                CaptureCoordinator.shared.captureArea()
            }
            HomeQuickButton(title: "Clipboard Shelf", symbol: "doc.on.clipboard",
                            shortcut: ClipboardShortcuts.shared.shortcut(for: .history)) {
                ClipboardPanelController.shared.show()
            }
            HomeQuickButton(title: "Search", symbol: "magnifyingglass",
                            shortcut: AOMPaletteShortcut.current(appState.currentPreset)) {
                showingCommandPalette = true
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Automations

    @ViewBuilder private func automations(lastRuns: [UUID: Date]) -> some View {
        if triggers.isEmpty {
            VStack(alignment: .leading, spacing: AOMSpace.s) {
                AOMHeading("Automations")
                Text("Connect a trackpad gesture, a key or a mouse button to the actions you repeat.")
                    .font(AOMType.body).foregroundStyle(AOMTheme.textSecondary)
                Button("Create an Automation") {
                    appState.selectedMainTab = .gestures
                    appState.showingAddTrigger = true
                }
                .buttonStyle(AOMFilledButtonStyle())
            }
        } else {
            let recent = triggers
                .filter { !$0.isFavorite && lastRuns[$0.id] != nil }
                .sorted { (lastRuns[$0.id] ?? .distantPast) > (lastRuns[$1.id] ?? .distantPast) }
            // Without any history, the enabled automations stand in.
            let rest = recent.isEmpty ? triggers.filter { !$0.isFavorite }.sorted { $0.isEnabled && !$1.isEnabled } : recent
            VStack(alignment: .leading, spacing: AOMSpace.l) {
                if !pinned.isEmpty {
                    section("Pinned", rows: pinned, lastRuns: lastRuns)
                }
                if !rest.isEmpty {
                    section(recent.isEmpty ? "Automations" : "Recently Used", rows: Array(rest.prefix(Self.rowsPerSection)),
                            lastRuns: lastRuns)
                }
                HStack(spacing: AOMSpace.s) {
                    Button("Show All \(triggers.count) in Automation") { appState.selectedMainTab = .gestures }
                        .buttonStyle(.link)
                    if pinned.isEmpty {
                        Text("Pin an automation from its ⋯ menu to keep it here.")
                            .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                    }
                }
                .font(AOMType.body)
            }
        }
    }

    private func section(_ title: String, rows: [Trigger], lastRuns: [UUID: Date]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AOMHeading(title, count: "\(rows.count)")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, trigger in
                    HomeAutomationRow(trigger: trigger, lastRun: lastRuns[trigger.id],
                                      runState: runStates[trigger.id] ?? .idle) { run(trigger) }
                    if index < rows.count - 1 { AOMDivider().padding(.leading, 38) }
                }
            }
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

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: AOMSpace.l) {
            VStack(alignment: .leading, spacing: AOMSpace.xs) {
                AOMHeading("Recent Captures") {
                    Button("Library") { appState.selectedMainTab = .capture }.buttonStyle(.link).font(AOMType.body)
                }
                if history.entries.isEmpty {
                    Text("Screenshots and recordings appear here, ready to copy, edit or drag.")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: AOMSpace.xs), GridItem(.flexible(), spacing: AOMSpace.xs)],
                              spacing: AOMSpace.xs) {
                        ForEach(history.entries.prefix(4)) { entry in
                            HomeCaptureThumb(entry: entry) {
                                CaptureItemActions.copy(entry)
                                toast.show("Copied capture")
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                AOMHeading("Recent Clipboard") {
                    Button("Open Shelf") { ClipboardPanelController.shared.show() }.buttonStyle(.link).font(AOMType.body)
                }
                if clipboard.isLoading && clipboard.entries.isEmpty {
                    Text("Unlocking clipboard history…").font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                        .padding(.top, 4)
                } else if clipboard.entries.isEmpty {
                    Text(clipboard.paused ? "Clipboard history is paused." : "Copied text, links, images and files appear here.")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
                        .padding(.top, 4)
                } else {
                    let entries = Array(clipboard.entries.prefix(5))
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HomeClipboardRow(entry: entry) { copy(entry) }
                            if index < entries.count - 1 { AOMDivider().padding(.leading, 38) }
                        }
                    }
                }
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

    // MARK: Summary

    private var summaryLine: some View {
        let zones = appState.effectiveSnapZones.filter(\.isEnabled).count
        let parts = [
            "\(zones) snap zone\(zones == 1 ? "" : "s")\(appState.currentPreset.snappingEnabled ? "" : " (Drag to Snap off)")",
            "\(clipboard.entries.count) clipboard item\(clipboard.entries.count == 1 ? "" : "s")",
            "\(history.entries.count) capture\(history.entries.count == 1 ? "" : "s")",
            "\(stats.totalFired.formatted()) run\(stats.totalFired == 1 ? "" : "s") recorded"
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
        .padding(.top, AOMSpace.xs)
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
                Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(AOMTheme.textTertiary)
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

/// One of the three everyday entry points: glyph, label, its shortcut.
private struct HomeQuickButton: View {
    let title: String
    let symbol: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AOMTheme.blue)
                Text(title).font(AOMType.body.weight(.medium)).foregroundStyle(AOMTheme.text)
                if let shortcut { AOMKeycap(text: shortcut.displayString) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovering ? AOMTheme.track : AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: AOMTheme.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(AOMMotion.quick, value: hovering)
        .help(shortcut.map { "\(title) (\($0.displayString))" } ?? title)
        .accessibilityLabel(shortcut.map { "\(title), \($0.displayString)" } ?? title)
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

/// Underlined filter tab used by the Automation page.
struct AOMUnderlineTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected || hovering ? AOMTheme.text : AOMTheme.textSecondary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(AOMTheme.blue).frame(height: 2.5) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A launcher row used by the Capture page's tool column.
struct AOMToolButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
                Text(title).font(.system(size: 14, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .foregroundStyle(prominent ? Color.white : AOMTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                if prominent {
                    shape.fill(AOMTheme.blue.aomDarker(hovering ? 0.06 : 0))
                } else if hovering {
                    shape.fill(AOMTheme.cardAlt)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { hovering = $0 }
    }
}

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

/// A titled inset group on a sheet: the grouped `Form` look for custom
/// layouts.
struct AOMGroup<Content: View>: View {
    let title: String?
    let trailing: String?
    @ViewBuilder var content: Content

    init(_ title: String?, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).aomSectionCaps() }
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(AOMTheme.textTertiary) }
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .aomCardStyle(.paper, radius: AOMTheme.cardRadius, padding: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One settings-style row: squircle symbol, title, secondary detail and a
/// trailing control. Optional single/double-click actions, hover highlight.
struct AOMRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var dimmed = false
    var showsDivider = true
    var onSelect: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    init(symbol: String, tint: Color, title: String, detail: String? = nil, dimmed: Bool = false,
         showsDivider: Bool = true, onSelect: (() -> Void)? = nil, onDoubleClick: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.dimmed = dimmed
        self.showsDivider = showsDivider
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.trailing = trailing()
    }

    private var interactive: Bool { onSelect != nil || onDoubleClick != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: symbol, tint: dimmed ? AOMTheme.textTertiary : tint, size: 32, filled: !dimmed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AOMType.rowTitle).lineLimit(1)
                        .foregroundStyle(dimmed ? AOMTheme.textTertiary : AOMTheme.text)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if onSelect != nil {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(hovering && interactive ? AOMTheme.cardAlt : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider {
                Rectangle().fill(AOMTheme.divider).frame(height: 1).padding(.leading, 54)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect != nil ? .isButton : [])
    }
}

/// Footer link inside a group ("Show All …").
struct AOMLinkRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AOMTheme.blue)
                Spacer()
                if let shortcut { AOMKeycap(text: shortcut) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(hovering ? AOMTheme.cardAlt : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
