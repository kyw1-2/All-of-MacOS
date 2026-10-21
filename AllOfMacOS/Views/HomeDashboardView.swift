import AppKit
import SwiftUI

/// The overview observes only preset state. High-frequency clipboard and
/// capture updates stay inside their own sections, away from window chrome.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    primaryActions(wide: geometry.size.width >= 820)
                    metrics
                    columns(wide: geometry.size.width >= 980)
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                Text("캡처하고, 자동화하고, 방금 한 작업을 이어서 하세요.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            statusChip
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "좋은 아침이에요"
        case 12..<18: return "안녕하세요"
        case 18..<23: return "좋은 저녁이에요"
        default: return "늦은 시간이네요"
        }
    }

    private var statusChip: some View {
        Button { appState.toggleGlobalEnabled() } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.globalEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(appState.globalEnabled ? "자동화 실행 중" : "자동화 일시정지")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("\(appState.currentPreset.triggers.filter(\.isEnabled).count)개 제스처 동작")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: appState.globalEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(appState.globalEnabled ? "Pause automation" : "Resume automation")
    }

    // MARK: Primary actions

    private func primaryActions(wide: Bool) -> some View {
        VStack(spacing: 12) {
            if wide {
                HStack(spacing: 12) {
                    primaryCard(title: "화면 캡처", subtitle: "영역을 끌어 선택하거나 전체 화면을 찍어요",
                                symbol: "viewfinder", tint: .orange, filled: true) {
                        CaptureCoordinator.shared.captureArea()
                    }
                    primaryCard(title: "클립보드", subtitle: "복사한 모든 것을 한 곳에서 다시 꺼내요",
                                symbol: "doc.on.clipboard", tint: .purple, filled: false) {
                        ClipboardPanelController.shared.show()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    primaryCard(title: "화면 캡처", subtitle: "영역을 끌어 선택하거나 전체 화면을 찍어요",
                                symbol: "viewfinder", tint: .orange, filled: true) {
                        CaptureCoordinator.shared.captureArea()
                    }
                    primaryCard(title: "클립보드", subtitle: "복사한 모든 것을 한 곳에서 다시 꺼내요",
                                symbol: "doc.on.clipboard", tint: .purple, filled: false) {
                        ClipboardPanelController.shared.show()
                    }
                }
            }
            HStack(spacing: 12) {
                secondaryCard(title: "텍스트 추출", symbol: "text.viewfinder", tint: .blue) {
                    CaptureCoordinator.shared.captureText()
                }
                secondaryCard(title: "화면 녹화", symbol: "record.circle", tint: .red) {
                    ScreenRecordingService.shared.promptAndStartRecording()
                }
            }
        }
    }

    private func primaryCard(title: String, subtitle: String, symbol: String, tint: Color,
                             filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : tint)
                    .frame(width: 44, height: 44)
                    .background(filled ? Color.white.opacity(0.2) : tint.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(filled ? Color.white : Color.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(filled ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(filled ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(filled ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)],
                                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(filled ? 0 : 0.45), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private func secondaryCard(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(spacing: 12) {
            metricCard("제스처", value: appState.currentPreset.triggers.filter(\.isEnabled).count,
                       symbol: "hand.tap", tint: .cyan, tab: .gestures)
            metricCard("앱 프로필", value: appState.currentPreset.appTargets.filter { !$0.isGlobal }.count,
                       symbol: "app.badge", tint: .blue, tab: .gestures)
            metricCard("스냅 존", value: appState.effectiveSnapZones.filter(\.isEnabled).count,
                       symbol: "rectangle.split.2x2", tint: .indigo, tab: .snapping)
        }
    }

    private func metricCard(_ title: String, value: Int, symbol: String, tint: Color, tab: AOMMainTab) -> some View {
        Button {
            appState.selectedMainTab = tab
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.formatted())
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                    Text(title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: Columns

    @ViewBuilder
    private func columns(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) { gesturesGroup; HomeCapturesSection() }
                VStack(spacing: 18) { HomeStatusSection(); HomeClipboardSection() }
            }
        } else {
            VStack(spacing: 18) {
                gesturesGroup
                HomeStatusSection()
                HomeClipboardSection()
                HomeCapturesSection()
            }
        }
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
