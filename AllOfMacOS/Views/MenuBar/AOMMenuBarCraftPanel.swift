import SwiftUI

struct AOMMenuBarCraftPanel: View {
    struct LiveSession: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        let stopLabel: String
        let onStop: () -> Void
    }

    struct ToggleTile: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
        let isOn: Bool
        /// Nil for a tile that is only a menu (Capture).
        let onToggle: (() -> Void)?
        /// 7.11 (spec §3): the feature's commands — clicking the tile's name
        /// opens them under the tiles; the round switch keeps its own click.
        var menu: [AOMFeatureCommand]? = nil
        /// A line at the top of the open menu ("25 min left").
        var menuNote: String? = nil
    }

    struct QuickAction: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let onRun: () -> Void
    }

    let isEngineRunning: Bool
    let liveSessions: [LiveSession]
    let toggles: [ToggleTile]
    let quickActions: [QuickAction]
    /// 7.8 (ME-02): how many quick commands one row shows (1–4); the rest are under More.
    var quickPerRow = 3
    let launcherShortcutText: String?

    let onToggleMaster: () -> Void
    let onOpenLauncher: () -> Void
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onShowClassicMenu: () -> Void
    /// 7.8 (ME-01): the pencil opens the menu editor.
    var onEditMenu: () -> Void = {}
    /// 7.0: a row of the host's own under the tiles (AOM's battery line).
    var accessory: AnyView? = nil
    /// 7.11: runs a tile menu's command (the host closes the panel first when asked).
    var onCommand: (AOMFeatureCommand) -> Void = { $0.run() }
    /// 7.11: the panel's height changed (a tile menu opened or closed).
    var onResize: () -> Void = {}
    @State private var openMenu: String?

    var body: some View {
        VStack(spacing: 12) {
            // 1. 헤더 & 마스터 스위치
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isEngineRunning ? AOMColor.success : AOMColor.warning)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("All of MacOS")
                        .font(AOMFont.bodyEmphasis.weight(.semibold))
                    // 7.18: the state in words too, not by colour alone.
                    Text(isEngineRunning ? "Running" : "Paused")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Toggle("Automation engine", isOn: Binding(get: { isEngineRunning }, set: { _ in onToggleMaster() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            // 2. 실행 중인 라이브 세션 배너 (녹화/집중/Keep Awake/마이크 음소거)
            if !liveSessions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(liveSessions) { session in
                        HStack(spacing: 8) {
                            Image(systemName: session.symbol)
                                .font(AOMFont.callout.weight(.semibold))
                                .foregroundStyle(session.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.title).font(AOMFont.callout.weight(.semibold))
                                Text(session.detail).font(Font.caption).foregroundStyle(AOMCraftColor.inkSecondary)
                            }
                            Spacer()
                            Button(session.stopLabel, action: session.onStop)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(session.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            // 3. Control Center 26 스타일 2열 토글 타일 (호버 시 스케일 확대 없음)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(toggles) { tile in tileView(tile) }
            }
            if let id = openMenu, let tile = toggles.first(where: { $0.id == id }), let commands = tile.menu {
                tileMenu(tile, commands)
            }

            if let accessory { accessory }

            // 4. 라벨을 갖춘 Quick Actions 3개
            HStack(spacing: 8) {
                ForEach(quickActions.prefix(quickPerRow)) { item in
                    Button(action: item.onRun) {
                        VStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(AOMFont.title)
                            Text(item.title)
                                .font(AOMFont.badge)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .aomCalmHover(radius: 10)
                }
            }

            // 5. Open Launcher… 진입 바
            Button(action: onOpenLauncher) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(AOMFont.callout.weight(.semibold))
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                    Text("Open Launcher…")
                        .font(AOMFont.callout.weight(.medium))
                        .foregroundStyle(AOMCraftColor.ink)
                    Text("Ask AI · Kill Process")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMCraftColor.inkTertiary)
                        .lineLimit(1)
                    Spacer()
                    if let shortcut = launcherShortcutText {
                        AOMCraftKeycap(text: shortcut)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .aomCalmHover(radius: 10)

            // 6. 하단 유틸리티 바 (전원 버튼은 '⋯' 클래식 메뉴 안으로 격리 유지)
            HStack(spacing: 6) {
                Button("Open Window", action: onOpenMainWindow)
                    .buttonStyle(.plain)
                    .font(AOMFont.caption.weight(.medium))
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .aomCalmHover(radius: 6)

                Spacer()

                if quickActions.count > quickPerRow {
                    Menu("More Actions") {
                        ForEach(quickActions.dropFirst(quickPerRow)) { item in
                            Button(item.title, action: item.onRun)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button(action: onEditMenu) {
                    Image(systemName: "pencil")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 6)
                .accessibilityLabel("Edit This Panel and Menu")
                .help("Edit this panel and the right-click menu")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 6)
                .accessibilityLabel("Settings")
                .help("Settings")

                Button(action: onShowClassicMenu) {
                    Image(systemName: "ellipsis.circle")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 6)
                .accessibilityLabel("All Commands and Quit")
                .help("All Commands & Quit")
            }
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: openMenu) { _, _ in DispatchQueue.main.async { onResize() } }
        // 7.1: Apple's Liquid Glass again (macOS 26+; a material before, an
        // opaque surface with Reduce Transparency or Increase Contrast). The
        // text keeps the launcher ink, so it stays readable on the glass.
        .aomFloatingGlass(radius: AOMCraftRadius.floatingPanel)
    }

    // MARK: Tiles and their menus (7.11)

    private func tileCircle(_ tile: ToggleTile) -> some View {
        ZStack {
            Circle()
                .fill(tile.isOn ? tile.tint : Color.primary.opacity(0.10))
                .frame(width: 28, height: 28)
            Image(systemName: tile.symbol)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(tile.isOn ? .white : .secondary)
        }
    }

    private func tileText(_ tile: ToggleTile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.title)
                .font(AOMFont.callout.weight(.semibold))
                .lineLimit(1)
            Text(tile.subtitle)
                .font(Font.caption)
                .foregroundStyle(AOMCraftColor.inkSecondary)
                .lineLimit(1)
        }
    }

    private func tileBackground(_ tile: ToggleTile) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tile.isOn ? tile.tint.opacity(0.14) : Color.primary.opacity(0.05))
    }

    @ViewBuilder
    private func tileView(_ tile: ToggleTile) -> some View {
        if tile.menu == nil {
            // A plain switch: the whole tile flips it (as through 7.10).
            Button { tile.onToggle?() } label: {
                HStack(spacing: 9) {
                    tileCircle(tile)
                    tileText(tile)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 48)
                .background(tileBackground(tile))
            }
            .buttonStyle(.plain)
            .aomCalmHover(radius: 12)
            .accessibilityValue(tile.isOn ? Text("On") : Text("Off"))
        } else {
            let isOpen = openMenu == tile.id
            HStack(spacing: 9) {
                // The switch has its own click area; the name only opens the menu.
                Button { if let toggle = tile.onToggle { toggle() } else { toggleMenu(tile.id) } } label: { tileCircle(tile) }
                    .buttonStyle(.plain)
                    .help(tile.onToggle == nil ? tile.title : (tile.isOn ? "Turn off \(tile.title)" : "Turn on \(tile.title)"))
                    .accessibilityLabel(tile.onToggle == nil ? "\(tile.title) commands" : "\(tile.title) switch")
                    .accessibilityValue(tile.onToggle == nil ? Text("") : (tile.isOn ? Text("On") : Text("Off")))
                Button { toggleMenu(tile.id) } label: {
                    HStack(spacing: 4) {
                        tileText(tile)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(Font.caption2.weight(.bold))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tile.title) commands")
                .accessibilityHint("Opens the \(tile.title) menu")
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(tileBackground(tile))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOpen ? tile.tint.opacity(0.7) : .clear, lineWidth: 1.5))
            .aomCalmHover(radius: 12)
        }
    }

    private func toggleMenu(_ id: String) {
        withAnimation(AOMCraftMotion.resolve(AOMCraftMotion.crossfade, reduceMotion: AOMMotion.systemReduceMotion)) {
            openMenu = openMenu == id ? nil : id
        }
    }

    private func tileMenu(_ tile: ToggleTile, _ commands: [AOMFeatureCommand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol).font(AOMFont.caption.weight(.semibold)).foregroundStyle(tile.tint)
                Text(tile.title).font(AOMFont.callout.weight(.semibold))
                if let note = tile.menuNote {
                    Text(note).font(AOMFont.caption).foregroundStyle(AOMCraftColor.inkSecondary).lineLimit(1)
                }
                Spacer()
                Button { toggleMenu(tile.id) } label: {
                    Image(systemName: "xmark").font(Font.caption2.weight(.bold)).foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tile.title) menu")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            ForEach(commands) { command in
                Button {
                    openMenu = nil
                    onCommand(command)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.symbol).font(AOMFont.callout).frame(width: 18)
                        Text(command.title).font(AOMFont.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 7)
            }
        }
        .padding(8)
        .background(tile.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }
}
