import SwiftUI
import AppKit

/// Searchable capture gallery with the same preview and actions as Quick Access.
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

        let targetScreen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let panelHeight: CGFloat = min(680, screen.visibleFrame.height - 48)
        let panelWidth: CGFloat = min(1000, screen.visibleFrame.width - 48)

        let targetX = screen.visibleFrame.midX - panelWidth / 2
        let targetY = screen.visibleFrame.midY - panelHeight / 2
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
            p.isMovableByWindowBackground = true
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
            context.duration = 0.26
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
            context.duration = 0.18
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
                if event.keyCode == 53 {
                    self.handleEscape()
                    return nil
                }
                if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   (panel.firstResponder as? NSTextView)?.isEditable != true,
                   self.onNavigate?(event.keyCode) == true { return nil }
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
    case recordings = "Recordings"
    case scrolling = "Scrolling"
    case pinned = "Pinned"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .screenshots: return "camera.viewfinder"
        case .recordings: return "video.fill"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .pinned: return "pin"
        }
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
    @State private var showingClearConfirmation = false
    @State private var previewEntry: CaptureHistoryEntry?
    @State private var gridColumns = 4

    private var filteredEntries: [CaptureHistoryEntry] {
        var result: [CaptureHistoryEntry]
        switch selectedFilter {
        case .all:
            result = history.entries
        case .screenshots:
            result = history.entries.filter { $0.kind != .scrolling && $0.kind != .videoRecording }
        case .recordings:
            result = history.entries.filter { $0.kind == .videoRecording }
        case .scrolling:
            result = history.entries.filter { $0.kind == .scrolling }
        case .pinned:
            result = history.entries
        }

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
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .sheet(item: $previewEntry) { entry in
            CapturePreviewSheet(entry: entry)
        }
        .onAppear {
            controller?.onNavigate = { key in
                guard !searchFocused, !filteredEntries.isEmpty else { return false }
                let index = filteredEntries.firstIndex { $0.id == selectedID }
                switch key {
                case 123, 124, 125, 126:
                    let delta = key == 123 ? -1 : key == 124 ? 1 : key == 125 ? gridColumns : -gridColumns
                    let next = index.map { min(filteredEntries.count - 1, max(0, $0 + delta)) } ?? 0
                    selectedID = filteredEntries[next].id
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
                guard selectedID != nil else { return false }
                selectedID = nil
                return true
            }
            controller?.onDeleteSelection = {
                guard let id = selectedID,
                      let entry = filteredEntries.first(where: { $0.id == id }) else { return false }
                deleteEntry(entry) // Same non-file-destructive behavior as context-menu Delete.
                selectedID = nil
                return true
            }
            updateSheetState()
        }
        .onChange(of: selectedFilter) { _, _ in selectedID = nil }
        .onChange(of: searchQuery) { _, _ in selectedID = nil }
        .onChange(of: previewEntry?.id) { _, _ in updateSheetState() }
        .onChange(of: showingClearConfirmation) { _, _ in updateSheetState() }
        .alert("Clear Capture History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                history.removeAll()
            }
        } message: {
            Text("Remove all captures from history, including AOM's cached thumbnails? Separately saved screenshots and recordings will be preserved.")
        }
    }

    private func updateSheetState() {
        controller?.isShowingSheet = previewEntry != nil || showingClearConfirmation
    }

    private var headerBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Text("Capture History").font(.system(size: 16, weight: .semibold))
                Spacer()
                Menu {
                    Button("Clear All History…", role: .destructive) { showingClearConfirmation = true }
                        .disabled(history.entries.isEmpty)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).frame(width: 24)
                Button { controller?.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).help("Close (Esc)")
            }
            HStack(spacing: 20) {
                Picker("Capture type", selection: $selectedFilter) {
                    // A pinned filter needs persistent pin membership; do not show an All alias.
                    ForEach([MediaHistoryFilter.all, .screenshots, .recordings, .scrolling]) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search captures", text: $searchQuery)
                        .focused($searchFocused).textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12)).padding(7).frame(width: 210)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(20)
    }

    private var captureDays: [Date] {
        Array(Set(filteredEntries.map { Calendar.current.startOfDay(for: $0.capturedAt) })).sorted(by: >)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var galleryContent: some View {
        GeometryReader { geometry in
            Group {
                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(captureDays, id: \.self) { day in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(dayTitle(day)).font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: gridColumns), spacing: 16) {
                                            ForEach(filteredEntries.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }) { entry in
                                                CaptureHistoryCard(
                                                    entry: entry,
                                                    isSelected: selectedID == entry.id,
                                                    onSelect: { selectedID = entry.id },
                                                    onCopy: { copyEntry(entry) },
                                                    onAnnotate: { annotateEntry(entry) },
                                                    onPin: { pinEntry(entry) },
                                                    onDelete: { deleteEntry(entry) },
                                                    onPreview: { previewEntry = entry }
                                                ).id(entry.id)
                                            }
                                        }
                                    }
                                }
                            }.padding(20)
                        }
                        .onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            .onAppear { gridColumns = max(1, Int((geometry.size.width - 24) / 220)) }
            .onChange(of: geometry.size.width) { _, width in gridColumns = max(1, Int((width - 24) / 220)) }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 4) {
                Text(searchQuery.isEmpty ? "No captures in history" : "No captures matching \"\(searchQuery)\"")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(searchQuery.isEmpty ? "Press ⇧⌘4 to capture an area or ⇧⌘3 for fullscreen." : "Try clearing your search query or switching filters.")
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
                Button("Preview") { previewEntry = entry }
                Button(entry.kind == .videoRecording ? "Edit Recording" : "Annotate") { annotateEntry(entry) }
                Button("Copy") { copyEntry(entry) }
                Button("Save") {
                    controller?.isShowingSheet = true
                    CapturePreviewActions.save(entry) { updateSheetState() }
                }
            } else {
                Text("Select a capture · Space to preview · Drag to export").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
        .frame(height: 28).padding(.horizontal, 20).padding(.vertical, 8)
    }

    // MARK: - Action Helpers

    private func copyEntry(_ entry: CaptureHistoryEntry) {
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
        } else {
            do {
                try ScreenCaptureService.shared.copyToClipboard(res)
                GestureHUD.shared.show(title: "Copied", detail: "Image copied to clipboard")
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
                return
            }
        }
        controller?.dismiss()
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
        var url = entry.fileURL
        if url == nil || !FileManager.default.fileExists(atPath: url?.path ?? "") {
            let res = CaptureResult(
                image: entry.image,
                globalRect: .zero,
                scale: entry.scale,
                kind: entry.kind,
                windowTitle: entry.windowTitle,
                capturedAt: entry.capturedAt
            )
            url = try? ScreenCaptureService.shared.writeToDisk(res)
            if let url { CaptureHistory.shared.attachFile(url, to: entry.id) }
        }
        PinnedScreenshotController.shared.pin(entry: entry, url: url)
        controller?.dismiss()
    }

    private func deleteEntry(_ entry: CaptureHistoryEntry) {
        withAnimation {
            if selectedID == entry.id { selectedID = nil }
            CaptureHistory.shared.remove(entry)
        }
    }
}

// MARK: - Capture Thumbnail

private struct CaptureHistoryCard: View {
    let entry: CaptureHistoryEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onPreview: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            footer.padding(.horizontal, 4).padding(.bottom, 4)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(selectionOutline)
        .shadow(color: Color.black.opacity(isHovered ? 0.18 : 0.08),
                radius: isHovered ? 10 : 4, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) {
            onAnnotate()
        }
        .onTapGesture { onSelect() }
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
                .frame(height: 140)
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 140)
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
        .frame(height: 140)
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            cardButton("doc.on.doc",
                       entry.kind == .videoRecording ? "Copy MP4 File" : "Copy Image", onCopy)
            if entry.kind == .videoRecording {
                cardButton("film.stack", "Edit Recording", onAnnotate)
            } else {
                cardButton("pencil.tip.crop.circle", "Annotate", onAnnotate)
                cardButton("pin.fill", "Pin to Screen", onPin)
            }
            cardButton("arrow.up.left.and.arrow.down.right", "Preview (Space)", onPreview)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
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
        Button("Remove from History", role: .destructive, action: onDelete)
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
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: entry.thumbnail)
        }
        // Never export a video's thumbnail as a misleading PNG.
        guard entry.kind != .videoRecording else { return NSItemProvider() }

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
