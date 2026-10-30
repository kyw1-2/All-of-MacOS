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
    @State private var selectedEntryID: UUID?
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
                      module: .clipboard, subtitle: subtitle,
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
        let state = ClipboardEmptyContent.resolve(isLoading: store.isLoading, storage: store.storageStatus, paused: store.paused)
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.x4)
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
                if search.isSearchPending {
                    ProgressView("Searching clipboard…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    if store.entries.isEmpty && (state.isStorageProblem || state == .loading) {
                        AOMEmptyState(state.title, systemImage: state.systemImage, message: state.message) { storageActions(state) }
                    } else if store.entries.isEmpty {
                        AOMEmptyState(state.title, systemImage: state.systemImage, message: state.message) {
                            if store.paused { Button("Resume History") { store.resume() }.buttonStyle(.borderedProminent) }
                        }
                    } else if !search.query.isEmpty {
                        ContentUnavailableView.search(text: search.query)
                    } else {
                        AOMEmptyState(search.board == nil ? "No Matching Items" : "Pinboard Is Empty",
                                      systemImage: search.board == nil ? "line.3.horizontal.decrease.circle" : "pin",
                                      message: search.board == nil ? "No items of this type yet." : "Pin items from their menu to keep them here.") {
                            Button("Show All Items") { search.kind = nil; search.board = nil }
                        }
                    }
                } else {
                    library(entries)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aomPane()
        .navigationTitle("Clipboard")
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search text, links and files")
        .toolbar { toolbarContent }
        .task(id: store.revision) {
            let entries = store.entries
            let counts = await Task.detached(priority: .userInitiated) {
                var counts: [UUID: Int] = [:]
                for entry in entries { for id in entry.pinboardIDs { counts[id, default: 0] += 1 } }
                return counts
            }.value
            guard !Task.isCancelled else { return }
            boardCounts = counts
        }
        .sheet(isPresented: $showingSettings) {
            ModuleSettingsSheet("Clipboard Settings", done: { showingSettings = false }) {
                ClipboardSettingsView()
            }
        }
        .sheet(isPresented: $showingNewBoardSheet) { newBoardSheet }
        .onAppear {
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
        .aomToast(toast.message)
    }

    /// The retry or recovery for a storage problem, on the same screen that
    /// reports it (until 3.3.1 they lived only in Clipboard Settings).
    @ViewBuilder
    private func storageActions(_ state: ClipboardEmptyContent) -> some View {
        switch state {
        case .keychainUnavailable:
            Button("Try Again") { Task { await store.recoverStorage() } }
                .buttonStyle(.borderedProminent)
        case .unreadableArchive:
            HStack(spacing: AOMSpace.x2) {
                Button("Recover Storage…") { showingRecoverConfirmation = true }
                    .buttonStyle(.borderedProminent)
                Button("Clipboard Settings…") { showingSettings = true }
            }
        case .loading, .empty:
            EmptyView()
        }
    }

    // MARK: - Library (Bear's list + preview; Paste's cards for the gallery)

    private func library(_ entries: [ClipboardEntry]) -> some View {
        GeometryReader { geometry in
            if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMSize.tileMin, maximum: AOMSize.tileMax), spacing: AOMSpace.tileGap)],
                              spacing: AOMSpace.tileGap) {
                        ForEach(entries) { entry in libraryCard(entry) }
                    }
                    .padding(.horizontal, AOMSpace.pageMargin)
                    .padding(.vertical, AOMSpace.x4)
                }
                .background(AOMColor.canvas)
            } else {
                let showsPreview = geometry.size.width >= AOMFeatureSize.previewPaneMinimumWidth
                HStack(spacing: 0) {
                    List(selection: $selectedEntryID) {
                        ForEach(entries) { entry in libraryRow(entry) }
                    }
                    // Plain rows with hairlines: alternating fills also striped
                    // the empty space under a short history.
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    // Rows are one line. A floor keeps rows inserted at the
                    // top (new copies) from being measured short.
                    .environment(\.defaultMinListRowHeight, AOMSize.rowSingle + AOMSpace.x1)
                    .frame(maxWidth: .infinity)
                    .onKeyPress(.return) {
                        guard let entry = entries.first(where: { $0.id == selectedEntryID }) else { return .ignored }
                        copy(entry)
                        return .handled
                    }
                    if showsPreview, let entry = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first {
                        AOMDivider(axis: .vertical)
                        previewPane(entry)
                            .frame(width: min(AOMFeatureSize.previewPane.upperBound,
                                              max(AOMFeatureSize.previewPane.lowerBound,
                                                  geometry.size.width * AOMFeatureSize.previewPaneShare)))
                    }
                }
            }
        }
    }

    /// One line per item, like a Finder list row: the kind glyph, the title
    /// in Body, then the source and time at the trailing edge in Callout.
    /// Hierarchical styles turn white on selection.
    private func libraryRow(_ entry: ClipboardEntry) -> some View {
        let detail = [Self.listSource(entry), AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: AOMSpace.x2) {
            Image(systemName: entry.kind.symbol)
                .font(AOMFont.body)
                .foregroundStyle(.secondary)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            Text(entry.title)
                .font(AOMFont.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            Text(detail)
                .font(AOMFont.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // Every row keeps the pin's column, so the times line up.
            Image(systemName: "pin.fill").font(AOMFont.caption).foregroundStyle(.secondary)
                .opacity(entry.pinboardIDs.isEmpty ? 0 : 1)
                .accessibilityLabel("Pinned")
                .accessibilityHidden(entry.pinboardIDs.isEmpty)
        }
        .frame(minHeight: AOMSize.rowSingle)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .help(entry.title)
        .tag(entry.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { copy(entry) })
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

    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry) -> some View {
        Button("Copy") { copy(entry) }
        if entry.kind == .text || entry.kind == .link {
            Button("Copy as Plain Text") { copy(entry, plainText: true) }
        }
        if !store.boards.isEmpty {
            Menu("Pinboards") {
                ForEach(store.boards) { board in
                    Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") { togglePin(entry, board) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(entryID: entry.id); showToast("Deleted item") }
    }

    /// The selected item, readable: a preview made for its kind, the source
    /// and time beneath, and the actions next to it.
    private func previewPane(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                if let icon = AppMetadataCache.shared.icon(for: entry.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: AOMFeatureSize.appIcon, height: AOMFeatureSize.appIcon)
                        .accessibilityHidden(true)
                }
                Text([entry.sourceName ?? entry.kind.displayName, AOMRelativeTime.string(entry.lastCopiedAt)].joined(separator: " · "))
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: AOMSpace.x1)
                if !entry.pinboardIDs.isEmpty {
                    AOMStatusPill("Pinned", tone: .neutral, symbol: "pin.fill")
                }
            }
            .padding(.horizontal, AOMSpace.x4)
            .frame(height: AOMSize.rowStandard + AOMSpace.x1)
            AOMDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.x3) {
                    ClipboardStudioCard.Preview(entry: entry, large: true)
                        .frame(maxWidth: .infinity, minHeight: entry.kind == .text ? nil : AOMSize.tileMin, alignment: .topLeading)
                }
                .padding(AOMSpace.x4)
            }
            AOMDivider()
            // The one primary action, and the rest behind a quiet icon menu
            // (the gallery cards' ⋯), not a second labelled button.
            HStack(spacing: AOMSpace.x2) {
                // The section's one prominent action at the regular size
                // (design-336 b.6).
                Button { copy(entry) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy (⇧⌘C, or press Return in the list)")
                Spacer(minLength: AOMSpace.x2)
                Menu {
                    entryMenu(entry)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(AOMColor.textSecondary)
                .help("More actions for this item")
                .accessibilityLabel("More actions")
            }
            .padding(.horizontal, AOMSpace.x4)
            .frame(height: AOMSize.rowDetail + AOMSpace.x1)
        }
        .background(AOMColor.canvas)
        .id(entry.id)
    }

    private func libraryCard(_ entry: ClipboardEntry) -> some View {
        ClipboardStudioCard(entry: entry, isHovered: hoveredCardID == entry.id, boards: store.boards,
            onCopy: { copy(entry) }, onTogglePin: { board in togglePin(entry, board) },
            onDelete: { store.delete(entryID: entry.id); showToast("Deleted item") })
            .onHover { hovering in
                if hovering { hoveredCardID = entry.id } else if hoveredCardID == entry.id { hoveredCardID = nil }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Picker("Layout", selection: $gridLayout) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Gallery", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .help("List with preview, or a gallery of cards")
            // Pause lives with the other history commands; while paused the
            // filter bar and the sidebar say so, with Resume one click away.
            Menu {
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
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Pause or erase history, and clipboard settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                ClipboardPanelController.shared.show()
            } label: {
                Label("Open Shelf", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Open the quick-paste shelf\(ClipboardShortcuts.shared.shortcut(for: .history).map { " (\($0.displayString))" } ?? "")")
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
            Picker("Type", selection: $search.kind) {
                Text("All").tag(ClipboardEntry.Kind?.none)
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    Image(systemName: kind.symbol)
                        .help(kind.displayName)
                        .accessibilityLabel(kind.displayName)
                        .tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, AOMSpace.pageMargin - AOMSpace.x1)
        .padding(.vertical, AOMSpace.x2)
        .frame(minHeight: AOMFeatureSize.chip + AOMSpace.x4)
    }

    private var pinboardsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AOMSpace.x2) {
                AOMFilterChip("All Items", symbol: "tray.full", count: store.entries.count, selected: search.board == nil) {
                    withAnimation(AOMMotion.quick) { search.board = nil }
                }
                ForEach(store.boards) { board in
                    let count = boardCounts[board.id] ?? 0
                    AOMFilterChip(board.name, dot: colorForBoard(board.color), count: count,
                                  selected: search.board == board.id) {
                        withAnimation(AOMMotion.quick) { search.board = search.board == board.id ? nil : board.id }
                    }
                    .contextMenu {
                        Button("Delete Pinboard…", role: .destructive) { boardPendingDeletion = board }
                    }
                }
                Button {
                    newBoardName = ""
                    newBoardColor = "blue"
                    showingNewBoardSheet = true
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

    // MARK: - New Board Sheet

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
                .buttonStyle(.borderedProminent)
                .disabled(newBoardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AOMSpace.x5)
        .frame(width: AOMFeatureSize.sheetCompact)
    }

    // MARK: - Helpers

    private func copy(_ entry: ClipboardEntry, plainText: Bool = false) {
        Task {
            do {
                _ = try await store.writeAsync(entryIDs: [entry.id], plainText: plainText, playSound: true)
                showToast("Copied “\(entry.title.prefix(40))”")
            } catch { showToast("Could not copy: \(error.localizedDescription)") }
        }
    }

    private func togglePin(_ entry: ClipboardEntry, _ board: ClipboardPinboard) {
        if entry.pinboardIDs.contains(board.id) {
            if store.unpin(entryID: entry.id, boardID: board.id) {
                showToast("Unpinned from \(board.name) · It was older than your history limit, so it was deleted; Undo Delete restores it")
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
        showToast(deleted > 0 ? "Deleted \(board.name) and \(deleted) item\(deleted == 1 ? "" : "s") · Undo Delete restores them"
                              : "Deleted \(board.name) · Undo Delete restores it")
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
        @State private var thumbnail: ClipboardThumbnailCache.Preview?

        var body: some View {
            content
                .task(id: entry.id) {
                    guard entry.kind == .image, let data = entry.imageData else { return }
                    thumbnail = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
                }
        }

        @ViewBuilder private var content: some View {
            switch entry.kind {
            case .color:
                let hex = entry.text ?? "#000000"
                Rectangle().fill(Color(hex: hex))
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
                    if large, let url = URL(string: entry.text ?? ""), url.scheme?.hasPrefix("http") == true {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
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
