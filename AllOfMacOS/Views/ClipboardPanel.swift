import AppKit
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
    @Published var stack: [UUID] = []
    @Published var stackMode = false
    @Published var status = ""
    @Published var searchFocusToken = UUID()
    @Published var searchExpanded = false
    @Published var editor: ClipboardEditorRequest?
    @Published var preview: ClipboardEntry?
    @Published var editingTitleID: UUID?

    func results(in store: ClipboardStore) -> [ClipboardEntry] {
        store.filtered(query: query, kind: kind, source: source,
                       board: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? board : nil,
                       since: recentDays == 0 ? nil : Date().addingTimeInterval(-Double(recentDays) * 86400))
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
        focusedID = id
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
    private var dismissalGeneration = 0
    private var slidingOut = false
    private var store: ClipboardStore { .shared }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }
    func showStack() {
        state.stackMode = true
        store.onCapture = { [weak self] id in
            guard let self, self.state.stackMode else { return }
            if !self.state.stack.contains(id) { self.state.stack.append(id) }
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
    }

    func stopStack() {
        state.stackMode = false
        store.onCapture = nil
        stackPanel?.orderOut(nil)
    }

    /// Clear selected cards with Escape before dismissing the history.
    /// A sheet or inline title editor must receive Escape itself.
    @discardableResult
    func handleEscape() -> Bool {
        guard isVisible else { return false }
        if state.editor != nil || state.preview != nil || state.editingTitleID != nil {
            return false
        }
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
            panel.setFrame(NSRect(x: bounds.minX + 16, y: bounds.minY + 12,
                                  width: max(1, bounds.width - 32), height: targetHeight), display: true)
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

    /// Separate from automatic paste so a double-click only updates NSPasteboard.
    @discardableResult
    static func copyEntry(_ entryID: UUID, from store: ClipboardStore,
                          plainText: Bool = false) throws -> Bool {
        try store.write(entryIDs: [entryID], plainText: plainText)
    }

    private func slideDownAndHide() {
        guard let panel, panel.isVisible else { hide(); return }
        dismissalGeneration += 1
        let generation = dismissalGeneration
        slidingOut = true
        clearPanelInteractionState()

        // Paste sits just above the bottom screen edge; exit beneath that edge.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { hide(); return }
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
            }
        }
    }

    func pasteSelected(plainText: Bool = false) {
        var ids = state.selectedIDs(in: store)
        if ids.isEmpty, let first = state.results(in: store).first { ids = [first.id] }
        paste(ids: ids, plainText: plainText)
    }

    func pasteNext() {
        state.stack.removeAll { id in !store.entries.contains { $0.id == id } }
        guard let id = state.stack.first else { state.status = "The paste stack is empty."; return }
        // A stack shortcut may run with the panel closed, so its target is the
        // current foreground application, not an older panel session.
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            destination = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        paste(ids: [id], plainText: store.settings.plainText) { [weak self] in
            self?.state.stack.removeAll { $0 == id }
        }
    }

    func enqueueSelection() {
        for id in state.selectedIDs(in: store) where !state.stack.contains(id) { state.stack.append(id) }
        showStack()
        state.status = "\(state.stack.count) items queued. Paste Next inserts one item at a time."
    }

    func paste(ids: [UUID], plainText: Bool = false, copied: (() -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        do {
            guard try store.write(entryIDs: ids, plainText: plainText || store.settings.plainText) else { return }
        } catch { state.status = error.localizedDescription; return }
        if !store.settings.pasteDirectly || destination == nil {
            state.status = "Copied to clipboard."
            copied?()
            return
        }
        let target = destination
        hide()
        pasteTask?.cancel()
        guard let target, !target.isTerminated else { state.status = "The destination app has closed. Item copied only."; return }
        // Fixture previews must never activate another app or generate input.
        guard !PresetManager.isUIPreview, !PresetManager.isRunningTests else { copied?(); return }
        target.activate(options: [])
        pasteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            for _ in 0..<30 {
                guard !Task.isCancelled, !target.isTerminated else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty,
                  let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                self?.state.status = "Focus changed or a modifier is held. Item copied without pasting."
                return
            }
            for event in [down, up] {
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
                event.post(tap: .cghidEventTap)
            }
            copied?()
        }
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel, self.state.editor == nil, self.state.preview == nil else { return event }
            if event.type == .flagsChanged {
                self.state.commandHeld = event.modifierFlags.contains(.command)
                return event
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
                if self.state.searchFieldActive { self.state.filtersExpanded.toggle() }
                else { self.state.searchFocusToken = UUID() }
                return nil
            }
            if self.state.searchFieldActive && [48, 125].contains(event.keyCode) {
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
                guard hasSelection,
                      ClipboardHistoryKeyboard.selectionAction(
                        keyCode: event.keyCode,
                        characters: event.charactersIgnoringModifiers,
                        modifiers: event.modifierFlags) != nil else { return event }
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
        if command && event.charactersIgnoringModifiers?.lowercased() == "f" { state.searchFocusToken = UUID(); return true }
        if command && event.charactersIgnoringModifiers?.lowercased() == "n" {
            if shift {
                state.editor = .init(operation: .newBoard, title: "New Pinboard", text: "")
            } else {
                state.editor = .init(operation: .newText, title: "New Text Item", text: "")
            }
            return true
        }
        let activeEntries = state.results(in: store)
        if command && event.charactersIgnoringModifiers?.lowercased() == "c" {
            let ids = state.selectedIDs(in: store)
            guard !ids.isEmpty else { return false }
            do {
                _ = try store.write(entryIDs: ids, plainText: shift)
                state.status = "Copied \(ids.count == 1 ? "item" : "\(ids.count) items") to clipboard."
            } catch { state.status = error.localizedDescription }
            return true
        }
        if command && event.charactersIgnoringModifiers?.lowercased() == "t" {
            store.paused.toggle()
            return true
        }
        if command && event.charactersIgnoringModifiers?.lowercased() == "g",
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
           let item = activeEntries.first(where: { state.selected.contains($0.id) }) {
            switch action {
            case .preview:
                state.preview = item
            case .edit:
                if let text = item.text, [.text, .link, .color].contains(item.kind) {
                    state.editor = .init(operation: .editEntry(item.id), title: "Edit Content", text: text)
                } else {
                    state.preview = item // binary and file content opens safely, not as text
                }
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
        if command, let text = event.charactersIgnoringModifiers, let number = Int(text), (1...9).contains(number), entries.indices.contains(number - 1) {
            paste(ids: [entries[number - 1].id], plainText: shift); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { pasteSelected(plainText: shift); return true }
        let editingText = (panel?.firstResponder as? NSTextView)?.isEditable == true
        if !editingText && (event.keyCode == 123 || event.keyCode == 124), !entries.isEmpty {
            let current = entries.firstIndex { $0.id == state.focusedID }
                ?? entries.firstIndex { state.selected.contains($0.id) } ?? -1
            let next = min(max(current + (event.keyCode == 124 ? 1 : -1), 0), entries.count - 1)
            state.select(entries[next].id, in: entries, extend: shift)
            state.keyboardScrollTarget = entries[next].id
            return true
        }
        if !editingText && command && event.charactersIgnoringModifiers?.lowercased() == "a" { state.selected = Set(entries.map(\.id)); return true }
        if !editingText && (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let selectedIDs = state.selectedIDs(in: store)
            guard !selectedIDs.isEmpty else { return false }
            for id in selectedIDs { store.delete(entryID: id) }
            state.selected.removeAll()
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
                .frame(height: 8)
                .overlay(alignment: .center) {
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 46, height: 3)
                        .allowsHitTesting(false)
                }
                .help("Drag to resize clipboard panel. Compact Mode starts automatically.")
            headerBar
            Divider().opacity(0.10)
            carouselContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: 8)
        .onChange(of: state.searchFocusToken) { _, _ in
            state.searchExpanded = true
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
        .sheet(item: $state.editor) { request in ClipboardEditorSheet(request: request, store: store) }
        .sheet(item: $state.preview) { entry in ClipboardPreviewSheet(entry: entry, store: store) }
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
                    .help("Filters (⌘F)")
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
                    .background(NativeScrollIndicatorsDisabled())
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
        .frame(height: 48)
        }
        .frame(height: 48)
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
            Text("Type").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                filterChip("All", icon: "square.grid.2x2", selected: state.kind == nil) { state.kind = nil }
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    filterChip(kind.displayName, icon: symbol(kind), selected: state.kind == kind) { state.kind = kind }
                }
            }
            Text("App").font(.caption).foregroundStyle(.secondary)
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
            HStack(spacing: 5) {
                ForEach([0, 1, 7, 30], id: \.self) { days in
                    filterChip(days == 0 ? "Any" : days == 1 ? "Today" : "\(days) days", icon: nil,
                               selected: state.recentDays == days) { state.recentDays = days }
                }
            }
        }.padding(18).frame(width: 340)
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
            let cardSide = min(300, max(100, geometry.size.height - 24))
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
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, compact ? 7 : 9)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                            .background(NativeScrollIndicatorsDisabled())
                        }
                        .scrollIndicators(.hidden)
                        .background(NativeScrollIndicatorsDisabled())
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
            return Color(red: 0.12, green: 0.44, blue: 0.88)
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
            return Color(red: 0.80, green: 0.60, blue: 0.38)
        } else if key.contains("paste") {
            return Color(red: 0.92, green: 0.30, blue: 0.42)
        } else if key.contains("code") || key.contains("cursor") {
            return Color(red: 0.12, green: 0.40, blue: 0.76)
        }

        let hash = (key.isEmpty ? "default" : key).utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let palette: [Color] = [
            Color(red: 0.12, green: 0.45, blue: 0.90),
            Color(red: 0.46, green: 0.22, blue: 0.76),
            Color(red: 0.86, green: 0.32, blue: 0.45),
            Color(red: 0.15, green: 0.62, blue: 0.58),
            Color(red: 0.88, green: 0.48, blue: 0.18),
            Color(red: 0.25, green: 0.45, blue: 0.85),
            Color(red: 0.22, green: 0.58, blue: 0.36)
        ]
        return palette[Int(hash % UInt64(palette.count))]
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
    private var appIcon: NSImage? {
        AppMetadataCache.shared.icon(for: entry.sourceBundleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if isEditingTitle {
                            TextField("Title", text: $editedTitle)
                                .textFieldStyle(.plain)
                                .focused($titleFocused)
                                .onSubmit { commitTitle() }
                                .onExitCommand { cancelTitle() }
                                .onChange(of: titleFocused) { _, focused in
                                    if !focused && isEditingTitle { commitTitle() }
                                }
                        } else {
                            Text(entry.title)
                                .font(.system(size: compact ? 12 : 15, weight: .semibold))
                                .lineLimit(1)
                                .onTapGesture(count: 2) { beginTitleEdit() }
                                .help("Double-click to rename")
                        }
                        if !entry.pinboardIDs.isEmpty {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                        }
                    }
                    Text(entry.lastCopiedAt, style: .relative)
                        .font(.system(size: compact ? 10 : 12))
                        .opacity(0.87)
                }
                Spacer(minLength: 4)
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 32 : 48, height: compact ? 32 : 48)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.15), radius: 1)
                        .help(entry.sourceName ?? "Source App")
                } else {
                    Image(systemName: symbol(entry.kind))
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.17),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, 7)
            .frame(height: compact ? 44 : 56, alignment: .top)
            .background(accent)

            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                previewContent
                    .padding(compact ? 7 : 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { copyByDoubleClick() }
            .background(ImmediateMouseSelection(select: selectCard))
            .onDrag { dragProvider(entry) }

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Text(metadataLabel)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovered || isSelected {
                    Button { beginTitleEdit() } label: {
                        Image(systemName: "pencil").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Rename Item")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 22 : 28)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if state.commandHeld && number <= 9 {
                Text("⌘\(number)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                              lineWidth: isSelected ? 3 : 0.5)
        }
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08),
                radius: isSelected ? 8 : 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .task(id: entry.id) {
            guard let data = entry.imageData else { imagePreview = nil; return }
            let preview = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
            guard !Task.isCancelled else { return }
            imagePreview = preview
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
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(hex: hex) ?? Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.1)))
                    .frame(height: compact ? 42 : 70)
                Text(hex)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(entry.previewText)
                .font(.system(size: compact ? 11 : 14))
                .lineSpacing(2)
                .lineLimit(compact ? 5 : 10)
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

    private func copyByDoubleClick() {
        guard !isEditingTitle else { return }
        controller.copyAndSlideDown(
            entryID: entry.id,
            plainText: NSEvent.modifierFlags.contains(.shift) && entry.text != nil
        )
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
        Button("Preview…") { state.preview = entry }
        Button("Rename…") { state.editor = .init(operation: .renameEntry(entry.id), title: "Rename Item", text: entry.title) }
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
    private let colors = ["red", "orange", "yellow", "green", "blue", "purple"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.weight(.semibold))
            if request.isTextEditor {
                TextEditor(text: $text).font(.body).frame(minHeight: 180).border(Color.secondary.opacity(0.2))
            } else { TextField("Name", text: $text).textFieldStyle(.roundedBorder) }
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
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460).onAppear { text = request.text }
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
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draftText = ""

    private var current: ClipboardEntry {
        store.entries.first(where: { $0.id == entry.id }) ?? entry
    }
    private var canEditText: Bool {
        current.text != nil && [.text, .link, .color].contains(current.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: current.kind.symbol).foregroundStyle(Color.accentColor)
                Text(current.title).font(.headline).lineLimit(1)
                Spacer()
                if canEditText && !editing {
                    Button("Edit Content") {
                        draftText = current.text ?? ""
                        editing = true
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Edit selected clipboard text (⌘E)")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if editing {
                TextEditor(text: $draftText)
                    .font(.body)
                    .frame(minHeight: 270)
                    .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.2)))
                HStack {
                    Spacer()
                    Button("Discard Changes") { editing = false }
                    Button("Save Changes") {
                        store.editText(entryID: current.id, text: draftText)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftText.utf8.count > ClipboardStore.maximumEntryBytes)
                }
            } else if let data = current.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .accessibilityLabel("Image preview: \(current.title)")
            } else if !current.fileURLs.isEmpty {
                VStack(spacing: 12) {
                    // Paste's file preview can be built with public QuickLookUI.
                    if current.fileURLs.count == 1, let url = current.fileURLs.first,
                       FileManager.default.fileExists(atPath: url.path) {
                        ClipboardFileQuickLookView(url: url).frame(height: 290)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(current.fileURLs, id: \.self) { url in
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().scaledToFit().frame(width: 28, height: 28)
                                    Text(url.lastPathComponent).lineLimit(2).textSelection(.enabled)
                                    Spacer()
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }
                    }.frame(minHeight: 56, maxHeight: 125)
                }
            } else {
                ScrollView {
                    Text(current.text ?? current.previewText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 300)
            }

            HStack(spacing: 8) {
                if let icon = AppMetadataCache.shared.icon(for: current.sourceBundleID) {
                    Image(nsImage: icon).resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Text(current.sourceName ?? "Clipboard")
                Spacer()
                Text(current.kind.displayName)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 650)
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

// Suppress the macOS scrollbar itself, not just SwiftUI's indicator drawing.
// This backing view is hit-test transparent; unlike the old invisible scroller
// injection, it cannot intercept card clicks, drags, or gestures.
private final class NativeScrollIndicatorsDisabledView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateScrollView() {
        // SwiftUI may recreate/configure its NSScrollView after an update.
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.enclosingScrollView else { return }
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScrollView()
    }
}

private struct NativeScrollIndicatorsDisabled: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeScrollIndicatorsDisabledView {
        let view = NativeScrollIndicatorsDisabledView(frame: .zero)
        view.updateScrollView()
        return view
    }

    func updateNSView(_ nsView: NativeScrollIndicatorsDisabledView, context: Context) {
        nsView.updateScrollView()
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
