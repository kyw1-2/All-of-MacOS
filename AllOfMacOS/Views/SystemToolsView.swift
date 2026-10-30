import SwiftUI

/// The System Tools page (design-3.3.6): a live "This Mac" panel (Activity
/// Monitor / Battery settings style), the Quick Toggles as Control Center
/// tiles, Favorites and Recent, then every other tool as a one-row tile in
/// titled sections. Toggle tiles show their current state; the toolbar
/// search matches titles, group names, keywords and descriptions. Each tool
/// collects its own inputs via menus and panels. The engines live in
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
    @State private var showActionLibrary = false
    @State private var query = ""

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
            let tools = SystemToolCatalog.tools(in: group).filter { $0.matches(query) }
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
            AOMPageHeader("\(SystemToolsInventory.count) tools in \(SystemToolGroup.allCases.count) groups",
                          module: .systemTools, subtitle: subtitle)
            if showActionLibrary {
                AOMSectionCard("All actions", symbol: "square.grid.3x3", accessory: {
                    Button("Hide") { showActionLibrary = false }
                }) {
                    ActionLibraryView().environmentObject(appState)
                }
            }
            if query.isEmpty {
                VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                    AOMSectionTitle("This Mac", detail: "live")
                    SystemStatusPanel(monitor: status)
                }
                shortcuts
            }
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
                        AOMSectionTitle(entry.group.name, detail: "\(entry.tools.count)")
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
                Button { showActionLibrary.toggle() } label: {
                    Label(showActionLibrary ? "Hide All Actions" : "All Actions", systemImage: "square.grid.3x3")
                }
                .help("Browse every action AOM can run")
            }
            // Activation groups belong to Automation: its toolbar's scope menu
            // has "Edit Activation Groups…". Floating menus stay one click here.
            ToolbarItem(placement: .automatic) {
                Button { FloatingMenuController.shared.edit() } label: {
                    Label("Floating Menus & Widgets", systemImage: "menubar.dock.rectangle")
                }
                .help("Create floating menus, clocks and variable widgets")
            }
        }
        .sheet(item: $model.cleanupReview) { review in
            CleanupReviewSheet(review: review, onTrash: { model.trashSelected($0) }, onCancel: { model.cleanupReview = nil })
        }
        .sheet(item: $model.processReview) { review in
            ProcessReviewSheet(review: review, onQuit: { model.quitProcess($0) }, onClose: { model.processReview = nil })
        }
        .aomToast(model.toast)
        .onChange(of: model.toast) { _, message in
            guard message != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                if model.toast == message { model.toast = nil }
            }
        }
        // Keep Awake and the keyboard lock also change from menus and timers.
        .onChange(of: keepAwake.current) { _, _ in model.refreshStates() }
        .onChange(of: keyboardLock.endsAt) { _, _ in model.refreshStates() }
        .onChange(of: sleepTimer.firesAt) { _, _ in model.refreshStates() }
        .onChange(of: appAwake.appName) { _, _ in model.refreshStates() }
        .onAppear { model.appear(); status.start() }
        .onDisappear { model.disappear(); status.stop() }
    }

    // MARK: - Favorites and recent

    @ViewBuilder
    private var shortcuts: some View {
        let favorites = model.favorites.map(SystemToolCatalog.info)
        let recent = model.recent.filter { !model.favorites.contains($0) }.map(SystemToolCatalog.info)
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
                               isRunning: model.running.contains(info.id), isFavorite: model.isFavorite(info.id),
                               run: { model.run(info.id) }, toggleFavorite: { model.toggleFavorite(info.id) })
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
}
