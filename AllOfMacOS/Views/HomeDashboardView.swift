import AppKit
import SwiftUI

/// A calm launchpad; live history is observed only by its own section.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    launchpad
                    metrics
                    columns(wide: geometry.size.width >= 940)
                }
                .padding(AOMTheme.pagePadding)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                welcome
                Spacer(minLength: 16)
                automationStatus.frame(width: 228)
            }
            VStack(alignment: .leading, spacing: 20) { welcome; automationStatus }
        }
        .padding(.vertical, 8)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("오늘도, 더 가볍게").font(.aomLabel(13)).foregroundStyle(AOMTheme.blue)
            Text("Mac의 모든 일, 한곳에서")
                .font(.aomDisplay(34)).tracking(-1.2).foregroundStyle(AOMTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("반복은 맡기고, 하던 일에 집중하세요.")
                .font(.aomBody(15)).foregroundStyle(AOMTheme.textSecondary)
        }
    }

    private var automationStatus: some View {
        Button { appState.toggleGlobalEnabled() } label: {
            HStack(spacing: 12) {
                Image(systemName: appState.globalEnabled ? "bolt.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(appState.globalEnabled ? AOMTheme.blue : AOMTheme.warning)
                    .frame(width: 44, height: 44)
                    .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.globalEnabled ? "자동화가 켜져 있어요" : "자동화가 쉬고 있어요")
                        .font(.aomLabel(13)).foregroundStyle(AOMTheme.text)
                    Text(appState.globalEnabled ? "눌러서 잠시 멈추기" : "눌러서 다시 시작하기")
                        .font(.aomCaption(11)).foregroundStyle(AOMTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .aomCard(padding: 18, elevated: false)
        }
        .buttonStyle(AOMCardButtonStyle())
    }

    private var launchpad: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("무엇을 할까요?").font(.aomTitle(20)).foregroundStyle(AOMTheme.text)
                Spacer()
                Text("자주 쓰는 기능").font(.aomCaption()).foregroundStyle(AOMTheme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 16)], spacing: 16) {
                launchCard("화면 캡처", detail: "필요한 영역만 깔끔하게", symbol: "viewfinder", tint: AOMTheme.blue, primary: true) {
                    CaptureCoordinator.shared.captureArea()
                }
                launchCard("복사한 내용", detail: "방금 복사한 내용을 다시 꺼내요", symbol: "doc.on.clipboard", tint: .purple) {
                    ClipboardPanelController.shared.show()
                }
                launchCard("텍스트 추출", detail: "이미지 속 글자도 바로 복사", symbol: "text.viewfinder", tint: .teal) {
                    CaptureCoordinator.shared.captureText()
                }
                launchCard("화면 녹화", detail: "화면의 흐름을 영상으로", symbol: "record.circle", tint: .orange) {
                    ScreenRecordingService.shared.promptAndStartRecording()
                }
            }
        }
    }

    private func launchCard(_ title: String, detail: String, symbol: String, tint: Color,
                            primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 27, weight: .medium))
                        .foregroundStyle(primary ? Color.white : tint)
                        .frame(width: 54, height: 54)
                        .background(primary ? Color.white.opacity(0.16) : tint.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primary ? Color.white.opacity(0.8) : AOMTheme.textTertiary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.aomTitle(19)).foregroundStyle(primary ? Color.white : AOMTheme.text)
                    Text(detail).font(.aomBody(12.5))
                        .foregroundStyle(primary ? Color.white.opacity(0.88) : AOMTheme.textSecondary)
                        .lineLimit(2).frame(minHeight: 32, alignment: .topLeading)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? AOMTheme.actionBlue : AOMTheme.card,
                        in: RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(AOMCardButtonStyle())
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 16) {
            metric("사용 중인 자동화", value: appState.currentPreset.triggers.filter(\.isEnabled).count,
                   symbol: "bolt", tab: .gestures)
            metric("나만의 앱 프로필", value: appState.currentPreset.appTargets.filter { !$0.isGlobal }.count,
                   symbol: "square.stack", tab: .gestures)
            metric("준비된 창 배치", value: appState.effectiveSnapZones.filter(\.isEnabled).count,
                   symbol: "rectangle.split.2x2", tab: .snapping)
        }
        .aomCard(padding: 24, elevated: false)
    }

    private func metric(_ title: String, value: Int, symbol: String, tab: AOMMainTab) -> some View {
        Button { appState.selectedMainTab = tab } label: {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).font(.aomCaption()).foregroundStyle(AOMTheme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value.formatted()).font(.aomDisplay(30)).monospacedDigit().foregroundStyle(AOMTheme.text)
                    Text("개").font(.aomBody(13)).foregroundStyle(AOMTheme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AOMTheme.textTertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(AOMCardButtonStyle())
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
        let shown = Array((triggers.filter(\.isFavorite) + triggers.filter { !$0.isFavorite }).prefix(4))
        return AOMGroup("내 자동화", trailing: "\(triggers.filter(\.isEnabled).count) of \(triggers.count) on") {
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
            AOMLinkRow(title: "자동화 전체 보기") { appState.selectedMainTab = .gestures }
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
        AOMGroup("Mac 상태") {
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
        AOMGroup("최근 복사한 내용", trailing: "두 번 눌러 복사") {
            if clipboard.entries.isEmpty {
                AOMRow(symbol: "doc.on.clipboard", tint: .purple, title: "Nothing copied yet",
                       detail: "Your next copy will be right here") { EmptyView() }
            }
            ForEach(clipboard.entries.prefix(3)) { entry in
                AOMRow(symbol: entry.kind.symbol, tint: .purple, title: entry.title,
                       detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "),
                       onDoubleClick: { Task { _ = try? await clipboard.writeAsync(entryIDs: [entry.id]) } }) { EmptyView() }
            }
            AOMLinkRow(title: "클립보드 열기", shortcut: "⇧⌘V") { ClipboardPanelController.shared.show() }
        }
    }
}

private struct HomeCapturesSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    var body: some View {
        AOMGroup("최근 캡처", trailing: history.entries.first.map { AOMRelativeTime.string($0.capturedAt) }) {
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
            AOMLinkRow(title: "캡처 전체 보기") { appState.selectedMainTab = .capture }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.aomHeadline(17)).foregroundStyle(AOMTheme.text)
                Spacer()
                if let trailing { Text(trailing).font(.aomCaption(12)).foregroundStyle(AOMTheme.textTertiary) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
                .shadow(color: AOMTheme.cardShadow, radius: 12, y: 5)
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
            .padding(.vertical, 16)
            .frame(minHeight: 72)
            .background(hovering && interactive ? AOMTheme.cardAlt : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider { Rectangle().fill(AOMTheme.divider.opacity(0.5)).frame(height: 0.5).padding(.leading, 62) }
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
