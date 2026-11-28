import SwiftUI

/// The menu bar panel's layout. 7.24 (menu bar spec 2026-11-28, §2.3): a
/// working pocket rather than a board of switches — a search field that takes
/// typing at once, the sound output and volume, the last three copies, four
/// tiles that all behave the same, and four quick actions from four tools.
struct AOMMenuBarCraftPanel: View {
    /// 7.24: 340 → 396 pt, so a half tile (180 pt) holds its subtitle.
    static let width: CGFloat = 396

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
        /// The switch; nil for a tile that is an action (Capture).
        let onToggle: (() -> Void)?
        /// The feature's commands, opened under the tiles (7.11 behaviour,
        /// kept at the user's request: the choices slide in below, the panel
        /// doesn't turn into another page).
        var menu: [AOMFeatureCommand]? = nil
        /// A line at the top of the open menu ("25 min left").
        var menuNote: String? = nil
        /// 7.24: what the round badge does when there is no switch (Capture Area).
        var primary: AOMFeatureCommand? = nil
    }

    struct QuickAction: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let onRun: () -> Void
    }

    /// 7.24 (SoundSource): the output and its volume, in the panel.
    struct SoundStrip {
        struct Device: Identifiable, Hashable { let id: String; let name: String }
        var deviceName: String
        var devices: [Device]
        var currentDeviceID: String?
        /// 0…1; nil when the output has no volume AOM can set (AirPlay).
        var volume: Double?
        var muted: Bool
        var appAudioOn: Bool
        var appAudioAvailable: Bool
        var onSelectDevice: (Device) -> Void
        var onVolume: (Double) -> Void
        var onToggleMute: () -> Void
        var onToggleAppAudio: () -> Void
        var onOpenMixer: () -> Void
    }

    /// 7.24 (Paste): one recent copy.
    struct ClipSlot: Identifiable {
        let id: UUID
        let title: String
        let detail: String
        let symbol: String
        let concealed: Bool
        let onPaste: () -> Void
        let onCopy: () -> Void
    }

    /// 7.24: one search result (a command, a hidden menu bar icon, a copy).
    struct SearchResult: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let run: () -> Void
    }

    /// 7.24: a one-tap start when nothing is running (Focus, Keep Awake 1 h).
    struct Chip: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let run: () -> Void
    }

    let isEngineRunning: Bool
    let liveSessions: [LiveSession]
    let toggles: [ToggleTile]
    let quickActions: [QuickAction]
    var quickPerRow = 4
    let launcherShortcutText: String?
    var sound: SoundStrip? = nil
    var recentClips: [ClipSlot] = []
    var idleChips: [Chip] = []
    var search: (String) -> [SearchResult] = { _ in [] }

    let onToggleMaster: () -> Void
    let onOpenLauncher: () -> Void
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onShowClassicMenu: () -> Void
    var onEditMenu: () -> Void = {}
    var accessory: AnyView? = nil
    var onCommand: (AOMFeatureCommand) -> Void = { $0.run() }
    var onResize: () -> Void = {}

    @State private var query = ""
    @State private var openMenu: String?
    /// The body's height when the search opens: the results take the same
    /// space, so the panel doesn't jump (spec MBP-3).
    @State private var bodyHeight: CGFloat = 260
    @FocusState private var searchFocused: Bool
    @State private var selectedResult = 0
    /// 7.24.1 (agy §6.1-1): the newest copy only, unless opened — the panel
    /// stays under 560 pt even on a laptop with the battery row.
    @AppStorage("AOMPanelClipsExpanded") private var clipsExpanded = false

    private var results: [SearchResult] { query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : search(query) }

    var body: some View {
        VStack(spacing: 10) {
            header
            searchField
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                resultsList.frame(height: bodyHeight)
            } else {
                mainBody
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { bodyHeight = max(180, geometry.size.height) }
                            .onChange(of: geometry.size.height) { _, height in bodyHeight = max(180, height) }
                    })
            }
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .onChange(of: openMenu) { _, _ in DispatchQueue.main.async { onResize() } }
        .onChange(of: query) { _, _ in selectedResult = 0 }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        // 7.1: Apple's Liquid Glass (macOS 26+; a material before, an opaque
        // surface with Reduce Transparency or Increase Contrast).
        .aomFloatingGlass(radius: AOMCraftRadius.floatingPanel)
    }

    // MARK: Header and search

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(isEngineRunning ? AOMColor.success : AOMColor.warning)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("All of MacOS").font(AOMFont.bodyEmphasis.weight(.semibold))
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
    }

    /// 7.24 (Ice's search panel, MBP-5): a real field — typing finds AOM's
    /// commands, hidden menu bar icons and recent copies; ↩ runs the first,
    /// ↑↓ move, esc clears, ⌘K opens the full launcher.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(AOMCraftColor.inkSecondary)
            TextField("Search commands, icons, copies", text: $query)
                .textFieldStyle(.plain)
                .font(AOMFont.body)
                .focused($searchFocused)
                .onSubmit(runSelected)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) {
                    if query.isEmpty, openMenu == nil { return .ignored }
                    if query.isEmpty { toggleMenu(nil) } else { query = "" }
                    return .handled
                }
                .accessibilityLabel("Search the panel")
            Button(action: onOpenLauncher) {
                HStack(spacing: 4) {
                    Text("Launcher").font(AOMFont.caption).foregroundStyle(AOMCraftColor.inkSecondary)
                    if let launcherShortcutText { AOMCraftKeycap(text: launcherShortcutText) }
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Open the full launcher (⌘K)")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedResult = (selectedResult + delta + count) % count
    }

    private func runSelected() {
        let list = results
        guard list.indices.contains(selectedResult) else { return }
        list[selectedResult].run()
        query = ""
    }

    private var resultsList: some View {
        let list = results
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if list.isEmpty {
                    Button(action: onOpenLauncher) {
                        row(symbol: "magnifyingglass", title: "Search “\(query)” in the launcher", subtitle: "Apps, files, AI and more")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { index, result in
                    Button {
                        result.run()
                        query = ""
                    } label: {
                        row(symbol: result.symbol, title: result.title, subtitle: result.subtitle)
                            .background(index == selectedResult ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .aomCalmHover(radius: 8)
                }
            }
        }
    }

    private func row(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(AOMFont.callout).frame(width: 20)
                .foregroundStyle(AOMCraftColor.inkSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(AOMFont.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(AOMFont.caption).foregroundStyle(AOMCraftColor.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    // MARK: Body

    private var mainBody: some View {
        VStack(spacing: 10) {
            sessionsOrChips
            if let sound { soundStrip(sound) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(toggles) { tile in tileView(tile) }
            }
            if let id = openMenu, let tile = toggles.first(where: { $0.id == id }), let commands = tile.menu {
                tileMenu(tile, commands)
            }
            if !recentClips.isEmpty { clipStrip }
            if let accessory { accessory }
            quickActionRow
        }
    }

    @ViewBuilder private var sessionsOrChips: some View {
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
        } else if !idleChips.isEmpty {
            HStack(spacing: 6) {
                ForEach(idleChips) { chip in
                    Button(action: chip.run) {
                        Label(chip.title, systemImage: chip.symbol)
                            .font(AOMFont.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .aomCalmHover(radius: 13)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func soundStrip(_ sound: SoundStrip) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(sound.devices) { device in
                        Button {
                            sound.onSelectDevice(device)
                        } label: {
                            Text(device.name + (device.id == sound.currentDeviceID ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Label(sound.deviceName, systemImage: "hifispeaker")
                        .font(AOMFont.callout.weight(.medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sound output")
                Spacer(minLength: 0)
                if sound.appAudioAvailable {
                    Button(action: sound.onOpenMixer) {
                        Text("Apps").font(AOMFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AOMCraftColor.inkSecondary)
                    .help("Per-app volume in the Audio page")
                    Toggle("App Audio", isOn: Binding(get: { sound.appAudioOn }, set: { _ in sound.onToggleAppAudio() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help(sound.appAudioOn ? "Per-app volume is on" : "Turn on per-app volume")
                }
            }
            HStack(spacing: 8) {
                Button(action: sound.onToggleMute) {
                    Image(systemName: sound.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(AOMFont.callout)
                        .foregroundStyle(sound.muted ? AOMColor.warning : AOMCraftColor.inkSecondary)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sound.muted ? "Unmute" : "Mute")
                if let volume = sound.volume {
                    Slider(value: Binding(get: { volume }, set: { sound.onVolume($0) }), in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("Volume")
                    Text("\(Int((volume * 100).rounded()))")
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                        .frame(width: 26, alignment: .trailing)
                } else {
                    Text("This output sets its own volume")
                        .font(AOMFont.caption).foregroundStyle(AOMCraftColor.inkSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var clipStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Recent copies").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMCraftColor.inkSecondary)
                Spacer()
                if recentClips.count > 1 {
                    Button {
                        clipsExpanded.toggle()
                        DispatchQueue.main.async { onResize() }
                    } label: {
                        HStack(spacing: 2) {
                            Text(clipsExpanded ? "Less" : "\(recentClips.count - 1) more").font(AOMFont.caption)
                            Image(systemName: clipsExpanded ? "chevron.up" : "chevron.down").font(Font.caption2.weight(.bold))
                        }
                        .foregroundStyle(AOMCraftColor.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(clipsExpanded ? "Show only the last copy" : "Show the last three copies")
                }
            }
            .padding(.horizontal, 4)
            ForEach(clipsExpanded ? recentClips : Array(recentClips.prefix(1))) { clip in
                Button(action: clip.onPaste) {
                    HStack(spacing: 8) {
                        Image(systemName: clip.concealed ? "lock.fill" : clip.symbol)
                            .font(AOMFont.caption).frame(width: 16)
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                        Text(clip.title).font(AOMFont.callout).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(clip.detail).font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMCraftColor.inkTertiary)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 7)
                .help("Paste into the app in front (⌥-click copies)")
                .accessibilityLabel(clip.concealed ? "Hidden secret" : clip.title)
                .accessibilityHint("Pastes it into the app in front")
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var quickActionRow: some View {
        HStack(spacing: 8) {
            ForEach(quickActions.prefix(quickPerRow)) { item in
                Button(action: item.onRun) {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(AOMFont.title)
                        Text(item.title)
                            .font(AOMFont.badge)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .aomCalmHover(radius: 10)
                .help(item.title)
            }
        }
    }

    // MARK: Footer (MBP-7: the window first, the rest quiet)

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: onOpenMainWindow) {
                Label("Open All of MacOS", systemImage: "macwindow")
                    .font(AOMFont.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open the main window (⌘O)")

            Spacer()

            if quickActions.count > quickPerRow {
                Menu("More") {
                    ForEach(quickActions.dropFirst(quickPerRow)) { item in
                        Button(item.title, action: item.onRun)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(AOMFont.caption)
            }
            iconButton("slider.horizontal.3", label: "Customize This Panel", action: onEditMenu)
            iconButton("gearshape", label: "Settings", action: onOpenSettings)
            iconButton("ellipsis.circle", label: "All Commands and Quit", action: onShowClassicMenu)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AOMFont.callout)
                .foregroundStyle(AOMCraftColor.inkSecondary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .aomCalmHover(radius: 6)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Tiles (MBP-3: one rule — the badge acts, the name opens)

    private func tileCircle(_ tile: ToggleTile) -> some View {
        ZStack {
            Circle()
                .fill(tile.isOn ? tile.tint : Color.primary.opacity(0.10))
                .frame(width: 30, height: 30)
            Image(systemName: tile.symbol)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(tile.isOn ? .white : .secondary)
        }
        .frame(width: 44, height: 52)
        .contentShape(Rectangle())
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
                .minimumScaleFactor(0.9)
        }
    }

    /// The badge flips the tile's switch (or, for a menu-only tile such as
    /// Capture, opens its choices); the name opens the choices under the
    /// tiles, sliding in as through 7.23, or flips a plain switch.
    private func tileView(_ tile: ToggleTile) -> some View {
        HStack(spacing: 0) {
            Button { badgeAction(tile) } label: { tileCircle(tile) }
                .buttonStyle(.plain)
                .help(tile.onToggle == nil ? (tile.primary?.title ?? tile.title)
                      : (tile.isOn ? "Turn off \(tile.title)" : "Turn on \(tile.title)"))
                .accessibilityLabel(tile.onToggle == nil ? (tile.primary?.title ?? tile.title) : "\(tile.title) switch")
                .accessibilityValue(tile.onToggle == nil ? Text("") : (tile.isOn ? Text("On") : Text("Off")))
            Button {
                if tile.menu != nil {
                    toggleMenu(openMenu == tile.id ? nil : tile.id)
                } else {
                    tile.onToggle?()
                }
            } label: {
                HStack(spacing: 4) {
                    tileText(tile)
                    Spacer(minLength: 0)
                    if tile.menu != nil {
                        Image(systemName: "chevron.down")
                            .font(Font.caption2.weight(.bold))
                            .foregroundStyle(AOMCraftColor.inkSecondary)
                            .rotationEffect(.degrees(openMenu == tile.id ? 180 : 0))
                    }
                }
                .padding(.trailing, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tile.menu != nil ? "\(tile.title) options" : tile.title)
        }
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tile.isOn ? tile.tint.opacity(0.14) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(openMenu == tile.id ? tile.tint.opacity(0.7) : .clear, lineWidth: 1.5))
        .aomCalmHover(radius: 12)
    }

    private func badgeAction(_ tile: ToggleTile) {
        if let toggle = tile.onToggle { toggle(); return }
        if let primary = tile.primary { onCommand(primary); return }
        if tile.menu != nil { toggleMenu(openMenu == tile.id ? nil : tile.id) }
    }

    private func toggleMenu(_ id: String?) {
        withAnimation(AOMCraftMotion.resolve(AOMCraftMotion.crossfade, reduceMotion: AOMMotion.systemReduceMotion)) {
            openMenu = id
        }
    }

    /// The choices slide in under the tiles (as through 7.23).
    private func tileMenu(_ tile: ToggleTile, _ commands: [AOMFeatureCommand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol).font(AOMFont.caption.weight(.semibold)).foregroundStyle(tile.tint)
                Text(tile.title).font(AOMFont.callout.weight(.semibold))
                if let note = tile.menuNote {
                    Text(note).font(AOMFont.caption).foregroundStyle(AOMCraftColor.inkSecondary).lineLimit(1)
                }
                Spacer()
                Button { toggleMenu(nil) } label: {
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
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
