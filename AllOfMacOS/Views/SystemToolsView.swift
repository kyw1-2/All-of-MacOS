import SwiftUI

/// The System Tools page: a compact This Mac strip, Favorites, then focused
/// sections (Quick Toggles, Display, Power & Session, Apps, Storage, Network,
/// Homebrew when installed, Fix It) and a Settings-style Tweaks list. Toggles
/// show live state, commands are compact buttons, and tools that open a sheet
/// show an ellipsis. Results are toasts and the header's last-result line.
struct SystemToolsView: View {
    @StateObject private var model = SystemToolsModel()
    @StateObject private var status = SystemStatusMonitor()
    @ObservedObject private var keepAwake = KeepAwakeService.shared
    @ObservedObject private var keyboardLock = KeyboardCleaningLock.shared
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @ObservedObject private var appAwake = AppAwakeService.shared
    @ObservedObject private var homebrew = HomebrewModel.shared
    @ObservedObject private var vpn = VPNModel.shared
    @State private var query = ""

    private static let tileMinimumWidth: CGFloat = 228
    private static let toggleMinimumWidth: CGFloat = 188
    private static let emptyStateMinimumHeight: CGFloat = 240

    private var showsStrip: Bool { query.isEmpty }

    private var visibleGroups: [(group: SystemToolGroup, tools: [SystemToolInfo])] {
        SystemToolGroup.allCases.compactMap { group in
            let tools = SystemToolCatalog.availableTools(in: group).filter { $0.matches(query) }
            return tools.isEmpty ? nil : (group, tools)
        }
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
            AOMPageHeader("System Tools", module: .systemTools, subtitle: subtitle)
                .help(model.lastResult?.message ?? "")
            if showsStrip {
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("This Mac", detail: "live")
                    SystemStatusStrip(monitor: status,
                                      openBattery: { model.run(.batteryDetails) },
                                      openFreeUpSpace: { model.showFreeUpSpace = true },
                                      openNetworkInfo: { model.showNetworkInfo = true })
                }
                favorites
            }
            let shown = visibleGroups
            if shown.isEmpty {
                AOMEmptyState("No Tools Match “\(query)”", systemImage: "magnifyingglass",
                              message: "Try another word.") {
                    Button("Clear Search") { query = "" }
                }
                .frame(minHeight: Self.emptyStateMinimumHeight)
            } else {
                ForEach(shown, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                        AOMSectionTitle(entry.group.name)
                        if entry.group == .toggles { toggleGrid(entry.tools) }
                        else if entry.group == .tweaks { tweaksCard(entry.tools) }
                        else { grid(entry.tools) }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .aomPage("System Tools")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Tools")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { model.run(.homebrew) } label: {
                    Label("Homebrew", systemImage: "mug")
                }
                .labelStyle(.titleAndIcon)
                .help("Outdated, installed and service packages")
            }
            ToolbarItem(placement: .automatic) {
                Button { model.run(.vpn) } label: {
                    Label("VPN", systemImage: "network.badge.shield.half.filled")
                }
                .labelStyle(.titleAndIcon)
                .help("VPN connections and Tailscale")
            }
        }
        .sheet(isPresented: $model.showFreeUpSpace) {
            FreeUpSpaceSheet(model: model)
        }
        .sheet(item: Binding(get: { model.showFreeUpSpace ? nil : model.cleanupReview },
                             set: { model.cleanupReview = $0 })) { review in
            CleanupReviewSheet(review: review, onTrash: { model.trashSelected($0) }, onCancel: { model.cleanupReview = nil })
        }
        .sheet(item: $model.processReview) { review in
            ProcessReviewSheet(review: review, onQuit: { model.quitProcess($0) },
                               onSort: { model.resortActivity($0) }, onClose: { model.processReview = nil })
        }
        .sheet(isPresented: $model.showNetworkInfo) {
            NetworkInfoSheet(model: model)
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
        .onAppear {
            SystemToolAvailability.shared.invalidate()
            if PresetManager.isUIPreview {
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
        .aomOnWindowVisibilityChange { visible in
            if visible { model.appear(); status.start() }
            else { model.disappear(); status.stop() }
        }
    }

    // MARK: - Favorites

    @ViewBuilder
    private var favorites: some View {
        let pinned = model.favorites.map(SystemToolCatalog.info).filter(\.isAvailable)
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                AOMSectionTitle("Favorites")
                grid(pinned)
            }
        }
    }

    // MARK: - Pieces

    private func grid(_ tools: [SystemToolInfo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: AOMSpace.tileGap)],
                  alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(tools) { info in
                SystemToolTile(info: info, state: model.states[info.id], isRunning: model.running.contains(info.id),
                               isFavorite: model.isFavorite(info.id), run: { model.run(info.id) },
                               toggleFavorite: { model.toggleFavorite(info.id) },
                               dropApp: info.id == .uninstall ? { model.reviewUninstall($0) } : nil)
            }
        }
    }

    private func toggleGrid(_ tools: [SystemToolInfo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.toggleMinimumWidth), spacing: AOMSpace.tileGap)],
                  alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(tools) { info in
                SystemToggleTile(info: info, state: model.states[info.id], isRunning: model.running.contains(info.id),
                                 isFavorite: model.isFavorite(info.id), run: { model.run(info.id) },
                                 toggleFavorite: { model.toggleFavorite(info.id) })
            }
        }
    }

    /// Tweaks read as Settings rows: a switch, and the value beside pickers.
    private func tweaksCard(_ tools: [SystemToolInfo]) -> some View {
        AOMSection {
            ForEach(tools) { info in
                AOMSettingRow(info.title, showsDivider: info.id != tools.first?.id) {
                    HStack(spacing: AOMSpace.x2) {
                        if let state = model.states[info.id], info.kind == .toggle || info.kind == .sheet {
                            SystemToolValue(state: state)
                        }
                        if info.kind == .sheet {
                            Button("Change…") { model.run(info.id) }
                        } else {
                            Toggle(info.title, isOn: Binding(get: { model.states[info.id]?.tone == .success },
                                                            set: { _ in model.run(info.id) }))
                                .labelsHidden()
                        }
                    }
                }
                .help(info.help)
            }
        }
    }
}
