import AppKit
import SwiftUI

/// An operational workspace: work in the main column, tools in the utility rail.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @State private var recentTab = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AOMPageHeader("Workspace", subtitle: "Everything you need. A little closer.", systemImage: "square.grid.2x2", tint: AOMTheme.blue) {
                        Button { appState.selectedMainTab = .gestures; appState.showingAddTrigger = true } label: {
                            Label("New Automation", systemImage: "plus")
                        }
                    }
                    Button { showingCommandPalette = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(AOMTheme.textSecondary)
                            Text("Find a command or jump to a tool…").font(.system(size: 12)).foregroundStyle(AOMTheme.textSecondary)
                            Spacer()
                            AOMKeycap(text: "⌘ K")
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if geometry.size.width >= 780 {
                        HStack(alignment: .top, spacing: 24) {
                            workColumn.frame(maxWidth: .infinity)
                            Rectangle().fill(AOMTheme.divider.opacity(0.5)).frame(width: 0.5)
                            utilityColumn.frame(width: 236)
                        }.fixedSize(horizontal: false, vertical: true)
                    } else {
                        workColumn
                        utilityColumn
                    }
                }
                .padding(AOMTheme.pagePadding)
            }
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }

    private var workColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            metrics
            automations
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    AOMUnderlineTab(title: "Clipboard", selected: recentTab == 0) { recentTab = 0 }
                    AOMUnderlineTab(title: "Captures", selected: recentTab == 1) { recentTab = 1 }
                    Spacer()
                    Text("RECENT").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(AOMTheme.textTertiary)
                }
                .overlay(alignment: .bottom) { AOMTheme.divider.opacity(0.4).frame(height: 0.5) }
                if recentTab == 0 { HomeClipboardSection() } else { HomeCapturesSection() }
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 20) {
            metric("Automations", value: appState.currentPreset.triggers.filter(\.isEnabled).count, tab: .gestures)
            metric("App profiles", value: appState.currentPreset.appTargets.filter { !$0.isGlobal }.count, tab: .gestures)
            metric("Snap zones", value: appState.effectiveSnapZones.filter(\.isEnabled).count, tab: .snapping)
        }
        .padding(.vertical, 3)
    }

    private func metric(_ title: String, value: Int, tab: AOMMainTab) -> some View {
        Button { appState.selectedMainTab = tab } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(value.formatted()).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(AOMTheme.text)
                Text(title).font(.system(size: 11)).foregroundStyle(AOMTheme.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var automations: some View {
        let triggers = appState.currentPreset.triggers
        let shown = Array((triggers.filter(\.isFavorite) + triggers.filter { !$0.isFavorite }).prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your automations").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("View all", systemImage: "arrow.up.right") { appState.selectedMainTab = .gestures }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(AOMTheme.textSecondary)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("NAME"); Spacer(); Text("ENABLED")
                }.font(.system(size: 9, weight: .medium)).tracking(0.7).foregroundStyle(AOMTheme.textTertiary)
                    .padding(.horizontal, 10).frame(height: 28).background(AOMTheme.cardAlt.opacity(0.7))
                if shown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One shortcut. A whole workflow.").font(.system(size: 13, weight: .medium))
                        Text("Connect a gesture or key to the actions you repeat.").font(.system(size: 12)).foregroundStyle(AOMTheme.textSecondary)
                        Button("Create an automation") { appState.selectedMainTab = .gestures; appState.showingAddTrigger = true }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(shown) { trigger in
                    HStack(spacing: 10) {
                        Button {
                            appState.selectedTrigger = trigger
                            appState.selectedMainTab = .gestures
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: trigger.input.category.iconName).font(.system(size: 13)).foregroundStyle(AOMTheme.textSecondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(trigger.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(AOMTheme.text)
                                    Text(trigger.input.displayName).font(.system(size: 10.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if trigger.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(AOMTheme.textTertiary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled }, set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).controlSize(.mini)
                    }.padding(.horizontal, 10).frame(height: 46)
                        .overlay(alignment: .bottom) { AOMTheme.divider.opacity(0.3).frame(height: 0.5) }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private var utilityColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK TOOLS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(AOMTheme.textTertiary)
                AOMToolButton(title: "Capture area", systemImage: "viewfinder", prominent: true) { CaptureCoordinator.shared.captureArea() }
                AOMToolButton(title: "Extract text", systemImage: "text.viewfinder") { CaptureCoordinator.shared.captureText() }
                AOMToolButton(title: "Record screen", systemImage: "record.circle") { ScreenRecordingService.shared.promptAndStartRecording() }
                AOMToolButton(title: "Open clipboard", systemImage: "doc.on.clipboard") { ClipboardPanelController.shared.show() }
            }
            HomeStatusSection()
        }
    }
}

struct AOMKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(AOMTheme.textSecondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AOMTheme.divider, lineWidth: 0.5))
    }
}

struct AOMUnderlineTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { if selected { AOMTheme.blue.frame(height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct AOMToolButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .regular))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).opacity(hovering || prominent ? 0.8 : 0.3)
            }
            .foregroundStyle(prominent ? .white : AOMTheme.text)
            .padding(.horizontal, 11).frame(height: 34)
            .background(prominent ? AOMTheme.actionBlue : (hovering ? AOMTheme.cardAlt : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
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
        AOMGroup("On this Mac") {
            AOMRow(symbol: "rectangle.split.2x2.fill", tint: .indigo, title: "Drag to Snap",
                   detail: "\(appState.effectiveSnapZones.filter(\.isEnabled).count) zones ready") {
                Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                    set: { appState.setSnappingEnabled($0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            AOMRow(symbol: "doc.on.clipboard.fill", tint: .purple, title: "Clipboard History",
                   detail: clipboard.paused ? "Paused" : "\(clipboard.entries.count) items · \(clipboard.boards.count) pinboards") {
                Toggle("Clipboard History", isOn: Binding(get: { !clipboard.paused },
                    set: { $0 ? clipboard.resume() : clipboard.pause() })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
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
        AOMGroup("Recent items", trailing: "Double-click to copy") {
            if clipboard.entries.isEmpty {
                AOMRow(symbol: "doc.on.clipboard", tint: .purple, title: "Nothing copied yet",
                       detail: "Your next copy will be right here") { EmptyView() }
            }
            ForEach(clipboard.entries.prefix(5)) { entry in
                AOMRow(symbol: entry.kind.symbol, tint: .purple, title: entry.title,
                       detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                       onDoubleClick: { Task { _ = try? await clipboard.writeAsync(entryIDs: [entry.id]) } }) { EmptyView() }
            }
            AOMLinkRow(title: "Open Clipboard", shortcut: "⇧⌘V") { ClipboardPanelController.shared.show() }
        }
    }
}

private struct HomeCapturesSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    var body: some View {
        AOMGroup("Recent items", trailing: history.entries.first.map { AOMRelativeTime.string($0.capturedAt) }) {
            if history.entries.isEmpty {
                AOMRow(symbol: "camera.viewfinder", tint: .orange, title: "Ready when you are",
                       detail: "Screenshots and recordings stay together") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                }
            } else {
                ForEach(history.entries.prefix(5)) { entry in
                    AOMRow(symbol: entry.kind == .videoRecording ? "video.fill" : "photo", tint: .orange,
                           title: entry.displayName,
                           detail: "\(entry.pixelWidth) × \(entry.pixelHeight) · \(AOMRelativeTime.string(entry.capturedAt))",
                           onDoubleClick: { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }) { EmptyView() }
                }
            }
            AOMLinkRow(title: "All Captures") { appState.selectedMainTab = .capture }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(AOMTheme.text)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(AOMTheme.textTertiary) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) { content }

                .clipShape(RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
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
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(dimmed ? AOMTheme.textTertiary : AOMTheme.textSecondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.aomLabel(12)).lineLimit(1)
                        .foregroundStyle(dimmed ? AOMTheme.textTertiary : AOMTheme.text)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.aomBody(11)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if onSelect != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(minHeight: 40)
            .background(hovering && interactive ? AOMTheme.cardAlt : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider { Rectangle().fill(AOMTheme.divider.opacity(0.5)).frame(height: 0.5).padding(.leading, 32) }
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
                Text(title).font(.aomLabel(11.5)).foregroundStyle(AOMTheme.blue)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(hovering ? AOMTheme.cardAlt : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
