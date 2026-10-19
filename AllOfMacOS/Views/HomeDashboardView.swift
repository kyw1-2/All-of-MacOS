import AppKit
import SwiftUI

/// The overview observes only preset state. High-frequency clipboard and
/// capture updates stay inside their own sections, away from window chrome.
struct HomeDashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    welcome
                    quickActions(columns: geometry.size.width >= 740 ? 4 : 2)
                    overview
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 22) {
                            VStack(spacing: 22) { HomeStatusSection(); gesturesGroup }
                            VStack(spacing: 22) { HomeClipboardSection(); HomeCapturesSection() }
                        }
                    } else {
                        VStack(spacing: 22) {
                            HomeStatusSection(); gesturesGroup; HomeClipboardSection(); HomeCapturesSection()
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1220)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }

    private var welcome: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) { heading; Spacer(minLength: 24); status }
            VStack(alignment: .leading, spacing: 14) { heading; status }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Your workspace").font(.system(size: 32, weight: .bold)).tracking(-0.8)
            Text("Capture, automate and pick up where you left off.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var status: some View {
        Button { appState.toggleGlobalEnabled() } label: {
            Label(appState.globalEnabled ? "Automation active" : "Automation paused",
                  systemImage: appState.globalEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(appState.globalEnabled ? Color.green : .orange)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background((appState.globalEnabled ? Color.green : .orange).opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(appState.globalEnabled ? "Pause automation" : "Resume automation")
    }

    private func quickActions(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            AOMActionTile(title: "Capture Area", systemImage: "viewfinder", tint: .orange,
                          subtitle: "Select any part of your screen") { CaptureCoordinator.shared.captureArea() }
            AOMActionTile(title: "Capture Text", systemImage: "text.viewfinder", tint: .blue,
                          subtitle: "Copy text from anywhere") { CaptureCoordinator.shared.captureText() }
            AOMActionTile(title: "Record Screen", systemImage: "record.circle", tint: .red,
                          subtitle: "Start a screen recording") { ScreenRecordingService.shared.promptAndStartRecording() }
            AOMActionTile(title: "Clipboard", systemImage: "doc.on.clipboard", tint: .purple,
                          subtitle: "Open your clipboard shelf") { ClipboardPanelController.shared.show() }
        }
    }

    private var overview: some View {
        HStack(spacing: 0) {
            summary("Active gestures", value: appState.currentPreset.triggers.filter(\.isEnabled).count,
                    symbol: "hand.tap", tint: .cyan, tab: .gestures)
            Divider().frame(height: 34)
            summary("App profiles", value: appState.currentPreset.appTargets.filter { !$0.isGlobal }.count,
                    symbol: "app.badge", tint: .blue, tab: .gestures)
            Divider().frame(height: 34)
            summary("Snap zones", value: appState.effectiveSnapZones.filter(\.isEnabled).count,
                    symbol: "rectangle.split.2x2", tint: .indigo, tab: .snapping)
        }
        .padding(.vertical, 5)
    }

    private func summary(_ title: String, value: Int, symbol: String, tint: Color, tab: AOMMainTab) -> some View {
        Button { appState.selectedMainTab = tab } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value). Open \(tab.title)")
    }

    private var gesturesGroup: some View {
        let triggers = appState.currentPreset.triggers
        // Stable partition of six visible rows; no sort of the entire preset.
        let shown = Array((triggers.filter(\.isFavorite) + triggers.filter { !$0.isFavorite }).prefix(6))
        return AOMGroup("Gestures", trailing: "\(triggers.filter(\.isEnabled).count) of \(triggers.count) on") {
            if shown.isEmpty {
                AOMRow(symbol: "hand.tap", tint: .cyan, title: "Make your first gesture", detail: "Give a shortcut or gesture something to do") {
                    Button("New Gesture…") { appState.selectedMainTab = .gestures; appState.showingAddTrigger = true }
                }
            }
            ForEach(shown) { trigger in
                AOMRow(symbol: trigger.input.category.iconName, tint: GestureVisual.tint(trigger.input.category),
                       title: trigger.displayName, detail: trigger.actions.first?.displayName ?? "No actions",
                       dimmed: !trigger.isEnabled, onSelect: {
                           appState.selectedTrigger = trigger; appState.selectedMainTab = .gestures
                       }) {
                    Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                        set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            AOMLinkRow(title: "All Gestures") { appState.selectedMainTab = .gestures }
        }
    }
}

private struct HomeStatusSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboard = ClipboardStore.shared
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }

    var body: some View {
        AOMGroup("System Status") {
            AOMRow(symbol: "rectangle.split.2x2.fill", tint: .indigo, title: "Drag to Snap",
                   detail: "\(appState.effectiveSnapZones.filter(\.isEnabled).count) zones ready") {
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                    set: { appState.setSnappingEnabled($0) })).labelsHidden().toggleStyle(.switch)
            }
            AOMRow(symbol: "doc.on.clipboard.fill", tint: .purple, title: "Clipboard History",
                   detail: clipboard.paused ? "Paused" : "\(clipboard.entries.count) items · \(clipboard.boards.count) pinboards") {
                Toggle("Clipboard History", isOn: Binding(get: { !clipboard.paused },
                    set: { $0 ? clipboard.resume() : clipboard.pause() })).labelsHidden().toggleStyle(.switch)
            }
            if let conflict = shortcutConflict {
                AOMRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "\(conflict.appName) also uses \(conflict.shortcut.displayString)",
                       detail: "Choose another shortcut to open the shelf") {
                    Button("Use \(ShortcutConflicts.alternativeHistoryShortcut.displayString)") {
                        ClipboardShortcuts.shared.setShortcut(ShortcutConflicts.alternativeHistoryShortcut, for: .history)
                        shortcutConflict = nil
                    }
                }
            }
            AOMRow(symbol: "checkmark.shield.fill", tint: missingPermissions.isEmpty ? .green : .orange,
                   title: "Permissions", detail: permissions.isEmpty ? "Checking…" : missingPermissions.isEmpty
                   ? "Everything AOM needs is allowed" : missingPermissions.map(\.title).joined(separator: ", "), showsDivider: false) {
                if let first = missingPermissions.first { Button("Open Settings…") { _ = first.openSettings() } }
                else if !permissions.isEmpty { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed") }
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
    }
}

private struct HomeClipboardSection: View {
    @ObservedObject private var clipboard = ClipboardStore.shared
    var body: some View {
        AOMGroup("Recent Clipboard", trailing: "Double-click to copy") {
            if clipboard.entries.isEmpty {
                AOMRow(symbol: "doc.on.clipboard", tint: .purple, title: "Nothing copied yet",
                       detail: "Your next copy will be right here") { EmptyView() }
            }
            ForEach(clipboard.entries.prefix(5)) { entry in
                AOMRow(symbol: entry.kind.symbol, tint: .purple, title: entry.title,
                       detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                       onDoubleClick: { Task { _ = try? await clipboard.writeAsync(entryIDs: [entry.id]) } }) { EmptyView() }
            }
            AOMLinkRow(title: "Open Clipboard Shelf", shortcut: "⇧⌘V") { ClipboardPanelController.shared.show() }
        }
    }
}

private struct HomeCapturesSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    var body: some View {
        AOMGroup("Recent Captures", trailing: history.entries.first.map { AOMRelativeTime.string($0.capturedAt) }) {
            if history.entries.isEmpty {
                AOMRow(symbol: "camera.viewfinder", tint: .orange, title: "Ready when you are",
                       detail: "Screenshots and recordings stay together") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                }
            } else {
                ForEach(history.entries.prefix(3)) { entry in
                    AOMRow(symbol: entry.kind == .videoRecording ? "video.fill" : "photo", tint: .orange,
                           title: entry.displayName,
                           detail: "\(entry.pixelWidth) × \(entry.pixelHeight) · \(AOMRelativeTime.string(entry.capturedAt))",
                           onDoubleClick: { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }) { EmptyView() }
                }
            }
            AOMLinkRow(title: "Open Capture Studio") { appState.selectedMainTab = .capture }
        }
    }
}

// MARK: - Grouped rows (System Settings idiom)

/// Category colours shared by gesture rows and icons.
enum GestureVisual {
    static func tint(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return .cyan
        case .keyboard: return .orange
        case .normalMouse: return .indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return .blue
        }
    }
}

/// A titled inset group: the grouped `Form` look, usable in custom layouts.
struct AOMGroup<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder var content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One settings-style row: colour symbol tile, title, secondary detail and a
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
            HStack(spacing: 10) {
                AOMIconTile(systemImage: symbol, tint: dimmed ? .gray : tint, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).foregroundStyle(dimmed ? .secondary : .primary)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if onSelect != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(hovering && interactive ? Color.primary.opacity(0.045) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider { Divider().padding(.leading, 46) }
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
                Text(title).foregroundStyle(.tint)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(hovering ? Color.primary.opacity(0.045) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
