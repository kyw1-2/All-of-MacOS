import Combine
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
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @ObservedObject private var appAwake = AppAwakeService.shared
    @ObservedObject private var homebrew = HomebrewModel.shared
    @ObservedObject private var vpn = VPNModel.shared
    @State private var query = ""
    @State private var selectedGroup: SystemToolGroup?
    /// Read in actions, not observed: a page change never re-renders this view.
    @Environment(\.aomPageActivity) private var pageActivity

    private static let tileMinimumWidth: CGFloat = 228
    private static let toggleMinimumWidth: CGFloat = 188
    private static let emptyStateMinimumHeight: CGFloat = 240

    private var showsStrip: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedGroup == nil }

    private var visibleGroups: [(group: SystemToolGroup, tools: [SystemToolInfo])] {
        SystemToolGroup.allCases.compactMap { group in
            guard selectedGroup == nil || selectedGroup == group else { return nil }
            // 7.2.2: a grouped tile's options show only while searching.
            let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let tools = SystemToolCatalog.availableTools(in: group).filter { $0.matches(query) && (searching || $0.groupedInto == nil) }
            return tools.isEmpty ? nil : (group, tools)
        }
    }

    /// The last result, or how to use the page before anything ran.
    private var subtitle: String {
        guard let result = model.lastResult else {
            return "Browse by category, search for a task, or star a tool for quick access."
        }
        let time = result.date.formatted(date: .omitted, time: .shortened)
        return "\(result.succeeded ? "✓" : "⚠︎") \(SystemToolCatalog.info(result.tool).title.replacingOccurrences(of: "…", with: "")): \(result.message) · \(time)"
    }

    var body: some View {
        AOMPage {
            // 7.15 (M01): the last result, or an invitation — not the page's name.
            AOMPageHeader(model.lastResult.map { $0.succeeded ? "Last task finished" : "Last task needs a look" } ?? "Maintenance and quick fixes",
                          subtitle: subtitle)
                .help(model.lastResult?.message ?? "")
            HStack {
                // 6.1: categories as view tabs (Linear, iStat Menus' module
                // bar) instead of a pop-up, so every group is one click away.
                AOMScopeBar(items: [AOMScopeItem<SystemToolGroup?>(id: nil, title: "All", symbol: "square.grid.2x2")]
                            + SystemToolGroup.allCases.map { AOMScopeItem(id: Optional($0), title: $0.name, symbol: $0.symbol) },
                            selection: $selectedGroup, accessibilityLabel: "Category")
                Spacer()
                if selectedGroup != nil || !query.isEmpty {
                    Button("Reset Filters") { selectedGroup = nil; query = "" }
                }
            }
            if showsStrip {
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("This Mac")
                    SystemStatusStrip(monitor: status,
                                      openBattery: { selectedGroup = .power },
                                      openFreeUpSpace: { model.showStartupDisk = true },
                                      openNetworkInfo: { model.showNetworkInfo = true })
                }
                favorites
            }
            let shown = visibleGroups
            if shown.isEmpty {
                AOMEmptyState(query.isEmpty ? "No available tools in this category" : "No Tools Match “\(query)”", systemImage: "magnifyingglass",
                              message: "Choose another category or try a different search.") {
                    Button("Show All Tools") { query = ""; selectedGroup = nil }
                }
                .frame(minHeight: Self.emptyStateMinimumHeight)
            } else {
                ForEach(shown, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                        AOMSectionTitle(entry.group.name)
                        // 6.11: the battery card heads Battery & Power.
                        if entry.group == .power && query.isEmpty { HardwareCareCard() }
                        if entry.group == .toggles { toggleGrid(entry.tools) }
                        else if entry.group == .tweaks { tweaksCard(entry.tools) }
                        else { grid(entry.tools) }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .aomPage("System Tools")
        .aomPageToolbar {
            AOMToolbarSearchItem(text: $query, prompt: "Search Tools")
        }
        .sheet(isPresented: $model.showFreeUpSpace) {
            FreeUpSpaceSheet(model: model)
        }
        .sheet(item: $model.cleanupReview) { review in
            CleanupReviewSheet(review: review, onTrash: { model.trashSelected($0) }, onCancel: { model.cleanupReview = nil })
        }
        .sheet(item: $model.processReview) { review in
            ProcessReviewSheet(review: review, onQuit: { model.quitProcess($0) },
                               onSort: { model.resortActivity($0) }, onClose: { model.processReview = nil })
        }
        .sheet(isPresented: $model.showStartupDisk) {
            StartupDiskSheet(model: model)
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
        // A hidden page catches up when it is selected (`model.appear()`).
        .onChange(of: keepAwake.current) { _, _ in refreshIfActive() }
        .onChange(of: sleepTimer.firesAt) { _, _ in refreshIfActive() }
        .onChange(of: appAwake.appName) { _, _ in refreshIfActive() }
        .onChange(of: homebrew.outdated) { _, _ in refreshIfActive() }
        .onChange(of: vpn.lastServices) { _, _ in refreshIfActive() }
        // Which tools exist is checked again at most every 30 s of selections.
        .aomPageLifecycle(minimumInterval: 30, onActivate: { SystemToolAvailability.shared.invalidate() })
        // ⌘K's "Uninstall…" on an app row starts the same review as the tile.
        .onReceive(SystemToolsRequests.shared.$pendingUninstall.compactMap { $0 }.receive(on: DispatchQueue.main)) { _ in
            if let app = SystemToolsRequests.shared.takeUninstall() { model.reviewUninstall(app) }
        }
        .onAppear {
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
        // Refreshed and polled while the page is selected and on screen.
        .aomOnPageVisibilityChange { visible in
            if visible { model.appear(); status.start() }
            else { model.disappear(); status.stop() }
        }
    }

    private func refreshIfActive() {
        if pageActivity.isActive { model.refreshStates() }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: AOMSpace.x1)],
                  alignment: .leading, spacing: 0) {
            ForEach(tools) { info in
                SystemToolTile(info: info, state: model.states[info.id], isRunning: model.running.contains(info.id),
                               isFavorite: model.isFavorite(info.id), run: { model.run(info.id) },
                               toggleFavorite: { model.toggleFavorite(info.id) },
                               dropApp: info.id == .uninstall ? { model.reviewUninstall($0) } : nil)
            }
        }
        .padding(AOMSpace.x1)
        .aomCard(padding: 0)
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
