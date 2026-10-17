import AppKit
import SwiftUI

/// Overview page in the System Settings idiom: grouped, flat rows with
/// inline controls and no decorative banners. Frequent commands live in the
/// window toolbar; every row is either a live control or a link to its page.
struct HomeDashboardView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?

    private var triggers: [Trigger] { appState.currentPreset.triggers }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let wide = geometry.size.width >= 900
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 20) { statusGroup; gesturesGroup }
                            VStack(spacing: 20) { clipboardGroup; capturesGroup }
                        }
                    } else {
                        VStack(spacing: 20) { statusGroup; gesturesGroup; clipboardGroup; capturesGroup }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .suppressScrollerReservation()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { CaptureCoordinator.shared.captureArea() } label: { Label("Capture Area", systemImage: "viewfinder") }
                    .help("Capture an area of the screen")
                Button { CaptureCoordinator.shared.captureText() } label: { Label("Capture Text", systemImage: "text.viewfinder") }
                    .help("Recognize text in an area and copy it")
                Button { ScreenRecordingService.shared.promptAndStartRecording() } label: { Label("Record", systemImage: "record.circle") }
                    .help("Record the screen")
                Button { ClipboardPanelController.shared.show() } label: { Label("Clipboard", systemImage: "rectangle.bottomthird.inset.filled") }
                    .help("Open the clipboard shelf (⇧⌘V)")
            }
        }
        .task {
            // Preflight checks only; refreshed so a grant made in System
            // Settings shows up without reopening the window.
            while !Task.isCancelled {
                let current = AOMPermission.required.map { ($0, $0.status) }
                if current.map(\.1) != permissions.map(\.1) { permissions = current }
                let conflict = ShortcutConflicts.clipboardHistoryConflict()
                if conflict != shortcutConflict { shortcutConflict = conflict }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }

    // MARK: - Status

    private var statusGroup: some View {
        AOMGroup("Status") {
            AOMRow(symbol: "bolt.fill", tint: appState.globalEnabled ? .green : .orange, title: "Automation",
                   detail: appState.globalEnabled ? "Gestures, shortcuts and triggers are listening" : "Paused — nothing is listening") {
                Toggle("Automation", isOn: Binding(get: { appState.globalEnabled }, set: { _ in appState.toggleGlobalEnabled() }))
                    .labelsHidden().toggleStyle(.switch)
            }
            AOMRow(symbol: "rectangle.split.2x2.fill", tint: .indigo, title: "Drag to Snap",
                   detail: "\(appState.effectiveSnapZones.filter(\.isEnabled).count) zones") {
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                     set: { appState.setSnappingEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if let conflict = shortcutConflict {
                AOMRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "\(conflict.appName) also uses \(conflict.shortcut.displayString)",
                       detail: "macOS sends the shortcut to \(conflict.appName), so the shelf can't open with it") {
                    Button("Use \(ShortcutConflicts.alternativeHistoryShortcut.displayString)") {
                        ClipboardShortcuts.shared.setShortcut(ShortcutConflicts.alternativeHistoryShortcut, for: .history)
                        shortcutConflict = nil
                    }
                }
            }
            AOMRow(symbol: "doc.on.clipboard.fill", tint: .purple, title: "Clipboard History",
                   detail: clipboard.paused ? "Paused" : "\(clipboard.entries.count) items · \(clipboard.boards.count) pinboards") {
                Toggle("Clipboard History", isOn: Binding(get: { !clipboard.paused },
                                                          set: { $0 ? clipboard.resume() : clipboard.pause() }))
                    .labelsHidden().toggleStyle(.switch)
            }
            AOMRow(symbol: "checkmark.shield.fill", tint: missingPermissions.isEmpty ? .green : .orange, title: "Permissions",
                   detail: permissions.isEmpty ? "Checking…"
                   : missingPermissions.isEmpty ? "Everything AOM needs is allowed"
                   : missingPermissions.map(\.title).joined(separator: ", "),
                   showsDivider: false) {
                if let first = missingPermissions.first {
                    Button("Open Settings…") { _ = first.openSettings() }
                } else if !permissions.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed")
                }
            }
        }
    }

    // MARK: - Gestures

    private var gesturesGroup: some View {
        let shown = Array(triggers.sorted { ($0.isFavorite ? 0 : 1) < ($1.isFavorite ? 0 : 1) }.prefix(6))
        return AOMGroup("Gestures", trailing: "\(triggers.filter(\.isEnabled).count) of \(triggers.count) on") {
            if shown.isEmpty {
                AOMRow(symbol: "hand.tap", tint: .cyan, title: "No gestures yet", detail: "Assign actions to a gesture, shortcut or mouse button") {
                    Button("New Gesture…") { appState.selectedMainTab = .gestures; appState.showingAddTrigger = true }
                }
            }
            ForEach(shown) { trigger in
                AOMRow(symbol: trigger.input.category.iconName, tint: GestureVisual.tint(trigger.input.category),
                       title: trigger.displayName,
                       detail: trigger.actions.first?.displayName ?? "No actions",
                       dimmed: !trigger.isEnabled,
                       onSelect: { open(trigger) }) {
                    Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                                                              set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            AOMLinkRow(title: "Show All Gestures") { appState.selectedMainTab = .gestures }
        }
    }

    private func open(_ trigger: Trigger) {
        appState.selectedTrigger = trigger
        appState.selectedMainTab = .gestures
    }

    // MARK: - Clipboard

    private var clipboardGroup: some View {
        AOMGroup("Recent Clipboard", trailing: "Double-click a row to copy") {
            if clipboard.entries.isEmpty {
                AOMRow(symbol: "doc.on.clipboard", tint: .purple, title: "Nothing copied yet",
                       detail: "Text, links, images and files you copy appear here") { EmptyView() }
            }
            ForEach(clipboard.entries.prefix(6)) { entry in
                AOMRow(symbol: entry.kind.symbol, tint: .gray, title: entry.title,
                       detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                       onDoubleClick: { _ = try? clipboard.write(entryIDs: [entry.id]) }) { EmptyView() }
            }
            AOMLinkRow(title: "Open Clipboard Shelf", shortcut: "⇧⌘V") { ClipboardPanelController.shared.show() }
        }
    }

    // MARK: - Captures

    private var capturesGroup: some View {
        AOMGroup("Recent Captures", trailing: history.entries.first.map { "Last \(AOMRelativeTime.string($0.capturedAt))" }) {
            if history.entries.isEmpty {
                AOMRow(symbol: "camera.viewfinder", tint: .orange, title: "No captures yet",
                       detail: "Screenshots and recordings appear here") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(history.entries.prefix(8)) { entry in
                        Image(nsImage: entry.thumbnail)
                            .resizable().interpolation(.medium).scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if entry.kind == .videoRecording {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(4)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }
                            .help("\(entry.displayName) — double-click to annotate")
                    }
                }
                .padding(12)
                Divider()
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .padding(.vertical, 7)
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
