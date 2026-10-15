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
    @Published var status = ""
    @Published var searchFocusToken = UUID()
    @Published var searchExpanded = false
    @Published var editor: ClipboardEditorRequest?
    @Published var preview: ClipboardEntry?
    @Published var editingTitleID: UUID?

    func results(in store: ClipboardStore) -> [ClipboardEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let since: Date?
        switch recentDays {
        case -1: since = calendar.date(byAdding: .day, value: -1, to: today)
        case 1: since = today
        case 0: since = nil
        default: since = calendar.date(byAdding: .day, value: -(recentDays - 1), to: today)
        }
        return store.filtered(query: query, kind: kind, source: source,
                              board: board, since: since)
            .filter { recentDays != -1 || $0.lastCopiedAt < today }
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

    func toggle() { isVisible ? hide() : show() }
    func showStack() {
        state.stackMode = true
        store.onCapture = { [weak self] id in
            guard let self, self.state.stackMode else { return }
            self.state.stack.append(id)
        }
        if stackPanel == nil {
            let window = ClipboardStackPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 420),
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
                let next = state.stack.first
                do {
                    if let next {
                        // Write before replaying the intercepted event. Do not
                        // pre-load the following item until this paste settles.
                        _ = try store.write(entryIDs: [next], plainText: plainText || store.settings.plainText, playSound: false)
                    }
                    guard ClipboardStackPasteMonitor.sendPaste(to: target) else { continue }
                    if let next {
                        if state.stack.first == next { state.stack.removeFirst() }
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
        if state.filtersExpanded {
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
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            let storedHeight = CGFloat(UserDefaults.standard.double(forKey: "AOMClipboardPanelHeight"))
            let targetHeight = min(max(storedHeight > 0 ? storedHeight : 332, 175),
                                   max(120, (bounds.height - 36) / 2))
            panel.setFrame(NSRect(x: bounds.minX + 8, y: bounds.minY + 8,
                                  width: max(1, bounds.width - 16), height: targetHeight), display: true)
        }
        state.status = destination == nil ? "Choose an item to copy. Open history from another app to paste directly." : ""
        state.searchExpanded = !state.query.isEmpty
        state.commandHeld = NSEvent.modifierFlags.contains(.command)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
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
        guard let panel, panel.isVisible else { hide(); completion(); return }
        dismissalGeneration += 1
        let generation = dismissalGeneration
        slidingOut = true
        clearPanelInteractionState()

        // Paste sits just above the bottom screen edge; exit beneath that edge.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { hide(); completion(); return }
        let bottomEdge = (panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? panel.frame.minY
        var offscreenFrame = panel.frame
        offscreenFrame.origin.y = bottomEdge - offscreenFrame.height - 20
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.23
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreenFrame, display: true)
            panel.animator().alphaValue = 0
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
        paste(ids: ids, plainText: plainText, directly: true)
    }

    func pasteNext() {
        state.stack.removeAll { id in !self.store.entries.contains { $0.id == id } }
        guard let id = state.stack.first else { state.status = "The paste stack is empty."; return }
        // A stack shortcut may run with the panel closed, so its target is the
        // current foreground application, not an older panel session.
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            destination = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        paste(ids: [id], plainText: store.settings.plainText) { [weak self] in
            if self?.state.stack.first == id { self?.state.stack.removeFirst() }
        }
    }

    func enqueueSelection() {
        for id in state.selectedIDs(in: store) where !state.stack.contains(id) { state.stack.append(id) }
        showStack()
        state.status = "\(state.stack.count) items queued. Press ⌘V in your destination to paste them in order."
    }

    func paste(ids: [UUID], plainText: Bool = false, directly: Bool = false,
               copied: (() -> Void)? = nil) {
        guard !ids.isEmpty, !slidingOut else { return }
        do {
            guard try store.write(entryIDs: ids, plainText: plainText || store.settings.plainText,
                                  playSound: false) else { return }
        } catch { state.status = error.localizedDescription; return }
        guard (directly || store.settings.pasteDirectly), let target = destination,
              !target.isTerminated else {
            ClipboardAudioFeedback.copy()
            state.status = "Copied to clipboard."
            copied?()
            if directly { slideDownAndHide() }
            return
        }
        pasteTask?.cancel()
        // Capture the destination before dismissal clears selection/focus.
        slideDownAndHide { [weak self] in
            guard let self else { return }
            guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { copied?(); return }
            target.activate(options: [])
            self.pasteTask = Task { @MainActor [weak self] in
                // Wait for focus and physical modifiers, including Command held
                // for a quick-paste badge. Never inject into a different app.
                for _ in 0..<200 {
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
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
                self?.state.status = "Destination unavailable or a modifier is held. Item copied without pasting."
            }
        }
    }

    func editEntry(_ item: ClipboardEntry) {
        if item.kind == .image, let data = item.imageData,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let capture = CaptureHistoryEntry(image: image, kind: .area, capturedAt: item.createdAt,
                                             windowTitle: item.title, fileURL: nil)
            hide()
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
            store.paused.toggle()
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
            paste(ids: [quickIDs[number - 1]], plainText: shift, directly: true); return true
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
        if !editingText && command && event.keyCode == 0 { state.selected = Set(entries.map(\.id)); return true }
        if !editingText && (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let selectedIDs = state.selectedIDs(in: store)
            guard !selectedIDs.isEmpty else { return false }
            store.delete(entryIDs: selectedIDs)
            state.clearSelection()
            let remaining = state.results(in: store)
            if let index = entries.firstIndex(where: { selectedIDs.contains($0.id) }), !remaining.isEmpty {
                let next = remaining[min(index, remaining.count - 1)]
                state.select(next.id, in: remaining)
                state.keyboardScrollTarget = next.id
            }
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

    private var entries: [ClipboardEntry] { state.results(in: store) }
    private var sources: [String] { Array(Set(store.entries.compactMap(\.sourceBundleID))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            PastePanelResizeGrip()
                .frame(height: 4)
                .help("Drag to resize clipboard panel")
            headerBar
            if state.searchExpanded {
                searchSuggestions
            }
            carouselContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
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
        .sheet(item: $state.editor) { request in ClipboardEditorSheet(request: request, store: store) }
    }

    // MARK: - Paste-inspired search, horizontal pinboards and filters

    // Keep layout arithmetic outside the SwiftUI view-builder expression.
    private func pinboardScrollWidth(containerWidth: CGFloat) -> CGFloat {
        let boardsWidth = store.boards.reduce(CGFloat(170)) { total, board in
            total + min(CGFloat(190), CGFloat(board.name.count * 8 + 35))
        }
        let available = containerWidth - (state.searchExpanded ? CGFloat(530) : CGFloat(160))
        return max(CGFloat(90), min(CGFloat(560), min(available, boardsWidth)))
    }

    private var searchSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if store.indexingImages {
                    ProgressView().controlSize(.mini)
                    Text("Indexing image text…").font(.caption).foregroundStyle(.secondary)
                }
                if state.query.isEmpty {
                    ForEach(state.recentSearches, id: \.self) { query in
                        Button(query) { state.query = query }.buttonStyle(.bordered).controlSize(.mini)
                    }
                    ForEach(ClipboardEntry.Kind.allCases) { kind in
                        Button { state.query = "type:\(kind.rawValue) " } label: {
                            Label(kind.displayName, systemImage: kind.symbol)
                        }.buttonStyle(.bordered).controlSize(.mini)
                    }
                } else {
                    Text("\(entries.count) results").font(.caption).foregroundStyle(.secondary)
                }
                Text("Use quotes for phrases · from:Safari · board:Work · after:2026-01-01 · -exclude")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 7)
        }.fixedSize(horizontal: false, vertical: true)
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
                        .frame(width: min(300, max(140, geometry.size.width * 0.22)))
                        .accessibilityIdentifier("PasteStyleClipboardSearch")
                        .onSubmit {
                            state.rememberSearch()
                            searchFocused = false
                            if let first = entries.first { state.select(first.id, in: entries) }
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
                                    Button("Rename Pinboard…") {
                                        state.editor = .init(operation: .renameBoard(board.id), title: "Rename Pinboard", text: board.name)
                                    }
                                    Menu("Color") {
                                        ForEach(["red", "orange", "yellow", "green", "blue", "purple"], id: \.self) { color in
                                            Button(color.capitalized) { store.setBoardColor(id: board.id, color: color) }
                                        }
                                    }
                                    Button("Delete Pinboard", role: .destructive) {
                                        store.deleteBoard(id: board.id)
                                        if state.board == board.id { state.selectBoard(nil) }
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
                compactTypeMenu
                compactTimeMenu
                compactAppMenu
                if state.kind != nil || state.source != nil || state.recentDays != 0 {
                    Button("Clear Filters") { state.kind = nil; state.source = nil; state.recentDays = 0 }
                }
                Divider()
                Button("Paste Stack…") { controller.showStack() }
                Button("Add Selection to Stack") { controller.enqueueSelection() }
                    .disabled(state.selected.isEmpty)
                Button(store.paused ? "Resume Clipboard History" : "Pause Clipboard History") { store.paused.toggle() }
                Button("Undo Delete (⌘Z)") {
                    let restored = store.undoDeletion()
                    state.selected = Set(restored)
                    state.focusedID = restored.first
                }.disabled(!store.canUndoDeletion)
                Button("New Text…") { state.editor = .init(operation: .newText, title: "New Text", text: "") }
                Button("Close (Esc)") { controller.hide() }
                Text("\(entries.count) items")
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Filters").font(.headline)
                Spacer()
                Button("Clear") { state.kind = nil; state.source = nil; state.recentDays = 0 }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(!hasFilters)
            }
            Text("Content Type").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                filterChip("All", icon: "square.grid.2x2", selected: state.kind == nil) { state.kind = nil }
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    filterChip(kind.displayName, icon: symbol(kind), selected: state.kind == kind) { state.kind = kind }
                }
            }
            Text("Source App").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112))], spacing: 6) {
                    filterChip("All Apps", icon: "app", selected: state.source == nil) { state.source = nil }
                    ForEach(sources, id: \.self) { source in
                        filterChip(store.entries.first { $0.sourceBundleID == source }?.sourceName ?? source,
                                   icon: nil, appIcon: AppMetadataCache.shared.icon(for: source),
                                   selected: state.source == source) { state.source = source }
                    }
                }
            }.frame(maxHeight: 142)
            Text("Date").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116))], spacing: 5) {
                ForEach([0, 1, -1, 7, 30], id: \.self) { days in
                    filterChip(days == 0 ? "Any" : days == 1 ? "Today" : days == -1 ? "Yesterday" : "Past \(days) Days", icon: nil,
                               selected: state.recentDays == days) { state.recentDays = days }
                }
            }
            Text("Pinboards").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112))], spacing: 6) {
                    filterChip("All Clipboard", icon: "tray", selected: state.board == nil) { state.selectBoard(nil) }
                    ForEach(store.boards) { board in
                        filterChip(board.name, icon: "pin", selected: state.board == board.id) { state.selectBoard(board.id) }
                    }
                }
            }.frame(maxHeight: 100)
        }.padding(18).frame(width: 420)
    }

    private func filterChip(_ title: String, icon: String?, appIcon: NSImage? = nil,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let appIcon {
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
            .frame(maxWidth: .infinity).padding(.vertical, 7).padding(.horizontal, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.065), in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: - Filters in the overflow menu

    private var compactTypeMenu: some View {
        Menu("Filter by Type") {
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
        Menu("Filter by App") {
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
        Menu("Filter by Time") {
            Button("Any Time") { state.recentDays = 0 }
            Divider()
            Button("Last 24 Hours") { state.recentDays = 1 }
            Button("Last 7 Days") { state.recentDays = 7 }
            Button("Last 30 Days") { state.recentDays = 30 }
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
                        Image(systemName: "clipboard")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(store.isLoading ? "Loading Clipboard…" : "No clipboard items")
                            .font(.headline)
                        Text(state.query.isEmpty
                             ? "Copy text, links, images or files to keep them here."
                             : "Try another search or clear the filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: compact ? 14 : 22) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    ClipboardCardView(entry: entry, number: index + 1,
                                                      compact: compact, side: cardSide, store: store,
                                                      state: state, controller: controller)
                                        .id(entry.id)
                                        .background(GeometryReader { cardGeometry in
                                            Color.clear.preference(key: ClipboardVisibleCardsKey.self,
                                                value: [entry.id: cardGeometry.frame(in: .named("clipboardViewport"))])
                                        })
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, compact ? 8 : 12)
                            .padding(.bottom, compact ? 12 : 24)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                            .background(NativeScrollChrome(.hidden))
                        }
                        .coordinateSpace(name: "clipboardViewport")
                        .onPreferenceChange(ClipboardVisibleCardsKey.self) { frames in
                            let viewport = CGRect(origin: .zero, size: geometry.size)
                            let ids = frames.filter { $0.value.intersects(viewport) }
                                .sorted { $0.value.minX < $1.value.minX }.map(\.key)
                            if state.visibleCardIDs != ids { state.visibleCardIDs = ids }
                        }
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

    func bannerColor(for bundleID: String?, name: String?) -> Color {
        let key = (bundleID ?? name ?? "").lowercased()
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
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardPanelState
    let controller: ClipboardPanelController

    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var imagePreview: ClipboardThumbnailCache.Preview?
    @FocusState private var titleFocused: Bool

    private var isSelected: Bool { state.selected.contains(entry.id) }

    private var accent: Color { AppMetadataCache.shared.bannerColor(for: entry.sourceBundleID, name: entry.sourceName) }
    private var headerTitle: String {
        if let text = entry.text {
            let automatic = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(100) ?? "Text".prefix(100))
            return entry.title == automatic ? entry.kind.displayName : entry.title
        }
        if entry.kind == .file, entry.title == entry.fileURLs.map(\.lastPathComponent).joined(separator: ", ") {
            return entry.fileURLs.count == 1 ? "File" : "Files"
        }
        return entry.title
    }
    private var quickNumber: Int? { state.quickPasteIDs(in: store).firstIndex(of: entry.id).map { $0 + 1 } }
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
                        Text(headerTitle).font(.system(size: compact ? 12 : 15, weight: .semibold)).lineLimit(1)
                    }
                    Text(entry.lastCopiedAt, style: .relative)
                        .font(.system(size: compact ? 10 : 12)).opacity(0.85)
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
                    .mask {
                        if entry.kind == .text || entry.kind == .link {
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
                            }
                        } else { Color.black }
                    }
                if entry.kind != .color {
                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        Text(metadataLabel).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).lineLimit(1)
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if state.commandHeld, let quickNumber {
                Text("⌘\(quickNumber)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                              lineWidth: isSelected ? 3 : 0.5)
        }
        .shadow(color: .black.opacity(isSelected ? 0.10 : 0.05),
                radius: isSelected ? 5 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .background(ImmediateMouseSelection(select: selectCard))
        .onTapGesture(count: 2) { pasteByDoubleClick() }
        .onHover { isHovered = $0 }
        .task(id: entry.id) {
            guard let data = entry.imageData else { imagePreview = nil; return }
            let preview = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
            guard !Task.isCancelled else { return }
            imagePreview = preview
        }
        .popover(isPresented: Binding(
            get: { state.preview?.id == entry.id },
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
        if entry.kind == .file { return "\(entry.fileURLs.count) files" }
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
            VStack(spacing: 7) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: compact ? 25 : 36, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                Text(entry.fileURLs.first?.lastPathComponent ?? entry.title)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entry.kind == .link {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.green)
                    Spacer()
                }
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(URL(string: entry.text ?? "")?.host ?? entry.previewText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
            Text(entry.previewText)
                .font(.system(size: compact ? 11 : 14))
                .lineSpacing(2)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary.opacity(0.88))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

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
        state.select(entry.id, in: state.results(in: store),
                     extend: NSEvent.modifierFlags.contains(.shift),
                     toggle: NSEvent.modifierFlags.contains(.command))
    }

    private func pasteByDoubleClick() {
        guard !isEditingTitle else { return }
        controller.paste(ids: [entry.id],
                         plainText: NSEvent.modifierFlags.contains(.shift), directly: true)
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

    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry) -> some View {
        Button("Paste") { controller.paste(ids: [entry.id]) }
        Button("Paste as Plain Text") { controller.paste(ids: [entry.id], plainText: true) }.disabled(entry.text == nil)
        Button("Copy") { do { _ = try store.write(entryIDs: [entry.id]); state.status = "Copied to clipboard." } catch { state.status = error.localizedDescription } }
        Button("Add to Paste Stack") { if !state.stack.contains(entry.id) { state.stack.append(entry.id) }; controller.showStack() }
        Divider()
        Menu("Pinboard") {
            ForEach(store.boards) { board in
                Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                    if entry.pinboardIDs.contains(board.id) { store.unpin(entryID: entry.id, boardID: board.id) }
                    else { store.pin(entryID: entry.id, boardID: board.id) }
                }
            }
            if store.boards.isEmpty { Text("Create a pinboard with + above") }
        }
        Button("Preview…") { controller.openPreview(entry) }
        Button("Rename…") { state.editor = .init(operation: .renameEntry(entry.id), title: "Rename Item", text: entry.title) }
        if entry.kind == .image {
            Button("Edit Image…") { controller.editEntry(entry) }
            Button("Copy Text from Image") {
                do { try store.copyRecognizedText(entryID: entry.id); state.status = "Image text copied." }
                catch { state.status = error.localizedDescription }
            }.disabled(entry.recognizedText?.isEmpty != false)
        }
        if let text = entry.text { Button("Edit Text…") { state.editor = .init(operation: .editEntry(entry.id), title: "Edit Text", text: text) } }
        Button("Duplicate") { _ = store.duplicate(entryID: entry.id) }
        if !entry.fileURLs.isEmpty { Button("Reveal in Finder") { if !PresetManager.isUIPreview { NSWorkspace.shared.activateFileViewerSelecting(entry.fileURLs) } } }
        if entry.kind == .link, let text = entry.text, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            Button("Open Link") { if !PresetManager.isUIPreview { NSWorkspace.shared.open(url) } }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(entryID: entry.id); state.selected.remove(entry.id) }
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
    private let colors = ["red", "orange", "yellow", "green", "blue", "purple"]

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
    @State private var editing = false
    @State private var draftText = ""
    @State private var discardRequested = false
    @FocusState private var editorFocused: Bool

    private var canSave: Bool { draftText.utf8.count <= ClipboardStore.maximumEntryBytes }
    private var position: Int? { state.results(in: store).firstIndex { $0.id == entry.id } }
    private func beginEditing() {
        draftText = current.text ?? ""
        editing = true
        editorFocused = true
    }
    private func saveEditing() {
        guard canSave else { return }
        store.editText(entryID: current.id, text: draftText)
        editing = false
        editorFocused = false
    }
    private func requestClose() {
        if editing && draftText != (current.text ?? "") { discardRequested = true }
        else { controller.closePreview() }
    }

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        guard !discardRequested else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53 { requestClose(); return true }
        if flags == .command, event.keyCode == 14, current.kind == .image {
            if !event.isARepeat { controller.editEntry(current) }
            return true
        }
        if flags == .command, event.keyCode == 14, canEditText {
            if !event.isARepeat { editing ? saveEditing() : beginEditing() }
            return true
        }
        if flags == .command, event.keyCode == 1, editing { saveEditing(); return true }
        // Spaces, arrows, Return and normal copy/select-all belong to the text editor.
        guard !editing else { return false }
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
            controller.paste(ids: [current.id], plainText: flags == .shift, directly: true)
            return true
        }
        if (flags == .command || flags == [.command, .shift]), event.keyCode == 8 {
            if flags == .command,
               let text = event.window?.firstResponder as? NSTextView,
               text.selectedRange().length > 0 { return false }
            copyCurrent(plainText: flags.contains(.shift))
            return true
        }
        return false
    }

    private func copyCurrent(plainText: Bool = false) {
        do {
            if try store.write(entryIDs: [current.id], plainText: plainText) {
                state.status = "Copied to clipboard."
            }
        } catch { state.status = error.localizedDescription }
    }

    private var current: ClipboardEntry { store.entries.first { $0.id == entry.id } ?? entry }
    private var canEditText: Bool { current.text != nil && [.text, .link, .color].contains(current.kind) }
    private var previewSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(720, max(320, screen.width - 48)), height: min(520, max(260, screen.height - 200)))
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
                Button { requestClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .help("Close Preview (Space / Esc)")
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
                } label: { Image(systemName: current.pinboardIDs.isEmpty ? "circle" : "pin.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize().help("Pinboard")
                Button { copyCurrent() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Item (⌘C)").disabled(editing)
                ClipboardPreviewShareButton(entry: current).frame(width: 26, height: 26)
                    .disabled(editing)
                if current.kind == .image {
                    Button("Copy Text") {
                        do { try store.copyRecognizedText(entryID: current.id); state.status = "Image text copied." }
                        catch { state.status = error.localizedDescription }
                    }.disabled(current.recognizedText?.isEmpty != false).help("Copy recognized image text")
                    Button("Edit Image") { controller.editEntry(current) }.help("Edit Image (⌘E)")
                }
                if canEditText {
                    Button(editing ? "Save" : "Edit") {
                        editing ? saveEditing() : beginEditing()
                    }
                    .help(editing ? "Save Changes (⌘S / ⌘E)" : "Edit Content (⌘E)")
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .disabled(editing && !canSave)
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 12).frame(height: 36)
            Divider().opacity(0.4)
            Group {
                if editing {
                    TextEditor(text: $draftText).font(.system(size: 13)).focused($editorFocused)
                        .scrollContentBackground(.hidden).padding(8)
                        .background(NativeScrollChrome(.overlay))
                } else if let data = current.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TransparencyGrid())
                } else if !current.fileURLs.isEmpty {
                    ClipboardFilesPreview(urls: current.fileURLs)
                } else {
                    ScrollView(.vertical) {
                        Text(current.text ?? current.previewText).font(.system(size: 13)).lineSpacing(2)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12).background(NativeScrollChrome(.overlay))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            Divider().opacity(0.4)
            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if editing {
                    if !canSave { Text("Text exceeds the item size limit").foregroundStyle(.red).font(.caption) }
                    Button("Discard") { editing = false; editorFocused = false }.buttonStyle(.plain).font(.system(size: 11))
                } else if let position {
                    Button { controller.movePreview(from: current.id, offset: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(position == 0).help("Previous Item (←)")
                    Text("\(position + 1) / \(state.results(in: store).count)").font(.system(size: 11)).monospacedDigit()
                    Button { controller.movePreview(from: current.id, offset: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(position + 1 >= state.results(in: store).count).help("Next Item (→)")
                }
            }.padding(.horizontal, 12).frame(height: 28)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .background(.regularMaterial)
        .background(ClipboardPreviewKeyHandler(controller: controller, handle: handlePreviewKey))
        .interactiveDismissDisabled(editing)
        .alert("Discard changes?", isPresented: $discardRequested) {
            Button("Keep Editing", role: .cancel) { editorFocused = true }
            Button("Discard", role: .destructive) { controller.closePreview() }
        } message: { Text("Your changes to this clipboard item have not been saved.") }
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
    static func board(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        default: return .blue
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
            initialY = window.convertPoint(toScreen: event.locationInWindow).y
            initialHeight = window.frame.height
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let y = window.convertPoint(toScreen: event.locationInWindow).y
            let maxHeight = max(120, ((window.screen?.visibleFrame.height ?? 900) - 36) / 2)
            let height = min(max(175, initialHeight + y - initialY), maxHeight)
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
