import AppKit
import SwiftUI

/// What the clipboard shows when it has nothing to list. A storage failure
/// comes before "empty": until 3.3.1 a locked login Keychain or an unreadable
/// archive looked exactly like an empty history ("Your Clipboard Is Empty"),
/// which reads as "my history was deleted" (audit 2026-10-28 F08). The
/// three cases — a really empty history, a Keychain that is not available
/// yet, and a damaged archive — each say something different.
enum ClipboardEmptyContent: Equatable {
    case loading
    /// `ClipboardStore.StorageStatus.transientFailure`: retried automatically.
    case keychainUnavailable
    /// `ClipboardStore.StorageStatus.unreadableArchive`: waits for the user.
    case unreadableArchive
    case empty(paused: Bool)

    static func resolve(isLoading: Bool, storage: ClipboardStore.StorageStatus, paused: Bool) -> ClipboardEmptyContent {
        switch storage {
        case .transientFailure: return .keychainUnavailable
        case .unreadableArchive: return .unreadableArchive
        case .ok: return isLoading ? .loading : .empty(paused: paused)
        }
    }

    var isStorageProblem: Bool { self == .keychainUnavailable || self == .unreadableArchive }

    var title: String {
        switch self {
        case .loading: return "Unlocking Clipboard History"
        case .keychainUnavailable: return "Clipboard History Is Locked"
        case .unreadableArchive: return "Clipboard History Can't Be Read"
        case .empty: return "Your Clipboard Is Empty"
        }
    }

    var systemImage: String {
        switch self {
        case .loading: return "lock"
        case .keychainUnavailable: return "lock.trianglebadge.exclamationmark"
        case .unreadableArchive: return "exclamationmark.triangle"
        case .empty: return "doc.on.clipboard"
        }
    }

    var message: String {
        switch self {
        case .loading:
            return "If macOS asks for your login keychain password, choose Always Allow."
        case .keychainUnavailable:
            return "Your saved history is still there, but the login Keychain that unlocks it is locked or unavailable. Nothing has been deleted or overwritten. AOM retries for about a minute; after that, unlock the Keychain and choose Try Again. New copies are kept until then."
        case .unreadableArchive:
            return "The saved history file could not be decoded, so AOM stopped saving to protect it. The file has not been changed. Recover Storage keeps it under a new name and starts a new history."
        case .empty(let paused):
            return paused ? "History is paused. Resume to keep what you copy."
                : "Copy text, links, colors, images or files and they appear here — searchable, pinnable and encrypted on this Mac."
        }
    }

    /// The shorter line for the ⇧⌘V shelf.
    var compactMessage: String {
        switch self {
        case .loading: return "If macOS asks for your login keychain password, choose Always Allow."
        case .keychainUnavailable: return "The login Keychain is locked. Your history is kept; unlock it, then choose Try Again on the Clipboard page."
        case .unreadableArchive: return "The history file can't be read. It is kept unchanged; recover it in Clipboard Settings."
        case .empty(let paused):
            return paused ? "Clipboard history is paused. Resume it from the ⋯ menu (⌘T)."
                : "Copy text, links, images or files to keep them here."
        }
    }
}

/// Clipboard library: the full, searchable history and pinboards in the main
/// window (the ⇧⌘V shelf is the quick-paste surface). Native search field,
/// segmented type filter, pinboard chips and an adaptive card grid whose
/// image thumbnails decode off the main thread.
struct ClipboardStudioView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @StateObject private var search = ClipboardPanelState()
    @AppStorage("AOMClipboardGridLayout") private var gridLayout = false
    @State private var target = AOMActionTarget<UUID>()
    @Environment(\.aomPageActivity) private var pageActivity
    @FocusState private var galleryFocused: Bool
    @State private var boardCounts: [UUID: Int] = [:]
    @State private var hoveredCardID: UUID? = nil
    @State private var showingSettings = false
    @State private var showingNewBoardSheet = false
    @State private var showingEraseConfirmation = false
    @State private var showingRecoverConfirmation = false
    @State private var newBoardName = ""
    @State private var newBoardColor = "blue"
    /// A pinboard awaiting the same delete-items-too choice as the shelf.
    @State private var boardPendingDeletion: ClipboardPinboard?
    @StateObject private var toast = AOMToastModel()
    /// List + detail (design-3.4.0 b.2): the list column's width.
    @AppStorage("AOMClipboardListWidth") private var listWidth: Double = 320
    /// Workbench 2 (D15, D09): the selected item's details in a trailing
    /// inspector when the window has room; in the detail otherwise.
    @AppStorage("AOMClipboardInspector") private var showsInspector = true
    @State private var inspectorBeside = false
    /// D16: the pinboard and type the library was narrowed to, kept across
    /// the page being rebuilt (LRU eviction, relaunch). The search text isn't.
    @AppStorage("AOMClipboardLibraryBoard") private var savedBoard = ""
    @AppStorage("AOMClipboardLibraryKind") private var savedKind = ""
    @Environment(\.undoManager) private var undoManager
    @State private var showingNewTextSheet = false
    @State private var newText = ""
    /// The detail's title while it is being renamed in place.
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var renameGeneration = AOMFocusGeneration()
    @FocusState private var renameFocused: Bool
    /// Characters, words and lines (or pixels) for the detail, read off the
    /// main thread by the preview cache.
    @State private var detailSummary: [UUID: String] = [:]
    /// The history revision `boardCounts` was counted from.
    @State private var boardCountsRevision: Int?

    private let boardColors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    private var filteredEntries: [ClipboardEntry] {
        search.displayedResults(in: store)
    }


    private var subtitle: String {
        let count = store.entries.count
        let pinned = store.entries.filter { !$0.pinboardIDs.isEmpty }.count
        var parts = ["\(count.formatted()) item\(count == 1 ? "" : "s")", "\(store.boards.count) pinboard\(store.boards.count == 1 ? "" : "s")"]
        if pinned > 0 { parts.append("\(pinned.formatted()) pinned") }
        if store.paused && store.pauseRemainingSeconds > 0 {
            let minutes = max(1, Int((Double(store.pauseRemainingSeconds) / 60).rounded(.up)))
            parts.append("resumes in \(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    /// d.9: whether history is being saved, what it holds, and the same
    /// switch as the Workspace tile (off pauses until resumed).
    private var header: some View {
        AOMPageHeader(store.paused ? "Clipboard history is paused" : "Clipboard history is on",
                      subtitle: subtitle,
                      help: "AOM keeps what you copy, encrypted on this Mac, so you can search it and paste it again. Pinboards keep items past the history limit. Open the shelf with \(ClipboardShortcuts.shared.shortcut(for: .history)?.displayString ?? "its shortcut") to paste without leaving your app.",
                      active: !store.paused) {
            Toggle("Save clipboard history", isOn: Binding(get: { !store.paused },
                                                           set: { $0 ? store.resume() : store.pause() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(store.paused ? "Resume clipboard history" : "Stop saving what you copy until you resume")
                .accessibilityLabel("Save clipboard history")
        }
    }

    var body: some View {
        let entries = filteredEntries
        let pending = search.isSearchPending
        let state = ClipboardEmptyContent.resolve(isLoading: store.isLoading, storage: store.storageStatus, paused: store.paused)
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.pageTop)
                .padding(.bottom, AOMSpace.x2)
            filterBar
            AOMDivider()
            // Copies made while storage is blocked are listed but not saved:
            // the library says so above the list, with the way to fix it.
            if state.isStorageProblem && !store.entries.isEmpty {
                AOMNotice(.warning, "Clipboard history isn't being saved", detail: state.message) { storageActions(state) }
                    .padding(.horizontal, AOMSpace.x4).padding(.vertical, AOMSpace.x3)
            }
            Group {
                if pending {
                    HStack(spacing: AOMSpace.x2) {
                        ProgressView().controlSize(.small)
                        Text("Searching clipboard…").font(AOMFont.callout)
                    }
                    .padding(AOMSpace.pageMargin)
                } else if entries.isEmpty {
                    emptyLibrary(state)
                } else {
                    library(entries)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .aomPane()
        .aomPageToolbar {
            toolbarContent
            AOMToolbarSearchItem(text: $search.query, prompt: "Search text, links and files")
        }
        // Pinboard counts follow the history while the page is selected and on
        // screen, and catch up on return if the history changed meanwhile.
        .aomVisibleTask(id: store.revision) {
            let revision = store.revision
            guard revision != boardCountsRevision else { return }
            let entries = store.entries
            let counts = await Task.detached(priority: .userInitiated) {
                var counts: [UUID: Int] = [:]
                for entry in entries { for id in entry.pinboardIDs { counts[id, default: 0] += 1 } }
                return counts
            }.value
            guard !Task.isCancelled else { return }
            boardCounts = counts
            boardCountsRevision = revision
        }
        .sheet(isPresented: $showingSettings) {
            ModuleSettingsSheet("Clipboard Settings", done: { showingSettings = false }) {
                ClipboardSettingsView()
            }
        }
        .onChange(of: entries.map(\.id)) { _, ids in reconcileSelection(ids, pending: pending) }
        .onChange(of: pending) { _, pending in reconcileSelection(entries.map(\.id), pending: pending) }
        .onChange(of: target.selected) { _, id in if renamingID != id { cancelRename() } }
        .onChange(of: gridLayout) { _, _ in cancelRename() }
        .onChange(of: store.boards.map(\.id)) { _, ids in
            if let board = search.board, !ids.contains(board) { search.board = nil; target.selected = nil }
        }
        .aomPageLifecycle(onActivate: {
            let live = filteredEntries
            reconcileSelection(live.map(\.id), pending: search.isSearchPending)
        }, onDeactivate: { cancelRename() })
        .task {
            guard AOMWorkbenchPreviewData.enabled else { return }
            await store.ready()
            guard !Task.isCancelled, store.entries.isEmpty else { return }
            let samples = AOMWorkbenchPreviewData.clipboard()
            store.seedWorkbenchPreview(entries: samples.entries, boards: samples.boards)
        }
        .sheet(isPresented: $showingNewBoardSheet) { newBoardSheet }
        .onChange(of: search.board) { _, board in savedBoard = board?.uuidString ?? "" }
        .onChange(of: search.kind) { _, kind in savedKind = kind?.rawValue ?? "" }
        .sheet(isPresented: $showingNewTextSheet) { newTextSheet }
        .onAppear {
            // D16: back to the pinboard and type last shown, if they still exist.
            let restored = ClipboardLibraryFilterMemory.restore(board: savedBoard, kind: savedKind,
                                                               boards: store.boards.map(\.id))
            if search.board == nil { search.board = restored.board }
            if search.kind == nil { search.kind = restored.kind }
            // Isolated previews can open the settings sheet for review
            // (`--aom-preview-clipboard-settings`).
            if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-clipboard-settings") {
                showingSettings = true
            }
        }
        .confirmationDialog("Delete “\(boardPendingDeletion?.name ?? "")”?", isPresented: Binding(
            get: { boardPendingDeletion != nil }, set: { if !$0 { boardPendingDeletion = nil } })) {
            let only = boardPendingDeletion.map { store.itemsOnlyOnBoard($0.id) } ?? 0
            Button(only == 0 ? "Delete Pinboard" : "Delete Pinboard and \(only) Item\(only == 1 ? "" : "s")", role: .destructive) {
                deletePendingBoard(deletingItems: true)
            }
            if only > 0 {
                Button("Delete Pinboard, Keep Items") { deletePendingBoard(deletingItems: false) }
            }
            Button("Cancel", role: .cancel) { boardPendingDeletion = nil }
        } message: {
            Text(ClipboardBoardDeletionCopy.message(onlyHere: boardPendingDeletion.map { store.itemsOnlyOnBoard($0.id) } ?? 0))
        }
        .confirmationDialog("Erase clipboard history?", isPresented: $showingEraseConfirmation) {
            Button("Erase History", role: .destructive) {
                store.eraseHistory()
                showToast("History erased · pinned items kept")
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(ClipboardEraseCopy.message(unpinned: store.entries.filter { $0.pinboardIDs.isEmpty }.count)) }
        .confirmationDialog("Recover clipboard storage?", isPresented: $showingRecoverConfirmation) {
            Button("Archive Unreadable File and Resume", role: .destructive) { Task { await store.recoverStorage() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The unreadable file is renamed and kept; AOM then starts a new history file.") }
        .aomToast(toast)
        // 6.0: the selected item and what can be done to it, in the action bar.
        .aomBarContext(id: clipboardBarKey) { clipboardBarContext() }
    }

    /// What the bar's clipboard context depends on: the item and its pins.
    private var clipboardBarKey: String {
        guard let entry = liveEntry() else { return "" }
        let id = entry.id
        // 7.16 (GPT V03): the boards' names and order too — the bar lists them.
        let boards = store.boards.prefix(4).map { $0.id.uuidString + $0.name }.joined(separator: "|")
        return id.uuidString + entry.pinboardIDs.map(\.uuidString).sorted().joined() + entry.title + "#" + boards
    }

    /// 7.16 (GPT V03): the bar's buttons find the item and the board again
    /// by id when pressed; one deleted or renamed meanwhile isn't acted on
    /// through a stale copy.
    private func liveEntry(expecting id: UUID? = nil, addressedTo row: UUID? = nil) -> ClipboardEntry? {
        guard pageActivity.isActive, search.board.map({ id in store.boards.contains { $0.id == id } }) != false else { return nil }
        // Refresh against the current query/revision *before* inspecting pending.
        // This also blocks a shortcut in the same turn as a query change.
        let visible = filteredEntries
        return target.resolve(in: visible, pending: search.isSearchPending, id: \.id,
                              addressedTo: row, expecting: id)
    }

    private func clipboardBarContext() -> AOMBarContext? {
        guard let entry = liveEntry() else { return nil }
        let hue = AOMModule.clipboard.hue
        let id = entry.id
        var actions = [
            AOMBarAction(id: "clip.copy", title: "Copy", identity: AOMIdentity(symbol: "doc.on.doc", color: hue),
                         run: { copy(expecting: id) }, key: SwiftUI.KeyboardShortcut(.return, modifiers: .command)),
            AOMBarAction(id: "clip.plain", title: "Copy as Plain Text", identity: AOMIdentity(symbol: "textformat", color: hue),
                         run: { copy(expecting: id, plainText: true) }),
            AOMBarAction(id: "clip.rename", title: "Rename", identity: AOMIdentity(symbol: "pencil", color: hue),
                         run: { if let now = liveEntry(expecting: id) { beginRename(now) } })
        ]
        for board in store.boards.prefix(4) {
            let pinned = entry.pinboardIDs.contains(board.id)
            let boardID = board.id
            actions.append(AOMBarAction(id: "clip.pin.\(board.id)", title: pinned ? "Unpin from \(board.name)" : "Pin to \(board.name)",
                                        identity: AOMIdentity(symbol: pinned ? "pin.slash" : "pin", color: hue),
                                        run: {
                                            guard let now = liveEntry(expecting: id) else { return }
                                            togglePin(now, boardID: boardID)
                                        }))
        }
        actions.append(AOMBarAction(id: "clip.delete", title: "Delete", identity: AOMIdentity(symbol: "trash", color: AOMColor.danger),
                                    run: { if let now = liveEntry(expecting: id) { delete(now) } }))
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return AOMBarContext(title: title.isEmpty ? "Selected item" : String(title.prefix(60)), actions: actions)
    }

    /// The retry or recovery for a storage problem, on the same screen that
    /// reports it (until 3.3.1 they lived only in Clipboard Settings).
    @ViewBuilder
    private func storageActions(_ state: ClipboardEmptyContent) -> some View {
        switch state {
        case .keychainUnavailable:
            Button("Try Again") { Task { await store.recoverStorage() } }
                .buttonStyle(AOMPrimaryButtonStyle())
        case .unreadableArchive:
            HStack(spacing: AOMSpace.x2) {
                Button("Recover Storage…") { showingRecoverConfirmation = true }
                    .buttonStyle(AOMPrimaryButtonStyle())
                Button("Clipboard Settings…") { showingSettings = true }
            }
        case .loading, .empty:
            EmptyView()
        }
    }

    // MARK: - Library (list + detail like Mail and Notes; Paste's cards for the gallery)

    private func library(_ entries: [ClipboardEntry]) -> some View {
        let previewID = target.preview(in: entries.map(\.id), autoHighlight: !isNarrowed)
        return Group {
            if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMSize.tileMin, maximum: AOMSize.tileMax), spacing: AOMSpace.tileGap)],
                              spacing: AOMSpace.tileGap) {
                        ForEach(entries) { entry in libraryCard(entry) }
                    }
                    .padding(.horizontal, AOMSpace.pageMargin)
                    .padding(.vertical, AOMSpace.x4)
                }
                .background(AOMPageTint())
                .focusable()
                .focusEffectDisabled()
                .focused($galleryFocused)
                .onKeyPress(.return) { copyFromSelection() }
                .onKeyPress(characters: .init(charactersIn: "c")) { press in copyFromSelection(press) }
                .aomPageDeleteCommand { if let entry = liveEntry() { delete(entry) } }
            } else {
                // The list + detail template (b.2). Workbench 2: `AOMListDetail`
                // draws plain columns now (no `.inspector` inset under the
                // header), and keeps the detail at its minimum in a narrow
                // window by drawing the list narrower than its stored width.
                AOMListDetail(listWidth: $listWidth, showsInspector: $showsInspector, narrowInspector: .inDetail,
                              onArrangementChange: { inspectorBeside = $0.showsInspectorBeside }) {
                    AOMListColumn(rows: {
                        List(selection: $target.selected) {
                            ForEach(entries) { entry in
                                libraryRow(entry)
                                    .listRowBackground(target.selected == nil && previewID == entry.id
                                                       ? AOMColor.track : Color.clear)
                            }
                        }
                        // Plain rows with hairlines: alternating fills also striped
                        // the empty space under a short history.
                        .listStyle(.inset(alternatesRowBackgrounds: false))
                        .scrollContentBackground(.hidden)
                        // Two-line rows (title over source and time), as Mail.
                        .environment(\.defaultMinListRowHeight, AOMSize.listRowDouble)
                        .onKeyPress(.return) { copyFromSelection() }
                        .onKeyPress(characters: .init(charactersIn: "c")) { press in copyFromSelection(press) }
                        .aomPageDeleteCommand { if let entry = liveEntry() { delete(entry) } }
                        .accessibilityLabel("Clipboard items")
                    }, footer: {
                        AOMAddRemoveBar(addLabel: "New Text Item", add: {
                            newText = ""
                            showingNewTextSheet = true
                        }, removeLabel: "Delete Item", remove: liveEntry().map { entry in
                            { if let now = liveEntry(expecting: entry.id) { delete(now) } }
                        }) {
                            Button("New Pinboard…") { presentNewBoard() }
                            Button("Open Shelf") { ClipboardPanelController.shared.show() }
                            Divider()
                            Button("Erase History…", role: .destructive) { showingEraseConfirmation = true }
                                .disabled(!store.entries.contains { $0.pinboardIDs.isEmpty })
                        }
                    })
                } detail: {
                    Group {
                        if let entry = entries.first(where: { $0.id == previewID }) {
                            detailPane(entry)
                        } else {
                            Label("Select an item to preview it.", systemImage: "doc.on.clipboard")
                                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                                .padding(AOMSpace.pageMargin)
                        }
                    }
                } inspector: {
                    inspector(entries.first(where: { $0.id == previewID }))
                }
                .aomListDetailSelection(target.selected)
            }
        }
    }

    /// Whether a search or filter (not the board, which is a place) narrows the library.
    private var isNarrowed: Bool {
        !search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.kind != nil
            || search.source != nil || search.recentDays != 0
    }

    private func reconcileSelection(_ ids: [UUID], pending: Bool) {
        var next = target
        next.reconcile(in: ids, pending: pending)
        if next != target { target = next }
        if let renamingID, pending || !ids.contains(renamingID) { cancelRename() }
    }

    private func copyFromSelection(_ press: KeyPress? = nil) -> KeyPress.Result {
        if let press, press.modifiers != .command { return .ignored }
        guard let entry = liveEntry() else { return .ignored }
        copy(expecting: entry.id)
        return .handled
    }

    private func emptyLibrary(_ state: ClipboardEmptyContent) -> some View {
        let title = store.entries.isEmpty ? state.title
            : (!search.query.isEmpty ? "No matching items" : (search.board == nil ? "No items of this type" : "Pinboard is empty"))
        return HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Label(title, systemImage: store.entries.isEmpty ? state.systemImage : "tray")
                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
            if store.entries.isEmpty {
                if case .empty(paused: true) = state {
                    Button("Resume History") { store.resume() }.buttonStyle(AOMSoftButtonStyle())
                } else {
                    storageActions(state)
                }
                AOMInfoButton(state.message)
            } else {
                Button("Show All Items") { search.query = ""; search.kind = nil; search.board = nil }
                    .buttonStyle(AOMSoftButtonStyle())
            }
        }
        .padding(AOMSpace.pageMargin)
    }

    /// Two lines per item, like a Mail or Notes list: the title in Body over
    /// the source and the time in Callout. Hierarchical styles turn white on
    /// selection.
    private func libraryRow(_ entry: ClipboardEntry) -> some View {
        let detail = [entry.kind.displayName, Self.listSource(entry), AOMRelativeTime.string(entry.lastCopiedAt)]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: AOMSpace.x2) {
            Group {
                if entry.kind == .color, let hex = entry.text {
                    Circle().fill(Color(hex: hex))
                        .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                        .frame(width: AOMIcon.row - AOMSpace.x1, height: AOMIcon.row - AOMSpace.x1)
                } else {
                    Image(systemName: entry.kind.symbol)
                        .font(AOMFont.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: AOMIcon.row)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(entry.title)
                    .font(AOMFont.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x1)
            if !entry.pinboardIDs.isEmpty {
                Image(systemName: "pin.fill").font(AOMFont.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, AOMSpace.x0_5)
        .frame(minHeight: AOMSize.rowDetail - AOMSpace.x2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .help(entry.title)
        .tag(entry.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { copy(addressedTo: entry.id) })
        .onDrag { liveEntry(addressedTo: entry.id).map(ClipboardStudioDrag.provider(for:)) ?? NSItemProvider() }
        .contextMenu { entryMenu(entry) }
    }

    /// AOM itself: items it makes (text it writes, edited images) carry the
    /// release bundle ID; copies from its own windows carry the running one.
    private static let ownBundleIDs = Set(["com.kyw.allofmacos", Bundle.main.bundleIdentifier].compactMap { $0 })

    /// The source a list row names. AOM's own items name none, so rows don't
    /// all repeat "All of MacOS"; the preview pane still shows the source.
    private static func listSource(_ entry: ClipboardEntry) -> String? {
        guard let id = entry.sourceBundleID, ownBundleIDs.contains(id) else { return entry.sourceName }
        return nil
    }

    /// Flat, no shortcuts, unavailable items hidden (b.4).
    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry, fromRow: Bool = true) -> some View {
        let expected = fromRow ? nil : entry.id
        let addressed = fromRow ? entry.id : nil
        let resolve: () -> ClipboardEntry? = { liveEntry(expecting: expected, addressedTo: addressed) }
        Button("Copy") { copy(expecting: expected, addressedTo: addressed) }
        if entry.kind == .text || entry.kind == .link {
            Button("Copy as Plain Text") { copy(expecting: expected, addressedTo: addressed, plainText: true) }
        }
        if entry.kind == .link {
            Button("Open Link") { openLink(resolve()) }
        }
        if !entry.fileURLs.isEmpty {
            Button("Show in Finder") {
                if let files = resolve()?.fileURLs, !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
            }
        }
        if !gridLayout {
            Button("Rename") { if let now = resolve() { beginRename(now) } }
        }
        if !store.boards.isEmpty {
            Menu("Pinboards") {
                ForEach(store.boards) { board in
                    Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                        if let now = resolve() { togglePin(now, boardID: board.id) }
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { if let now = resolve() { delete(now) } }
    }

    private func openLink(_ entry: ClipboardEntry?) {
        guard let entry, entry.kind == .link, let text = entry.text,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The selected item, readable (design-3.4.0 b.2 detail): its title
    /// (click to rename), what it is and where it came from, the actions, the
    /// content made for its kind, then the details.
    private func detailPane(_ entry: ClipboardEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                detailHeader(entry)
                ClipboardStudioCard.Preview(entry: entry, large: true, onOpenLink: { openLink(liveEntry(expecting: entry.id)) })
                    .frame(maxWidth: .infinity,
                           minHeight: entry.kind == .text || entry.kind == .link ? AOMSize.textPreviewMinHeight : AOMSize.tileMin,
                           alignment: .topLeading)
                    .padding(entry.kind == .image || entry.kind == .color ? 0 : AOMSpace.x4)
                    .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
                    .onDrag { liveEntry(expecting: entry.id).map(ClipboardStudioDrag.provider(for:)) ?? NSItemProvider() }
                // In the inspector when it is beside the preview (D15).
                if !(showsInspector && inspectorBeside) {
                    AOMSection("Details") {
                        ForEach(details(entry)) { row in detailRow(row.label, row.value) }
                    }
                }
            }
            .padding(AOMSpace.pageMargin)
            .frame(maxWidth: AOMSize.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AOMPageTint())
        .id(entry.id)
        .task(id: entry.contentVersion) {
            let content = await ClipboardPreviewCache.shared.content(for: entry)
            guard !Task.isCancelled else { return }
            detailSummary[entry.id] = content.summary
        }
    }

    /// The fixed metadata of an item, in one order for the detail and the
    /// inspector: what it is, where and when it came from, how big, where pinned.
    private struct DetailRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private func details(_ entry: ClipboardEntry) -> [DetailRow] {
        [DetailRow(label: "Kind", value: entry.kind.displayName),
         DetailRow(label: "From", value: entry.sourceName ?? "Unknown app"),
         DetailRow(label: "Copied", value: entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)),
         DetailRow(label: "Contents", value: detailSummary[entry.id] ?? "…"),
         DetailRow(label: "Pinboards", value: pinboardNames(entry) ?? "None")]
    }

    /// The trailing inspector: the selected item's details as aligned
    /// label/value rows (AOMInspectorRow), nothing when no item is selected.
    @ViewBuilder private func inspector(_ entry: ClipboardEntry?) -> some View {
        AOMInspector {
            if let entry {
                AOMInspectorSection("Details", showsDivider: false) {
                    ForEach(details(entry)) { row in
                        AOMInspectorRow(row.label) {
                            Text(row.value).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                AOMInspectorSection("Source") {
                    AOMInspectorRow("App", text: entry.sourceName ?? "Unknown app")
                    if let bundle = entry.sourceBundleID, !bundle.isEmpty {
                        AOMInspectorRow("Bundle ID") { Text(bundle).textSelection(.enabled) }
                    }
                }
            } else {
                AOMInspectorSection("Details", showsDivider: false) {
                    Text("Select an item to see where it came from and what it holds.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        AOMSettingRow(title) {
            Text(value)
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func pinboardNames(_ entry: ClipboardEntry) -> String? {
        let names = store.boards.filter { entry.pinboardIDs.contains($0.id) }.map(\.name)
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }

    private func detailHeader(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            Group {
                if let icon = AppMetadataCache.shared.icon(for: entry.sourceBundleID) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    AOMModuleBadge(symbol: entry.kind.symbol, size: AOMIcon.tileBadge)
                }
            }
            .frame(width: AOMIcon.tileBadge, height: AOMIcon.tileBadge)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                if renamingID == entry.id {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(AOMFont.title)
                        .focused($renameFocused)
                        .task(id: renameGeneration.token) { [token = renameGeneration.token] in
                            await Task.yield()
                            guard !Task.isCancelled, renameGeneration.matches(token), renamingID == entry.id,
                                  liveEntry(expecting: entry.id) != nil else { return }
                            renameFocused = true
                        }
                        .onSubmit { commitRename(entry.id) }
                        .onExitCommand { cancelRename() }
                        .onChange(of: renameFocused) { _, focused in if !focused { commitRename(entry.id) } }
                        .accessibilityLabel("Title")
                } else {
                    Text(entry.title)
                        .font(AOMFont.title)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(2)
                        .contentShape(Rectangle())
                        .onTapGesture { beginRename(entry) }
                        .help("Click to rename")
                        .accessibilityLabel("Title, \(entry.title)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { beginRename(entry) }
                }
                Text([entry.kind.displayName, entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            // The section's one prominent action (design-336 b.6).
            // 7.19: pressing Copy on the item you are looking at is an explicit
            // choice of that item, so it works on an auto-highlighted preview too
            // (it still resolves the live, visible row by id).
            Button { copy(addressedTo: entry.id) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(AOMPrimaryButtonStyle())
                .disabled(liveEntry(addressedTo: entry.id) == nil)
                .aomShortcut("c", modifiers: [.command, .shift])
                .help("Copy this item (⇧⌘C, or press Return in the list)")
            Menu {
                entryMenu(entry, fromRow: true)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(AOMColor.textSecondary)
            .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
            .disabled(liveEntry(addressedTo: entry.id) == nil)
            .help("More actions for this item")
            .accessibilityLabel("More actions")
        }
    }

    private func beginRename(_ entry: ClipboardEntry) {
        guard !gridLayout else { return }
        target.selected = entry.id
        renameText = entry.title
        renamingID = entry.id
        renameGeneration.invalidate()
    }

    private func cancelRename() {
        guard renamingID != nil else { return }
        renamingID = nil
        renameGeneration.invalidate()
        renameFocused = false
    }

    private func commitRename(_ id: UUID) {
        guard renamingID == id else { return }
        let entry = liveEntry(expecting: id)
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRename()
        guard let entry, !trimmed.isEmpty, trimmed != entry.title else { return }
        store.rename(entryID: id, title: trimmed)
        toast.show("Renamed to “\(trimmed.prefix(40))”")
    }

    /// The toast and Edit › Undo each address this command's deletion receipt.
    private func delete(_ entry: ClipboardEntry) {
        let id = entry.id
        if target.selected == id { target.selected = nil }
        if renamingID == id { cancelRename() }
        let store = store
        var receipt: ClipboardStore.DeletionReceipt?
        let revert: @MainActor () -> Void = {
            guard let current = receipt else { return }
            receipt = nil
            _ = store.undoDeletion(current)
        }
        AOMUndo.perform("Delete Item", undoManager: undoManager, perform: {
            receipt = store.deleteRecordingReceipt(entryIDs: [id])
        }, revert: revert)
        toast.show("Deleted “\(entry.title.prefix(40))”", action: revert)
    }

    private func libraryCard(_ entry: ClipboardEntry) -> some View {
        ClipboardStudioCard(entry: entry, isHovered: hoveredCardID == entry.id, boards: store.boards,
            onCopy: { copy(addressedTo: entry.id) }, onTogglePin: { board in
                if let now = liveEntry(addressedTo: entry.id) { togglePin(now, boardID: board.id) }
            }, onDelete: { if let now = liveEntry(addressedTo: entry.id) { delete(now) } })
            .overlay {
                if target.selected == entry.id {
                    RoundedRectangle(cornerRadius: AOMRadius.card).strokeBorder(AOMColor.accent, lineWidth: 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onTapGesture {
                if liveEntry(addressedTo: entry.id) != nil { target.selected = entry.id; galleryFocused = true }
            }
            .accessibilityAddTraits(target.selected == entry.id ? .isSelected : [])
            .accessibilityAction(named: Text("Select Item")) {
                if liveEntry(addressedTo: entry.id) != nil { target.selected = entry.id; galleryFocused = true }
            }
            .onHover { hovering in
                if hovering { hoveredCardID = entry.id } else if hoveredCardID == entry.id { hoveredCardID = nil }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Layout", selection: $gridLayout) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Gallery", systemImage: "square.grid.2x2").tag(true)
                }
                if !gridLayout {
                    Button(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                        withAnimation(AOMMotion.panel) { showsInspector.toggle() }
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
                Divider()
                Button("Open Shelf", systemImage: "rectangle.bottomthird.inset.filled") { ClipboardPanelController.shared.show() }
                // "History", the page's own word for it; "Recording" is the
                // screen recorder's (Capture, the status menu).
                if store.paused {
                    Button("Resume History") {
                        store.resume()
                        showToast("Clipboard history resumed")
                    }
                } else {
                    Menu("Pause History") {
                        Button("For 5 Minutes") { store.pause(for: 300) }
                        Button("For 15 Minutes") { store.pause(for: 900) }
                        Button("For 1 Hour") { store.pause(for: 3600) }
                        Divider()
                        Button("Until Resumed") { store.pause() }
                    }
                }
                Divider()
                // Erase never touches pinned items (the old "Clear All History"
                // deleted pinboard items too, without asking).
                Button("Erase History…", role: .destructive) { showingEraseConfirmation = true }
                    .disabled(!store.entries.contains { $0.pinboardIDs.isEmpty })
                Divider()
                Button("Clipboard Settings…") { showingSettings = true }
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
            .help("Clipboard layout, inspector and history options")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Text Item…") { newText = ""; showingNewTextSheet = true }
                Button("New Pinboard…") { presentNewBoard() }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                newText = ""
                showingNewTextSheet = true
            }
            .help("Create a text item or pinboard")
        }
    }

    // MARK: - Filter bar (pinboards and kinds — this page's own navigation)

    private var filterBar: some View {
        HStack(spacing: AOMSpace.x3) {
            pinboardsBar
            if store.paused {
                // Paused is a state (e.6), one click from Resume.
                Button { store.resume() } label: {
                    AOMStatusPill("Paused", tone: .neutral, symbol: "pause.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Clipboard history is paused — click to resume")
                .accessibilityLabel("Clipboard history is paused. Resume")
            }
            HStack(spacing: AOMSpace.x0_5) {
                filterChip("All Types", symbol: "line.3.horizontal.decrease", selected: search.kind == nil, iconOnly: true) {
                    search.kind = nil
                }
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    filterChip(kind.displayName, symbol: kind.symbol, selected: search.kind == kind, iconOnly: true) {
                        search.kind = kind
                    }
                }
            }
            .padding(AOMSpace.x0_5)
            .background(AOMColor.track, in: RoundedRectangle(cornerRadius: AOMRadius.control))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Clipboard type filter")
        }
        .padding(.horizontal, AOMSpace.pageMargin - AOMSpace.x1)
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMFeatureSize.chip + AOMSpace.x4)
    }

    private var pinboardsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AOMSpace.x2) {
                filterChip("All Items · \(store.entries.count)", symbol: "tray.full", selected: search.board == nil) {
                    search.board = nil
                }
                ForEach(store.boards) { board in
                    let count = boardCounts[board.id] ?? 0
                    filterChip("\(board.name) · \(count)", symbol: "pin", selected: search.board == board.id) {
                        search.board = search.board == board.id ? nil : board.id
                    }
                    .contextMenu {
                        Button("Delete Pinboard…", role: .destructive) { boardPendingDeletion = board }
                    }
                }
                Button {
                    presentNewBoard()
                } label: {
                    Label("New Pinboard", systemImage: "plus")
                        .font(AOMFont.callout.weight(.medium))
                        .padding(.horizontal, AOMSpace.x2).frame(height: AOMFeatureSize.chip)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AOMColor.textSecondary)
                .help("Create a pinboard")
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterChip(_ title: String, symbol: String, selected: Bool, iconOnly: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(ClipboardChipLabelStyle(iconOnly: iconOnly))
                .font(AOMFont.callout.weight(.medium))
                .foregroundStyle(selected ? AOMColor.accent : AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2)
                .frame(height: AOMFeatureSize.chip)
                .background(selected ? AOMColor.surface : (iconOnly ? Color.clear : AOMColor.track),
                            in: RoundedRectangle(cornerRadius: AOMRadius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    // MARK: - New Board and New Text sheets

    private func presentNewBoard() {
        newBoardName = ""
        newBoardColor = "blue"
        showingNewBoardSheet = true
    }

    /// A text item typed by hand (the shelf's New Text Item).
    private var newTextSheet: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text("New Text Item").font(AOMFont.title).foregroundStyle(AOMColor.text)
            TextEditor(text: $newText)
                .font(AOMFont.body)
                .frame(minHeight: AOMSize.tileMin * 0.75)
                .scrollContentBackground(.hidden)
                .padding(AOMSpace.x1)
                .background(AOMColor.field, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                .accessibilityLabel("Text")
            HStack {
                Text("Saved in clipboard history, encrypted on this Mac.")
                    .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                Spacer()
                Button("Cancel") { showingNewTextSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let text = newText
                    showingNewTextSheet = false
                    if let entry = store.createTextItem(text) {
                        target.selected = entry.id
                        showToast("Added “\(entry.title.prefix(40))”")
                    } else {
                        toast.show("Couldn't add the text because history can't be saved right now", tone: .danger)
                    }
                }
                .buttonStyle(AOMPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: AOMSize.readableWidth * 0.7)
    }

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            Text("New Pinboard").font(AOMFont.pageStatus).foregroundStyle(AOMColor.text)
            TextField("Name (e.g. Snippets, Colors, Work)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                Text("Color").font(AOMFont.caption.weight(.medium)).foregroundStyle(AOMColor.textSecondary)
                HStack(spacing: AOMSpace.x3) {
                    ForEach(boardColors, id: \.self) { colorName in
                        Button { newBoardColor = colorName } label: {
                            Circle()
                                .fill(colorForBoard(colorName))
                                .frame(width: AOMFeatureSize.swatch, height: AOMFeatureSize.swatch)
                                .overlay(Circle().strokeBorder(AOMColor.text,
                                                               lineWidth: newBoardColor == colorName ? AOMFeatureSize.swatchRing : 0)
                                    .padding(-AOMFeatureSize.swatchRing - 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName.capitalized)
                        .accessibilityAddTraits(newBoardColor == colorName ? .isSelected : [])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingNewBoardSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = store.createBoard(name: trimmed, color: newBoardColor)
                    showingNewBoardSheet = false
                    showToast("Created pinboard “\(trimmed)”")
                }
                .buttonStyle(AOMPrimaryButtonStyle())
                .disabled(newBoardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: AOMFeatureSize.sheetCompact)
    }

    // MARK: - Helpers

    private func copy(expecting id: UUID? = nil, addressedTo row: UUID? = nil, plainText: Bool = false) {
        Task {
            guard let entry = liveEntry(expecting: id, addressedTo: row) else { return }
            do {
                _ = try await store.writeAsync(entryIDs: [entry.id], plainText: plainText, playSound: true)
                showToast("Copied “\(entry.title.prefix(40))”")
            } catch { toast.show("Couldn't copy because \(error.localizedDescription)", tone: .danger) }
        }
    }

    private func togglePin(_ entry: ClipboardEntry, boardID: UUID) {
        guard let board = store.boards.first(where: { $0.id == boardID }) else { return }
        if entry.pinboardIDs.contains(board.id) {
            if store.unpin(entryID: entry.id, boardID: board.id) {
                showToast("Unpinned from \(board.name). It was older than the history limit, so it was deleted; Undo Delete restores it")
            } else {
                showToast("Unpinned from \(board.name)")
            }
        } else {
            let moves = store.settings.onePinboardPerItem && !entry.pinboardIDs.isEmpty
            store.pin(entryID: entry.id, boardID: board.id)
            showToast(moves ? "Moved to \(board.name)" : "Pinned to \(board.name)")
        }
    }

    private func showToast(_ message: String) { toast.show(message) }

    private func deletePendingBoard(deletingItems: Bool) {
        guard let board = boardPendingDeletion else { return }
        if search.board == board.id { search.board = nil }
        let deleted = store.deleteBoard(id: board.id, deletingItems: deletingItems)
        boardPendingDeletion = nil
        toast.show(deleted > 0 ? "Deleted \(board.name) and \(deleted) item\(deleted == 1 ? "" : "s")" : "Deleted \(board.name)",
                   action: { _ = store.undoDeletion() })
    }

    private func colorForBoard(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        default: return .gray
        }
    }
}

private struct ClipboardChipLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AOMSpace.x1) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

// MARK: - Clipboard Studio Card

private struct ClipboardStudioCard: View {
    let entry: ClipboardEntry
    let isHovered: Bool
    let boards: [ClipboardPinboard]
    let onCopy: () -> Void
    let onTogglePin: (ClipboardPinboard) -> Void
    let onDelete: () -> Void
    private var appIcon: NSImage? { AppMetadataCache.shared.icon(for: entry.sourceBundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: AOMFeatureSize.appIcon, height: AOMFeatureSize.appIcon)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: entry.kind.symbol).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Text(entry.sourceName ?? entry.kind.displayName)
                    .font(AOMFont.caption.weight(.medium))
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                if !entry.pinboardIDs.isEmpty {
                    Image(systemName: "pin.fill").font(AOMFont.badge).foregroundStyle(AOMColor.textSecondary)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: AOMSpace.x1)
                Text(AOMRelativeTime.string(entry.lastCopiedAt))
                    .font(AOMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: AOMSize.rowSingle + AOMSpace.x1)

            Preview(entry: entry)
                .frame(height: AOMFeatureSize.galleryPreview)
                .frame(maxWidth: .infinity)
                .background(AOMColor.sunken)

            HStack(spacing: AOMSpace.x2) {
                Label(entry.kind.displayName, systemImage: entry.kind.symbol)
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                Spacer(minLength: AOMSpace.x1)
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AOMColor.textSecondary)
                    .help("Copy").accessibilityLabel("Copy item")
                Menu {
                    Button("Copy", action: onCopy)
                    if !boards.isEmpty {
                        Menu("Pinboards") {
                            ForEach(boards) { board in
                                Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                                    onTogglePin(board)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(AOMColor.textSecondary)
                .help("Item actions").accessibilityLabel("Item actions")
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: AOMSize.rowSingle + AOMSpace.x1)
        }
        // Hover shifts the fill only; cards never lift or outline (c.6).
        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, hovering: isHovered)
        .clipShape(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .onTapGesture(count: 2, perform: onCopy)
        .contextMenu {
            Button("Copy", action: onCopy)
            if !boards.isEmpty {
                Menu("Pinboards") {
                    ForEach(boards) { board in
                        Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                            onTogglePin(board)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .aomAnimation(.quick, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.kind.displayName): \(entry.title)")
    }

    fileprivate static func isLikelyCode(_ text: String) -> Bool {
        ["func ", "struct ", "class ", "import ", "const ", "var ", "let ", "def ", "return ", "{", "}"].contains { text.contains($0) }
    }
}


extension ClipboardStudioCard {
    /// The content of one item, made for its kind. `large` is the library's
    /// preview pane: full text, a bigger image and the whole link.
    struct Preview: View {
        let entry: ClipboardEntry
        var large = false
        var onOpenLink: (() -> Void)? = nil
        @Environment(\.aomPageActivity) private var pageActivity
        @State private var decoded: (revision: UUID, thumbnail: ClipboardThumbnailCache.Preview)?
        private var thumbnail: ClipboardThumbnailCache.Preview? {
            decoded?.revision == entry.contentVersion ? decoded?.thumbnail : nil
        }

        var body: some View {
            content
                .aomVisibleTask(id: entry.contentVersion) {
                    guard entry.kind == .image, let data = entry.imageData, thumbnail == nil,
                          let result = await ClipboardThumbnailCache.shared.cancellablePreview(
                              id: entry.id, revision: entry.contentVersion, data: data),
                          !Task.isCancelled, pageActivity.isActive else { return }
                    decoded = (entry.contentVersion, result)
                }
        }

        @ViewBuilder private var content: some View {
            switch entry.kind {
            case .color:
                let hex = entry.text ?? "#000000"
                Rectangle().fill(Color(hex: hex))
                    .frame(minHeight: large ? AOMSize.tileMin : nil)
                    .overlay {
                        Text(hex.uppercased())
                            .font(AOMFont.mono.weight(.semibold))
                            .padding(.horizontal, AOMSpace.x2).padding(.vertical, AOMSpace.x0_5)
                            .aomMediaBadge(radius: AOMRadius.panel)
                    }
            case .image:
                if let image = thumbnail?.image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(AOMSpace.x2)
                        .overlay(alignment: .bottomTrailing) {
                            if let size = thumbnail?.dimensions {
                                Text(size).font(AOMFont.badge).monospacedDigit()
                                    .padding(.horizontal, AOMSpace.x1).padding(.vertical, AOMSpace.x0_5)
                                    .aomMediaBadge()
                                    .padding(AOMSpace.x2)
                            }
                        }
                } else {
                    Image(systemName: "photo").font(AOMFont.title.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
                }
            case .link:
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    Label(URL(string: entry.text ?? "")?.host ?? "Link", systemImage: "safari")
                        .font(AOMFont.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    Text(entry.text ?? "")
                        .font(large ? AOMFont.body : AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(large ? nil : 4)
                        .textSelection(.enabled)
                    if large, let onOpenLink {
                        Button("Open in Browser", action: onOpenLink).buttonStyle(AOMSoftButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
                .padding(large ? 0 : AOMSpace.x3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .file:
                VStack(spacing: AOMSpace.x2) {
                    if let url = entry.fileURLs.first {
                        let side = large ? AOMFeatureSize.fileIconLarge : AOMFeatureSize.fileIcon
                        Image(nsImage: AppMetadataCache.shared.fileIcon(for: url)).resizable().scaledToFit()
                            .frame(width: side, height: side)
                    } else {
                        Image(systemName: "doc.fill").font(AOMFont.hero.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
                    }
                    Text(entry.fileURLs.count > 1 ? "\(entry.fileURLs.first?.lastPathComponent ?? "") +\(entry.fileURLs.count - 1)"
                         : entry.fileURLs.first?.lastPathComponent ?? "File")
                        .font(AOMFont.caption.weight(.medium))
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .padding(AOMSpace.x2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                let full = large ? (entry.text ?? entry.previewText) : entry.previewText
                let text = String(full.prefix(large ? 16000 : 600))
                let code = ClipboardStudioCard.isLikelyCode(text)
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    Text(text)
                        .font(code ? (large ? AOMFont.body : AOMFont.callout).monospaced() : (large ? AOMFont.body : AOMFont.callout))
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(large ? nil : 5)
                        .textSelection(.enabled)
                    if large, full.count > 16000 {
                        Text("Preview shortened. Copy includes the full text.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    }
                }
                .padding(large ? 0 : AOMSpace.x3)
                .frame(maxWidth: .infinity, maxHeight: large ? nil : .infinity, alignment: .topLeading)
            }
        }

    }
}

/// Dragging an item out of the library: its files, its link or its text,
/// the way the shelf hands them to other apps (#100).
enum ClipboardStudioDrag {
    static func provider(for entry: ClipboardEntry) -> NSItemProvider {
        if let url = entry.fileURLs.first {
            return NSItemProvider(object: url as NSURL)
        }
        if entry.kind == .image, let data = entry.imageData, let image = NSImage(data: data) {
            return NSItemProvider(object: image)
        }
        if entry.kind == .link, let url = URL(string: (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: (entry.text ?? entry.title) as NSString)
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// D16: which saved pinboard and type filter to restore. A pinboard that was
/// deleted meanwhile, or a value an older build wrote, restores nothing.
enum ClipboardLibraryFilterMemory {
    static func restore(board: String, kind: String, boards: [UUID]) -> (board: UUID?, kind: ClipboardEntry.Kind?) {
        let id = UUID(uuidString: board).flatMap { boards.contains($0) ? $0 : nil }
        return (id, ClipboardEntry.Kind(rawValue: kind))
    }
}
