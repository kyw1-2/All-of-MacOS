import AppKit
import SwiftUI

@MainActor
final class ClipboardPanelState: ObservableObject {
    /// ⌘C in the shelf copies and keeps the shelf open on purpose (Paste
    /// does the same) so several items can be copied in a row; the status
    /// says so, because every other capture surface closes after Copy.
    nonisolated static func multiCopyStatus(count: Int) -> String {
        "\(count == 1 ? "Copied" : "Copied \(count) items") — the shelf stays open for more. Return pastes, Esc closes."
    }
    @Published var query = ""
    @Published var recentSearches: [String] = []
    func rememberSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        recentSearches.removeAll { $0 == value }
        recentSearches.insert(value, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
    }
    @Published var kind: ClipboardEntry.Kind?
    @Published var source: String?
    @Published var board: UUID?
    @Published var recentDays = 0
    @Published var selected = Set<UUID>()
    @Published var focusedID: UUID?
    @Published var keyboardScrollTarget: UUID?
    private var selectionAnchor: UUID?
    @Published var searchFieldActive = false
    @Published var filtersExpanded = false
    @Published var commandHeld = false
    /// Cards currently on screen, for ⌘1–9. Scrolling changes this constantly;
    /// it only needs to re-render the panel while ⌘ badges are showing, so
    /// changes are published only then (the next ⌘ press reads the latest).
    var visibleCardIDs: [UUID] = [] {
        didSet { if commandHeld, visibleCardIDs != oldValue { objectWillChange.send() } }
    }
    func setCommandHeld(_ held: Bool) { if commandHeld != held { commandHeld = held } }
    @Published var stack: [UUID] = []
    @Published var stackMode = false
    /// Paste Stack direction toggle: newest copy first when true.
    @Published var stackReversed = UserDefaults.standard.bool(forKey: "AOMPasteStackReversed") {
        didSet { UserDefaults.standard.set(stackReversed, forKey: "AOMPasteStackReversed") }
    }
    /// The item that ⌘V / Paste Next will deliver, honoring the direction.
    var nextStackID: UUID? { stackReversed ? stack.last : stack.first }
    func removeStackItem(_ id: UUID) {
        if stackReversed, let index = stack.lastIndex(of: id) { stack.remove(at: index) }
        else if let index = stack.firstIndex(of: id) { stack.remove(at: index) }
    }
    /// Reject a drop if collection/pasting changed the queue during the drag.
    func reorderStack(from source: Int, before target: Int, expected: [UUID]) {
        guard stack == expected, stack.indices.contains(source), stack.indices.contains(target), source != target else { return }
        let moved = stack.remove(at: source)
        let destination = target - (source < target ? 1 : 0) + (stackReversed ? 1 : 0)
        stack.insert(moved, at: min(max(0, destination), stack.count))
    }
    /// Multi-item deletes ask first, like Paste's "Delete selected items?".
    @Published var pendingDeletion: [UUID] = []
    @Published var status = ""
    @Published var searchFocusToken = UUID()
    @Published var searchExpanded = false
    @Published var editor: ClipboardEditorRequest?
    @Published var preview: ClipboardEntry?
    @Published var editingTitleID: UUID?
    /// A card asked to rename its title in place (Rename in the card menu,
    /// ⌘R on the selection), Paste-style; the card clears it when it starts.
    @Published var renameRequestID: UUID?
    /// Intelligent Clipboard picks for the current destination, best first.
    /// Shown at the front of Clipboard History when no search or filter is on.
    @Published var suggestedIDs: [UUID] = []

    /// Date filter codes: 0 any, 1 today, -1 yesterday, -7 this week,
    /// -14 last week, N > 1 the last N days (Paste's Date filter section).
    static let dateFilters: [(code: Int, title: String)] = [
        (1, "Today"), (-1, "Yesterday"), (-7, "This Week"), (-14, "Last Week"), (30, "Last 30 Days"),
    ]
    static func dateFilterTitle(_ code: Int) -> String {
        dateFilters.first { $0.code == code }?.title ?? (code > 1 ? "Last \(code) Days" : "Any Time")
    }

    static func dateRange(for code: Int, now: Date = Date(),
                          calendar: Calendar = .current) -> (since: Date?, before: Date?) {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        switch code {
        case 0: return (nil, nil)
        case 1: return (today, nil)
        case -1: return (calendar.date(byAdding: .day, value: -1, to: today), today)
        case -7: return (weekStart, nil)
        case -14: return (calendar.date(byAdding: .day, value: -7, to: weekStart), weekStart)
        default: return (calendar.date(byAdding: .day, value: -(max(code, 1) - 1), to: today), nil)
        }
    }

    private struct ResultsKey: Equatable {
        let store: ObjectIdentifier, revision: Int, query: String, kind: ClipboardEntry.Kind?
        let source: String?, board: UUID?, recentDays: Int, day: Date, suggested: [UUID]
    }
    private var resultsCache: (key: ResultsKey, value: [ClipboardEntry])?

    /// A query, or a filter chosen while the search is open.
    var isSearching: Bool {
        !query.isEmpty || (searchExpanded && (kind != nil || source != nil || recentDays != 0))
    }

    /// The pinboard results are limited to. Paste searches every list from
    /// any pinboard ("search looks across all of your lists rather than
    /// filtering the one you're in"); AOM does too unless the user turned
    /// that off. A typed `board:` filter still narrows the results.
    func scopeBoard(in store: ClipboardStore) -> UUID? {
        isSearching && store.settings.searchesAllLists ? nil : board
    }

    /// True while results come from every list although a pinboard is open.
    func searchesAllLists(in store: ClipboardStore) -> Bool {
        board != nil && scopeBoard(in: store) == nil
    }

    private func resultsKey(_ store: ClipboardStore) -> ResultsKey {
        ResultsKey(store: ObjectIdentifier(store), revision: store.revision, query: query, kind: kind,
                   source: source, board: scopeBoard(in: store), recentDays: recentDays,
                   day: Calendar.current.startOfDay(for: Date()), suggested: suggestedIDs)
    }

    /// Memoised per store revision and filter state: the panel, every card and
    /// the key handler ask for this many times per update.
    func results(in store: ClipboardStore) -> [ClipboardEntry] {
        let key = resultsKey(store)
        if let resultsCache, resultsCache.key == key { return resultsCache.value }
        let range = Self.dateRange(for: recentDays)
        var value = store.filtered(query: query, kind: kind, source: source,
                                   board: key.board, since: range.since)
            .filter { range.before == nil || $0.lastCopiedAt < range.before! }
        if !suggestedIDs.isEmpty, board == nil, query.isEmpty, kind == nil, source == nil, recentDays == 0 {
            value = Self.promoting(suggestedIDs, in: value)
        }
        resultsCache = (key, value)
        return value
    }

    private var searchTask: Task<Void, Never>?
    private var pendingSearchKey: ResultsKey?
    private var selectionAfterSearch: (key: ResultsKey, index: Int)?
    @Published private var searchCompletion = 0
    var isSearchPending: Bool { pendingSearchKey != nil }

    /// UI-only search path. Full text matching never runs in a view body or a
    /// key handler. An obsolete search cannot restore its results/selection.
    func displayedResults(in store: ClipboardStore) -> [ClipboardEntry] {
        let key = resultsKey(store)
        if query.isEmpty {
            searchTask?.cancel(); searchTask = nil; pendingSearchKey = nil
            return results(in: store)
        }
        if let resultsCache, resultsCache.key == key {
            searchTask?.cancel(); searchTask = nil; pendingSearchKey = nil
            return resultsCache.value
        }
        if pendingSearchKey != key {
            searchTask?.cancel()
            pendingSearchKey = key
            let snapshot = store.entries, boards = store.boards
            let range = Self.dateRange(for: recentDays)
            searchTask = Task.detached(priority: .userInitiated) { [weak self, weak store] in
                let search = ClipboardSearchQuery(key.query, boards: boards)
                var matches: [ClipboardEntry] = []
                for entry in snapshot {
                    guard !Task.isCancelled else { return }
                    if (key.kind == nil || entry.kind == key.kind) &&
                       (key.source == nil || entry.sourceBundleID == key.source || entry.sourceName == key.source) &&
                       (key.board == nil || entry.pinboardIDs.contains(key.board!)) &&
                       (range.since == nil || entry.lastCopiedAt >= range.since!) &&
                       (range.before == nil || entry.lastCopiedAt < range.before!) && search.matches(entry, boards: boards) {
                        matches.append(entry)
                    }
                }
                guard !Task.isCancelled else { return }
                let found = ClipboardStore.ordered(matches, board: key.board, boards: boards)
                await MainActor.run {
                    guard let self, let store, self.pendingSearchKey == key,
                          self.query == key.query, store.revision == key.revision else { return }
                    self.resultsCache = (key, found)
                    self.pendingSearchKey = nil
                    if let pending = self.selectionAfterSearch, pending.key == key {
                        self.selectionAfterSearch = nil
                        self.selectNeighbor(at: pending.index, from: found)
                    }
                    self.searchCompletion &+= 1
                }
            }
        }
        return []
    }

    func selectNeighbor(at index: Int, in store: ClipboardStore) {
        let current = displayedResults(in: store)
        if let pendingSearchKey { selectionAfterSearch = (pendingSearchKey, index) }
        else { selectNeighbor(at: index, from: current) }
    }

    private func selectNeighbor(at index: Int, from entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        let next = entries[min(max(0, index), entries.count - 1)]
        select(next.id, in: entries)
        keyboardScrollTarget = next.id
    }

    /// Moves the suggested entries to the front, in suggestion order.
    static func promoting(_ ids: [UUID], in entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let picked = ids.compactMap { id in entries.first { $0.id == id } }
        guard !picked.isEmpty else { return entries }
        let set = Set(picked.map(\.id))
        return picked + entries.filter { !set.contains($0.id) }
    }

    func quickPasteIDs(in store: ClipboardStore) -> [UUID] {
        let visible = Set(visibleCardIDs)
        // Stop at nine; mapping/filtering all 10,000 clips on every modifier
        // event made the shortcut badges needlessly scale with history size.
        return Array(displayedResults(in: store).lazy.map(\.id)
            .filter { visible.isEmpty || visible.contains($0) }.prefix(9))
    }

    func selectedIDs(in store: ClipboardStore) -> [UUID] {
        displayedResults(in: store).filter { selected.contains($0.id) }.map(\.id)
    }

    /// Keep pinboard tab changes atomic, without leaving stale selection
    /// attached to clips from the previously displayed collection.
    func selectBoard(_ id: UUID?) {
        board = id
        clearSelection()
    }

    func clearSelection() {
        selectionAfterSearch = nil
        if preview != nil { preview = nil }
        if !selected.isEmpty { selected.removeAll() }
        if focusedID != nil { focusedID = nil }
        if keyboardScrollTarget != nil { keyboardScrollTarget = nil }
        selectionAnchor = nil
    }

    func select(_ id: UUID, in entries: [ClipboardEntry], extend: Bool = false, toggle: Bool = false) {
        guard let next = entries.firstIndex(where: { $0.id == id }) else { return }
        if extend, let anchor = selectionAnchor,
           let start = entries.firstIndex(where: { $0.id == anchor }) {
            selected = Set(entries[min(start, next)...max(start, next)].map(\.id))
        } else if toggle {
            if !selected.insert(id).inserted { selected.remove(id) }
            selectionAnchor = id
        } else {
            selected = [id]
            selectionAnchor = id
        }
        let focus = selected.contains(id) ? id : entries.first(where: { selected.contains($0.id) })?.id
        if focusedID != focus { focusedID = focus }
        if searchFieldActive { searchFieldActive = false }
    }

    func selectAll(in entries: [ClipboardEntry]) {
        selected = Set(entries.map(\.id))
        selectionAnchor = entries.first?.id
        focusedID = entries.first?.id
    }

    func showIn(_ board: UUID?, entryID: UUID) {
        query = ""
        kind = nil
        source = nil
        recentDays = 0
        searchExpanded = false
        filtersExpanded = false
        selectBoard(board)
        selected = [entryID]
        focusedID = entryID
        selectionAnchor = entryID
        // The shelf is rebuilt for the new list first; scroll once it exists.
        DispatchQueue.main.async { [weak self] in self?.keyboardScrollTarget = entryID }
    }

    /// Where ⌘G takes an item (Paste's "jump to where an item lives"): its
    /// pinboard when it is pinned and not already shown there, otherwise
    /// Clipboard History.
    static func home(of entry: ClipboardEntry, viewing board: UUID?, searching: Bool,
                     boards: [ClipboardPinboard]) -> UUID? {
        let pinned = boards.map(\.id).filter(entry.pinboardIDs.contains)
        if let board, !searching, entry.pinboardIDs.contains(board) { return nil }
        return pinned.first
    }

    /// Paste's Show In menu: the lists an item lives in other than the one on
    /// screen. Search results are not a list, so a search offers them all.
    static func showInTargets(for entry: ClipboardEntry, viewing board: UUID?, searching: Bool,
                              boards: [ClipboardPinboard]) -> [UUID?] {
        let lists: [UUID?] = [nil] + boards.map(\.id).filter(entry.pinboardIDs.contains).map(Optional.some)
        guard !searching else { return lists }
        return lists.filter { $0 != board }
    }
}

struct ClipboardEditorRequest: Identifiable {
    enum Operation { case renameEntry(UUID), editEntry(UUID), newText, newBoard, renameBoard(UUID) }
    let id = UUID()
    var operation: Operation
    var title: String
    var text: String

    var isTextEditor: Bool {
        switch operation {
        case .editEntry, .newText: return true
        default: return false
        }
    }
}

/// Paste-inspired contextual shortcuts, isolated for deterministic tests.
/// A user must explicitly select a card before Space or Command-E is handled.
enum ClipboardHistoryKeyboard {
    enum Action: Equatable { case preview, edit, rename }

    static func selectionAction(keyCode: UInt16, characters: String?,
                                modifiers: NSEvent.ModifierFlags) -> Action? {
        let blocked: NSEvent.ModifierFlags = [.option, .control]
        guard modifiers.intersection(blocked).isEmpty else { return nil }
        if keyCode == 49, !modifiers.contains(.command) { return .preview }
        guard modifiers.contains(.command), !modifiers.contains(.shift) else { return nil }
        // Hardware key codes survive Korean and other IME composition.
        if keyCode == 14 { return .edit }   // ANSI E
        if keyCode == 15 { return .rename } // ANSI R
        switch characters?.lowercased() {
        case "e": return .edit
        case "r": return .rename
        default: return nil
        }
    }
}
