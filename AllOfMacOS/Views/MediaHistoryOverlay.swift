import SwiftUI
import AppKit

/// A top-edge capture shelf, separate from the bottom-edge clipboard history.
private final class MediaHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            MediaHistoryOverlayController.shared.handleEscape()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        MediaHistoryOverlayController.shared.handleEscape()
    }
}

@MainActor
final class MediaHistoryOverlayController: NSObject {
    static let shared = MediaHistoryOverlayController()

    private var panel: MediaHistoryPanel?
    private(set) var isPresented = false
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var activationObserver: Any?
    var isShowingSheet = false
    var onEscape: (() -> Bool)?
    var onDeleteSelection: (() -> Bool)?
    var onNavigate: ((UInt16) -> Bool)?
    var onCommand: ((NSEvent) -> Bool)?

    private override init() {
        super.init()
    }

    func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        guard !isPresented else { return }
        CaptureHistory.shared.applyRetention()

        let targetScreen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let panelHeight: CGFloat = min(332, max(120, (screen.visibleFrame.height - 36) / 2))
        let panelWidth: CGFloat = max(1, screen.visibleFrame.width - 32)

        let targetX = screen.visibleFrame.midX - panelWidth / 2
        let targetY = screen.visibleFrame.maxY - panelHeight - 12
        let endFrame = NSRect(x: targetX, y: targetY, width: panelWidth, height: panelHeight)
        let startFrame = NSRect(x: targetX, y: targetY + 12, width: panelWidth, height: panelHeight)

        if panel == nil {
            let p = MediaHistoryPanel(
                contentRect: startFrame,
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isFloatingPanel = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: MediaHistoryOverlayView(controller: self))
            panel = p
        }

        guard let panel = panel else { return }

        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        panel.makeKey()
        isPresented = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        setupDismissMonitors()
    }

    func dismiss() {
        guard isPresented, let panel = panel else { return }
        isPresented = false
        isShowingSheet = false
        teardownDismissMonitors()

        let currentFrame = panel.frame
        let offscreenY = currentFrame.minY + 12
        let exitFrame = NSRect(x: currentFrame.minX, y: offscreenY, width: currentFrame.width, height: currentFrame.height)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(exitFrame, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // An older dismissal animation must not hide a newly reopened panel.
                if !self.isPresented { panel.orderOut(nil) }
            }
        })
    }

    func handleEscape() {
        guard isPresented, !isShowingSheet else { return }
        // First Escape clears selection, second Escape closes the history.
        if onEscape?() == true { return }
        dismiss()
    }

    @discardableResult
    func handleDeleteSelection() -> Bool {
        guard isPresented, !isShowingSheet else { return false }
        return onDeleteSelection?() == true
    }

    static func isDeleteKey(_ keyCode: UInt16) -> Bool {
        keyCode == 51 || keyCode == 117 // Backspace and Forward Delete
    }

    private func setupDismissMonitors() {
        teardownDismissMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isPresented, let panel = self.panel else { return event }
            if event.type == .keyDown {
                guard event.window === panel, !self.isShowingSheet else { return event }
                if self.onCommand?(event) == true { return nil }
                if event.keyCode == 53 {
                    self.handleEscape()
                    return nil
                }
                if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   (panel.firstResponder as? NSTextView)?.isEditable != true {
                    // Holding Space must not immediately toggle the newly opened preview.
                    if event.keyCode == 49 && event.isARepeat { return nil }
                    if self.onNavigate?(event.keyCode) == true { return nil }
                }
                if Self.isDeleteKey(event.keyCode),
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   (panel.firstResponder as? NSTextView)?.isEditable != true,
                   self.handleDeleteSelection() {
                    return nil
                }
            }
            if event.type != .keyDown, !self.isShowingSheet, event.window !== panel,
               event.window?.level != .popUpMenu {
                self.dismiss()
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.isPresented, !self.isShowingSheet, let panel = self.panel else { return }
                if !panel.frame.contains(clickLocation) { self.dismiss() }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  activated.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPresented, !self.isShowingSheet else { return }
                self.dismiss()
            }
        }
    }

    private func teardownDismissMonitors() {
        for monitor in [localEventMonitor, globalEventMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localEventMonitor = nil
        globalEventMonitor = nil
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }
}

// MARK: - Filter Enum

enum MediaHistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case screenshots = "Screenshots"
    case recordings = "Videos"
    // AOM extras, shown after the CleanShot trio.
    case scrolling = "Scrolling"
    case pinned = "Kept"

    var id: String { rawValue }

    /// CleanShot's filter buttons; the rest are AOM extras.
    static let primary: [MediaHistoryFilter] = [.all, .screenshots, .recordings]
    static let extras: [MediaHistoryFilter] = [.scrolling, .pinned]

    func includes(_ entry: CaptureHistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return entry.kind != .videoRecording
        case .recordings: return entry.kind == .videoRecording
        case .scrolling: return entry.kind == .scrolling
        case .pinned: return entry.isPinned
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .screenshots: return "camera.viewfinder"
        case .recordings: return "video.fill"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .pinned: return "bookmark"
        }
    }
}

/// CleanShot "Keep History" choices mapped onto AOM's count/age limits.
enum MediaHistoryRetention: CaseIterable, Identifiable {
    case never, oneDay, threeDays, oneWeek, oneMonth
    var id: Self { self }

    var title: String {
        switch self {
        case .never: return "Never"
        case .oneDay: return "1 Day"
        case .threeDays: return "3 Days"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "1 Month"
        }
    }

    /// Age limit in days; `never` disables history (capacity 0).
    var days: Int {
        switch self {
        case .never: return 0
        case .oneDay: return 1
        case .threeDays: return 3
        case .oneWeek: return 7
        case .oneMonth: return 30
        }
    }

    static func current(capacity: Int, retentionDays: Int) -> MediaHistoryRetention? {
        if capacity == 0 { return .never }
        return allCases.first { $0 != .never && $0.days == retentionDays }
    }

    /// Resulting (capacity, retentionDays). Re-enabling restores the default
    /// capacity when history had been switched off.
    func apply(capacity: Int, retentionDays: Int) -> (capacity: Int, retentionDays: Int) {
        if self == .never { return (0, retentionDays) }
        return (capacity == 0 ? 40 : capacity, days)
    }
}

// MARK: - Capture Gallery

struct MediaHistoryOverlayView: View {
    weak var controller: MediaHistoryOverlayController?

    @ObservedObject private var history = CaptureHistory.shared
    @State private var selectedFilter: MediaHistoryFilter = .all
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedID: UUID?
    @State private var keyboardScrollTarget: UUID?
    @State private var showingClearConfirmation = false
    @State private var previewEntry: CaptureHistoryEntry?

    private var filteredEntries: [CaptureHistoryEntry] {
        var result = history.entries.filter(selectedFilter.includes)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { entry in
                entry.displayName.lowercased().contains(query) ||
                (entry.windowTitle?.lowercased().contains(query) ?? false)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.18)
            galleryContent
            Divider().opacity(0.18)
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.10)))
        .sheet(item: $previewEntry) { entry in
            CapturePreviewSheet(entry: entry)
        }
        .onAppear {
            controller?.onCommand = { event in
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
                if event.keyCode == 3 { searchFocused = true; return true } // Cmd-F
                if event.keyCode == 13 { controller?.dismiss(); return true } // Cmd-W
                guard !searchFocused,
                      let entry = filteredEntries.first(where: { $0.id == selectedID }) else { return false }
                switch event.keyCode {
                case 8: copyEntry(entry)
                case 14: annotateEntry(entry)
                case 1: saveEntry(entry)
                default: return false
                }
                return true
            }
            controller?.onNavigate = { key in
                guard !searchFocused, !filteredEntries.isEmpty else { return false }
                let index = filteredEntries.firstIndex { $0.id == selectedID }
                switch key {
                case 123, 124, 125, 126:
                    let delta = key == 123 ? -1 : key == 124 ? 1 : key == 125 ? 1 : -1
                    let next = index.map { min(filteredEntries.count - 1, max(0, $0 + delta)) } ?? 0
                    selectedID = filteredEntries[next].id
                    keyboardScrollTarget = selectedID
                case 49:
                    guard let index else { return false }
                    previewEntry = filteredEntries[index]
                case 36, 76:
                    guard let index else { return false }
                    copyEntry(filteredEntries[index])
                default: return false
                }
                return true
            }
            controller?.onEscape = {
                if searchFocused || !searchQuery.isEmpty {
                    searchQuery = ""
                    searchFocused = false
                    return true
                }
                guard selectedID != nil else { return false }
                selectedID = nil
                return true
            }
            controller?.onDeleteSelection = {
                guard let id = selectedID,
                      let entry = filteredEntries.first(where: { $0.id == id }) else { return false }
                confirmAndDelete(entry) // Same non-file-destructive behavior as context-menu Delete.
                return true
            }
            updateSheetState()
        }
        .onChange(of: selectedFilter) { _, _ in selectedID = nil }
        .onChange(of: searchQuery) { _, _ in selectedID = nil }
        .onChange(of: history.entries.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .onChange(of: previewEntry?.id) { _, _ in updateSheetState() }
        .onChange(of: showingClearConfirmation) { _, _ in updateSheetState() }
        .alert("Are you sure you want to delete all files from history?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                history.removeAll()
            }
        } message: {
            Text("AOM's cached copies are removed. Screenshots and recordings you saved elsewhere are kept.")
        }
    }

    private func updateSheetState() {
        controller?.isShowingSheet = previewEntry != nil || showingClearConfirmation
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            Label("Captures", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search captures", text: $searchQuery)
                    .focused($searchFocused).textFieldStyle(.plain)
                    .onSubmit {
                        searchFocused = false
                        selectedID = filteredEntries.first?.id
                        keyboardScrollTarget = selectedID
                    }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 10).frame(width: 190, height: 30)
            .background(Color.primary.opacity(0.065), in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(MediaHistoryFilter.primary) { filter in filterButton(filter) }
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 3)
                    ForEach(MediaHistoryFilter.extras) { filter in filterButton(filter) }
                }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470)
            Spacer(minLength: 0)
            Menu {
                Menu("Keep History") {
                    let current = MediaHistoryRetention.current(capacity: CaptureSettings.historyCapacity,
                                                                retentionDays: history.retentionDays)
                    ForEach(MediaHistoryRetention.allCases) { choice in
                        Button { setRetention(choice) } label: {
                            if current == choice { Label(choice.title, systemImage: "checkmark") }
                            else { Text(choice.title) }
                        }
                    }
                    Divider()
                    Button { setRetention(nil) } label: {
                        if current == nil { Label("Until Capacity Limit", systemImage: "checkmark") }
                        else { Text("Until Capacity Limit") }
                    }
                }
                Divider()
                Button("Clear History…", role: .destructive) { showingClearConfirmation = true }
                    .disabled(history.entries.isEmpty)
                Button("Clear All Except Kept", role: .destructive) { history.removeUnpinned() }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 25, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("History Settings").accessibilityLabel("History Settings")
            Button { controller?.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 25, height: 28)
            }.buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close")
        }.padding(.horizontal, 20).frame(height: 52)
    }

    private func filterButton(_ filter: MediaHistoryFilter) -> some View {
        Button { selectedFilter = filter } label: {
            Label(filter.rawValue, systemImage: filter.icon)
                .font(.system(size: 13, weight: selectedFilter == filter ? .semibold : .regular))
                .padding(.horizontal, 10).frame(height: 28)
                .background(selectedFilter == filter ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
    }

    /// nil = AOM's "Until Capacity Limit" (no age limit).
    private func setRetention(_ choice: MediaHistoryRetention?) {
        guard let choice else {
            if CaptureSettings.historyCapacity == 0 { CaptureSettings.historyCapacity = 40 }
            history.retentionDays = 0
            return
        }
        if choice == .never {
            let unkept = history.entries.filter { !$0.isPinned }.count
            if unkept > 0 {
                controller?.isShowingSheet = true
                let alert = NSAlert()
                alert.messageText = "Turn off Capture History?"
                alert.informativeText = "\(unkept) capture(s) will be removed from history. Kept captures and files you saved are not affected."
                alert.addButton(withTitle: "Turn Off")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                updateSheetState()
                guard response == .alertFirstButtonReturn else { return }
            }
        }
        let applied = choice.apply(capacity: CaptureSettings.historyCapacity, retentionDays: history.retentionDays)
        CaptureSettings.historyCapacity = applied.capacity
        history.retentionDays = applied.retentionDays   // also re-trims
    }

    private var galleryContent: some View {
        GeometryReader { geometry in
            let side = min(280, max(120, geometry.size.height - 20))
            Group {
                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 18) {
                                ForEach(filteredEntries) { entry in
                                    CaptureHistoryCard(
                                        entry: entry,
                                        isSelected: selectedID == entry.id,
                                        thumbnailHeight: max(60, side - 58),
                                        onSelect: { searchFocused = false; selectedID = entry.id },
                                        onCopy: { copyEntry(entry) },
                                        onAnnotate: { annotateEntry(entry) },
                                        onPin: { pinEntry(entry) },
                                        onRestore: { restoreEntry(entry) },
                                        onDelete: { confirmAndDelete(entry) },
                                        onPreview: { previewEntry = entry }
                                    ).frame(width: side).id(entry.id)
                                }
                            }.padding(.horizontal, 24).padding(.vertical, 10)
                        }
                        .onChange(of: keyboardScrollTarget) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: selectedFilter) { _, _ in
                            if let first = filteredEntries.first { proxy.scrollTo(first.id, anchor: .leading) }
                        }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 4) {
                Text(CaptureSettings.historyCapacity == 0 ? "Capture History is disabled."
                     : searchQuery.isEmpty ? "No files to restore..." : "No captures matching \"\(searchQuery)\"")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(CaptureSettings.historyCapacity == 0 ? "Choose Keep History in the settings menu to turn it on."
                     : searchQuery.isEmpty ? "Captures you take appear here so closed ones can be restored."
                     : "Try clearing your search query or switching filters.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text("\(filteredEntries.count) captures").foregroundStyle(.secondary)
            Spacer()
            if let entry = filteredEntries.first(where: { $0.id == selectedID }) {
                Button(entry.isPinned ? "Unpin History" : "Keep in History") { history.togglePin(entry) }
                Button("Preview") { previewEntry = entry }.help("Preview (Space)")
                Button(entry.kind == .videoRecording ? "Edit Recording" : "Annotate") { annotateEntry(entry) }
                    .help("Edit (⌘E)")
                Button("Copy") { copyEntry(entry) }.help("Copy (⌘C or Return)")
                Button("Save") { saveEntry(entry) }.help("Save (⌘S)")
            } else {
                Text("Select a capture · Space to preview · Drag to export").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
        .frame(height: 28).padding(.horizontal, 20).padding(.vertical, 8)
    }

    // MARK: - Action Helpers

    /// Like Copy, Annotate, Pin and Restore, a completed Save closes the
    /// overlay (⌥ keeps it). Cancelling the save panel or a failed write keeps
    /// it open.
    private func saveEntry(_ entry: CaptureHistoryEntry) {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        controller?.isShowingSheet = true
        CapturePreviewActions.save(entry) { ok in
            updateSheetState()
            if QuickAccessPolicy.closesSurface(afterSucceeded: ok, optionPressed: keepOpen) { controller?.dismiss() }
        }
    }

    private func copyEntry(_ entry: CaptureHistoryEntry) {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        let res = CaptureResult(
            image: entry.image,
            globalRect: .zero,
            scale: entry.scale,
            kind: entry.kind,
            windowTitle: entry.windowTitle,
            capturedAt: entry.capturedAt
        )
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL else {
                GestureHUD.shared.show(title: "Video Unavailable", detail: "The MP4 file is missing.")
                return
            }
            guard ScreenCaptureService.shared.copyFileToClipboard(url) else {
                GestureHUD.shared.show(title: "Copy Failed", detail: "The MP4 file could not be copied.")
                return
            }
            GestureHUD.shared.show(title: "Copied", detail: "MP4 file copied to clipboard")
            if !keepOpen { controller?.dismiss() }
            return
        }
        // F-04B: encode the image off the main thread; dismiss the sheet only
        // once the pasteboard actually holds the pixels so it never closes on a
        // stale/empty clipboard.
        Task { @MainActor in
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(res)
                GestureHUD.shared.show(title: "Copied", detail: "Image copied to clipboard")
                if !keepOpen { controller?.dismiss() }
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
            }
        }
    }

    private func annotateEntry(_ entry: CaptureHistoryEntry) {
        guard entry.kind != .videoRecording || entry.playableVideoURL != nil else {
            previewEntry = entry
            return
        }
        controller?.dismiss()
        CapturePreviewActions.edit(entry)
    }

    private func pinEntry(_ entry: CaptureHistoryEntry) {
        guard entry.kind != .videoRecording else { previewEntry = entry; return }
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        let res = CaptureResult(
            image: entry.image,
            globalRect: .zero,
            scale: entry.scale,
            kind: entry.kind,
            windowTitle: entry.windowTitle,
            capturedAt: entry.capturedAt
        )
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            PinnedScreenshotController.shared.pin(entry: entry, url: url)
            if !keepOpen { controller?.dismiss() }
            return
        }
        // F-04B: a pin wants a file to hand to other apps on drag-out, so write
        // it off the main thread and pin only after the write lands. The entry
        // may have gained a valid file (or been deleted) while we awaited, so
        // re-check before attaching and never clobber a newer file.
        Task { @MainActor in
            var pinURL: URL?
            do {
                let written = try await ScreenCaptureService.shared.writeToDiskAsync(res)
                if let current = entry.fileURL, FileManager.default.fileExists(atPath: current.path) {
                    pinURL = current
                } else {
                    CaptureHistory.shared.attachFile(written, to: entry.id)
                    pinURL = written
                }
            } catch {
                GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
            }
            PinnedScreenshotController.shared.pin(entry: entry, url: pinURL)
            if !keepOpen { controller?.dismiss() }
        }
    }

    /// Reopens the capture as a Quick Access overlay (CleanShot "Restore").
    private func restoreEntry(_ entry: CaptureHistoryEntry) {
        controller?.dismiss()
        CaptureCoordinator.shared.restoreToQuickAccess(entry)
    }

    private static let skipDeleteConfirmKey = "AOMHistoryDeleteWithoutConfirmation"

    /// Removing a never-saved capture loses it, so that case asks first
    /// (with CleanShot's "Don't ask again"). Saved files are never deleted.
    private func confirmAndDelete(_ entry: CaptureHistoryEntry) {
        let saved = entry.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !saved, !UserDefaults.standard.bool(forKey: Self.skipDeleteConfirmKey) {
            controller?.isShowingSheet = true
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to delete “\(entry.displayName)”?"
            alert.informativeText = "This capture was never saved to disk and cannot be restored afterwards."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            updateSheetState()
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.skipDeleteConfirmKey)
            }
        }
        deleteEntry(entry)
    }

    private func deleteEntry(_ entry: CaptureHistoryEntry) {
        let entries = filteredEntries
        let index = entries.firstIndex { $0.id == entry.id }
        let wasSelected = selectedID == entry.id
        withAnimation {
            CaptureHistory.shared.remove(entry)
            if wasSelected, let index {
                let remaining = filteredEntries
                selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
                keyboardScrollTarget = selectedID
            }
        }
    }
}

// MARK: - Capture Thumbnail

/// Click handling shared by history cards (pure for tests).
enum HistoryClick {
    static func isDoubleClick(_ clickCount: Int?) -> Bool { (clickCount ?? 1) >= 2 }
}

private struct CaptureHistoryCard: View {
    let entry: CaptureHistoryEntry
    let isSelected: Bool
    var thumbnailHeight: CGFloat = 140
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onPreview: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            footer.padding(.horizontal, 4).padding(.bottom, 4)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(selectionOutline.allowsHitTesting(false))
        .shadow(color: Color.black.opacity(isHovered ? 0.18 : 0.08),
                radius: isHovered ? 10 : 4, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { isHovered = hovering }
            // Have a drag file ready before a drag can start (no UI stall).
            if hovering { CaptureDragFiles.shared.prefetch(entry) }
        }
        // One recogniser, like the clipboard panel: the first click selects
        // at once (no wait for the double-click interval) and the second
        // click of a double-click opens Annotate.
        .onTapGesture {
            onSelect()
            if HistoryClick.isDoubleClick(NSApp.currentEvent?.clickCount) { onAnnotate() }
        }
        .onDrag { dragItemProvider() }
        .contextMenu { cardMenu }
    }

    private var cardBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        return isHovered ? Color.primary.opacity(0.06)
                         : Color(nsColor: .controlBackgroundColor).opacity(0.82)
    }

    private var selectionOutline: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isSelected ? Color.accentColor
                   : (isHovered ? Color.accentColor.opacity(0.4)
                                : Color.primary.opacity(0.10)),
                    lineWidth: isSelected ? 2 : 1)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .frame(height: thumbnailHeight)
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if entry.kind == .videoRecording {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 37, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 5)
            }
            if isHovered {
                hoverActions
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(height: thumbnailHeight)
    }

    /// CleanShot order: Copy, Annotate, Pin, Restore, Delete.
    private var hoverActions: some View {
        HStack(spacing: 6) {
            cardButton("doc.on.doc",
                       entry.kind == .videoRecording ? "Copy MP4 File (⌘C)" : "Copy (⌘C)", onCopy)
            if entry.kind == .videoRecording {
                cardButton("film.stack", "Edit Recording (⌘E)", onAnnotate)
            } else {
                cardButton("pencil.tip.crop.circle", "Annotate (⌘E)", onAnnotate)
                cardButton("pin.fill", "Pin to the Screen", onPin)
            }
            cardButton("arrow.uturn.backward", "Restore to Quick Access", onRestore)
            cardButton("trash", "Delete from History (⌫)", onDelete)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if entry.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor) }
                Text(entry.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            HStack(spacing: 4) {
                Text(relativeTimeString(entry.capturedAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(entry.image.width) × \(entry.image.height)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cardMenu: some View {
        if entry.kind == .videoRecording {
            Button("Play Recording…", action: onPreview)
            Button("Edit Recording…", action: onAnnotate)
            Button("Copy MP4 File", action: onCopy)
            Button("Restore to Quick Access", action: onRestore)
            if let url = entry.playableVideoURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } else {
            Button("Copy Image", action: onCopy)
            Button("Annotate…", action: onAnnotate)
            Button("Pin to Screen", action: onPin)
            Button("Preview…", action: onPreview)
            Button("Restore to Quick Access", action: onRestore)
            Button("Copy QR Code") {
                Task { @MainActor in
                    do {
                        let codes = try await TextRecognitionService.detectQRCodes(entry.image)
                        guard let value = codes.first else {
                            GestureHUD.shared.show(title: "No QR Code",
                                                   detail: "No QR code was detected.")
                            return
                        }
                        let board = NSPasteboard.general
                        board.clearContents()
                        if board.setString(value, forType: .string) {
                            GestureHUD.shared.show(title: "QR Copied",
                                                   detail: "QR content copied as text.")
                        } else {
                            GestureHUD.shared.show(title: "Copy Failed",
                                                   detail: "Cannot copy QR text.")
                        }
                    } catch {
                        GestureHUD.shared.show(title: "QR Detection Failed",
                                               detail: error.localizedDescription)
                    }
                }
            }
        }
        Divider()
        Button(entry.isPinned ? "Unpin from History" : "Keep in History") { CaptureHistory.shared.togglePin(entry) }
        Button("Delete from History…", role: .destructive, action: onDelete)
    }

    private func cardButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void, tint: Color = .primary) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func iconForKind(_ kind: CaptureKind) -> String {
        switch kind {
        case .area, .selection: return "crop"
        case .fullscreen: return "display"
        case .window, .windowUnderCursor: return "macwindow"
        case .previousArea: return "clock.arrow.circlepath"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .videoRecording: return "video.fill"
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 {
            return "Just now"
        } else if diff < 3600 {
            return "\(Int(diff / 60))m ago"
        } else if diff < 86400 {
            return "\(Int(diff / 3600))h ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, HH:mm"
            return formatter.string(from: date)
        }
    }

    private func dragItemProvider() -> NSItemProvider {
        // `.onDrag` needs the item synchronously. Saved captures hand over
        // their file; unsaved ones use the drag file prefetched on hover
        // (encoded off the main thread by CaptureDragFiles). Only a drag that
        // beats the prefetch falls back to the synchronous write below.
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: entry.thumbnail)
        }
        // Never export a video's thumbnail as a misleading PNG.
        guard entry.kind != .videoRecording else { return NSItemProvider() }
        if let url = CaptureDragFiles.shared.readyFile(for: entry) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: entry.thumbnail)
        }

        let res = CaptureResult(
            image: entry.image,
            globalRect: .zero,
            scale: entry.scale,
            kind: entry.kind,
            windowTitle: entry.windowTitle,
            capturedAt: entry.capturedAt
        )
        if let url = try? ScreenCaptureService.shared.writeToDisk(res) {
            CaptureHistory.shared.attachFile(url, to: entry.id)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: entry.thumbnail)
        }
        return NSItemProvider(object: entry.thumbnail)
    }
}

// MARK: - Shared Capture Preview

private struct CapturePreviewSheet: View {
    let entry: CaptureHistoryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CapturePreviewContent(entry: entry, onClose: { dismiss() })
            .frame(minWidth: 720, idealWidth: 840, minHeight: 480, idealHeight: 560)
            .onExitCommand { dismiss() }
    }
}
