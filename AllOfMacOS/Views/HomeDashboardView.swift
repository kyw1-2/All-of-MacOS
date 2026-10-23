import AppKit
import SwiftUI

/// The overview observes only preset state. High-frequency clipboard and
/// capture updates stay inside their own sections, away from window chrome.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            ScrollView {
                VStack(spacing: 18) {
                    HStack(alignment: .stretch, spacing: 18) {
                        hero
                            .frame(maxWidth: .infinity)
                            .frame(height: 208)
                        summaryCard
                            .frame(width: wide ? 300 : nil)
                            .frame(height: 208)
                    }
                    quickActions(wide: wide)
                    metrics
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            gesturesGroup
                            HomeCapturesSection()
                        }
                        HomeClipboardSection()
                        HomeStatusSection()
                    } else {
                        gesturesGroup
                        HomeCapturesSection()
                        HomeClipboardSection()
                        HomeStatusSection()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 32)
                .frame(maxWidth: 1320)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.globalEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(appState.globalEnabled ? "자동화 실행 중" : "자동화 일시정지")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Spacer(minLength: 0)
            }

            Spacer(minLength: 10)

            Text(greeting)
                .font(.system(size: 32, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.white)
            Text("캡처하고, 자동화하고, 방금 한 작업을 이어서 하세요.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.82))
                .padding(.top, 4)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button {
                    CaptureCoordinator.shared.captureArea()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder").font(.system(size: 12, weight: .bold))
                        Text("지금 캡처").font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(AOMTheme.text)
                    .padding(.horizontal, 15)
                    .frame(height: 36)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    ClipboardPanelController.shared.show()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .semibold))
                        Text("클립보드").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(22)
        .background(AOMTheme.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: AOMTheme.blue.opacity(0.28), radius: 22, x: 0, y: 10)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.07))
                .offset(x: -6, y: 6)
                .clipped()
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "좋은 아침이에요"
        case 12..<18: return "안녕하세요"
        case 18..<23: return "좋은 저녁이에요"
        default: return "늦은 시간이네요"
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("오늘의 요약").font(.aomHeadline(15))
                Spacer()
                Button { appState.toggleGlobalEnabled() } label: {
                    AOMChip(text: appState.globalEnabled ? "실행 중" : "정지",
                            tint: appState.globalEnabled ? AOMTheme.positive : AOMTheme.warning,
                            symbol: appState.globalEnabled ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            summaryRow("제스처", "\(appState.currentPreset.triggers.filter(\.isEnabled).count)개 동작",
                       symbol: "hand.tap", tint: .cyan)
            summaryRow("앱 프로필", "\(appState.currentPreset.appTargets.filter { !$0.isGlobal }.count)개 앱",
                       symbol: "app.badge", tint: .blue)
            summaryRow("스냅 존", "\(appState.effectiveSnapZones.filter(\.isEnabled).count)개 영역",
                       symbol: "rectangle.split.2x2", tint: .indigo)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: AOMTheme.cardShadow, radius: 14, y: 6)
    }

    private func summaryRow(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.aomBody(12.5)).foregroundStyle(AOMTheme.textSecondary)
            Spacer(minLength: 6)
            Text(value).font(.aomLabel(12.5)).foregroundStyle(AOMTheme.text)
        }
        .padding(.vertical, 6)
    }

    // MARK: Quick actions

    private func quickActions(wide: Bool) -> some View {
        let columns = wide ? 4 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
            quickTile("영역 캡처", "viewfinder", .orange) { CaptureCoordinator.shared.captureArea() }
            quickTile("텍스트 추출", "text.viewfinder", .blue) { CaptureCoordinator.shared.captureText() }
            quickTile("화면 녹화", "record.circle", .red) { ScreenRecordingService.shared.promptAndStartRecording() }
            quickTile("클립보드", "doc.on.clipboard", .purple) { ClipboardPanelController.shared.show() }
        }
    }

    private func quickTile(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(title)
                    .font(.aomLabel(13.5))
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .frame(height: 74)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AOMTheme.cardShadow, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(spacing: 14) {
            metric("제스처", appState.currentPreset.triggers.filter(\.isEnabled).count, "hand.tap", .cyan, .gestures)
            metric("앱 프로필", appState.currentPreset.appTargets.filter { !$0.isGlobal }.count, "app.badge", .blue, .gestures)
            metric("스냅 존", appState.effectiveSnapZones.filter(\.isEnabled).count, "rectangle.split.2x2", .indigo, .snapping)
        }
    }

    private func metric(_ title: String, _ value: Int, _ symbol: String, _ tint: Color, _ tab: AOMMainTab) -> some View {
        Button {
            appState.selectedMainTab = tab
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.aomCaption(11.5)).foregroundStyle(AOMTheme.textSecondary)
                    Text(value.formatted())
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(AOMTheme.text)
                }
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(7)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.horizontal, 16)
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AOMTheme.cardShadow, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
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
                Text(title).font(.aomHeadline(17)).foregroundStyle(AOMTheme.text)
                Spacer()
                if let trailing { Text(trailing).font(.aomCaption(12)).foregroundStyle(AOMTheme.textTertiary) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: AOMTheme.cardShadow, radius: 14, y: 6)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                AOMIconTile(systemImage: symbol, tint: dimmed ? .gray : tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.aomLabel(14)).lineLimit(1)
                        .foregroundStyle(dimmed ? AOMTheme.textTertiary : AOMTheme.text)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.aomBody(12)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if onSelect != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(hovering && interactive ? AOMTheme.cardAlt : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider { Rectangle().fill(AOMTheme.divider).frame(height: 0.6).padding(.leading, 62) }
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
                Text(title).font(.aomLabel(13.5)).foregroundStyle(AOMTheme.blue)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(hovering ? AOMTheme.cardAlt : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
