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
}

@MainActor
final class ClipboardPanelState: ObservableObject {
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
    @Published var visibleCardIDs: [UUID] = []
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

    /// Memoised per store revision and filter state: the panel, every card and
    /// the key handler ask for this many times per update.
    func results(in store: ClipboardStore) -> [ClipboardEntry] {
        let key = ResultsKey(store: ObjectIdentifier(store), revision: store.revision, query: query, kind: kind,
                             source: source, board: board, recentDays: recentDays,
                             day: Calendar.current.startOfDay(for: Date()), suggested: suggestedIDs)
        if let resultsCache, resultsCache.key == key { return resultsCache.value }
        let range = Self.dateRange(for: recentDays)
        var value = store.filtered(query: query, kind: kind, source: source,
                                   board: board, since: range.since)
            .filter { range.before == nil || $0.lastCopiedAt < range.before! }
        if !suggestedIDs.isEmpty, board == nil, query.isEmpty, kind == nil, source == nil, recentDays == 0 {
            value = Self.promoting(suggestedIDs, in: value)
        }
        resultsCache = (key, value)
        return value
    }

    /// Moves the suggested entries to the front, in suggestion order.
    static func promoting(_ ids: [UUID], in entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let picked = ids.compactMap { id in entries.first { $0.id == id } }
        guard !picked.isEmpty else { return entries }
        let set = Set(picked.map(\.id))
        return picked + entries.filter { !set.contains($0.id) }
    }

    func quickPasteIDs(in store: ClipboardStore) -> [UUID] {
        let ids = results(in: store).map(\.id)
        let visible = Set(visibleCardIDs)
        return Array((visible.isEmpty ? ids : ids.filter { visible.contains($0) }).prefix(9))
    }

    func selectedIDs(in store: ClipboardStore) -> [UUID] {
        results(in: store).filter { selected.contains($0.id) }.map(\.id)
    }

    /// Keep pinboard tab changes atomic, without leaving stale selection
    /// attached to clips from the previously displayed collection.
    func selectBoard(_ id: UUID?) {
        board = id
        clearSelection()
    }

    func clearSelection() {
        preview = nil
        selected.removeAll()
        focusedID = nil
        keyboardScrollTarget = nil
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
        focusedID = selected.contains(id) ? id : entries.first(where: { selected.contains($0.id) })?.id
        searchFieldActive = false
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
        stackPanel?.orderFrontRegardless()
        stackPasteMonitor.onPaste = { [weak self] plainText in
            guard let self, self.stackPanel?.isVisible == true, !self.isVisible,
                  let target = NSWorkspace.shared.frontmostApplication,
                  target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            self.store.poll()
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
            defer { stackPasteTask = nil }
            while !Task.isCancelled, !pendingStackPastes.isEmpty {
                let (target, plainText) = pendingStackPastes.removeFirst()
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
        guard state.editor == nil, state.editingTitleID == nil, state.preview == nil else { return }
        state.select(id, in: state.results(in: store),
                     extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
        // Clear the native field editor too, so arrows/Space act on this card
        // immediately after the user leaves the search field.
        panel?.makeFirstResponder(nil)
    }

    func openPreview(_ entry: ClipboardEntry) {
        previewNavigationGeneration += 1
        state.searchFieldActive = false
        state.select(entry.id, in: state.results(in: store))
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
        let entries = state.results(in: store)
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
                  self.state.results(in: self.store).contains(where: { $0.id == next.id }) else { return }
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
            window.contentView = NSHostingView(rootView: ClipboardPanelView(store: store, state: state, controller: self))
            panel = window
        }
        guard let panel else { return }
        // A new presentation may interrupt a previous slide-out animation.
        panel.alphaValue = 1
        let wasVisible = panel.isVisible
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        var target = panel.frame
        if let bounds = screen?.visibleFrame {
            let storedHeight = CGFloat(UserDefaults.standard.double(forKey: "AOMClipboardPanelHeight"))
            let targetHeight = Self.clampedHeight(storedHeight > 0 ? storedHeight : Self.defaultHeight,
                                                  visibleHeight: bounds.height)
            target = NSRect(x: bounds.minX + 8, y: bounds.minY + 8,
                            width: max(1, bounds.width - 16), height: targetHeight)
        }
        // Stale messages from an earlier session must not greet the user.
        state.status = ""
        if !wasVisible {
            state.suggestedIDs = ClipboardIntelligence.shared.suggestions(for: destination, store: store) { [weak self] ids in
                guard let self, self.isVisible, !self.slidingOut else { return }
                self.state.suggestedIDs = ids
            }
            ClipboardIntelligence.shared.refineClassesWithModel(store.entries)
        }
        state.searchExpanded = !state.query.isEmpty
        state.commandHeld = NSEvent.modifierFlags.contains(.command)
        if wasVisible || !Self.animatesPanel {
            panel.setFrame(target, display: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Paste slides the shelf up from beneath the screen edge in 0.15 s.
            var start = target
            start.origin.y = target.minY - target.height - 8
            panel.setFrame(start, display: false)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        installMonitors()
    }

    static let defaultHeight: CGFloat = 332
    static let minimumHeight: CGFloat = 175
    static func clampedHeight(_ height: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), max(120, (visibleHeight - 36) / 2))
    }
    private static var animatesPanel: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !PresetManager.isRunningTests
    }

    /// Dismisses with Paste's slide-down. Use `hideImmediately` when another
    /// window must take over the screen at once.
    func hide() { slideDownAndHide() }

    func hideImmediately() {
        dismissalGeneration += 1
        slidingOut = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        clearPanelInteractionState()
    }

    private func clearPanelInteractionState() {
        previewNavigationGeneration += 1
        for token in [keyMonitor, outsideMonitor, localClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(token)
        }
        keyMonitor = nil
        outsideMonitor = nil
        localClickMonitor = nil
        state.editor = nil
        state.preview = nil
        state.editingTitleID = nil
        state.clearSelection()
        state.commandHeld = false
        state.visibleCardIDs = []
        state.suggestedIDs = []
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
        clearPanelInteractionState()

        // Paste sits just above the bottom screen edge; exit beneath that edge.
        guard Self.animatesPanel else { hideImmediately(); completion(); return }
        let bottomEdge = (panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? panel.frame.minY
        var offscreenFrame = panel.frame
        offscreenFrame.origin.y = bottomEdge - offscreenFrame.height - 8
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreenFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, self.dismissalGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.slidingOut = false
                completion()
            }
        }
    }

    func pasteSelected(plainText: Bool = false) {
        var ids = state.selectedIDs(in: store)
        if ids.isEmpty, let first = state.results(in: store).first { ids = [first.id] }
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
        guard !ids.isEmpty, !slidingOut else { return }
        do {
            guard try store.write(entryIDs: ids, plainText: plainText || store.settings.plainText,
                                  playSound: false) else { return }
        } catch { state.status = error.localizedDescription; return }
        ClipboardIntelligence.shared.recordPaste(entryIDs: ids, destination: destination, store: store)
        guard store.settings.pasteDirectly, let target = destination,
              !target.isTerminated else {
            ClipboardAudioFeedback.copy()
            state.status = "Copied to clipboard."
            copied?()
            if dismissAfterCopy { slideDownAndHide() }
            return
        }
        pasteTask?.cancel()
        target.activate(options: [.activateIgnoringOtherApps])
        self.pasteTask = Task { @MainActor [weak self] in
            guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { copied?(); return }
            // Wait for focus and physical modifiers, including Command held
            // for a quick-paste badge. Never inject into a different app.
            for _ in 0..<150 {
                guard !Task.isCancelled, !target.isTerminated else { return }
                let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if focused && flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty {
                    guard let source = CGEventSource(stateID: .privateState),
                          let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
                          let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return }
                    for (index, event) in [commandDown, down, up, commandUp].enumerated() {
                        event.flags = index == 3 ? [] : .maskCommand
                        event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
                        event.post(tap: .cghidEventTap)
                    }
                    ClipboardAudioFeedback.paste()
                    copied?()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            self?.state.status = "Destination unavailable or a modifier is held. Item copied without pasting."
        }
        slideDownAndHide()
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
        } else if let text = item.text, [.text, .link, .color].contains(item.kind) {
            state.editor = .init(operation: .editEntry(item.id), title: "Edit Content", text: text)
        } else { openPreview(item) }
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel, self.state.editor == nil, self.state.preview == nil else { return event }
            if event.type == .flagsChanged {
                self.state.commandHeld = event.modifierFlags.contains(.command)
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
                if let first = self.state.results(in: self.store).first {
                    self.state.select(first.id, in: self.state.results(in: self.store))
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
                let quickPaste = command && (1...9).contains(digit)
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
        let before = state.results(in: store)
        store.delete(entryIDs: ids)
        state.pendingDeletion = []
        state.clearSelection()
        let remaining = state.results(in: store)
        if let index = before.firstIndex(where: { ids.contains($0.id) }), !remaining.isEmpty {
            let next = remaining[min(index, remaining.count - 1)]
            state.select(next.id, in: remaining)
            state.keyboardScrollTarget = next.id
        }
        state.status = ids.count == 1 ? "Item deleted. Press ⌘Z to undo." : "\(ids.count) items deleted. Press ⌘Z to undo."
    }

    /// Targets of a card action: the whole selection when the card is part of
    /// it, otherwise just that card (Paste's context-menu behaviour).
    func actionTargets(for entry: ClipboardEntry) -> [UUID] {
        let selected = state.selectedIDs(in: store)
        return selected.contains(entry.id) ? selected : [entry.id]
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
        if event.keyCode == 53 { hide(); return true }
        if command && event.keyCode == 3 { state.searchFocusToken = UUID(); return true }
        if command && !shift && event.keyCode == 6 {
            let restored = store.undoDeletion()
            state.selected = Set(restored)
            state.focusedID = restored.first
            state.status = restored.isEmpty ? "Nothing to restore." : "Restored \(restored.count) item(s)."
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
        let activeEntries = state.results(in: store)
        if command && event.keyCode == 8 {
            let ids = state.selectedIDs(in: store)
            guard !ids.isEmpty else { return false }
            do {
                _ = try store.write(entryIDs: ids, plainText: shift)
                state.status = "Copied \(ids.count == 1 ? "item" : "\(ids.count) items") to clipboard."
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
           state.selected.count == 1, let id = state.selected.first {
            state.showIn(nil, entryID: id)
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
        let entries = state.results(in: store)
        let quickIDs = state.quickPasteIDs(in: store)
        if command, let text = event.charactersIgnoringModifiers, let number = Int(text),
           (1...9).contains(number), quickIDs.indices.contains(number - 1) {
            paste(ids: [quickIDs[number - 1]], plainText: shift, dismissAfterCopy: true); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { pasteSelected(plainText: shift); return true }
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
        if !editingText && command && event.keyCode == 0 { state.selected = Set(entries.map(\.id)); return true }
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
    @State private var showAllFilterApps = false

    private var entries: [ClipboardEntry] { state.results(in: store) }
    private var sources: [String] { Array(Set(store.entries.compactMap(\.sourceBundleID))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            PastePanelResizeGrip()
                .frame(height: 4)
                .help("Drag to resize · Double-click to reset")
            headerBar
            // Only recent searches get a row; counts and syntax help live in
            // the search capsule so the cards keep their size while typing.
            if state.searchExpanded && state.query.isEmpty && !state.recentSearches.isEmpty {
                searchSuggestions
            }
            carouselContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Messages float over the shelf instead of pushing the cards up, and
        // fade away on their own (Paste shows no permanent status row).
        .overlay(alignment: .bottom) {
            if !state.status.isEmpty {
                HStack(spacing: 8) {
                    Text(state.status)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .accessibilityIdentifier("ClipboardStatus")
                    Button { state.status = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Dismiss Message").accessibilityLabel("Dismiss Message")
                }
                .padding(.leading, 14).padding(.trailing, 8).frame(height: 30)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18), value: state.status)
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
            Button("Delete", role: .destructive) {
                if let board = boardPendingDeletion {
                    store.deleteBoard(id: board.id)
                    if state.board == board.id { state.selectBoard(nil) }
                }
                boardPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { boardPendingDeletion = nil }
        } message: {
            Text("The Pinboard will be deleted. Its items stay in Clipboard History unless they expire.")
        }
        .onChange(of: state.searchFocusToken) { _, _ in
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
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
        .onChange(of: state.query) { _, _ in state.clearSelection() }
        .onChange(of: state.kind) { _, _ in state.clearSelection() }
        .onChange(of: state.source) { _, _ in state.clearSelection() }
        .onChange(of: state.recentDays) { _, _ in state.clearSelection() }
        .onChange(of: entries.map(\.id)) { _, ids in
            let visible = Set(ids)
            state.selected.formIntersection(visible)
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
        let available = containerWidth - (state.searchExpanded ? CGFloat(620) : CGFloat(160))
        return max(CGFloat(90), min(CGFloat(560), min(available, boardsWidth)))
    }

    private var searchSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(state.recentSearches, id: \.self) { query in
                    Button(query) { state.query = query }.buttonStyle(.bordered).controlSize(.mini)
                }
            }.padding(.horizontal, 24).padding(.bottom, 6)
        }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
    }

    private var headerBar: some View {
        GeometryReader { geometry in
        HStack(spacing: 12) {
            Spacer(minLength: 30)
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                Button { state.searchFocusToken = UUID() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Search Clipboard (⌘F)")
                .accessibilityLabel("Search Clipboard")
                if state.searchExpanded {
                    TextField("Search Clipboard", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .frame(width: min(400, max(160, geometry.size.width * 0.28)))
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
                        Text(entries.count == 1 ? "1 result" : "\(entries.count) results")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    }
                    Button {
                        state.query = ""
                        state.searchExpanded = false
                        searchFocused = false
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Close Search")
                    Button { state.filtersExpanded.toggle() } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(hasFilters ? Color.accentColor : Color.secondary)
                            .frame(width: 25, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Filters")
                    .accessibilityLabel("Filters")
                    .popover(isPresented: $state.filtersExpanded, arrowEdge: .top) { filterPopover }
                }
                }
                .padding(.horizontal, state.searchExpanded ? 9 : 0)
                .frame(height: 34)
                .background(state.searchExpanded ? Color.primary.opacity(0.075) : Color.clear, in: Capsule())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        boardButton("Clipboard", color: .secondary, icon: "clock.arrow.circlepath", id: nil)
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
                            Image(systemName: "plus").font(.system(size: 19, weight: .regular))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Add Pinboard (⇧⌘N)")
                        .accessibilityLabel("Add Pinboard")
                    }
                    .padding(.horizontal, 3)
                    .background(NativeScrollChrome(.hidden))
                }
                .scrollIndicators(.hidden)
                .frame(width: pinboardScrollWidth(containerWidth: geometry.size.width))
            }
            Spacer(minLength: 30)
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
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(store.paused || state.kind != nil || state.source != nil || state.recentDays != 0 ? Color.accentColor : Color.primary)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Clipboard Options and Filters")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        }
        .frame(height: 52)
        .accessibilityIdentifier("PasteStyleClipboardToolbar")
    }

    private func boardButton(_ name: String, color: Color, icon: String?, id: UUID?) -> some View {
        Button {
            state.selectBoard(id)
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(state.board == id ? Color.primary : Color.secondary)
                } else {
                    Circle().fill(color).frame(width: 11, height: 11)
                }
                if !state.searchExpanded {
                Text(name)
                    .font(.system(size: 14, weight: state.board == id ? .medium : .regular))
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(state.board == id
                        ? Color.primary.opacity(0.12)
                        : Color.clear,
                        in: Capsule())
            .foregroundStyle(state.board == id ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityIdentifier("PasteStylePinboard_\(id?.uuidString ?? "clipboard-history")")
        .accessibilityAddTraits(state.board == id ? [.isSelected] : [])
        .onDrop(of: [PasteClipboardDrag.entryType], isTargeted: nil) { providers in
            guard let id, let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(PasteClipboardDrag.entryType)
            }) else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: PasteClipboardDrag.entryType) {
                data, _ in
                guard let data, let raw = String(data: data, encoding: .utf8),
                      let entryID = UUID(uuidString: raw) else { return }
                Task { @MainActor in
                    store.pin(entryID: entryID, boardID: id)
                }
            }
            return true
        }
    }

    private var hasFilters: Bool { state.kind != nil || state.source != nil || state.recentDays != 0 }

    private var filterPopover: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        let appLimit = 8
        let visibleSources = showAllFilterApps ? sources : Array(sources.prefix(appLimit))
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Filters").font(.headline)
                    Spacer()
                    Button("Clear") { state.kind = nil; state.source = nil; state.recentDays = 0 }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(!hasFilters)
                }
                filterSection("Type")
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ClipboardEntry.Kind.allCases) { kind in
                        filterChip(kind.displayName, icon: symbol(kind), selected: state.kind == kind) {
                            state.kind = state.kind == kind ? nil : kind
                        }
                    }
                }
                if !sources.isEmpty {
                    filterSection("App")
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(visibleSources, id: \.self) { source in
                            filterChip(store.entries.first { $0.sourceBundleID == source }?.sourceName ?? source,
                                       icon: nil, appIcon: AppMetadataCache.shared.icon(for: source),
                                       selected: state.source == source) {
                                state.source = state.source == source ? nil : source
                            }
                        }
                        if sources.count > appLimit {
                            filterChip(showAllFilterApps ? "Less" : "More", icon: showAllFilterApps ? "chevron.up" : "ellipsis",
                                       selected: false) { showAllFilterApps.toggle() }
                        }
                    }
                }
                if !store.boards.isEmpty {
                    filterSection("Pinboard")
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(store.boards) { board in
                            filterChip(board.name, icon: nil, dot: PasteClipboardPalette.board(board.color),
                                       selected: state.board == board.id) {
                                state.selectBoard(state.board == board.id ? nil : board.id)
                            }
                        }
                    }
                }
                filterSection("Date")
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ClipboardPanelState.dateFilters, id: \.code) { filter in
                        filterChip(filter.title, icon: "calendar", selected: state.recentDays == filter.code) {
                            state.recentDays = state.recentDays == filter.code ? 0 : filter.code
                        }
                    }
                }
            }.padding(16)
        }
        .frame(width: 440).frame(maxHeight: 470)
    }

    private func filterSection(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func filterChip(_ title: String, icon: String?, appIcon: NSImage? = nil, dot: Color? = nil,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 9, height: 9)
                } else if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit()
                        .frame(width: 15, height: 15).accessibilityHidden(true)
                } else if let icon {
                    Image(systemName: icon)
                } else {
                    Image(systemName: "app")
                }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 27).padding(.horizontal, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.065), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            ForEach(sources, id: \.self) { source in
                Button { state.source = source } label: {
                    HStack {
                        if let appIcon = AppMetadataCache.shared.icon(for: source) {
                            Image(nsImage: appIcon).resizable().scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                        } else {
                            Image(systemName: "app")
                        }
                        Text(store.entries.first { $0.sourceBundleID == source }?.sourceName ?? source)
                        if state.source == source { Image(systemName: "checkmark") }
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
            let compact = geometry.size.height < 205
            let cardSide = min(300, max(100, geometry.size.height - (compact ? 24 : 44)))
            Group {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: isFiltering ? "magnifyingglass" : state.board == nil ? "clipboard" : "pin")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(store.isLoading ? "Loading Clipboard…" : emptyTitle)
                            .font(.headline)
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let entries = self.entries
                    let spacing: CGFloat = compact ? 14 : 24
                    let quickIDs = state.quickPasteIDs(in: store)
                    let suggested = Set(state.suggestedIDs)
                    let boards = store.boards
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: spacing) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    ClipboardCardView(entry: entry, number: index + 1,
                                                      compact: compact, side: cardSide,
                                                      isSelected: state.selected.contains(entry.id),
                                                      quickNumber: quickIDs.firstIndex(of: entry.id).map { $0 + 1 },
                                                      showsQuickNumber: state.commandHeld,
                                                      searchActive: state.searchFieldActive,
                                                      isPreviewing: state.preview?.id == entry.id,
                                                      isSuggested: suggested.contains(entry.id),
                                                      boards: boards,
                                                      store: store, state: state, controller: controller)
                                        .id(entry.id)
                                        .modifier(ClipboardLegacyVisibilityProbe(id: entry.id))
                                }
                            }
                            .padding(.horizontal, Self.shelfInset)
                            .padding(.top, compact ? 8 : 12)
                            .padding(.bottom, compact ? 12 : 24)
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

    static let shelfInset: CGFloat = 24

    private var isFiltering: Bool { !state.query.isEmpty || hasFilters }
    private var emptyTitle: String {
        isFiltering ? "Nothing found" : state.board == nil ? "History is empty" : "Pinboard is empty"
    }
    private var emptyMessage: String {
        if isFiltering { return "Try another search or clear the filters." }
        if state.board != nil { return "Drag items onto this Pinboard, or use Pin in a card's menu." }
        return store.paused ? "Clipboard history is paused. Resume it from the ⋯ menu (⌘T)."
            : "Copy text, links, images or files to keep them here."
    }

    private func symbol(_ kind: ClipboardEntry.Kind) -> String {
        switch kind { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .file: return "doc"; case .color: return "paintpalette" }
    }

    private func dragProvider(_ entry: ClipboardEntry) -> NSItemProvider {
        if let url = entry.fileURLs.first { return NSItemProvider(object: url as NSURL) }
        if let data = entry.imageData, let image = NSImage(data: data) { return NSItemProvider(object: image) }
        return NSItemProvider(object: (entry.text ?? entry.previewText) as NSString)
    }
}

// MARK: - App Metadata & Banner Color Cache

@MainActor
final class AppMetadataCache {
    static let shared = AppMetadataCache()
    private var iconCache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }

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
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var bins = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        var gray: (weight: CGFloat, value: CGFloat) = (0, 0)
        for x in 0..<side { for y in 0..<side {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.6 else { continue }
            let h = c.hueComponent, sat = c.saturationComponent, v = c.brightnessComponent
            if sat < 0.22 || v < 0.12 {
                gray.weight += 1; gray.value += v
                continue
            }
            let weight = sat * v
            let i = min(11, Int(h * 12))
            bins[i].weight += weight
            bins[i].r += c.redComponent * weight; bins[i].g += c.greenComponent * weight; bins[i].b += c.blueComponent * weight
        }}
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
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        let length = hexSanitized.count
        if length == 6 {
            self.init(
                red: Double((rgb & 0xFF0000) >> 16) / 255.0,
                green: Double((rgb & 0x00FF00) >> 8) / 255.0,
                blue: Double(rgb & 0x0000FF) / 255.0
            )
        } else if length == 8 {
            self.init(
                red: Double((rgb & 0xFF000000) >> 24) / 255.0,
                green: Double((rgb & 0x00FF0000) >> 16) / 255.0,
                blue: Double((rgb & 0x0000FF00) >> 8) / 255.0,
                opacity: Double(rgb & 0x000000FF) / 255.0
            )
        } else {
            return nil
        }
    }
}

// MARK: - Paste-style Luxury Card View

@MainActor
private struct ClipboardCardView: View {
    let entry: ClipboardEntry
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
    let isPreviewing: Bool
    let isSuggested: Bool
    let boards: [ClipboardPinboard]
    // Action targets only; deliberately not observed.
    let store: ClipboardStore
    let state: ClipboardPanelState
    let controller: ClipboardPanelController

    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var imagePreview: ClipboardThumbnailCache.Preview?
    @FocusState private var titleFocused: Bool

    static let radius: CGFloat = 16

    private var accent: Color { AppMetadataCache.shared.bannerColor(for: entry.sourceBundleID, name: entry.sourceName) }
    private var headerTitle: String {
        if let text = entry.text {
            let automatic = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(100) ?? "Text".prefix(100))
            return entry.title == automatic ? entry.kind.displayName : entry.title
        }
        if entry.kind == .file, entry.title == entry.fileURLs.map(\.lastPathComponent).joined(separator: ", ") {
            return entry.fileURLs.count == 1 ? "File" : "\(entry.fileURLs.count) Files"
        }
        return entry.title
    }
    private var appIcon: NSImage? {
        AppMetadataCache.shared.icon(for: entry.sourceBundleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    if isEditingTitle {
                        TextField("Title", text: $editedTitle)
                            .textFieldStyle(.plain).focused($titleFocused)
                            .onSubmit { commitTitle() }.onExitCommand { cancelTitle() }
                            .onChange(of: titleFocused) { _, focused in
                                if !focused && isEditingTitle { commitTitle() }
                            }
                    } else {
                        HStack(spacing: 4) {
                            if isSuggested {
                                Image(systemName: "sparkles").font(.system(size: compact ? 9 : 11, weight: .semibold))
                                    .help("Suggested for the app you are pasting into")
                                    .accessibilityLabel("Suggested")
                            }
                            Text(headerTitle).font(.system(size: compact ? 12 : 15, weight: .semibold)).lineLimit(1)
                        }
                    }
                    // "16 minutes ago", refreshed while the shelf is open.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ClipboardRelativeDate.string(entry.lastCopiedAt, now: context.date))
                            .font(.system(size: compact ? 10 : 12)).opacity(0.85).lineLimit(1)
                    }
                }
                .padding(.leading, 12).padding(.top, compact ? 6 : 8)
                Spacer(minLength: compact ? 38 : 52)
            }
            .foregroundStyle(.white)
            .frame(height: compact ? 38 : 48, alignment: .top)
            .background(accent)
            .overlay(alignment: .trailing) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFill()
                        .frame(width: compact ? 43 : 56, height: compact ? 43 : 56)
                        .offset(x: 3).help(entry.sourceName ?? "Source App")
                }
            }
            .clipped()

            ZStack(alignment: .bottom) {
                if entry.kind == .image { TransparencyGrid() }
                else { Color(nsColor: .textBackgroundColor) }
                previewContent
                    .padding(entry.kind == .image || entry.kind == .color ? 0 : compact ? 9 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // A solid-colour fade is far cheaper than a per-card mask.
                        if entry.kind == .text || entry.kind == .link {
                            LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 32).allowsHitTesting(false)
                        }
                    }
                if entry.kind == .image, !compact || side >= 150 {
                    HStack {
                        Spacer()
                        Text(metadataLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }.padding(8).allowsHitTesting(false)
                } else if ![.color, .image, .link].contains(entry.kind) {
                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        Text(metadataLabel).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(entry.kind == .file ? .head : .tail)
                        if entry.kind != .image { Spacer(minLength: 0) }
                        if isHovered && entry.kind != .image {
                            Button { beginTitleEdit() } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                                .buttonStyle(.plain).help("Rename Item")
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 9).padding(.top, 16)
                    .background {
                        if entry.kind != .image {
                            LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .allowsHitTesting(isHovered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrag { dragProvider(entry) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if showsQuickNumber, let quickNumber {
                Text("⌘\(quickNumber)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // Paste draws a 4 pt ring outside the card: accent while the shelf has
        // focus, gray while typing in the search field.
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.radius + 4, style: .continuous)
                    .strokeBorder(searchActive ? Color.secondary.opacity(0.7) : Color.accentColor, lineWidth: 4)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        // Paste selects on the first click immediately. An exclusive
        // double-tap gesture made every single click wait for the system
        // double-click interval (~0.5 s) before selecting; both recognisers
        // now run side by side, so the first click selects at once and the
        // second click of a double-click pastes.
        .simultaneousGesture(TapGesture(count: 1).onEnded { selectCard() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { pasteByDoubleClick() })
        .onHover { isHovered = $0 }
        .task(id: entry.id) {
            guard let data = entry.imageData else { imagePreview = nil; return }
            let preview = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
            guard !Task.isCancelled else { return }
            imagePreview = preview
        }
        .popover(isPresented: Binding(
            get: { isPreviewing },
            set: { if !$0 && state.preview?.id == entry.id { state.preview = nil } }
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
        return "\(entry.text?.count ?? 0) characters"
    }

    @ViewBuilder
    private var previewContent: some View {
        if compact && side < 150 {
            if entry.kind == .color, let hex = entry.text {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: hex) ?? .clear)
                    .overlay { Text(hex).font(.system(size: 10)).padding(.horizontal, 3).background(.regularMaterial, in: Capsule()) }
            } else if entry.kind == .image {
                thumbnailContent
            } else {
                Text(entry.kind == .link ? (URL(string: entry.text ?? "")?.host ?? entry.previewText) : entry.previewText)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if entry.kind == .image {
            thumbnailContent
        } else if entry.kind == .file {
            // Real Finder icons (stacked for several files), name below.
            VStack(spacing: 8) {
                ZStack {
                    ForEach(Array(entry.fileURLs.prefix(3).enumerated().reversed()), id: \.offset) { offset, url in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(width: compact ? 44 : 76, height: compact ? 44 : 76)
                            .rotationEffect(.degrees(Double(offset) * -6))
                            .offset(x: CGFloat(offset) * 7, y: CGFloat(offset) * -3)
                    }
                }
                Text(entry.fileURLs.count == 1 ? (entry.fileURLs.first?.lastPathComponent ?? entry.title)
                     : "\(entry.fileURLs.first?.lastPathComponent ?? "") and \(entry.fileURLs.count - 1) more")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entry.kind == .link {
            // No network previews (privacy): a site tile plus title and URL.
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.12))
                    Image(systemName: "safari")
                        .font(.system(size: compact ? 22 : 34, weight: .light))
                        .foregroundStyle(accent)
                }
                .frame(maxWidth: .infinity).frame(height: compact ? 44 : side * 0.36)
                Text(linkTitle)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .lineLimit(2)
                Text(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.previewText)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if entry.kind == .color, let hex = entry.text {
            Rectangle().fill(Color(hex: hex) ?? .clear)
                .overlay {
                    Text(hex).font(.system(size: compact ? 15 : 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
        } else {
            // Lay out only what fits: a 4,000-character preview per card made
            // every scroll frame re-measure large text blocks.
            Text(String(entry.previewText.prefix(cardTextBudget)))
                .font(.system(size: compact ? 11 : 14))
                .lineSpacing(2)
                .lineLimit(cardLineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary.opacity(0.88))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var linkTitle: String {
        let automatic = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.title != automatic, !entry.title.isEmpty { return entry.title }
        return URL(string: automatic ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
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
                         plainText: NSEvent.modifierFlags.contains(.shift), dismissAfterCopy: true)
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
        let targets = controller.actionTargets(for: entry)
        let many = targets.count > 1
        let suffix = many ? " \(targets.count) Items" : ""
        Button("\(controller.pasteActionTitle)\(suffix)") {
            controller.paste(ids: targets, dismissAfterCopy: true)
        }.keyboardShortcut(.return, modifiers: [])
        Button("Paste as Plain Text") { controller.paste(ids: targets, plainText: true, dismissAfterCopy: true) }
            .keyboardShortcut(.return, modifiers: .shift)
            .disabled(!many && entry.text == nil && entry.fileURLs.isEmpty)
        Button("Copy\(suffix)") {
            do { _ = try store.write(entryIDs: targets); state.status = many ? "Copied \(targets.count) items." : "Copied to clipboard." }
            catch { state.status = error.localizedDescription }
        }.keyboardShortcut("c", modifiers: .command)
        Divider()
        if !many {
            Button(entry.kind == .image ? "Edit Image…" : "Edit…") { controller.editEntry(entry) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(entry.kind == .file)
            Button("Rename…") { state.editor = .init(operation: .renameEntry(entry.id), title: "Rename Item", text: entry.title) }
                .keyboardShortcut("r", modifiers: .command)
        }
        Button("Delete\(suffix)", role: .destructive) {
            if many { state.pendingDeletion = targets } else { controller.delete(targets) }
        }.keyboardShortcut(.delete, modifiers: [])
        Divider()
        Menu(many ? "Pin \(targets.count) Items" : (entry.pinboardIDs.isEmpty ? "Pin" : "Pinboards")) {
            ForEach(boards) { board in
                let pinned = targets.allSatisfy { id in store.entries.first { $0.id == id }?.pinboardIDs.contains(board.id) == true }
                Button {
                    for id in targets {
                        if pinned { store.unpin(entryID: id, boardID: board.id) } else { store.pin(entryID: id, boardID: board.id) }
                    }
                } label: {
                    Label { Text(pinned ? "Unpin from \(board.name)" : board.name) } icon: {
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
        Button(many ? "Add \(targets.count) Items to Paste Stack" : "Add to Paste Stack") {
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

    private func shareItem(_ entry: ClipboardEntry) -> String {
        if let url = entry.fileURLs.first { return url.absoluteString }
        return entry.text ?? entry.title
    }

    private func dragProvider(_ entry: ClipboardEntry) -> NSItemProvider {
        let provider: NSItemProvider
        if let url = entry.fileURLs.first {
            provider = NSItemProvider(object: url as NSURL)
        } else if let data = entry.imageData, let image = NSImage(data: data) {
            provider = NSItemProvider(object: image)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.weight(.semibold))
            if request.isTextEditor {
                TextEditor(text: $text).font(.body).frame(minHeight: 180).border(Color.secondary.opacity(0.2)).focused($inputFocused)
                if text.utf8.count > ClipboardStore.maximumEntryBytes { Text("Text exceeds the item size limit").font(.caption).foregroundStyle(.red) }
            } else { TextField("Name", text: $text).textFieldStyle(.roundedBorder).focused($inputFocused) }
            if case .newBoard = request.operation {
                HStack(spacing: 10) {
                    Text("Color").font(.caption).foregroundStyle(.secondary)
                    ForEach(colors, id: \.self) { name in
                        Button { newBoardColor = name } label: {
                            Circle().fill(PasteClipboardPalette.board(name))
                                .frame(width: 20, height: 20)
                                .padding(4)
                                .overlay(Circle().strokeBorder(
                                    newBoardColor == name ? Color.primary : Color.clear,
                                    lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name) Pinboard")
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(request.isTextEditor ? "s" : .return, modifiers: request.isTextEditor ? .command : [])
                    .disabled(!canSave)
            }
        }.padding(24).frame(width: 460).onAppear { text = request.text; inputFocused = true }
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

    private func beginEditing() {
        let item = current
        controller.closePreview()
        DispatchQueue.main.async {
            state.editor = .init(operation: .editEntry(item.id), title: "Edit Content", text: item.text ?? "")
        }
    }

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53 { controller.closePreview(); return true }
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
        if (flags.isEmpty || flags == .shift), [36, 76].contains(event.keyCode) {
            controller.paste(ids: [current.id], plainText: flags == .shift, dismissAfterCopy: true)
            return true
        }
        if (flags == .command || flags == [.command, .shift]), event.keyCode == 8 {
            if flags == .command,
               let text = event.window?.firstResponder as? NSTextView,
               text.selectedRange().length > 0 { return false }
            do {
                if try store.write(entryIDs: [current.id], plainText: flags.contains(.shift)) {
                    state.status = "Copied to clipboard."
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
    private var summary: String {
        if let text = current.text {
            let words = text.split(whereSeparator: \.isWhitespace).count
            let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
            return "\(text.count.formatted()) characters · \(words.formatted()) words · \(lines.formatted()) lines"
        }
        if !current.fileURLs.isEmpty { return "\(current.fileURLs.count) file(s)" }
        if let data = current.imageData, let rep = NSBitmapImageRep(data: data) { return "\(rep.pixelsWide) × \(rep.pixelsHigh) pixels" }
        return current.kind.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.closePreview() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                }.help("Close Preview (Space / Esc)").accessibilityLabel("Close Preview")
                Text(current.kind.displayName).font(.system(size: 12, weight: .semibold))
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
                ClipboardPreviewShareButton(entry: current).frame(width: 24, height: 24)
                if current.kind == .image || canEditText {
                    Button("Edit") {
                        if current.kind == .image { controller.editEntry(current) }
                        else { beginEditing() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help("Edit Content (⌘E)")
                }
            }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 36)
            Group {
                if let data = current.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TransparencyGrid())
                } else if !current.fileURLs.isEmpty {
                    ClipboardFilesPreview(urls: current.fileURLs)
                } else {
                    ClipboardReadOnlyTextPreview(entry: current)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 5).padding(.top, 2)
            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 30)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ClipboardPreviewKeyHandler(controller: controller, handle: handlePreviewKey))
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
    func updateNSView(_ view: ScrollChromeView, context: Context) { view.mode = mode; view.attach() }

    final class ScrollChromeView: NSView {
        var mode: Mode
        private weak var scrollView: NSScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var applying = false
        init(mode: Mode) { self.mode = mode; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func layout() { super.layout(); attach() }
        func attach() {
            guard window != nil else { observations.removeAll(); scrollView = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
            let side: CGFloat = 10
            var squares = Path()
            for row in 0..<Int(ceil(size.height / side)) {
                for column in 0..<Int(ceil(size.width / side)) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
                }
            }
            context.fill(squares, with: .color(.primary.opacity(0.045)))
        }.background(Color(nsColor: .textBackgroundColor)).allowsHitTesting(false)
    }
}

// MARK: - Paste-like palette and height resizing, using original UI primitives.

private enum PasteClipboardPalette {
    static func type(_ kind: ClipboardEntry.Kind) -> Color {
        switch kind {
        case .text: return Color(red: 0.96, green: 0.28, blue: 0.32)
        case .link: return Color(red: 0.22, green: 0.76, blue: 0.37)
        case .image: return Color(red: 0.11, green: 0.60, blue: 0.95)
        case .file: return Color(red: 0.17, green: 0.55, blue: 0.97)
        case .color: return Color(red: 0.65, green: 0.33, blue: 0.88)
        }
    }
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
private struct PastePanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active)
                    .opacity(0.55))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
                .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    .allowsHitTesting(false))
        }
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
private struct ClipboardFilesPreview: View {
    let urls: [URL]
    @State private var selected = 0
    private var current: URL? { urls.indices.contains(selected) ? urls[selected] : urls.first }

    var body: some View {
        VStack(spacing: 0) {
            if let url = current {
                if urls.count > 1 {
                    HStack(spacing: 10) {
                        Button { selected = max(0, selected - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(selected == 0).help("Previous File")
                        Picker("File", selection: $selected) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { index, item in
                                Text("\(index + 1). \(item.lastPathComponent)").tag(index)
                            }
                        }.labelsHidden()
                        Text("\(selected + 1) / \(urls.count)").font(.caption).foregroundStyle(.secondary)
                        Button { selected = min(urls.count - 1, selected + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(selected >= urls.count - 1).help("Next File")
                    }.padding(10)
                    Divider()
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    ClipboardFileQuickLookView(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                        Text("File is no longer at its original location").font(.headline)
                        Text(url.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                }.padding(10)
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
