import SwiftUI
import UniformTypeIdentifiers

/// The System Tools page (design-3.4.0 b.2 Dashboard): a live "This Mac"
/// panel (Activity Monitor / Battery settings style) with the opt-in
/// Weather card, Favorites and Recent, the Quick Toggles as Control Center
/// tiles, then every other tool as a one-row tile in titled groups —
/// Homebrew's group only where brew is installed. Toggle tiles show their
/// current state; the toolbar search matches titles, group names, keywords
/// and descriptions. Results are toasts (failures in the danger tone with
/// why) and the header's last-result line. The engines live in
/// Services/SystemTools and Services/MacMagic, the flows in
/// `SystemToolsModel`.
struct SystemToolsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model = SystemToolsModel()
    @StateObject private var status = SystemStatusMonitor()
    @ObservedObject private var keepAwake = KeepAwakeService.shared
    @ObservedObject private var keyboardLock = KeyboardCleaningLock.shared
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @ObservedObject private var appAwake = AppAwakeService.shared
    @ObservedObject private var homebrew = HomebrewModel.shared
    @ObservedObject private var vpn = VPNModel.shared
    @ObservedObject private var weather = WeatherCardModel.shared
    @State private var showActionLibrary = false
    @State private var choosingWeather = false
    @State private var query = ""
    @State private var selectedGroup: SystemToolGroup? = nil

    /// Wide enough for the longest name ("Awake While App Runs") plus a
    /// state pill on one line: four columns in a 1320 pt window.
    private static let tileMinimumWidth: CGFloat = 228
    /// Control Center tiles: five across in a 1320 pt window.
    private static let toggleMinimumWidth: CGFloat = 188
    /// The no-match state's height, so the page doesn't collapse while typing.
    private static let emptyStateMinimumHeight: CGFloat = 240

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: AOMSpace.tileGap)]
    }

    private var toggleColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.toggleMinimumWidth), spacing: AOMSpace.tileGap)]
    }

    private var visibleGroups: [(group: SystemToolGroup, tools: [SystemToolInfo])] {
        SystemToolGroup.allCases.compactMap { group in
            if let selectedGroup, selectedGroup != group { return nil }
            let tools = SystemToolCatalog.availableTools(in: group).filter { $0.matches(query) }
            return tools.isEmpty ? nil : (group, tools)
        }
    }

    private var groupFilterBar: some View {
        let availableGroups = SystemToolGroup.allCases.filter { !SystemToolCatalog.availableTools(in: $0).isEmpty }
        return ScrollView(.horizontal) {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                AOMFilterChip("All Groups", count: SystemToolsInventory.count, selected: selectedGroup == nil) {
                    withAnimation(AOMMotion.quick) { selectedGroup = nil }
                }
                ForEach(availableGroups, id: \.self) { group in
                    let count = SystemToolCatalog.availableTools(in: group).count
                    AOMFilterChip(group.name, count: count, selected: selectedGroup == group) {
                        withAnimation(AOMMotion.quick) {
                            selectedGroup = selectedGroup == group ? nil : group
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// The last result, or how to use the page before anything ran.
    private var subtitle: String {
        guard let result = model.lastResult else {
            return "Click a tool to run it · right-click to pin it to Favorites"
        }
        let time = result.date.formatted(date: .omitted, time: .shortened)
        return "\(result.succeeded ? "✓" : "⚠︎") \(SystemToolCatalog.info(result.tool).title.replacingOccurrences(of: "…", with: "")): \(result.message) · \(time)"
    }

    var body: some View {
        AOMPage {
            AOMPageHeader("\(SystemToolsInventory.count) tools in \(SystemToolsInventory.groupCount) groups",
                          module: .systemTools, subtitle: subtitle)
                .help(model.lastResult.map(\.message) ?? "")
            if showActionLibrary {
                AOMSectionCard("All actions", symbol: "square.grid.3x3", accessory: {
                    Button("Hide") { showActionLibrary = false }
                }) {
                    ActionLibraryView().environmentObject(appState)
                }
            }
            if query.isEmpty {
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("This Mac", detail: "live") {
                        if !weather.isOn {
                            AOMCardLink("Show Weather", symbol: "cloud.sun") { choosingWeather = true }
                                .help("Adds a weather card from Open-Meteo for a city you choose")
                                .popover(isPresented: $choosingWeather, arrowEdge: .bottom) {
                                    WeatherPlacePicker(model: weather) { choosingWeather = false }
                                }
                        }
                    }
                    SystemStatusPanel(monitor: status, weather: weather.isOn ? weather : nil)
                }
                HardwareCareCard()
                shortcuts
            }
            groupFilterBar
            let shown = visibleGroups
            if shown.isEmpty {
                AOMEmptyState("No Tools Match “\(query)”", systemImage: "magnifyingglass",
                              message: "Try another word, or browse every action AOM can run.") {
                    Button("Clear Search") { query = "" }
                    Button("All Actions") { query = ""; showActionLibrary = true }
                }
                .frame(minHeight: Self.emptyStateMinimumHeight)
            } else {
                ForEach(shown, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                        AOMSectionTitle(entry.group.name, detail: "\(entry.tools.count)") { groupAccessory(entry.group) }
                        if entry.group == .toggles { toggleGrid(entry.tools) } else { grid(entry.tools) }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .aomPage("System Tools")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Tools")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { homebrew.present(.outdated, refresh: true) } label: {
                    Label("Homebrew", systemImage: "mug")
                }
                .labelStyle(.titleAndIcon)
                .help("Check outdated packages, installed packages, services and Brew Doctor")
            }
            ToolbarItem(placement: .automatic) {
                Button { showActionLibrary.toggle() } label: {
                    Label(showActionLibrary ? "Hide All Actions" : "All Actions", systemImage: "square.grid.3x3")
                }
                .help("Browse every action AOM can run")
            }
            ToolbarItem(placement: .automatic) {
                Button { FloatingMenuController.shared.edit() } label: {
                    Label("Floating Menus", systemImage: "menubar.rectangle")
                }
                .help("Configure custom floating menus and desktop widgets")
            }
            ToolbarItem(placement: .automatic) {
                Button { model.run(.vpn) } label: {
                    Label("VPN", systemImage: "network.badge.shield.half.filled")
                }
                .help("Manage VPN and Tailscale connections")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Floating Menus & Widgets…") { FloatingMenuController.shared.edit() }
                    Divider()
                    Button("VPN Connections…") { model.run(.vpn) }
                    if !weather.isOn {
                        Button("Show Weather…") { choosingWeather = true }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Floating menus, VPN and the weather card")
            }
        }
        .sheet(item: $model.cleanupReview) { review in
            CleanupReviewSheet(review: review, onTrash: { model.trashSelected($0) }, onCancel: { model.cleanupReview = nil })
        }
        .sheet(item: $model.processReview) { review in
            ProcessReviewSheet(review: review, onQuit: { model.quitProcess($0) }, onClose: { model.processReview = nil })
        }
        .sheet(isPresented: $homebrew.isPresented, onDismiss: { model.refreshStates() }) {
            HomebrewSheet(model: homebrew)
        }
        .sheet(isPresented: $vpn.isPresented, onDismiss: { model.refreshStates() }) {
            VPNSheet(model: vpn)
        }
        .aomToast(model.toasts)
        // Keep Awake and the keyboard lock also change from menus and timers.
        .onChange(of: keepAwake.current) { _, _ in model.refreshStates() }
        .onChange(of: keyboardLock.endsAt) { _, _ in model.refreshStates() }
        .onChange(of: sleepTimer.firesAt) { _, _ in model.refreshStates() }
        .onChange(of: appAwake.appName) { _, _ in model.refreshStates() }
        .onChange(of: homebrew.outdated) { _, _ in model.refreshStates() }
        .onChange(of: vpn.lastServices) { _, _ in model.refreshStates() }
        .onChange(of: vpn.tailscale) { _, _ in model.refreshStates() }
        .onAppear {
            SystemToolAvailability.shared.invalidate()
            model.appear()
            status.start()
            if PresetManager.isUIPreview {
                weather.loadPreviewSample()
                MicMutePreview.runIfRequested()
                if ProcessInfo.processInfo.arguments.contains("--aom-preview-homebrew") {
                    homebrew.loadPreviewSample()
                    homebrew.isPresented = true
                }
                if ProcessInfo.processInfo.arguments.contains("--aom-preview-vpn") {
                    vpn.loadPreviewSample()
                    vpn.isPresented = true
                }
            }
        }
        .onDisappear { model.disappear(); status.stop() }
    }

    /// A group title's one action: Homebrew's sheet, the VPN sheet.
    @ViewBuilder
    private func groupAccessory(_ group: SystemToolGroup) -> some View {
        switch group {
        case .homebrew:
            AOMCardLink(homebrew.isBusy ? "Running…" : "Open Homebrew") { model.run(.brewOutdated) }
                .help("Outdated, installed, services, search and the live log")
        case .pdf:
            Text("Each tool saves a new file").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Favorites and recent

    @ViewBuilder
    private var shortcuts: some View {
        let favorites = model.favorites.map(SystemToolCatalog.info).filter(\.isAvailable)
        let recent = model.recent.filter { !model.favorites.contains($0) }.map(SystemToolCatalog.info).filter(\.isAvailable)
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                AOMSectionTitle("Favorites", detail: "\(favorites.count)")
                grid(favorites)
            }
        }
        if !recent.isEmpty {
            HStack(spacing: AOMSpace.x3) {
                Text("Recent").font(AOMFont.section).foregroundStyle(AOMColor.text).accessibilityAddTraits(.isHeader)
                ForEach(recent) { info in
                    Button { model.run(info.id) } label: {
                        Label(info.title, systemImage: info.symbol).font(AOMFont.body).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.running.contains(info.id))
                    .help(info.help)
                    .contextMenu {
                        Button("Run") { model.run(info.id) }
                        Button("Add to Favorites") { model.toggleFavorite(info.id) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x0_5)
        }
    }

    // MARK: - Pieces

    private func grid(_ tools: [SystemToolInfo]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(tools) { info in
                SystemToolTile(info: info, state: info.isToggle ? model.states[info.id] : nil,
                               isRunning: model.running.contains(info.id) || isBusy(info.id), isFavorite: model.isFavorite(info.id),
                               run: { model.run(info.id) }, toggleFavorite: { model.toggleFavorite(info.id) },
                               dropApp: info.id == .uninstall ? { model.uninstallApp($0) } : nil)
            }
        }
    }

    private func toggleGrid(_ tools: [SystemToolInfo]) -> some View {
        LazyVGrid(columns: toggleColumns, alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(tools) { info in
                SystemToggleTile(info: info, state: info.isToggle ? model.states[info.id] : nil,
                                 isRunning: model.running.contains(info.id), isFavorite: model.isFavorite(info.id),
                                 run: { model.run(info.id) }, toggleFavorite: { model.toggleFavorite(info.id) })
            }
        }
    }

    /// Homebrew tiles spin while a brew job they started runs in the sheet.
    private func isBusy(_ id: SystemToolID) -> Bool {
        guard let job = homebrew.job else { return false }
        switch (id, job.command) {
        case (.brewOutdated, .outdated), (.brewUpgradeAll, .upgradeAll), (.brewInstalled, .installed), (.brewUpdate, .update),
             (.brewCleanup, .cleanup), (.brewCleanup, .cleanupDryRun), (.brewDoctor, .doctor), (.brewServices, .services):
            return true
        default:
            return false
        }
    }
}
