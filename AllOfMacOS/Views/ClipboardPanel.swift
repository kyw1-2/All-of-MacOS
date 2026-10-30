import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import QuickLookUI

/// The history window takes keyboard focus without activating AOM. The original
/// application remains the destination; selecting a card never guesses a new one.
private final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// `makeFirstResponder(nil)` would hand focus back to the window and make
    /// AppKit search SwiftUI's focus graph on the next activation; park it on
    /// the lightweight container instead.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder == nil, let container = contentView as? ClipboardPanelContainerView {
            return super.makeFirstResponder(container)
        }
        return super.makeFirstResponder(responder)
    }
}

/// Key-capable but otherwise inert root view of the shelf.
private final class ClipboardPanelContainerView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

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

    func finishPendingSearch() async { await searchTask?.value }

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

@MainActor
final class ClipboardPanelController {
    static let shared = ClipboardPanelController()
    let state = ClipboardPanelState()
    private var panel: ClipboardHistoryPanel?
    private var stackPanel: NSPanel?
    private var detachedPreview: NSWindow?
    private var presentationObserver: NSObjectProtocol?
    private init() {
        presentationObserver = NotificationCenter.default.addObserver(forName: ClipboardPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let sharing: NSWindow.SharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
                self.panel?.sharingType = sharing; self.stackPanel?.sharingType = sharing; self.detachedPreview?.sharingType = sharing
                if self.isVisible { self.show() }
            }
        }
    }

    func navigateBoard(offset: Int) {
        if !isVisible { show() }
        let ids: [UUID?] = [nil] + store.boards.map { Optional($0.id) }
        let index = ids.firstIndex(of: state.board) ?? 0
        state.selectBoard(ids[(index + offset + ids.count) % ids.count])
    }

    func fitStackPanel() {
        guard let window = stackPanel else { return }
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(150, CGFloat(state.stack.count) * 45 + 88), min(600, limit - 40))
        var frame = window.frame; frame.origin.y += frame.height - height; frame.size.height = height
        window.setFrame(frame, display: true)
    }

    func detachPreview(_ entry: ClipboardEntry) {
        state.preview = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = entry.title
        window.isReleasedWhenClosed = false
        window.sharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
        window.contentView = NSHostingView(rootView: ClipboardDetachedPreview(entry: entry, store: store))
        window.center(); detachedPreview?.close(); detachedPreview = window
        hideImmediately(); window.makeKeyAndOrderFront(nil)
    }

    /// A rename inside the detached preview keeps the window's title bar in step.
    func syncDetachedPreviewTitle(_ title: String) {
        detachedPreview?.title = title
    }
    private var destination: NSRunningApplication?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var pasteTask: Task<Void, Never>?
    private let stackPasteMonitor = ClipboardStackPasteMonitor()
    private var stackPasteTask: Task<Void, Never>?
    private var pendingStackPastes: [(NSRunningApplication, Bool)] = []
    private var dismissalGeneration = 0
    private var previewNavigationGeneration = 0
    private var slidingOut = false
    private var store: ClipboardStore { .shared }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { (isVisible && !slidingOut) ? hide() : show() }
    func showStack() {
        state.stackMode = true
        store.onCapture = { [weak self] id in
            guard let self, self.state.stackMode else { return }
            self.state.stack.append(id)
        }
        if stackPanel == nil {
            // Paste's stack panel is a narrow 264 pt column beside the destination.
            let window = ClipboardStackPanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 420),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: ClipboardStackView(store: store, state: state, controller: self))
            stackPanel = window
        }
        if let panel = stackPanel, !panel.isVisible,
           let bounds = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - panel.frame.width - 20,
                                         y: bounds.maxY - panel.frame.height - 20))
        }
        stackPanel?.sharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
        fitStackPanel()
        stackPanel?.orderFrontRegardless()
        stackPasteMonitor.onPaste = { [weak self] plainText in
            guard let self, self.stackPanel?.isVisible == true, !self.isVisible,
                  let target = NSWorkspace.shared.frontmostApplication,
                  target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            guard self.pendingStackPastes.count < 32 else { return true }
            // Never read promised clipboard data inside a consuming event tap.
            // If a fresh copy is still being captured, the worker waits for it.
            self.pendingStackPastes.append((target, plainText))
            self.drainStackPastes()
            return true
        }
        if !stackPasteMonitor.start() {
            state.status = "Enable Accessibility access for repeated ⌘V in Paste Stack. Paste Next remains available."
        }
    }

    private func drainStackPastes() {
        guard stackPasteTask == nil else { return }
        stackPasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                stackPasteTask = nil
                // A new stack session may queue input while the cancelled worker exits.
                if !pendingStackPastes.isEmpty, stackPanel?.isVisible == true { drainStackPastes() }
            }
            while !Task.isCancelled, !pendingStackPastes.isEmpty {
                let (target, plainText) = pendingStackPastes.removeFirst()
                store.poll()
                await store.finishPendingCaptures()
                guard !Task.isCancelled, stackPanel?.isVisible == true,
                      !target.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    pendingStackPastes.removeAll()
                    return
                }
                state.stack.removeAll { id in !self.store.entries.contains { $0.id == id } }
                let next = state.nextStackID
                do {
                    if let next {
                        // Write before replaying the intercepted event. Do not
                        // pre-load the following item until this paste settles.
                        _ = try store.write(entryIDs: [next], plainText: plainText || store.settings.plainText, playSound: false)
                    }
                    guard ClipboardStackPasteMonitor.sendPaste(to: target) else { continue }
                    if let next {
                        if state.nextStackID == next { state.removeStackItem(next) }
                        ClipboardAudioFeedback.paste()
                        state.status = state.stack.isEmpty ? "Stack finished." : "\(state.stack.count) items remaining — press ⌘V."
                    }
                    // Consumers retrieve pasteboard data after processing their
                    // event. Serialize rapid repeats instead of replacing it
                    // immediately after posting the first key pair.
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    state.status = error.localizedDescription
                    pendingStackPastes.removeAll()
                    return
                }
            }
        }
    }

    func stopStack() {
        state.stackMode = false
        stackPasteMonitor.stop()
        stackPasteTask?.cancel()
        pendingStackPastes.removeAll()
        store.onCapture = nil
        stackPanel?.orderOut(nil)
    }

    /// Clear selected cards with Escape before dismissing the history.
    /// A sheet or inline title editor must receive Escape itself.
    @discardableResult
    func handleEscape() -> Bool {
        guard isVisible else { return false }
        // The preview owns Escape while its editor or discard prompt is active.
        if state.editor != nil || state.preview != nil || state.editingTitleID != nil { return false }
        if !state.pendingDeletion.isEmpty {
            state.pendingDeletion = []
        } else if state.filtersExpanded {
            state.filtersExpanded = false
        } else if state.searchExpanded {
            state.query = ""
            state.searchExpanded = false
            state.searchFieldActive = false
            panel?.makeFirstResponder(nil)
            state.clearSelection()
        } else if !state.selected.isEmpty {
            state.clearSelection()
        } else {
            hide()
        }
        return true
    }

    func isHistoryWindow(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    func selectCard(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard isVisible, !slidingOut,
              state.editor == nil, state.editingTitleID == nil, state.preview == nil else { return }
        state.select(id, in: state.displayedResults(in: store),
                     extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
        // Clear the native field editor too, so arrows/Space act on this card
        // immediately after the user leaves the search field.
        if panel?.firstResponder is NSTextView { panel?.makeFirstResponder(nil) }
    }

    func openPreview(_ entry: ClipboardEntry) {
        previewNavigationGeneration += 1
        state.searchFieldActive = false
        state.select(entry.id, in: state.displayedResults(in: store))
        panel?.makeFirstResponder(nil)
        state.preview = entry
    }

    func closePreview() {
        previewNavigationGeneration += 1
        state.preview = nil
        state.searchFieldActive = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(nil)
    }

    func movePreview(from id: UUID, offset: Int) {
        let entries = state.displayedResults(in: store)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(index + offset) else { return }
        let next = entries[index + offset]
        closePreview()
        let generation = previewNavigationGeneration
        state.select(next.id, in: entries)
        state.keyboardScrollTarget = next.id
        // Let the lazy shelf materialize the new card before attaching its popover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.previewNavigationGeneration == generation,
                  self.isVisible, self.state.focusedID == next.id,
                  self.state.preview == nil, self.state.editor == nil,
                  self.state.displayedResults(in: self.store).contains(where: { $0.id == next.id }) else { return }
            self.openPreview(next)
        }
    }

    func show() {
        pasteTask?.cancel()
        dismissalGeneration += 1
        slidingOut = false
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            destination = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        if panel == nil {
            let window = ClipboardHistoryPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // No system zoom-in when ordered front: AOM fades the shelf itself.
            window.animationBehavior = .none
            // A plain container is the window's initial first responder, so
            // ordering the shelf front never asks SwiftUI to walk its whole
            // focus graph for a "first key view" (≈200 ms per ⇧⌘V).
            let container = ClipboardPanelContainerView()
            let hosting = NSHostingView(rootView: ClipboardPanelView(store: store, state: state, controller: self))
            // The controller owns both dimensions. Intrinsic min/ideal/max
            // sizing needlessly measures the SwiftUI shelf while AppKit
            // orders the panel front (including its lazy card hierarchy).
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            container.addSubview(hosting)
            window.contentView = container
            window.initialFirstResponder = container
            window.autorecalculatesKeyViewLoop = false
            panel = window
        }
        guard let panel else { return }
        panel.sharingType = ClipboardPreferences.shared.showInScreenCapture ? .readOnly : .none
        if let container = panel.contentView as? ClipboardPanelContainerView, panel.firstResponder !== container,
           !((panel.firstResponder as? NSTextView)?.isEditable ?? false) {
            panel.makeFirstResponder(container)
        }
        // A new presentation may interrupt a previous slide-out animation.
        panel.alphaValue = 1
        let wasVisible = panel.isVisible
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        var target = panel.frame
        if let bounds = screen?.visibleFrame {
            let storedHeight = CGFloat(UserDefaults.standard.double(forKey: "AOMClipboardPanelHeight"))
            let targetHeight = Self.clampedHeight(ClipboardPreferences.shared.compact ? Self.minimumHeight : (storedHeight > 0 ? storedHeight : Self.defaultHeight),
                                                  visibleHeight: bounds.height)
            target = NSRect(x: bounds.minX + 8, y: bounds.minY + 8,
                            width: max(1, bounds.width - 16), height: targetHeight)
        }
        // Stale messages from an earlier session must not greet the user.
        if !state.status.isEmpty { state.status = "" }
        if !wasVisible {
            // Suggestions are computed off the main thread and slot in while
            // the shelf slides up; opening never waits on Accessibility IPC.
            if !state.suggestedIDs.isEmpty { state.suggestedIDs = [] }
            ClipboardIntelligence.shared.suggestionsAsync(for: destination, store: store) { [weak self] ids in
                guard let self, self.isVisible, !self.slidingOut, self.state.suggestedIDs != ids else { return }
                self.state.suggestedIDs = ids
            }
            ClipboardIntelligence.shared.refineClassesWithModel(store.entries.filter { !store.settings.excludes($0.sourceBundleID) })
        }
        DispatchQueue.main.async { [weak self] in self?.store.poll() }
        let expandSearch = !state.query.isEmpty
        if state.searchExpanded != expandSearch { state.searchExpanded = expandSearch }
        state.setCommandHeld(NSEvent.modifierFlags.contains(ClipboardPreferences.shared.quickModifier.flags))
        if wasVisible || !Self.animatesPanel {
            panel.setFrame(target, display: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            var start = target
            // Keep the complete window on its own display during animation.
            start.origin.y = max(screen?.frame.minY ?? target.minY, target.minY - 28)
            panel.alphaValue = 0
            panel.setFrame(start, display: true)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        store.defersBackgroundUpdates = true
        installMonitors()
    }

    static let defaultHeight: CGFloat = 280
    static let minimumHeight: CGFloat = 175
    static func clampedHeight(_ height: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), max(120, (visibleHeight - 36) / 2))
    }
    private static var animatesPanel: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !PresetManager.isRunningTests
    }

    /// Dismisses with Paste's slide-down. Use `hideImmediately` when another
    /// window must take over the screen at once.
    func hide() { pasteTask?.cancel(); slideDownAndHide() }

    func hideImmediately(cancelPendingPaste: Bool = true) {
        if cancelPendingPaste { pasteTask?.cancel() }
        dismissalGeneration += 1
        slidingOut = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        clearPanelInteractionState()
    }

    private func clearPanelInteractionState() {
        removeInteractionMonitors()
        resetPanelState()
    }

    /// Immediate part of dismissal: stop reacting to input.
    private func removeInteractionMonitors() {
        previewNavigationGeneration += 1
        for token in [keyMonitor, outsideMonitor, localClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(token)
        }
        keyMonitor = nil
        outsideMonitor = nil
        localClickMonitor = nil
    }

    /// Deferred part: everything that re-renders the cards runs once the
    /// shelf is off screen, never during its slide-out animation.
    private func resetPanelState() {
        if state.editor != nil { state.editor = nil }
        if state.preview != nil { state.preview = nil }
        if state.editingTitleID != nil { state.editingTitleID = nil }
        state.clearSelection()
        state.setCommandHeld(false)
        state.visibleCardIDs = []
        if !state.suggestedIDs.isEmpty { state.suggestedIDs = [] }
        // Releases deferred work: copy-time reordering and image OCR results.
        store.defersBackgroundUpdates = false
    }

    /// Copy the chosen rich clipboard item without sending Cmd-V to any app.
    /// Returns false (and leaves the panel open) if copying fails.
    @discardableResult
    func copyAndSlideDown(entryID: UUID, plainText: Bool = false) -> Bool {
        guard isVisible, !slidingOut,
              state.editor == nil, state.preview == nil, state.editingTitleID == nil else { return false }
        do {
            guard try Self.copyEntry(entryID, from: store, plainText: plainText) else { return false }
        } catch {
            state.status = error.localizedDescription
            return false
        }
        state.status = "Copied to clipboard."
        slideDownAndHide()
        return true
    }

    /// Copy-only entry point used by explicit copy actions.
    @discardableResult
    static func copyEntry(_ entryID: UUID, from store: ClipboardStore,
                          plainText: Bool = false) throws -> Bool {
        try store.write(entryIDs: [entryID], plainText: plainText)
    }

    private func slideDownAndHide(completion: @escaping () -> Void = {}) {
        guard let panel, panel.isVisible, !slidingOut else {
            if !slidingOut { hideImmediately() }
            completion(); return
        }
        dismissalGeneration += 1
        let generation = dismissalGeneration
        slidingOut = true
        removeInteractionMonitors()

        // Paste sits just above the bottom screen edge; exit beneath that edge.
        guard Self.animatesPanel else { hideImmediately(); completion(); return }
        var finished = false
        let finish: () -> Void = { [weak self, weak panel] in
            guard !finished, let self, let panel, self.dismissalGeneration == generation else { return }
            finished = true
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.slidingOut = false
            self.resetPanelState()
            completion()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            var target = panel.frame
            target.origin.y = max(panel.screen?.frame.minY ?? target.minY, target.minY - 28)
            panel.animator().setFrame(target, display: true)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in finish() }
        }
        // The shelf must never linger half-faded if the completion is late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { finish() } }
    }

    func pasteSelected(plainText: Bool = false) {
        _ = state.displayedResults(in: store)
        guard !state.isSearchPending else { return }
        var ids = state.selectedIDs(in: store)
        if ids.isEmpty, let first = state.displayedResults(in: store).first { ids = [first.id] }
        paste(ids: ids, plainText: plainText, dismissAfterCopy: true)
    }

    func pasteNext() {
        state.stack.removeAll { id in !self.store.entries.contains { $0.id == id } }
        guard let id = state.nextStackID else { state.status = "The paste stack is empty."; return }
        // A stack shortcut may run with the panel closed, so its target is the
        // current foreground application, not an older panel session.
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            destination = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        paste(ids: [id], plainText: store.settings.plainText) { [weak self] in
            if self?.state.nextStackID == id { self?.state.removeStackItem(id) }
        }
    }

    func enqueueSelection() {
        for id in state.selectedIDs(in: store) where !state.stack.contains(id) { state.stack.append(id) }
        showStack()
        state.status = "\(state.stack.count) items queued. Press ⌘V in your destination to paste them in order."
    }

    func paste(ids: [UUID], plainText: Bool = false, dismissAfterCopy: Bool = false,
               copied: (() -> Void)? = nil) {
        guard !ids.isEmpty, !slidingOut, !state.isSearchPending else { return }
        pasteTask?.cancel()
        let target = destination
        let directly = store.settings.pasteDirectly
        let versionAtRequest = dismissalGeneration
        self.pasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clipboardVersion: Int
            do {
                clipboardVersion = try await store.writeAsync(entryIDs: ids,
                    plainText: plainText || store.settings.plainText, playSound: false)
            } catch is CancellationError { return }
            catch { state.status = error.localizedDescription; return }
            guard !Task.isCancelled, dismissalGeneration == versionAtRequest else { return }
            guard directly, let target, !target.isTerminated else {
                ClipboardAudioFeedback.copy()
                state.status = "Copied to clipboard."
                copied?()
                if dismissAfterCopy { slideDownAndHide() }
                return
            }
            let result = await ClipboardPasteDelivery.deliver(version: clipboardVersion, environment: .init(
                relinquishFocus: { [self] in self.hideImmediately(cancelPendingPaste: false) },
                targetIsAlive: { !target.isTerminated },
                targetIsFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier },
                activateTarget: { target.activate(options: [.activateIgnoringOtherApps]) },
                clipboardVersion: { NSPasteboard.general.changeCount },
                send: { !PresetManager.isUIPreview && !PresetManager.isRunningTests && ClipboardStackPasteMonitor.sendPaste(to: target) }))
            switch result {
            case .pasted:
                ClipboardIntelligence.shared.recordPaste(entryIDs: ids, destination: target, store: store)
                ClipboardAudioFeedback.paste()
                copied?()
            case .clipboardChanged: state.status = "Clipboard changed before pasting. Choose the item again."
            case .permissionDenied: state.status = "Item copied. Enable Accessibility access to paste directly."
            case .unavailable, .activationTimedOut: state.status = "Destination unavailable. Item copied without pasting."
            case .cancelled: break
            }
        }
    }

    /// "Paste to Safari" when direct paste can reach the destination.
    var pasteActionTitle: String {
        if store.settings.pasteDirectly, let name = destination?.localizedName, destination?.isTerminated == false {
            return "Paste to \(name)"
        }
        return "Paste"
    }

    func editEntry(_ item: ClipboardEntry) {
        if item.kind == .image, let data = item.imageData,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let capture = CaptureHistoryEntry(image: image, kind: .area, capturedAt: item.createdAt,
                                             windowTitle: item.title, fileURL: nil)
            hideImmediately()
            AnnotationEditorController.shared.open(capture: capture, url: nil, onApply: { [weak self] image in
                self?.store.editImage(entryID: item.id, image: image)
            })
        } else if item.kind == .color, let text = item.text {
            closePreview()
            ClipboardColorEditor.shared.show(hex: text) { [weak self] value in self?.store.editText(entryID: item.id, text: value) }
        } else if let text = item.text, [.text, .link].contains(item.kind) {
            state.editor = .init(operation: .editEntry(item.id), title: "Edit Content", text: text)
        } else { openPreview(item) }
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel, self.state.editor == nil, self.state.preview == nil else { return event }
            if event.type == .flagsChanged {
                self.state.setCommandHeld(event.modifierFlags.contains(ClipboardPreferences.shared.quickModifier.flags))
                return event
            }
            if self.state.editingTitleID != nil { return event }
            if event.modifierFlags.contains(.command), event.keyCode == 3 {
                self.state.searchFocusToken = UUID()
                return nil
            }
            if self.state.searchFieldActive && [48, 125].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                self.state.searchFieldActive = false
                self.panel?.makeFirstResponder(nil)
                if let first = self.state.displayedResults(in: self.store).first {
                    self.state.select(first.id, in: self.state.displayedResults(in: self.store))
                }
                return nil
            }
            if event.keyCode == 53 {
                // Inline text renaming uses its own Escape-to-cancel behavior.
                if self.state.editingTitleID != nil { return event }
                return self.handleEscape() ? nil : event
            }
            // Selection commands must work even if SwiftUI's search field still
            // owns the NSTextView first responder after a card mouse-down.
            // Ordinary typing/editing in the search field remains untouched.
            if (self.panel?.firstResponder as? NSTextView)?.isEditable == true {
                let hasSelection = !self.state.selectedIDs(in: self.store).isEmpty
                let command = event.modifierFlags.contains(.command)
                let digit = Int(event.charactersIgnoringModifiers ?? "") ?? 0
                let quickPaste = ClipboardPreferences.shared.isQuick(event.modifierFlags) && (1...9).contains(digit)
                let selectedAction = hasSelection && !self.state.searchFieldActive && (
                    [36, 76].contains(event.keyCode) ||
                    (command && event.keyCode == 8) ||
                    ClipboardHistoryKeyboard.selectionAction(
                        keyCode: event.keyCode,
                        characters: event.charactersIgnoringModifiers,
                        modifiers: event.modifierFlags) != nil)
                guard quickPaste || selectedAction else { return event }
            }
            return self.handleKey(event) ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.editor == nil, self.state.preview == nil else { return }
                self.hide()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel, event.window?.level != .popUpMenu,
               !self.state.filtersExpanded, self.state.editor == nil, self.state.preview == nil { self.hide() }
            return event
        }
    }

    /// Deletes and keeps a neighbouring card selected; ⌘Z restores.
    func delete(_ ids: [UUID]) {
        let before = state.displayedResults(in: store)
        store.delete(entryIDs: ids)
        state.pendingDeletion = []
        state.clearSelection()
        if let index = before.firstIndex(where: { ids.contains($0.id) }) {
            state.selectNeighbor(at: index, in: store)
        }
        state.status = ids.count == 1 ? "Item deleted. Press ⌘Z to undo." : "\(ids.count) items deleted. Press ⌘Z to undo."
    }

    /// Targets of a card action: the whole selection when the card is part of
    /// it, otherwise just that card (Paste's context-menu behaviour).
    func actionTargets(for entry: ClipboardEntry) -> [UUID] {
        let selected = state.selectedIDs(in: store)
        return selected.contains(entry.id) ? selected : [entry.id]
    }

    /// Paste 7's Edit Image ▸ Remove Background: the cut-out is a new item
    /// right after the original, which is kept untouched.
    func removeBackground(_ entry: ClipboardEntry) {
        guard let data = entry.imageData, let source = NSBitmapImageRep(data: data)?.cgImage else {
            state.status = "This item has no image to edit."
            return
        }
        state.status = "Removing background…"
        Task { @MainActor in
            do {
                let output = try await BackgroundRemoval.removingBackground(source)
                guard let created = store.createImageItem(output, from: entry) else {
                    state.status = store.lastError ?? "Could not add the image."
                    return
                }
                state.selected = [created.id]
                state.focusedID = created.id
                state.status = "Background removed — added as a new item."
            } catch {
                state.status = error.localizedDescription
            }
        }
    }

    /// Paste's "Erase History": unpinned items go, pinboards stay; asks first.
    func confirmEraseHistory() {
        let unpinned = store.entries.filter { $0.pinboardIDs.isEmpty }.count
        guard unpinned > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Erase clipboard history?"
        alert.informativeText = ClipboardEraseCopy.message(unpinned: unpinned)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.eraseHistory()
        state.selected.removeAll()
        state.status = "History erased. Pinned items were kept — Undo Delete brings the rest back."
    }

    private var pauseTask: Task<Void, Never>?
    func togglePause() {
        pauseTask?.cancel()
        store.paused.toggle()
        state.status = store.paused ? "Clipboard history paused." : "Clipboard history resumed."
    }

    /// Paste's "Pause Paste ▸" durations. `nil` pauses until resumed.
    func pause(for minutes: Int?) {
        pauseTask?.cancel()
        store.paused = true
        guard let minutes else { state.status = "Clipboard history paused."; return }
        state.status = "Clipboard history paused for \(minutes >= 60 ? "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")" : "\(minutes) minutes")."
        pauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.store.paused else { return }
            self.store.paused = false
        }
    }

    func openSettings() {
        guard !PresetManager.isUIPreview else { return }
        hideImmediately()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// ⌘O: open a link in the browser or a file in its default app.
    func openExternally(_ entry: ClipboardEntry) {
        guard !PresetManager.isUIPreview else { return }
        if !entry.fileURLs.isEmpty {
            hide()
            for url in entry.fileURLs.prefix(10) { NSWorkspace.shared.open(url) }
        } else if entry.kind == .link, let text = entry.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            hide()
            NSWorkspace.shared.open(url)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let plain = ClipboardPreferences.shared.isPlain(event.modifierFlags)
        if event.keyCode == 53 { hide(); return true }
        if command && event.keyCode == 3 { state.searchFocusToken = UUID(); return true }
        if command && !shift && event.keyCode == 6 {
            let undone = store.undoLastDeletion()
            state.selected = Set(undone.entryIDs)
            state.focusedID = undone.entryIDs.first
            if undone.isEmpty {
                state.status = "Nothing to restore."
            } else if undone.boardCount > 0 {
                state.status = "Restored \(undone.boardCount) pinboard\(undone.boardCount == 1 ? "" : "s")"
                    + (undone.entryIDs.isEmpty ? "." : " and \(undone.entryIDs.count) item(s).")
            } else {
                state.status = "Restored \(undone.entryIDs.count) item(s)."
            }
            return true
        }
        if command && event.keyCode == 45 {
            if shift {
                state.editor = .init(operation: .newBoard, title: "New Pinboard", text: "")
            } else {
                state.editor = .init(operation: .newText, title: "New Text Item", text: "")
            }
            return true
        }
        let activeEntries = state.displayedResults(in: store)
        if command && event.keyCode == 8 {
            let ids = state.selectedIDs(in: store)
            guard !ids.isEmpty else { return false }
            do {
                _ = try store.write(entryIDs: ids, plainText: plain)
                state.status = ClipboardPanelState.multiCopyStatus(count: ids.count)
            } catch { state.status = error.localizedDescription }
            return true
        }
        if command && event.keyCode == 17 {
            togglePause()
            return true
        }
        if command && !shift && event.keyCode == 43 {   // ⌘, Settings
            openSettings()
            return true
        }
        if command && !shift && event.keyCode == 31,     // ⌘O Open link / file
           let item = activeEntries.first(where: { state.selected.contains($0.id) }) {
            openExternally(item)
            return true
        }
        if command && event.keyCode == 5,
           state.selected.count == 1, let id = state.selected.first,
           let entry = store.entries.first(where: { $0.id == id }) {
            state.showIn(ClipboardPanelState.home(of: entry, viewing: state.board, searching: state.isSearching,
                                                  boards: store.boards), entryID: id)
            return true
        }
        if event.keyCode == 48 {
            state.searchFocusToken = UUID()
            return true
        }
        if let action = ClipboardHistoryKeyboard.selectionAction(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags),
           let item = activeEntries.first(where: { $0.id == state.focusedID && state.selected.contains($0.id) })
                ?? activeEntries.first(where: { state.selected.contains($0.id) }) {
            switch action {
            case .preview:
                if !event.isARepeat { openPreview(item) }
            case .edit:
                editEntry(item)
            case .rename:
                state.editor = .init(operation: .renameEntry(item.id), title: "Rename Item", text: item.title)
            }
            state.searchFieldActive = false
            return true
        }
        if command && (event.keyCode == 123 || event.keyCode == 124) {
            let boards: [UUID?] = [nil] + store.boards.map { Optional($0.id) }
            let index = boards.firstIndex(of: state.board) ?? 0
            state.selectBoard(boards[(index + (event.keyCode == 124 ? 1 : boards.count - 1)) % boards.count])
            return true
        }
        let entries = state.displayedResults(in: store)
        let quickIDs = state.quickPasteIDs(in: store)
        if ClipboardPreferences.shared.isQuick(event.modifierFlags), let text = event.charactersIgnoringModifiers, let number = Int(text),
           (1...9).contains(number), quickIDs.indices.contains(number - 1) {
            paste(ids: [quickIDs[number - 1]], plainText: plain, dismissAfterCopy: true); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { pasteSelected(plainText: plain); return true }
        let editingText = (panel?.firstResponder as? NSTextView)?.isEditable == true
        if !editingText && (event.keyCode == 123 || event.keyCode == 124),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty, !entries.isEmpty {
            let current = entries.firstIndex { $0.id == state.focusedID }
                ?? entries.firstIndex { state.selected.contains($0.id) } ?? -1
            let next = min(max(current + (event.keyCode == 124 ? 1 : -1), 0), entries.count - 1)
            state.select(entries[next].id, in: entries, extend: shift)
            state.keyboardScrollTarget = entries[next].id
            return true
        }
        // ⌘↑/⌘↓ (and Home/End) jump to the first/last item, as in Paste.
        if !editingText, !entries.isEmpty,
           (command && (event.keyCode == 126 || event.keyCode == 125)) || event.keyCode == 115 || event.keyCode == 119 {
            let target = (event.keyCode == 126 || event.keyCode == 115) ? entries[0] : entries[entries.count - 1]
            state.select(target.id, in: entries, extend: shift)
            state.keyboardScrollTarget = target.id
            return true
        }
        if !editingText && command && event.keyCode == 0 { state.selectAll(in: entries); return true }
        if !editingText && (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.option, .control]).isEmpty {
            let selectedIDs = state.selectedIDs(in: store)
            guard !selectedIDs.isEmpty else { return false }
            if selectedIDs.count > 1 { state.pendingDeletion = selectedIDs } else { delete(selectedIDs) }
            return true
        }
        if event.modifierFlags.intersection([.command, .control]).isEmpty,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            state.query += characters
            state.searchFocusToken = UUID()
            return true
        }
        return false
    }
}

@MainActor
struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardPanelState
    let controller: ClipboardPanelController
    @FocusState private var searchFocused: Bool
    @State private var boardPendingDeletion: ClipboardPinboard?
    /// Link cards follow their switches without reopening the shelf.
    @ObservedObject private var preferences = ClipboardPreferences.shared

    private var entries: [ClipboardEntry] { state.displayedResults(in: store) }
    private var sources: [ClipboardStore.AppSource] { store.availableAppSources }

    var body: some View {
        VStack(spacing: 0) {
            PastePanelResizeGrip()
                .frame(height: 4)
                .help("Drag to resize · Double-click to reset")
            headerBar
            // Active tokens stay in the search capsule; suggestions remain keyboard focusable below it.
            if state.searchExpanded {
                searchSuggestions
            }
            carouselContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Messages float over the shelf instead of pushing the cards up, and
        // fade away on their own (Paste shows no permanent status row).
        .overlay(alignment: .bottom) {
            if !state.status.isEmpty {
                HStack(spacing: AOMSpace.x2) {
                    Text(state.status)
                        .font(AOMFont.callout.weight(.medium))
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(2)
                        .accessibilityIdentifier("ClipboardStatus")
                    Button { state.status = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary)
                    }.buttonStyle(.plain).help("Dismiss Message").accessibilityLabel("Dismiss Message")
                }
                .padding(.leading, AOMSpace.x4).padding(.trailing, AOMSpace.x2).frame(minHeight: AOMSize.rowSingle)
                // The shelf is already glass: the message is an opaque capsule (c.4).
                .aomInPanelCapsule()
                .padding(.bottom, AOMSpace.x3)
                .transition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .aomAnimation(.standard, value: state.status)
        .task(id: state.status) {
            guard !state.status.isEmpty else { return }
            let shown = state.status
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled, state.status == shown { state.status = "" }
        }
        .modifier(PastePanelBackground())
        .alert("Delete selected items?", isPresented: Binding(
            get: { !state.pendingDeletion.isEmpty },
            set: { if !$0 { state.pendingDeletion = [] } }
        )) {
            Button("Delete", role: .destructive) { controller.delete(state.pendingDeletion) }
            Button("Cancel", role: .cancel) { state.pendingDeletion = [] }
        } message: {
            Text("\(state.pendingDeletion.count) items will be removed from the history. You can undo with ⌘Z.")
        }
        .alert("Delete “\(boardPendingDeletion?.name ?? "")”?", isPresented: Binding(
            get: { boardPendingDeletion != nil },
            set: { if !$0 { boardPendingDeletion = nil } }
        )) {
            let only = boardPendingDeletion.map { store.itemsOnlyOnBoard($0.id) } ?? 0
            Button(only == 0 ? "Delete Pinboard" : "Delete Pinboard and \(only) Item\(only == 1 ? "" : "s")", role: .destructive) {
                deleteBoard(deletingItems: true)
            }
            if only > 0 {
                Button("Delete Pinboard, Keep Items") { deleteBoard(deletingItems: false) }
            }
            Button("Cancel", role: .cancel) { boardPendingDeletion = nil }
        } message: {
            Text(ClipboardBoardDeletionCopy.message(onlyHere: boardPendingDeletion.map { store.itemsOnlyOnBoard($0.id) } ?? 0))
        }
        .onChange(of: state.searchFocusToken) { _, _ in
            withAnimation(AOMMotion.quick) {
                state.searchExpanded = true
            }
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: searchFocused) { _, focused in state.searchFieldActive = focused }
        .onChange(of: state.searchFieldActive) { _, focused in searchFocused = focused }
        .onChange(of: state.searchExpanded) { _, expanded in if !expanded { searchFocused = false } }
        .onChange(of: state.focusedID) { _, id in
            if id != nil {
                // Card selection has priority over the old search cursor.
                searchFocused = false
                state.searchFieldActive = false
            }
        }
        .onChange(of: state.query) { _, _ in
            absorbChipTokens()
            state.clearSelection()
        }
        .onChange(of: state.kind) { _, _ in state.clearSelection() }
        .onChange(of: state.source) { _, _ in state.clearSelection() }
        .onChange(of: state.recentDays) { _, _ in state.clearSelection() }
        .onChange(of: entries.map(\.id)) { _, ids in
            let visible = Set(ids)
            let selection = state.selected.intersection(visible)
            if state.selected != selection { state.selected = selection }
            if let id = state.focusedID, !visible.contains(id) { state.focusedID = nil }
            if let preview = state.preview, !visible.contains(preview.id) { state.preview = nil }
        }
        .sheet(item: Binding(
            get: { state.editor?.isTextEditor == false ? state.editor : nil },
            set: { if $0 == nil, state.editor?.isTextEditor == false { state.editor = nil } }
        )) { request in ClipboardEditorSheet(request: request, store: store) }
        .background(ClipboardTextEditorPresenter(request: $state.editor, store: store))
    }

    // MARK: - Paste-inspired search, horizontal pinboards and filters

    // Keep layout arithmetic outside the SwiftUI view-builder expression.
    private func pinboardScrollWidth(containerWidth: CGFloat) -> CGFloat {
        let boardsWidth = store.boards.reduce(CGFloat(170)) { total, board in
            total + min(CGFloat(190), CGFloat(board.name.count * 8 + 35))
        }
        let available = containerWidth - (state.searchExpanded ? (ClipboardSearchQuery.filterTokens(in: state.query).isEmpty ? CGFloat(620) : CGFloat(810)) : CGFloat(160))
        return max(CGFloat(90), min(CGFloat(560), min(available, boardsWidth)))
    }

    /// Deletes the pinboard awaiting confirmation; Undo Delete restores it.
    private func deleteBoard(deletingItems: Bool) {
        guard let board = boardPendingDeletion else { return }
        let deleted = store.deleteBoard(id: board.id, deletingItems: deletingItems)
        if state.board == board.id { state.selectBoard(nil) }
        boardPendingDeletion = nil
        state.status = deleted > 0
            ? "Deleted “\(board.name)” and \(deleted) item\(deleted == 1 ? "" : "s"). Press ⌘Z to undo."
            : "Deleted “\(board.name)”. Press ⌘Z to undo."
    }

    /// Typed `type:`/`from:`/`board:` tokens become chip selections, so the
    /// chips and the query never disagree. Unknown apps or boards stay typed.
    /// While searches cover every list, a `board:` token stays in the query:
    /// it is the only way to narrow such a search to one pinboard.
    private func absorbChipTokens() {
        var query = state.query
        for filter in ClipboardSearchQuery.chipFilters(in: query) {
            switch filter.field {
            case "type":
                guard let kind = ClipboardSearchQuery.kind(named: filter.value) else { continue }
                state.kind = kind
            case "from":
                guard let source = sources.first(where: { $0.name.caseInsensitiveCompare(filter.value) == .orderedSame
                    || $0.bundleID?.caseInsensitiveCompare(filter.value) == .orderedSame }) else { continue }
                state.source = source.filterValue
            case "board":
                guard !store.settings.searchesAllLists,
                      let board = store.boards.first(where: { $0.name.caseInsensitiveCompare(filter.value) == .orderedSame }) else { continue }
                state.selectBoard(board.id)
            default: continue
            }
            query = ClipboardSearchQuery.removing(token: filter.token, from: query)
        }
        if query != state.query { state.query = query.isEmpty ? "" : query + " " }
    }

    /// The Filters popover's Pinboard choice. While searches cover every list
    /// it adds or removes a `board:` filter; otherwise it opens the pinboard.
    private func toggleBoardFilter(_ board: ClipboardPinboard) {
        guard store.settings.searchesAllLists, state.isSearching || state.searchExpanded else {
            state.selectBoard(state.board == board.id ? nil : board.id)
            return
        }
        let token = "board:\"\(board.name)\""
        if ClipboardSearchQuery.tokens(in: state.query).contains(token) {
            state.query = ClipboardSearchQuery.removing(token: token, from: state.query)
        } else {
            state.query = ClipboardSearchQuery.inserting(token: token, into: state.query)
        }
    }

    private func boardFilterSelected(_ board: ClipboardPinboard) -> Bool {
        guard store.settings.searchesAllLists, state.isSearching || state.searchExpanded else { return state.board == board.id }
        return ClipboardSearchQuery.tokens(in: state.query).contains("board:\"\(board.name)\"")
    }

    /// Paste-style filter chips under the search field: kind, date and the
    /// apps you copy from most. Selecting a chip and typing its token are the
    /// same filter.
    private var searchSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AOMSpace.x1) {
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    quickChip(kind.displayName, icon: symbol(kind), selected: state.kind == kind,
                              help: "Only \(kind.displayName.lowercased()) items (type:\(kind.rawValue))") {
                        state.kind = state.kind == kind ? nil : kind
                    }
                }
                Divider().frame(height: AOMSpace.x4)
                ForEach([1, -7, 30], id: \.self) { code in
                    quickChip(ClipboardPanelState.dateFilterTitle(code), icon: "calendar", selected: state.recentDays == code,
                              help: "Copied \(ClipboardPanelState.dateFilterTitle(code).lowercased())") {
                        state.recentDays = state.recentDays == code ? 0 : code
                    }
                }
                if state.recentDays != 0, ![1, -7, 30].contains(state.recentDays) {
                    quickChip(ClipboardPanelState.dateFilterTitle(state.recentDays), icon: "calendar", selected: true, help: "Date filter") {
                        state.recentDays = 0
                    }
                }
                if !sources.isEmpty { Divider().frame(height: AOMSpace.x4) }
                ForEach(chipSources) { source in
                    quickChip(source.name, icon: nil, appIcon: AppMetadataCache.shared.icon(for: source.bundleID),
                              selected: state.source == source.filterValue,
                              help: "Copied from \(source.name) (from:\"\(source.name)\")") {
                        state.source = state.source == source.filterValue ? nil : source.filterValue
                    }
                }
                ForEach(filterSuggestions, id: \.self) { token in
                    Button("+ " + token) { state.query = ClipboardSearchQuery.inserting(token: token, into: state.query); state.searchFocusToken = UUID() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                if state.query.isEmpty {
                    ForEach(state.recentSearches.prefix(3), id: \.self) { query in
                        Button(query) { state.query = query }.buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }.padding(.horizontal, AOMSpace.x6).padding(.bottom, AOMSpace.x1 + AOMSpace.x0_5)
        }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
    }
    /// The three most-used apps, plus the selected one if it is not among them.
    private var chipSources: [ClipboardStore.AppSource] {
        var top = Array(sources.prefix(3))
        if let selected = state.source, !top.contains(where: { $0.filterValue == selected }),
           let source = sources.first(where: { $0.filterValue == selected }) { top.append(source) }
        return top
    }

    /// One filter under the search field: the shared filter chip, with a
    /// resting fill so it reads as a button on the glass shelf.
    private func quickChip(_ title: String, icon: String?, appIcon: NSImage? = nil, selected: Bool,
                           help: String, action: @escaping () -> Void) -> some View {
        AOMFilterChip(title, symbol: icon, appIcon: appIcon, selected: selected, filled: true, showsClear: true,
                      help: help, action: action)
    }
    /// Token completions, only while a token is being typed ("from:Sa…").
    private var filterSuggestions: [String] {
        let suffix = state.query.last?.isWhitespace == true ? "" : (ClipboardSearchQuery.editableText(in: state.query).split(separator: " ").last.map(String.init) ?? "")
        guard suffix.contains(":") else { return [] }
        let all = ClipboardEntry.Kind.allCases.map { "type:" + $0.rawValue }
            + store.availableAppSources.prefix(6).map { "from:\"" + $0.name + "\"" }
            + store.boards.prefix(6).map { "board:\"" + $0.name + "\"" }
        return Array(all.filter { !state.query.contains($0) && $0.localizedCaseInsensitiveContains(suffix) }.prefix(7))
    }

    private var headerBar: some View {
        GeometryReader { geometry in
        HStack(spacing: AOMSpace.x3) {
            Spacer(minLength: AOMSpace.x8)
            HStack(spacing: AOMSpace.x3) {
                HStack(spacing: AOMSpace.x2) {
                Button { state.searchFocusToken = UUID() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(AOMFont.pageStatus.weight(.regular))
                        .frame(width: AOMIcon.hitArea + AOMSpace.x0_5, height: AOMIcon.hitArea + AOMSpace.x0_5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search Clipboard (⌘F)")
                .accessibilityLabel("Search Clipboard")
                if state.searchExpanded {
                    if !ClipboardSearchQuery.filterTokens(in: state.query).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AOMSpace.x1) {
                                ForEach(ClipboardSearchQuery.filterTokens(in: state.query), id: \.self) { token in
                                    ClipboardSearchTokenChip(token: token, update: { edited in
                                        state.query = ClipboardSearchQuery.replacing(token: token, with: edited, in: state.query)
                                        state.searchFocusToken = UUID()
                                    }, remove: {
                                        state.query = ClipboardSearchQuery.removing(token: token, from: state.query)
                                        state.searchFocusToken = UUID()
                                    })
                                }
                            }
                        }.frame(maxWidth: AOMFeatureSize.shelfTokenStrip)
                    }
                    TextField("Search Clipboard", text: Binding(
                        get: { ClipboardSearchQuery.editableText(in: state.query) },
                        set: { state.query = ClipboardSearchQuery.updatingEditableText($0, in: state.query) }))
                        .textFieldStyle(.plain)
                        .font(AOMFont.body)
                        .focused($searchFocused)
                        .frame(width: min(AOMFeatureSize.shelfSearchField.upperBound,
                                          max(AOMFeatureSize.shelfSearchField.lowerBound, geometry.size.width * 0.28)))
                        .accessibilityIdentifier("PasteStyleClipboardSearch")
                        .help("Search titles, text, apps and image text. Use quotes for phrases, -word to exclude, from:Safari, board:Work, type:image, after:2026-01-01.")
                        .onSubmit {
                            state.rememberSearch()
                            searchFocused = false
                            if let first = entries.first { state.select(first.id, in: entries) }
                        }
                    if store.indexingImages {
                        ProgressView().controlSize(.mini).help("Indexing image text…")
                    }
                    if !state.query.isEmpty || hasFilters {
                        Text(resultsLabel)
                            .font(AOMFont.caption).monospacedDigit().foregroundStyle(AOMColor.textSecondary).fixedSize()
                            .help(state.searchesAllLists(in: store)
                                  ? "Search looks through Clipboard History and every pinboard. Add board:Name to search one pinboard."
                                  : "Results in the list on screen")
                    }
                    Button {
                        state.query = ""
                        state.searchExpanded = false
                        searchFocused = false
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AOMColor.textSecondary) }
                    .buttonStyle(.plain)
                    .help("Close Search")
                    Button { state.filtersExpanded.toggle() } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(hasFilters ? AOMColor.accent : AOMColor.textSecondary)
                            .frame(width: AOMIcon.hitArea - AOMSpace.x0_5, height: AOMIcon.hitArea)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Filters")
                    .accessibilityLabel("Filters")
                    .popover(isPresented: $state.filtersExpanded, arrowEdge: .top) { filterPopover }
                }
                }
                .padding(.horizontal, state.searchExpanded ? AOMSpace.x2 : 0)
                .frame(height: AOMFeatureSize.barControlHeight + AOMSpace.x0_5)
                .background(state.searchExpanded ? AOMColor.sunken : Color.clear, in: Capsule())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AOMSpace.x3) {
                        boardButton("Clipboard", color: AOMColor.textSecondary, icon: "clock.arrow.circlepath", id: nil)
                        ForEach(store.boards) { board in
                            boardButton(board.name, color: PasteClipboardPalette.board(board.color), icon: nil, id: board.id)
                                .contextMenu {
                                    Button("Rename") {
                                        state.editor = .init(operation: .renameBoard(board.id), title: "Rename Pinboard", text: board.name)
                                    }
                                    Button("Delete…", role: .destructive) { boardPendingDeletion = board }
                                    Divider()
                                    ForEach(PasteClipboardPalette.boardColors, id: \.self) { color in
                                        Button { store.setBoardColor(id: board.id, color: color) } label: {
                                            Label {
                                                Text(color.capitalized)
                                            } icon: {
                                                Image(nsImage: PasteClipboardPalette.swatch(color, selected: board.color == color))
                                            }
                                        }
                                    }
                                }
                        }
                        Button {
                            state.editor = .init(operation: .newBoard, title: "New Pinboard", text: "")
                        } label: {
                            Image(systemName: "plus").font(AOMFont.pageStatus.weight(.regular))
                                .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add Pinboard (⇧⌘N)")
                        .accessibilityLabel("Add Pinboard")
                    }
                    .padding(.horizontal, AOMSpace.x1)
                    .background(NativeScrollChrome(.hidden))
                }
                .scrollIndicators(.hidden)
                .frame(width: pinboardScrollWidth(containerWidth: geometry.size.width))
            }
            Spacer(minLength: AOMSpace.x8)
        }
        .overlay(alignment: .trailing) {
            Menu {
                Button("New Text Item") { state.editor = .init(operation: .newText, title: "New Text Item", text: "") }
                Button("New Pinboard…") { state.editor = .init(operation: .newBoard, title: "New Pinboard", text: "") }
                Divider()
                Button("Paste Stack") { controller.showStack() }
                Button("Add Selection to Paste Stack") { controller.enqueueSelection() }
                    .disabled(state.selected.isEmpty)
                Divider()
                Menu("Filters") {
                    compactTypeMenu
                    compactAppMenu
                    compactTimeMenu
                    if hasFilters {
                        Divider()
                        Button("Clear Filters") { state.kind = nil; state.source = nil; state.recentDays = 0 }
                    }
                }
                Button("Undo Delete") {
                    let restored = store.undoDeletion()
                    state.selected = Set(restored)
                    state.focusedID = restored.first
                }.disabled(!store.canUndoDeletion)
                Button("Erase History…") { controller.confirmEraseHistory() }
                    .disabled(!store.entries.contains { $0.pinboardIDs.isEmpty })
                Divider()
                Button("Settings…") { controller.openSettings() }
                Divider()
                if store.paused {
                    Button("Resume Clipboard History") { controller.togglePause() }
                } else {
                    Menu("Pause Clipboard History") {
                        Button("For 5 Minutes") { controller.pause(for: 5) }
                        Button("For 15 Minutes") { controller.pause(for: 15) }
                        Button("For 1 Hour") { controller.pause(for: 60) }
                        Button("For 8 Hours") { controller.pause(for: 480) }
                        Divider()
                        Button("Until Resumed") { controller.pause(for: nil) }
                    }
                }
                Button("Close") { controller.hide() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AOMFont.pageStatus)
                    .foregroundStyle(store.paused || state.kind != nil || state.source != nil || state.recentDays != 0 ? AOMColor.accent : AOMColor.text)
                    .frame(width: AOMIcon.hitArea + AOMSpace.x0_5, height: AOMIcon.hitArea + AOMSpace.x0_5)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Clipboard Options and Filters")
        }
        .padding(.horizontal, AOMSpace.x5)
        .frame(height: AOMSize.rowDetail)
        }
        .frame(height: AOMSize.rowDetail)
        .accessibilityIdentifier("PasteStyleClipboardToolbar")
    }

    private func boardButton(_ name: String, color: Color, icon: String?, id: UUID?) -> some View {
        Button {
            state.selectBoard(id)
        } label: {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                if let icon {
                    Image(systemName: icon)
                        .font(AOMFont.caption)
                        .foregroundStyle(state.board == id ? AOMColor.text : AOMColor.textSecondary)
                } else {
                    Circle().fill(color).frame(width: AOMFeatureSize.chipDot + AOMSpace.x1, height: AOMFeatureSize.chipDot + AOMSpace.x1)
                }
                if !state.searchExpanded {
                Text(name)
                    .font(state.board == id ? AOMFont.body.weight(.medium) : AOMFont.body)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: AOMIcon.hitArea + AOMSpace.x0_5)
            .background(state.board == id
                        ? AOMColor.sunken
                        : Color.clear,
                        in: Capsule())
            .foregroundStyle(state.board == id ? AOMColor.text : AOMColor.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityIdentifier("PasteStylePinboard_\(id?.uuidString ?? "clipboard-history")")
        .accessibilityAddTraits(state.board == id ? [.isSelected] : [])
        .onDrag {
            let provider = NSItemProvider()
            if let id { provider.registerDataRepresentation(forTypeIdentifier: PasteClipboardDrag.boardType, visibility: .ownProcess) { done in done(Data(id.uuidString.utf8), nil); return nil } }
            return provider
        }
        .onDrop(of: [PasteClipboardDrag.entryType, PasteClipboardDrag.boardType], isTargeted: nil) { providers in
            if let id, let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(PasteClipboardDrag.boardType) }) {
                provider.loadDataRepresentation(forTypeIdentifier: PasteClipboardDrag.boardType) { data, _ in
                    guard let data, let raw = String(data: data, encoding: .utf8), let moved = UUID(uuidString: raw) else { return }
                    Task { @MainActor in store.moveBoard(moved, before: id) }
                }
                return true
            }
            guard let id, let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(PasteClipboardDrag.entryType)
            }) else { return false }
            // Paste: dragging a card from one pinboard onto another moves it;
            // holding ⌥ copies (a separate copy while each item stays on one
            // pinboard). Dragging out of History always adds.
            let sourceBoard = state.board
            let copies = NSEvent.modifierFlags.contains(.option)
            provider.loadDataRepresentation(forTypeIdentifier: PasteClipboardDrag.entryType) {
                data, _ in
                guard let data, let raw = String(data: data, encoding: .utf8),
                      let entryID = UUID(uuidString: raw) else { return }
                Task { @MainActor in
                    if copies {
                        store.copy(entryID: entryID, toBoard: id)
                    } else {
                        store.pin(entryID: entryID, boardID: id)
                        if let sourceBoard, sourceBoard != id { store.unpin(entryID: entryID, boardID: sourceBoard) }
                    }
                }
            }
            return true
        }
    }

    private var hasFilters: Bool { state.kind != nil || state.source != nil || state.recentDays != 0 }

    private var resultsLabel: String {
        let count = entries.count == 1 ? "1 result" : "\(entries.count) results"
        return state.searchesAllLists(in: store) ? count + " in all lists" : count
    }

    private var filterPopover: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: AOMSpace.x1 + AOMSpace.x0_5), count: 3)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.x3) {
                HStack {
                    Text("Filters").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                    Spacer()
                    Button("Clear") { state.kind = nil; state.source = nil; state.recentDays = 0 }
                        .buttonStyle(.plain).foregroundStyle(AOMColor.accent).disabled(!hasFilters)
                }
                filterSection("Type")
                LazyVGrid(columns: columns, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    ForEach(ClipboardEntry.Kind.allCases) { kind in
                        filterChip(kind.displayName, icon: symbol(kind), selected: state.kind == kind) {
                            state.kind = state.kind == kind ? nil : kind
                        }
                    }
                }
                if !sources.isEmpty {
                    filterSection("App")
                    LazyVGrid(columns: columns, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                        ForEach(sources) { source in
                            filterChip(source.name, icon: nil,
                                       appIcon: AppMetadataCache.shared.icon(for: source.bundleID),
                                       selected: state.source == source.filterValue) {
                                state.source = state.source == source.filterValue ? nil : source.filterValue
                            }
                            .help("\(source.name) · \(source.count) saved clips")
                        }
                    }
                }
                if !store.boards.isEmpty {
                    filterSection("Pinboard")
                    LazyVGrid(columns: columns, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                        ForEach(store.boards) { board in
                            filterChip(board.name, icon: nil, dot: PasteClipboardPalette.board(board.color),
                                       selected: boardFilterSelected(board)) {
                                toggleBoardFilter(board)
                            }
                        }
                    }
                }
                filterSection("Date")
                LazyVGrid(columns: columns, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    ForEach(ClipboardPanelState.dateFilters, id: \.code) { filter in
                        filterChip(filter.title, icon: "calendar", selected: state.recentDays == filter.code) {
                            state.recentDays = state.recentDays == filter.code ? 0 : filter.code
                        }
                    }
                }
            }.padding(AOMSpace.x4)
        }
        .frame(width: AOMFeatureSize.shelfFilterPopover.width).frame(maxHeight: AOMFeatureSize.shelfFilterPopover.height)
    }

    private func filterSection(_ title: String) -> some View {
        Text(title).font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary).padding(.top, AOMSpace.x1)
    }

    /// A choice in the Filters popover grid: the shared filter chip, full
    /// width in its cell. Pinboards show their colour, apps their icon.
    private func filterChip(_ title: String, icon: String?, appIcon: NSImage? = nil, dot: Color? = nil,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        AOMFilterChip(title, symbol: icon ?? (appIcon == nil && dot == nil ? "app" : nil), appIcon: appIcon, dot: dot,
                      selected: selected, filled: true, expands: true, action: action)
    }

    // MARK: - Filters in the overflow menu

    private var compactTypeMenu: some View {
        Menu("Type") {
            Button("All Types") { state.kind = nil }
            Divider()
            ForEach(ClipboardEntry.Kind.allCases) { kind in
                Button { state.kind = kind } label: {
                    HStack {
                        Text(kind.displayName)
                        if state.kind == kind { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    private var compactAppMenu: some View {
        Menu("App") {
            Button("All Apps") { state.source = nil }
            Divider()
            ForEach(sources) { source in
                Button { state.source = source.filterValue } label: {
                    HStack {
                        if let appIcon = AppMetadataCache.shared.icon(for: source.bundleID) {
                            Image(nsImage: appIcon).resizable().scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                        } else {
                            Image(systemName: "app")
                        }
                        Text(source.name)
                        if state.source == source.filterValue { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    private var compactTimeMenu: some View {
        Menu("Date") {
            Button("Any Time") { state.recentDays = 0 }
            Divider()
            ForEach(ClipboardPanelState.dateFilters, id: \.code) { filter in
                Button { state.recentDays = filter.code } label: {
                    HStack {
                        Text(filter.title)
                        if state.recentDays == filter.code { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    // MARK: - Resizable timeline / automatic compact mode

    private var carouselContent: some View {
        GeometryReader { geometry in
            let _ = entries // Start a pending search before choosing its progress state.
            let compact = geometry.size.height < 205
            let cardSide = min(240, max(100, geometry.size.height - (compact ? AOMSpace.x6 : AOMSpace.x10 + AOMSpace.x1)))
            Group {
                if state.isSearchPending {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    // The shelf's empty state: ContentUnavailableView's anatomy
                    // (symbol, title, one sentence, at most one action) sized
                    // for a panel that can be shorter than its 40 pt glyph needs.
                    VStack(spacing: AOMSpace.x2) {
                        Image(systemName: isFiltering ? "magnifyingglass" : state.board == nil ? "clipboard" : "pin")
                            .font(AOMFont.hero.weight(.regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AOMColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(store.isLoading ? "Loading Clipboard…" : emptyTitle)
                            .font(AOMFont.headline)
                            .foregroundStyle(AOMColor.text)
                        Text(emptyMessage)
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .multilineTextAlignment(.center)
                        // One quiet action per state: fix a broken store, or
                        // resume recording; a merely empty history stays text-only.
                        if !store.isLoading && !isFiltering && state.board == nil {
                            if store.storageStatus != .ok {
                                Button("Open Clipboard Settings…") { controller.openSettings() }
                                    .buttonStyle(.bordered).controlSize(.small)
                            } else if store.paused {
                                Button("Resume") { controller.togglePause() }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let entries = self.entries
                    let spacing: CGFloat = compact ? AOMSpace.x3 - AOMSpace.x0_5 : AOMSpace.x3 + AOMSpace.x0_5
                    let quickIDs = state.quickPasteIDs(in: store)
                    let suggested = Set(state.suggestedIDs)
                    let boards = store.boards
                    let linkCards = preferences.networkPreviews && preferences.linkCards
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: spacing) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    ClipboardCardView(entry: entry, revision: store.revision, number: index + 1,
                                                      compact: compact, side: cardSide,
                                                      isSelected: state.selected.contains(entry.id),
                                                      quickNumber: quickIDs.firstIndex(of: entry.id).map { $0 + 1 },
                                                      showsQuickNumber: state.commandHeld,
                                                      searchActive: state.searchFieldActive,
                                                      searchQuery: state.query,
                                                      isPreviewing: state.preview?.id == entry.id,
                                                      isSuggested: suggested.contains(entry.id),
                                                      boards: boards,
                                                      linkCards: linkCards,
                                                      store: store, state: state, controller: controller)
                                        .equatable()
                                        .id(entry.id)
                                        .modifier(ClipboardLegacyVisibilityProbe(id: entry.id))
                                }
                            }
                            .padding(.horizontal, Self.shelfInset)
                            .padding(.top, compact ? AOMSpace.x2 : AOMSpace.x3)
                            .padding(.bottom, compact ? AOMSpace.x3 : AOMSpace.x6)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                            .background(NativeScrollChrome(.hidden))
                        }
                        .coordinateSpace(name: "clipboardViewport")
                        .modifier(ClipboardVisibleRangeTracker(
                            ids: entries.map(\.id), pitch: cardSide + spacing, side: cardSide,
                            inset: Self.shelfInset, viewportWidth: geometry.size.width, state: state))
                        .scrollIndicators(.hidden)
                        .background(NativeScrollChrome(.hidden))
                        .id(state.board?.uuidString ?? "clipboard-history")
                        .onChange(of: state.keyboardScrollTarget) { _, id in
                            guard let id else { return }
                            searchFocused = false
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    static let shelfInset: CGFloat = 18

    private var isFiltering: Bool { !state.query.isEmpty || hasFilters }
    /// A storage failure is reported before "empty" (audit 2026-10-28 F08).
    private var storageContent: ClipboardEmptyContent {
        ClipboardEmptyContent.resolve(isLoading: store.isLoading, storage: store.storageStatus, paused: store.paused)
    }
    private var emptyTitle: String {
        if isFiltering { return "Nothing found" }
        if state.board != nil { return "Pinboard is empty" }
        // Loading and storage problems say so; only a real empty history is "empty".
        if case .empty = storageContent { return "History is empty" }
        return storageContent.title
    }
    private var emptyMessage: String {
        if isFiltering { return "Try another search or clear the filters." }
        if state.board != nil { return "Drag items onto this Pinboard, or use Pin in a card's menu." }
        return storageContent.compactMessage
    }

    private func symbol(_ kind: ClipboardEntry.Kind) -> String {
        switch kind { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .file: return "doc"; case .color: return "paintpalette" }
    }


}

// MARK: - App Metadata & Banner Color Cache

@MainActor
final class AppMetadataCache {
    static let shared = AppMetadataCache()
    private var iconCache: [String: NSImage] = [:]
    /// Uninstalled source apps: LaunchServices lookups are not free, so a
    /// miss is remembered instead of repeated for every card render.
    private var missingIcons = Set<String>()
    private var fileIconCache: [String: NSImage] = [:]

    func fileIcon(for url: URL) -> NSImage {
        if let cached = fileIconCache[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if fileIconCache.count > 300 { fileIconCache.removeAll() }
        fileIconCache[url.path] = icon
        return icon
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        if missingIcons.contains(bundleID) { return nil }

        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            image = app.icon
        }

        if let image {
            iconCache[bundleID] = image
            return image
        }
        missingIcons.insert(bundleID)
        return nil
    }

    private var colorCache: [String: Color] = [:]

    /// Paste paints the card header with the source app's icon colour.
    /// The dominant saturated hue of the real icon is used, darkened enough
    /// for white header text; a small curated map remains the fallback.
    func bannerColor(for bundleID: String?, name: String?) -> Color {
        let key = (bundleID ?? name ?? "").lowercased()
        if let cached = colorCache[key] { return cached }
        let color = icon(for: bundleID).flatMap(Self.dominantColor(of:)) ?? fallbackBanner(key)
        colorCache[key] = color
        return color
    }

    static func dominantColor(of image: NSImage) -> Color? {
        // Raw RGBA bytes from one 24×24 draw; NSBitmapImageRep.colorAt plus a
        // colour-space conversion per pixel made the first shelf open stall.
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: rect)
        var bins = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        var gray: (weight: CGFloat, value: CGFloat) = (0, 0)
        for i in 0..<(side * side) {
            let alpha = CGFloat(pixels[i * 4 + 3]) / 255
            guard alpha > 0.6 else { continue }
            let r = CGFloat(pixels[i * 4]) / 255 / alpha, g = CGFloat(pixels[i * 4 + 1]) / 255 / alpha
            let bl = CGFloat(pixels[i * 4 + 2]) / 255 / alpha
            let maxC = max(r, g, bl), minC = min(r, g, bl)
            let v = maxC, sat = maxC > 0 ? (maxC - minC) / maxC : 0
            if sat < 0.22 || v < 0.12 {
                gray.weight += 1; gray.value += v
                continue
            }
            var h: CGFloat
            let d = maxC - minC
            if maxC == r { h = (g - bl) / d } else if maxC == g { h = 2 + (bl - r) / d } else { h = 4 + (r - g) / d }
            h /= 6; if h < 0 { h += 1 }
            let weight = sat * v
            let index = min(11, Int(h * 12))
            bins[index].weight += weight
            bins[index].r += r * weight; bins[index].g += g * weight; bins[index].b += bl * weight
        }
        let best = bins.max { $0.weight < $1.weight }!
        let colorful = best.weight > 0 && best.weight * 2.2 > gray.weight * 0.35
        let base: NSColor
        if colorful {
            base = NSColor(deviceRed: best.r / best.weight, green: best.g / best.weight, blue: best.b / best.weight, alpha: 1)
        } else if gray.weight > 0 {
            let v = gray.value / gray.weight
            let w = min(0.42, max(0.18, v * 0.55))
            base = NSColor(deviceRed: w, green: w, blue: w, alpha: 1)
        } else { return nil }
        // Keep white title text legible (Paste's headers are mid-tone).
        let hue = base.hueComponent, sat = base.saturationComponent
        let brightness = min(base.brightnessComponent, colorful ? 0.82 : 0.42)
        let adjusted = NSColor(deviceHue: hue, saturation: colorful ? max(sat, 0.45) : sat,
                               brightness: max(brightness, 0.2), alpha: 1)
        return Color(nsColor: adjusted)
    }

    private func fallbackBanner(_ key: String) -> Color {
        if key.contains("terminal") || key.contains("iterm") {
            return Color(red: 0.16, green: 0.18, blue: 0.22)
        } else if key.contains("chrome") {
            return Color(red: 0.25, green: 0.52, blue: 0.96)
        } else if key.contains("safari") {
            return Color(red: 0.00, green: 0.48, blue: 0.98)
        } else if key.contains("zen") {
            return Color(red: 0.48, green: 0.18, blue: 0.72)
        } else if key.contains("textedit") {
            return Color(red: 0.86, green: 0.46, blue: 0.32)
        } else if key.contains("xcode") {
            return Color(red: 0.08, green: 0.46, blue: 0.94)
        } else if key.contains("finder") {
            return Color(red: 0.00, green: 0.50, blue: 0.95)
        } else if key.contains("slack") {
            return Color(red: 0.32, green: 0.10, blue: 0.32)
        } else if key.contains("discord") {
            return Color(red: 0.35, green: 0.40, blue: 0.92)
        } else if key.contains("notes") {
            return Color(red: 0.97, green: 0.81, blue: 0.02)
        } else if key.contains("paste") {
            return Color(red: 0.92, green: 0.30, blue: 0.42)
        } else if key.contains("code") || key.contains("cursor") {
            return Color(red: 0.12, green: 0.40, blue: 0.76)
        }

        return Color(red: 0.51, green: 0.51, blue: 0.51)
    }
}

private extension Color {
    init?(hex: String) {
        guard let color = ClipboardColorEditor.color(hex) else { return nil }
        self.init(nsColor: color)
    }
}

/// Bounded first-line extraction for card headers. Finding the newline before
/// taking a prefix walks an entire multi-megabyte single-line clip on each draw.
enum ClipboardCardText {
    static func automaticTitle(_ text: String) -> String {
        // A clip consisting mostly of whitespace must be bounded too. If
        // its real title is farther away, the card uses the stored title
        // already derived by background capture instead of rescanning it.
        guard let start = text.prefix(4_096).firstIndex(where: { !$0.isWhitespace }) else { return "Text" }
        let rest = text[start...]
        let prefix = rest.prefix(101)
        let end = prefix.firstIndex(where: \.isNewline) ?? prefix.endIndex
        var line = prefix[..<end]
        if end == text.endIndex {
            while let last = line.last, last.isWhitespace { line = line.dropLast() }
        }
        return String(line.prefix(100))
    }
}

// MARK: - Paste-style Luxury Card View

@MainActor
private struct ClipboardCardView: View, Equatable {
    let entry: ClipboardEntry
    /// Store revision: content edits (rename, pin, OCR, image edit) bump it,
    /// so equality never has to compare megabytes of pasteboard data.
    let revision: Int
    let number: Int
    let compact: Bool
    let side: CGFloat
    // Plain values: a card re-renders only when its own inputs change, not on
    // every scroll-driven or unrelated panel update (that made scrolling and
    // clicks lag behind Paste's).
    let isSelected: Bool
    let quickNumber: Int?
    let showsQuickNumber: Bool
    let searchActive: Bool
    let searchQuery: String
    let isPreviewing: Bool
    let isSuggested: Bool
    let boards: [ClipboardPinboard]
    /// Both link-card switches are on: link cards may look pages up.
    let linkCards: Bool
    // Action targets only; deliberately not observed.
    let store: ClipboardStore
    let state: ClipboardPanelState
    let controller: ClipboardPanelController

    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var imagePreview: ClipboardThumbnailCache.Preview?
    @State private var characterCount: Int?
    @FocusState private var titleFocused: Bool

    /// Paste-style cards, on the card radius every surface shares (c.3).
    static let radius: CGFloat = AOMRadius.card

    /// Hover, selection and scrolling elsewhere in the shelf leave unchanged
    /// cards alone instead of re-running every visible card body.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id == rhs.entry.id && lhs.revision == rhs.revision && lhs.number == rhs.number
            && lhs.compact == rhs.compact && lhs.side == rhs.side && lhs.isSelected == rhs.isSelected
            && lhs.quickNumber == rhs.quickNumber && lhs.showsQuickNumber == rhs.showsQuickNumber
            && lhs.searchActive == rhs.searchActive && lhs.searchQuery == rhs.searchQuery && lhs.isPreviewing == rhs.isPreviewing
            && lhs.isSuggested == rhs.isSuggested && lhs.boards == rhs.boards && lhs.linkCards == rhs.linkCards
    }

    private var accent: Color { AppMetadataCache.shared.bannerColor(for: entry.sourceBundleID, name: entry.sourceName) }
    private var headerTitle: String {
        if let text = entry.text {
            return entry.title == Self.automaticTitle(text) ? entry.kind.displayName : entry.title
        }
        if entry.kind == .file, entry.title == entry.fileURLs.map(\.lastPathComponent).joined(separator: ", ") {
            return entry.fileURLs.count == 1 ? "File" : "\(entry.fileURLs.count) Files"
        }
        return entry.title
    }
    private var appIcon: NSImage? {
        AppMetadataCache.shared.icon(for: entry.sourceBundleID)
    }

    /// The title `ClipboardEntry.captured` derives (first non-empty line,
    /// 100 characters) without trimming or splitting the whole clip.
    static func automaticTitle(_ text: String) -> String {
        ClipboardCardText.automaticTitle(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            // One header line (3.3.5, was the kind over the time): the kind,
            // then the time, then the source app's icon at the trailing edge.
            HStack(alignment: .center, spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x1) {
                    if isEditingTitle {
                        TextField("Title", text: $editedTitle)
                            .textFieldStyle(.plain).focused($titleFocused)
                            .onSubmit { commitTitle() }.onExitCommand { cancelTitle() }
                            .onChange(of: titleFocused) { _, focused in
                                if !focused && isEditingTitle { commitTitle() }
                            }
                    } else {
                        HStack(spacing: AOMSpace.x1) {
                            if isSuggested {
                                Image(systemName: "sparkles").font((compact ? AOMFont.badge : AOMFont.caption).weight(.semibold))
                                    .help("Suggested for the app you are pasting into")
                                    .accessibilityLabel("Suggested")
                            }
                            Text(headerTitle).font((compact ? AOMFont.caption : AOMFont.callout).weight(.semibold)).lineLimit(1)
                        }
                    }
                    // "16 minutes ago", refreshed while the shelf is open.
                    TimelineView(.everyMinute) { context in
                        Text(ClipboardRelativeDate.string(entry.lastCopiedAt, now: context.date))
                            .font(compact ? AOMFont.badge : AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                    }
                }
                .padding(.leading, compact ? AOMSpace.x2 : AOMSpace.x3)
                // Room for the app icon drawn over the trailing edge.
                Spacer(minLength: AOMIcon.row + AOMSpace.x4)
            }
            .foregroundStyle(AOMColor.text)
            .frame(height: compact ? ShelfCardMetrics.headerCompact : ShelfCardMetrics.header)
            .background(AOMColor.sunken)
            .overlay(alignment: .trailing) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFill()
                        .frame(width: AOMIcon.row + AOMSpace.x0_5, height: AOMIcon.row + AOMSpace.x0_5)
                        .padding(.trailing, AOMSpace.x3 - AOMSpace.x0_5).help(entry.sourceName ?? "Source App")
                }
            }
            .clipped()

            ZStack(alignment: .bottom) {
                if entry.kind == .image || entry.kind == .color { TransparencyGrid() }
                else { AOMColor.raised }
                previewContent
                    .overlay(alignment: .bottomLeading) {
                        if let ocr = entry.recognizedText, !searchQuery.isEmpty,
                           ClipboardSearchQuery(searchQuery).highlightValues.contains(where: { ocr.localizedStandardContains($0) }) {
                            Text(ClipboardSearchQuery(searchQuery).highlighted(ocr, limit: 220))
                                .font(AOMFont.caption).lineLimit(3).padding(AOMSpace.x1 + AOMSpace.x0_5)
                                .aomMediaBadge(radius: AOMRadius.control)
                                .padding(AOMSpace.x1 + AOMSpace.x0_5).allowsHitTesting(false)
                        }
                    }
                    .padding(entry.kind == .image || entry.kind == .color ? 0 : compact ? AOMSpace.x2 : AOMSpace.x3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // A solid-colour fade is far cheaper than a per-card mask.
                        if entry.kind == .text || entry.kind == .link {
                            LinearGradient(colors: [AOMColor.raised.opacity(0), AOMColor.raised],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: AOMSpace.x8).allowsHitTesting(false)
                        }
                    }
                if entry.kind == .image, !compact || side >= 150 {
                    HStack {
                        Spacer()
                        Text(metadataLabel).font(AOMFont.caption.weight(.medium)).monospacedDigit().lineLimit(1)
                            .padding(.horizontal, AOMSpace.x1 + AOMSpace.x0_5).frame(height: AOMIcon.row)
                            .aomMediaBadge()
                    }.padding(AOMSpace.x2).allowsHitTesting(false)
                } else if ![.color, .image, .link].contains(entry.kind) {
                    HStack(spacing: AOMSpace.x1) {
                        Spacer(minLength: 0)
                        Text(metadataLabel).font(compact ? AOMFont.badge : AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                            .truncationMode(entry.kind == .file ? .head : .tail)
                        if entry.kind != .image { Spacer(minLength: 0) }
                        if isHovered && entry.kind != .image {
                            Button { beginTitleEdit() } label: { Image(systemName: "pencil").font(AOMFont.badge) }
                                .buttonStyle(.plain).help("Rename Item")
                        }
                    }
                    .padding(.horizontal, AOMSpace.x3 - AOMSpace.x0_5).padding(.bottom, AOMSpace.x2).padding(.top, AOMSpace.x4)
                    .background {
                        if entry.kind != .image {
                            LinearGradient(colors: [AOMColor.raised.opacity(0), AOMColor.raised],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .allowsHitTesting(isHovered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .modifier(ClipboardCardDrag(entry: entry, provider: { dragProvider(entry) }))
            .onDrop(of: [PasteClipboardDrag.entryType], isTargeted: nil) { providers in
                guard let board = state.board, let provider = providers.first else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: PasteClipboardDrag.entryType) { data, _ in
                    guard let data, let raw = String(data: data, encoding: .utf8), let moved = UUID(uuidString: raw) else { return }
                    Task { @MainActor in store.moveItem(moved, before: entry.id, in: board) }
                }
                return true
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if showsQuickNumber, let quickNumber {
                Text("\(ClipboardPreferences.shared.quickModifier.symbol)\(quickNumber)")
                    .font(AOMFont.callout.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, AOMSpace.x2).padding(.vertical, AOMSpace.x1)
                    .aomMediaBadge(radius: AOMRadius.control)
                    .padding(AOMSpace.x2).allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(AOMColor.hairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // Paste draws a 4 pt ring outside the card: accent while the shelf has
        // focus, gray while typing in the search field.
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.radius + AOMSpace.x1, style: .continuous)
                    .strokeBorder(searchActive ? AOMColor.textSecondary : AOMColor.accent, lineWidth: AOMSpace.x0_5)
                    .padding(-AOMSpace.x0_5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        // Paste selects on the first click immediately. An exclusive
        // double-tap gesture made every single click wait for the system
        // double-click interval (~0.5 s) before selecting; both recognisers
        // now run side by side, so the first click selects at once and the
        // second click of a double-click pastes.
        // One recognizer: the second click of a double-click pastes, every
        // other click selects. Two competing tap recognizers re-selected the
        // card on the pasting click (and toggled ⌘/extended ⇧ selections).
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { pasteByDoubleClick() } else { selectCard() }
        }
        .onHover { isHovered = $0 }
        .task(id: entry.contentVersion) {
            if entry.text != nil {
                // UTF-16 counting is linear for native non-ASCII strings.
                // A large Korean clip must not block the key/scroll loop.
                let content = await ClipboardPreviewCache.shared.content(for: entry)
                guard !Task.isCancelled else { return }
                characterCount = content.characterCount
            } else { characterCount = nil }
        }
        .task(id: entry.contentVersion) {
            guard let data = entry.imageData else { imagePreview = nil; return }
            let preview = await ClipboardThumbnailCache.shared.preview(id: entry.id, revision: entry.contentVersion, data: data)
            guard !Task.isCancelled else { return }
            imagePreview = preview
        }
        .popover(isPresented: Binding(
            get: { isPreviewing },
            set: { if !$0 && state.preview?.id == entry.id { controller.closePreview() } }
        ), attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ClipboardPreviewSheet(entry: entry, store: store, state: state, controller: controller)
        }
        .contextMenu { entryMenu(entry) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.kind.displayName): \(entry.title), \(entry.sourceName ?? "Unknown app")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("PasteStyleClipCard_\(entry.id.uuidString)")
    }

    private var metadataLabel: String {
        if entry.kind == .image { return imagePreview?.dimensions ?? "Image" }
        if entry.kind == .file {
            return entry.fileURLs.count == 1 ? Self.abbreviatedPath(entry.fileURLs[0]) : "\(entry.fileURLs.count) files"
        }
        if entry.kind == .link { return URL(string: entry.text ?? "")?.host ?? "Link" }
        guard entry.text != nil else { return "0 characters" }
        guard let characterCount else { return "Text" }
        return "\(characterCount.formatted()) characters"
    }

    @ViewBuilder
    private var previewContent: some View {
        if compact && side < 150 {
            if entry.kind == .color, let hex = entry.text {
                RoundedRectangle(cornerRadius: AOMRadius.keycap, style: .continuous)
                    .fill(Color(hex: hex) ?? .clear)
                    .overlay {
                        Text(hex).font(AOMFont.badge).monospaced()
                            .padding(.horizontal, AOMSpace.x1).aomMediaBadge(radius: AOMRadius.panel)
                    }
            } else if entry.kind == .image {
                thumbnailContent
            } else {
                Text(entry.kind == .link ? (URL(string: entry.text ?? "")?.host ?? entry.previewText) : entry.previewText)
                    .font(AOMFont.badge.weight(.regular))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if entry.kind == .image {
            thumbnailContent
        } else if entry.kind == .file {
            // Real Finder icons (stacked for several files), name below.
            VStack(spacing: AOMSpace.x2) {
                ZStack {
                    ForEach(Array(entry.fileURLs.prefix(3).enumerated().reversed()), id: \.offset) { offset, url in
                        Image(nsImage: AppMetadataCache.shared.fileIcon(for: url))
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(width: compact ? AOMFeatureSize.fileIcon - AOMSpace.x1 : AOMFeatureSize.fileIconLarge + AOMSpace.x3,
                                   height: compact ? AOMFeatureSize.fileIcon - AOMSpace.x1 : AOMFeatureSize.fileIconLarge + AOMSpace.x3)
                            .rotationEffect(.degrees(Double(offset) * -6))
                            .offset(x: CGFloat(offset) * 7, y: CGFloat(offset) * -3)
                    }
                }
                Text(entry.fileURLs.count == 1 ? (entry.fileURLs.first?.lastPathComponent ?? entry.title)
                     : "\(entry.fileURLs.first?.lastPathComponent ?? "") and \(entry.fileURLs.count - 1) more")
                    .font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, AOMSpace.x4 + AOMSpace.x0_5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entry.kind == .link {
            // Offline site tile unless link cards are on (P03); then the
            // page's title, site and image, fetched once per session.
            ClipboardLinkCardContent(entry: entry, compact: compact, side: side, accent: accent,
                                     title: linkTitle, userTitled: isUserTitledLink, fetches: linkCards)
        } else if entry.kind == .color, let hex = entry.text {
            Rectangle().fill(Color(hex: hex) ?? .clear)
                .overlay {
                    Text(hex).font((compact ? AOMFont.section : AOMFont.pageStatus).weight(.medium)).monospaced()
                        .foregroundStyle(AOMFeatureColor.onMedia)
                        .shadow(color: AOMFeatureColor.onMediaShadow, radius: 2, y: 1)
                }
        } else {
            // Lay out only what fits: a 4,000-character preview per card made
            // every scroll frame re-measure large text blocks.
            Text(ClipboardSearchQuery(searchQuery).highlighted(entry.previewText, limit: cardTextBudget))
                .font(compact ? AOMFont.caption : AOMFont.body)
                .lineSpacing(AOMSpace.x0_5)
                .lineLimit(cardLineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(AOMColor.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var linkTitle: String {
        let automatic = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.title != automatic, !entry.title.isEmpty { return entry.title }
        return URL(string: automatic ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
    }

    /// The user renamed this link; a fetched page title never replaces that.
    private var isUserTitledLink: Bool {
        !entry.title.isEmpty && entry.title != entry.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Paste head-truncates paths so the file name stays visible.
    static func abbreviatedPath(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    private var cardLineLimit: Int { max(2, Int((side - (compact ? 60 : 96)) / (compact ? 15 : 19))) }
    private var cardTextBudget: Int { cardLineLimit * (compact ? 40 : 48) }

    @ViewBuilder private var thumbnailContent: some View {
        if let image = imagePreview?.image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Paste highlights matching text inside images (P04).
                    if !searchQuery.isEmpty, let lines = entry.recognizedLines, !lines.isEmpty {
                        ClipboardImageMatchOverlay(lines: lines, terms: ClipboardSearchQuery(searchQuery).highlightValues,
                                                   imageSize: CGSize(width: image.width, height: image.height))
                    }
                }
        } else {
            Image(systemName: "photo").foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectCard() {
        guard !isEditingTitle else { return }
        controller.selectCard(entry.id, modifiers: NSEvent.modifierFlags)
    }

    private func pasteByDoubleClick() {
        guard !isEditingTitle else { return }
        controller.paste(ids: [entry.id],
                         plainText: ClipboardPreferences.shared.isPlain(NSEvent.modifierFlags), dismissAfterCopy: true)
    }

    private func beginTitleEdit() {
        editedTitle = entry.title
        isEditingTitle = true
        state.editingTitleID = entry.id
        titleFocused = true
    }

    private func cancelTitle() {
        isEditingTitle = false
        state.editingTitleID = nil
        titleFocused = false
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.rename(entryID: entry.id, title: trimmed) }
        isEditingTitle = false
        state.editingTitleID = nil
        titleFocused = false
    }

    private func symbol(_ kind: ClipboardEntry.Kind) -> String {
        switch kind { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .file: return "doc"; case .color: return "paintpalette" }
    }

    /// Paste 6.5 card menu: Paste to App ↩ · Paste as Plain Text ⇧↩ · Copy ⌘C |
    /// Edit ⌘E · Rename ⌘R · Delete ⌫ | Pin ▸ | Preview Space · Share ▸.
    /// AOM-only commands follow in their own section. With several cards
    /// selected, the paste/copy/pin/delete commands act on the whole selection.
    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry) -> some View {
        // The menu is built with the card body; keep it O(1) and resolve the
        // exact targets only when a command actually runs.
        let selectionCount = state.selected.contains(entry.id) ? state.selected.count : 1
        let many = selectionCount > 1
        let suffix = many ? " \(selectionCount) Items" : ""
        var targets: [UUID] { controller.actionTargets(for: entry) }
        Button("\(controller.pasteActionTitle)\(suffix)") {
            controller.paste(ids: targets, dismissAfterCopy: true)
        }.keyboardShortcut(.return, modifiers: [])
        Button("Paste as Plain Text") { controller.paste(ids: targets, plainText: true, dismissAfterCopy: true) }
            .keyboardShortcut(.return, modifiers: ClipboardPreferences.shared.plainModifier.eventModifiers)
            .disabled(!many && entry.text == nil && entry.fileURLs.isEmpty)
        Button("Copy\(suffix)") {
            do { _ = try store.write(entryIDs: targets); state.status = ClipboardPanelState.multiCopyStatus(count: targets.count) }
            catch { state.status = error.localizedDescription }
        }.keyboardShortcut("c", modifiers: .command)
        Divider()
        if !many {
            Button(entry.kind == .image ? "Edit Image…" : "Edit…") { controller.editEntry(entry) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(entry.kind == .file)
            if entry.kind == .image {
                Button("Remove Background") { controller.removeBackground(entry) }
            }
            Button("Rename…") { state.editor = .init(operation: .renameEntry(entry.id), title: "Rename Item", text: entry.title) }
                .keyboardShortcut("r", modifiers: .command)
        }
        Button("Delete\(suffix)", role: .destructive) {
            if many { state.pendingDeletion = targets } else { controller.delete(targets) }
        }.keyboardShortcut(.delete, modifiers: [])
        Divider()
        Menu(many ? "Pin \(selectionCount) Items" : (entry.pinboardIDs.isEmpty ? "Pin" : "Pinboards")) {
            ForEach(boards) { board in
                let pinned = !many && entry.pinboardIDs.contains(board.id)
                // One pinboard per item (Paste): pinning elsewhere moves it.
                let moves = !many && !pinned && !entry.pinboardIDs.isEmpty && store.settings.onePinboardPerItem
                Button {
                    let ids = targets
                    let allPinned = ids.allSatisfy { id in store.entries.first { $0.id == id }?.pinboardIDs.contains(board.id) == true }
                    var deleted = 0
                    for id in ids {
                        if allPinned { deleted += store.unpin(entryID: id, boardID: board.id) ? 1 : 0 }
                        else { store.pin(entryID: id, boardID: board.id) }
                    }
                    if deleted > 0 {
                        state.status = "Removed from \(board.name). \(deleted == 1 ? "It was" : "\(deleted) items were") older than your history limit, so \(deleted == 1 ? "it was" : "they were") deleted — ⌘Z brings \(deleted == 1 ? "it" : "them") back."
                    }
                } label: {
                    Label { Text(pinned ? "Unpin from \(board.name)" : moves ? "Move to \(board.name)" : board.name) } icon: {
                        Image(nsImage: PasteClipboardPalette.swatch(board.color, selected: pinned))
                    }
                }
            }
            if !boards.isEmpty { Divider() }
            Button("New Pinboard…") { state.editor = .init(operation: .newBoard, title: "New Pinboard", text: "") }
        }
        Divider()
        if !many {
            Button("Preview") { controller.openPreview(entry) }.keyboardShortcut(.space, modifiers: [])
            // Paste's Show In: the lists this item lives in, other than this one.
            let searching = state.isSearching
            ForEach(ClipboardPanelState.showInTargets(for: entry, viewing: state.board, searching: searching, boards: boards),
                    id: \.self) { target in
                Button("Show in \(target.flatMap { id in boards.first { $0.id == id }?.name } ?? "Clipboard")") {
                    state.showIn(target, entryID: entry.id)
                }
            }
            if !entry.fileURLs.isEmpty || entry.kind == .link {
                Button(entry.kind == .link ? "Open Link" : "Open") { controller.openExternally(entry) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            if !entry.fileURLs.isEmpty {
                Button("Reveal in Finder") { if !PresetManager.isUIPreview { NSWorkspace.shared.activateFileViewerSelecting(entry.fileURLs) } }
            }
            ShareLink(item: shareItem(entry)) { Text("Share…") }
            Divider()
        }
        Button(many ? "Add \(selectionCount) Items to Paste Stack" : "Add to Paste Stack") {
            for id in targets where !state.stack.contains(id) { state.stack.append(id) }
            controller.showStack()
        }
        if !many {
            if entry.kind == .image {
                Button("Copy Text from Image") {
                    do { try store.copyRecognizedText(entryID: entry.id); state.status = "Image text copied." }
                    catch { state.status = error.localizedDescription }
                }.disabled(entry.recognizedText?.isEmpty != false)
            }
            Button("Duplicate") { _ = store.duplicate(entryID: entry.id) }
        }
    }

    private static func imageRepresentation(_ entry: ClipboardEntry) -> (String, Data)? {
        for item in entry.items {
            for type in [NSPasteboard.PasteboardType.png.rawValue, "public.jpeg", "public.heic",
                         NSPasteboard.PasteboardType.tiff.rawValue] {
                if let data = item[type] { return (type, data) }
            }
        }
        return nil
    }

    private func shareItem(_ entry: ClipboardEntry) -> String {
        if let url = entry.fileURLs.first { return url.absoluteString }
        return entry.text ?? entry.title
    }

    private func dragProvider(_ entry: ClipboardEntry) -> NSItemProvider {
        let provider: NSItemProvider
        if let (type, data) = Self.imageRepresentation(entry) {
            // Hand over the stored bytes; decoding a large image with NSImage
            // on the main thread stalled the start of every drag.
            provider = NSItemProvider(item: data as NSData, typeIdentifier: type)
        } else {
            provider = NSItemProvider(object: (entry.text ?? entry.previewText) as NSString)
        }
        // Internal pinboard drags supplement the user's original clipboard
        // representation rather than replacing file/image/text export.
        provider.registerDataRepresentation(
            forTypeIdentifier: PasteClipboardDrag.entryType,
            visibility: .ownProcess
        ) { completion in
            completion(Data(entry.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

@MainActor
private struct ClipboardEditorSheet: View {
    let request: ClipboardEditorRequest
    let store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var newBoardColor = "blue"
    @FocusState private var inputFocused: Bool
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!request.isTextEditor || text.utf8.count <= ClipboardStore.maximumEntryBytes)
    }
    private let colors = ClipboardStore.boardColors

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            Text(request.title).font(AOMFont.pageStatus).foregroundStyle(AOMColor.text)
            if request.isTextEditor {
                TextEditor(text: $text).font(AOMFont.body).frame(minHeight: AOMFeatureSize.snippetTall + AOMSpace.x2)
                    .scrollContentBackground(.hidden)
                    .padding(AOMSpace.x1)
                    .background(AOMColor.canvas, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                        .strokeBorder(AOMColor.hairline, lineWidth: 1))
                    .focused($inputFocused)
                if text.utf8.count > ClipboardStore.maximumEntryBytes {
                    Text("Text exceeds the item size limit").font(AOMFont.caption).foregroundStyle(AOMColor.dangerText)
                }
            } else { TextField("Name", text: $text).textFieldStyle(.roundedBorder).focused($inputFocused) }
            if case .newBoard = request.operation {
                HStack(spacing: AOMSpace.x3) {
                    Text("Color").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    ForEach(colors, id: \.self) { name in
                        Button { newBoardColor = name } label: {
                            Circle().fill(PasteClipboardPalette.board(name))
                                .frame(width: AOMFeatureSize.swatch, height: AOMFeatureSize.swatch)
                                .padding(AOMSpace.x1)
                                .overlay(Circle().strokeBorder(
                                    newBoardColor == name ? AOMColor.text : Color.clear,
                                    lineWidth: AOMFeatureSize.swatchRing))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name) Pinboard")
                        .accessibilityAddTraits(newBoardColor == name ? .isSelected : [])
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(request.isTextEditor ? "s" : .return, modifiers: request.isTextEditor ? .command : [])
                    .disabled(!canSave)
            }
        }.padding(AOMSpace.x6).frame(width: AOMFeatureSize.sheetStandard).onAppear { text = request.text; inputFocused = true }
    }
    private func save() {
        switch request.operation {
        case .renameEntry(let id): store.rename(entryID: id, title: text)
        case .editEntry(let id): store.editText(entryID: id, text: text)
        case .newText: store.createTextItem(text)
        case .newBoard: _ = store.createBoard(name: text, color: newBoardColor)
        case .renameBoard(let id): store.renameBoard(id: id, name: text)
        }
    }
}

@MainActor
private struct ClipboardPreviewSheet: View {
    let entry: ClipboardEntry
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardPanelState
    let controller: ClipboardPanelController

    @State private var content: ClipboardPreviewCache.Content?
    @ObservedObject private var preferences = ClipboardPreferences.shared
    @State private var loadedVersion: UUID?
    /// A region dragged out on an image (P04) and the text read from it.
    @State private var regionSelection: CGRect?
    @State private var regionText: String?
    // Paste-style rename: the title shows in the preview and edits in place
    // on double-click. The preview key handler already yields to editingTitleID.
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFocused: Bool
    private var currentContent: ClipboardPreviewCache.Content? { loadedVersion == current.contentVersion ? content : nil }

    private func beginTitleEdit() {
        editedTitle = current.title
        isEditingTitle = true
        state.editingTitleID = current.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            titleFocused = true
        }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != current.title { store.rename(entryID: current.id, title: trimmed) }
        finishTitleEdit()
    }

    private func finishTitleEdit() {
        isEditingTitle = false
        state.editingTitleID = nil
        titleFocused = false
    }

    private func beginEditing() {
        let item = current
        if item.kind == .color { controller.editEntry(item); return }
        controller.closePreview()
        DispatchQueue.main.async {
            state.editor = .init(operation: .editEntry(item.id), title: "Edit Content", text: item.text ?? "")
        }
    }

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        // While the title is being edited the field editor owns the keyboard;
        // returning false lets Esc cancel the edit via onExitCommand.
        if state.editingTitleID != nil { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53 {
            // Esc first clears a region selected on an image.
            if regionSelection != nil { regionSelection = nil; regionText = nil; return true }
            controller.closePreview()
            return true
        }
        if flags == .command, event.keyCode == 14, current.kind == .image {
            if !event.isARepeat { controller.editEntry(current) }
            return true
        }
        if flags == .command, event.keyCode == 14, canEditText {
            if !event.isARepeat { beginEditing() }
            return true
        }
        if flags.isEmpty, event.keyCode == 49 {
            if !event.isARepeat { controller.closePreview() }
            return true
        }
        if flags.isEmpty, [123, 124].contains(event.keyCode) {
            controller.movePreview(from: current.id, offset: event.keyCode == 124 ? 1 : -1)
            return true
        }
        if flags == .command, event.keyCode == 3 {
            controller.closePreview()
            state.searchFocusToken = UUID()
            return true
        }
        if flags == .command, event.keyCode == 15 {
            let item = current
            controller.closePreview()
            DispatchQueue.main.async {
                state.editor = .init(operation: .renameEntry(item.id), title: "Rename Item", text: item.title)
            }
            return true
        }
        if (flags.isEmpty || flags == ClipboardPreferences.shared.plainModifier.flags), [36, 76].contains(event.keyCode) {
            controller.paste(ids: [current.id], plainText: ClipboardPreferences.shared.isPlain(flags), dismissAfterCopy: true)
            return true
        }
        if (flags == .command || flags == NSEvent.ModifierFlags.command.union(ClipboardPreferences.shared.plainModifier.flags)), event.keyCode == 8 {
            if flags == .command,
               let text = event.window?.firstResponder as? NSTextView,
               text.selectedRange().length > 0 { return false }
            // ⌘C with a region selected on an image copies that region's text.
            if flags == .command, regionSelection != nil, let text = regionText, !text.isEmpty {
                do { try store.copyDerivedText(text); state.status = "Text from the selected area copied." }
                catch { state.status = error.localizedDescription }
                return true
            }
            do {
                if try store.write(entryIDs: [current.id], plainText: ClipboardPreferences.shared.isPlain(flags)) {
                    state.status = ClipboardPanelState.multiCopyStatus(count: 1)
                }
            } catch { state.status = error.localizedDescription }
            return true
        }
        return false
    }

    private var current: ClipboardEntry { store.entries.first { $0.id == entry.id } ?? entry }
    private var canEditText: Bool { current.text != nil && [.text, .link, .color].contains(current.kind) }
    private var previewSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let text = canEditText
        return CGSize(width: min(text ? 390 : 500, max(300, screen.width - 48)),
                      height: min(text ? 316 : 360, max(220, screen.height - 200)))
    }
    private var summary: String { currentContent?.summary ?? current.kind.displayName }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Button { controller.closePreview() } label: {
                    Image(systemName: "xmark.circle.fill").font(AOMFont.section.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
                }.help("Close Preview (Space / Esc)").accessibilityLabel("Close Preview")
                if isEditingTitle {
                    TextField("Title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(AOMFont.callout.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit { commitTitle() }
                        .onExitCommand { finishTitleEdit() }
                        .frame(maxWidth: AOMSize.tileMin)
                        .accessibilityLabel("Title")
                } else {
                    Text(current.title.isEmpty ? current.kind.displayName : current.title)
                        .font(AOMFont.callout.weight(.semibold))
                        .foregroundStyle(current.title.isEmpty ? AOMColor.textSecondary : AOMColor.text)
                        .lineLimit(1).truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginTitleEdit() }
                        .help(current.title.isEmpty ? "Double-click to name this item" : "Double-click to rename")
                        .accessibilityLabel("Title, \(current.title.isEmpty ? current.kind.displayName : current.title). Double-click to rename.")
                }
                Spacer()
                Menu {
                    ForEach(store.boards) { board in
                        Button(current.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                            if current.pinboardIDs.contains(board.id) { store.unpin(entryID: current.id, boardID: board.id) }
                            else { store.pin(entryID: current.id, boardID: board.id) }
                        }
                    }
                    if store.boards.isEmpty { Text("Create a pinboard in the timeline") }
                } label: { Image(systemName: current.pinboardIDs.isEmpty ? "pin" : "pin.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pinboard")
                Button { controller.detachPreview(current) } label: { Image(systemName: "arrow.up.right.square") }.help("Detach Preview")
                ClipboardPreviewShareButton(entry: current).frame(width: AOMIcon.row + AOMSpace.x1, height: AOMIcon.row + AOMSpace.x1)
                if current.kind == .image || canEditText {
                    Button("Edit") {
                        if current.kind == .image { controller.editEntry(current) }
                        else { beginEditing() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Edit Content (⌘E)")
                }
            }.buttonStyle(.plain).padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowStandard)
            Group {
                if current.imageData != nil {
                    Group {
                        if let image = currentContent?.image {
                            // Search matches are highlighted in the picture,
                            // and a dragged region can be read or copied (P04).
                            ClipboardImageInspector(entry: current, image: image, query: state.query, store: store,
                                                    selection: $regionSelection, regionText: $regionText,
                                                    onStatus: { state.status = $0 })
                        }
                        else if currentContent == nil { ProgressView().controlSize(.small) }
                        else { Label("Preview unavailable", systemImage: "photo").foregroundStyle(AOMColor.textSecondary) }
                    }.padding(AOMSpace.x3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TransparencyGrid())
                } else if !current.fileURLs.isEmpty {
                    ClipboardFilesPreview(urls: current.fileURLs)
                } else if preferences.networkPreviews, current.kind == .link,
                          let url = URL(string: (current.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    ClipboardPrivateLinkPreview(url: url)
                } else {
                    ClipboardReadOnlyTextPreview(entry: current, prepared: currentContent?.attributedText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AOMFeatureColor.documentPage)
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .padding(.horizontal, AOMSpace.x1).padding(.top, AOMSpace.x0_5)
            HStack {
                Text(summary).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowSingle)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .background(AOMColor.canvas)
        .background(ClipboardPreviewKeyHandler(controller: controller, handle: handlePreviewKey))
        .task(id: current.contentVersion) {
            content = nil; loadedVersion = nil
            let entry = current
            let loaded = await ClipboardPreviewCache.shared.content(for: entry)
            guard !Task.isCancelled else { return }
            content = loaded; loadedVersion = entry.contentVersion
        }
    }
}

/// Only intercept keys from this popover's window; other AOM windows keep their responders.
@MainActor
private struct ClipboardPreviewKeyHandler: NSViewRepresentable {
    let controller: ClipboardPanelController
    var handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        view.controller = controller
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle; view.controller = controller }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        weak var controller: ClipboardPanelController?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window || self.controller?.isHistoryWindow(event.window) == true,
                      window.attachedSheet == nil else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

@MainActor
private struct ClipboardPreviewShareButton: NSViewRepresentable {
    let entry: ClipboardEntry
    func makeCoordinator() -> Coordinator { Coordinator(entry: entry) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false
        button.toolTip = "Share"
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.entry = entry }
    final class Coordinator: NSObject {
        var entry: ClipboardEntry
        init(entry: ClipboardEntry) { self.entry = entry }
        @objc func share(_ sender: NSButton) {
            let items: [Any]
            if !entry.fileURLs.isEmpty { items = entry.fileURLs }
            else if let data = entry.imageData, let image = NSImage(data: data) { items = [image] }
            else { items = [entry.text ?? entry.previewText] }
            NSSharingServicePicker(items: items).show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }
}

/// Native system renderer for previews of user-selected local file URLs.
private struct ClipboardFileQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Quick Look preview unavailable")
        }
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? QLPreviewView)?.previewItem = url as NSURL
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? QLPreviewView)?.close()
    }
}

/// Configure only the enclosing scroll surface. Reapply when SwiftUI changes
/// scroller visibility, so the system's "Always" setting cannot add a gutter to
/// a timeline or tool strip. Content, wheel events and momentum remain native.
struct NativeScrollChrome: NSViewRepresentable {
    enum Mode: Equatable { case hidden, overlay }
    var mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func makeNSView(context: Context) -> ScrollChromeView { ScrollChromeView(mode: mode) }
    func updateNSView(_ view: ScrollChromeView, context: Context) {
        guard view.mode != mode else { return }
        view.mode = mode
        view.attach()
    }

    final class ScrollChromeView: NSView {
        var mode: Mode
        private weak var scrollView: NSScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var applying = false
        private var attachScheduled = false
        init(mode: Mode) { self.mode = mode; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        // Layout runs on every scroll frame of a lazy stack; only look for the
        // scroll view until it has been found (it never changes afterwards).
        override func layout() { super.layout(); if scrollView == nil { attach() } }
        func attach() {
            guard window != nil else { observations.removeAll(); scrollView = nil; return }
            guard !attachScheduled else { return }
            attachScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachScheduled = false
                guard self.window != nil else { return }
                var target = self.enclosingScrollView
                if target == nil {
                    var parent = self.superview
                    for _ in 0..<3 {
                        guard let current = parent else { break }
                        target = current.subviews.compactMap { $0 as? NSScrollView }.first
                        if target != nil { break }
                        parent = current.superview
                    }
                }
                guard let target else { return }
                if self.scrollView !== target {
                    self.observations.removeAll()
                    self.scrollView = target
                    self.observations = [
                        target.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.apply() } },
                        target.observe(\.hasVerticalScroller, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.apply() } },
                        target.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.apply() } }
                    ]
                }
                self.apply()
            }
        }
        private func apply() {
            guard !applying, let scrollView else { return }
            applying = true
            defer { applying = false }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
            if scrollView.borderType != .noBorder { scrollView.borderType = .noBorder }
            if mode == .hidden {
                if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
                if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
            }
        }
    }
}

/// Transparency is visible without making a preview depend on desktop colours.
struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let side = AOMSpace.x3 - AOMSpace.x0_5
            var squares = Path()
            for row in 0..<Int(ceil(size.height / side)) {
                for column in 0..<Int(ceil(size.width / side)) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
                }
            }
            context.fill(squares, with: .color(AOMColor.track))
        }.background(AOMColor.raised).allowsHitTesting(false)
    }
}

// MARK: - Paste-like palette and height resizing, using original UI primitives.

private enum PasteClipboardPalette {
    /// Pinboard colours in Paste's order.
    static let boardColors = ClipboardStore.boardColors

    static func board(_ name: String) -> Color { Color(nsColor: nsBoard(name)) }

    static func nsBoard(_ name: String) -> NSColor {
        switch name.lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray": return .systemGray
        default: return .systemBlue
        }
    }

    /// Non-template colour dot for NSMenu items (SF Symbols would be tinted).
    static func swatch(_ name: String, selected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            nsBoard(name).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            if selected {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Paste 6.5 on macOS 26 uses a Liquid Glass shelf (radius 26, 8 pt inset);
/// earlier systems keep the translucent popover material.
/// The shelf uses the shared floating material, so it gains the same
/// Reduce Transparency / Increase Contrast fallbacks as every other panel.
private struct PastePanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.aomFloatingSurface(.panel, radius: AOMRadius.panel + 4)
    }
}

private struct PastePanelResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizableGripView { ResizableGripView() }
    func updateNSView(_ nsView: ResizableGripView, context: Context) {}

    final class ResizableGripView: NSView {
        private var initialY: CGFloat = 0
        private var initialHeight: CGFloat = 0

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // Double-clicking the edge restores the default shelf height.
            if event.clickCount == 2 {
                var frame = window.frame
                frame.size.height = ClipboardPanelController.defaultHeight
                window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                UserDefaults.standard.removeObject(forKey: "AOMClipboardPanelHeight")
                return
            }
            initialY = window.convertPoint(toScreen: event.locationInWindow).y
            initialHeight = window.frame.height
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let y = window.convertPoint(toScreen: event.locationInWindow).y
            let height = ClipboardPanelController.clampedHeight(initialHeight + y - initialY,
                                                               visibleHeight: window.screen?.visibleFrame.height ?? 900)
            var frame = window.frame
            frame.size.height = height
            window.setFrame(frame, display: true)
            UserDefaults.standard.set(Double(height), forKey: "AOMClipboardPanelHeight")
        }
    }
}


private enum PasteClipboardDrag {
    static let entryType = "com.kyw.allofmacos.clipboard-pinboard-entry"
    static let boardType = "com.kyw.allofmacos.clipboard-pinboard"
}

/// Visible-card tracking for ⌘1–9. On macOS 15+ the indices come from the
/// scroll offset arithmetically and are published only when the visible range
/// changes; the old per-card geometry preference (re-evaluated every scroll
/// frame) remains only for macOS 14.
private struct ClipboardVisibleRangeTracker: ViewModifier {
    let ids: [UUID]
    let pitch: CGFloat
    let side: CGFloat
    let inset: CGFloat
    let viewportWidth: CGFloat
    let state: ClipboardPanelState

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                publish(offset: offset)
            }
            .onAppear { publish(offset: 0) }
            .onChange(of: ids) { _, _ in publish(offset: 0) }
        } else {
            content.onPreferenceChange(ClipboardVisibleCardsKey.self) { frames in
                let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: .greatestFiniteMagnitude)
                let visible = frames.filter { $0.value.intersects(viewport) }
                    .sorted { $0.value.minX < $1.value.minX }.map(\.key)
                if state.visibleCardIDs != visible { state.visibleCardIDs = visible }
            }
        }
    }

    private func publish(offset: CGFloat) {
        let range = ClipboardShelfGeometry.visibleRange(offset: offset, viewportWidth: viewportWidth,
                                                        pitch: pitch, side: side, inset: inset, count: ids.count)
        let visible = Array(ids[range])
        if state.visibleCardIDs != visible { state.visibleCardIDs = visible }
    }
}

private struct ClipboardLegacyVisibilityProbe: ViewModifier {
    let id: UUID
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content } else {
            content.background(GeometryReader { geometry in
                Color.clear.preference(key: ClipboardVisibleCardsKey.self,
                                       value: [id: geometry.frame(in: .named("clipboardViewport"))])
            })
        }
    }
}

enum ClipboardShelfGeometry {
    /// Indices of cards intersecting the viewport for a horizontal shelf
    /// whose card `i` spans `inset + i·pitch … + side`.
    static func visibleRange(offset: CGFloat, viewportWidth: CGFloat, pitch: CGFloat,
                             side: CGFloat, inset: CGFloat, count: Int) -> Range<Int> {
        guard count > 0, pitch > 0 else { return 0..<0 }
        let first = Int(floor((offset - inset - side) / pitch)) + 1
        let last = Int(floor((offset + viewportWidth - inset) / pitch))
        let lower = min(max(first, 0), count), upper = min(max(last + 1, lower), count)
        return lower..<upper
    }
}

private struct ClipboardVisibleCardsKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

/// Every referenced file gets the same Quick Look surface; multi-file clips
/// retain their order and let the user navigate without leaving the preview.
@MainActor
struct ClipboardFilesPreview: View {
    let urls: [URL]
    @State private var selected = 0
    private var current: URL? { urls.indices.contains(selected) ? urls[selected] : urls.first }

    var body: some View {
        VStack(spacing: 0) {
            if let url = current {
                if urls.count > 1 {
                    HStack(spacing: AOMSpace.x3) {
                        Button { selected = max(0, selected - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(selected == 0).help("Previous File")
                        Picker("File", selection: $selected) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { index, item in
                                Text("\(index + 1). \(item.lastPathComponent)").tag(index)
                            }
                        }.labelsHidden()
                        Text("\(selected + 1) / \(urls.count)").font(AOMFont.caption).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                        Button { selected = min(urls.count - 1, selected + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(selected >= urls.count - 1).help("Next File")
                    }.padding(AOMSpace.x3)
                    Divider()
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    ClipboardFileQuickLookView(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: AOMSpace.x3) {
                        Image(systemName: "doc.badge.ellipsis").font(AOMFont.hero.weight(.regular))
                            .symbolRenderingMode(.hierarchical).foregroundStyle(AOMColor.textSecondary)
                        Text("File is no longer at its original location").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                        Text(url.path).font(AOMFont.caption).textSelection(.enabled).foregroundStyle(AOMColor.textSecondary)
                    }.padding(AOMSpace.x4).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text(url.lastPathComponent).font(AOMFont.caption).foregroundStyle(AOMColor.text).lineLimit(1)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                }.padding(AOMSpace.x3)
            }
        }
        .onChange(of: urls) { _, _ in selected = 0 }
    }
}

/// Paste-style relative dates: "Just now", "16 minutes ago", "2 hours ago",
/// "Yesterday", then "5 days ago".
enum ClipboardRelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "Just now") }
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// The shelf card's header strip: one line (3.3.5, was 38 / 42 pt for two).
private enum ShelfCardMetrics {
    static let header: CGFloat = 28
    static let headerCompact: CGFloat = 24
}
