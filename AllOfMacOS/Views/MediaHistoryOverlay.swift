import SwiftUI
import AppKit
import AVKit

/// Paste-style horizontal slide-in Capture History Overlay (`MediaHistoryOverlay`).
///
/// Features:
/// - Floating acrylic glass bar anchored to the top of the active screen (Paste-style presentation)
/// - Slide-down from the top screen edge with smooth spring physics
/// - Centered category/filter tabs: All, Screenshots, Scrolling, Pinned
/// - Live instant search across capture file names and window titles
/// - Horizontal scrollable carousel (`ScrollView(.horizontal)`) of large rich thumbnail cards
/// - Keyboard navigation: Arrow keys to browse, Enter to copy & close, Space to preview, Esc to dismiss
/// - Hover quick actions: Copy, Annotate, Pin, Delete
/// - Native Drag & Drop: Drag any capture card directly into Finder, Slack, Discord, etc.
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

        // Paste-style top edge floating panel
        let panelHeight: CGFloat = min(360, max(300, screen.visibleFrame.height * 0.42))
        let panelWidth: CGFloat = max(600, screen.visibleFrame.width - 32)

        let targetX = screen.visibleFrame.minX + 16
        let targetY = screen.visibleFrame.maxY - panelHeight - 12
        let endFrame = NSRect(x: targetX, y: targetY, width: panelWidth, height: panelHeight)
        let startFrame = NSRect(x: targetX, y: screen.visibleFrame.maxY + 30, width: panelWidth, height: panelHeight)

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
        let screen = panel.screen ?? NSScreen.main
        let offscreenY = (screen?.visibleFrame.maxY ?? currentFrame.maxY) + 30
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

// MARK: - SwiftUI Overlay View (Paste-Style Top Shelf)

struct MediaHistoryOverlayView: View {
    weak var controller: MediaHistoryOverlayController?

    @ObservedObject private var history = CaptureHistory.shared
    @State private var selectedFilter: MediaHistoryFilter = .all
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedID: UUID?
    @State private var showingClearConfirmation = false
    @State private var previewEntry: CaptureHistoryEntry?

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
            carouselContent
            Divider().opacity(0.18)
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                Color(nsColor: .windowBackgroundColor).opacity(0.40)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.38), radius: 30, x: 0, y: 12)
        .sheet(item: $previewEntry) { entry in
            CapturePreviewSheet(entry: entry)
        }
        .onAppear {
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

    // MARK: - Header Bar (Centered Paste-Style Categories)

    private var headerBar: some View {
        HStack(spacing: 14) {
            // Left: Title & Badge
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)

                Text("Capture History")
                    .font(.system(size: 14, weight: .bold))

                Text("\(history.entries.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Center: Filter Segment Bar (Centered like Paste pinboards)
            HStack(spacing: 4) {
                ForEach(MediaHistoryFilter.allCases) { filter in
                    let count: Int = {
                        switch filter {
                        case .all: return history.entries.count
                        case .screenshots: return history.entries.filter { $0.kind != .scrolling && $0.kind != .videoRecording }.count
                        case .recordings: return history.entries.filter { $0.kind == .videoRecording }.count
                        case .scrolling: return history.entries.filter { $0.kind == .scrolling }.count
                        case .pinned: return history.entries.count
                        }
                    }()
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedFilter = filter
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: filter.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(filter.rawValue)
                                .font(.system(size: 12, weight: selectedFilter == filter ? .semibold : .regular))
                            Text("\(count)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selectedFilter == filter
                                ? Color.accentColor.opacity(0.22)
                                : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(selectedFilter == filter ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 0.8)
                        )
                        .foregroundStyle(selectedFilter == filter ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: Capsule())

            Spacer()

            // Right: Search & Actions
            HStack(spacing: 8) {
                // Search Input
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search captures…", text: $searchQuery)
                        .focused($searchFocused)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 130)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Clear button
                Button {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(history.entries.isEmpty)
                .help("Clear All History")

                // Close button
                Button {
                    controller?.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close (⌘⇧6 / Esc)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Carousel Content (Paste Horizontal Cards)

    private var carouselContent: some View {
        Group {
            if filteredEntries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                PasteStyleCaptureCard(
                                    entry: entry,
                                    index: index + 1,
                                    isSelected: selectedID == entry.id,
                                    onSelect: { selectedID = entry.id },
                                    onCopy: { copyEntry(entry) },
                                    onAnnotate: { annotateEntry(entry) },
                                    onPin: { pinEntry(entry) },
                                    onDelete: { deleteEntry(entry) },
                                    onPreview: { previewEntry = entry }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedID) { _, newID in
                        if let newID {
                            searchFocused = false
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
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
        HStack {
            Text("Capacity: \(history.entries.count)/\(CaptureSettings.historyCapacity)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 10) {
                Text("↵ Copy")
                Text("•")
                Text("⎵ Preview")
                Text("•")
                Text("⌫ Remove selected")
                Text("•")
                Text("Drag to apps")
                Text("•")
                Text("⇧⌘6 / Esc to Close")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary.opacity(0.85))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
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
        if entry.kind == .videoRecording {
            previewEntry = entry
        } else {
            AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
            controller?.dismiss()
        }
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
            CaptureHistory.shared.remove(entry)
        }
    }
}

// MARK: - Paste-Style Horizontal Capture Card

private struct PasteStyleCaptureCard: View {
    let entry: CaptureHistoryEntry
    let index: Int
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
            // Card Header: Kind Badge + Shortcut Tag (1..9)
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: iconForKind(entry.kind))
                        .font(.system(size: 9, weight: .bold))
                    Text(entry.kind.displayName)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)

                if index <= 9 {
                    Text("⌘\(index)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }

            // Thumbnail Image Area
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .frame(height: 125)

                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 125)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if entry.kind == .videoRecording {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 37, weight: .light))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 5)
                }

                // Hover Actions Pill
                if isHovered {
                    HStack(spacing: 6) {
                        cardButton("doc.on.doc", entry.kind == .videoRecording ? "Copy MP4 File" : "Copy Image", onCopy)
                        if entry.kind == .videoRecording {
                            cardButton("play.fill", "Play Recording", onPreview)
                        } else {
                            cardButton("pencil.tip.crop.circle", "Annotate", onAnnotate)
                            cardButton("pin.fill", "Pin to Screen", onPin)
                        }
                        cardButton("trash", "Delete", onDelete, tint: .red.opacity(0.9))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }

            Divider().opacity(0.25)

            // Card Footer: Display Name & Relative Time
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(relativeTimeString(entry.capturedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 2)

                    Text(entry.kind == .videoRecording ? "MP4" : "PNG")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
        }
        .padding(11)
        .frame(width: 225, height: 215)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.16)
                : (isHovered ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor).opacity(0.82)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.accentColor
                        : (isHovered ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.10)),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 10 : 4, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) {
            if entry.kind == .videoRecording { onPreview() }
            else { onAnnotate() }
        }
        .onTapGesture {
            onSelect()
        }
        .onDrag {
            dragItemProvider()
        }
        .contextMenu {
            if entry.kind == .videoRecording {
                Button("Play Recording…", action: onPreview)
                Button("Copy MP4 File", action: onCopy)
                if let url = entry.playableVideoURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                                GestureHUD.shared.show(title: "No QR Code", detail: "No QR code was detected.")
                                return
                            }
                            let board = NSPasteboard.general
                            board.clearContents()
                            if board.setString(value, forType: .string) {
                                GestureHUD.shared.show(title: "QR Copied", detail: "QR content copied as text.")
                            } else {
                                GestureHUD.shared.show(title: "Copy Failed", detail: "Cannot copy QR text.")
                            }
                        } catch {
                            GestureHUD.shared.show(title: "QR Detection Failed", detail: error.localizedDescription)
                        }
                    }
                }
            }
            Divider()
            Button("Remove from History", role: .destructive, action: onDelete)
        }
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

// MARK: - Capture Preview Sheet

private struct CapturePreviewSheet: View {
    let entry: CaptureHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showingRecordingEditor = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(entry.displayName).font(.headline)
                Spacer()
                if let file = entry.playableVideoURL {
                    Button("Edit Video…") { showingRecordingEditor = true }
                        .help("Trim the original MP4 or export a short animated GIF")
                        .sheet(isPresented: $showingRecordingEditor) {
                            RecordingExportEditor(source: file)
                        }
                }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.top)

            if entry.kind == .videoRecording {
                if let url = entry.playableVideoURL {
                    CaptureVideoPlayer(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                } else {
                    ContentUnavailableView("Recording Missing", systemImage: "video.slash",
                        description: Text("The recorded MP4 file can no longer be found."))
                }
            } else {
                Image(decorative: entry.image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(VisualEffectBackground(material: .hudWindow, state: .active))
        .onExitCommand { dismiss() }
    }
}


// MARK: - MP4 playback using the actual recording instead of its still thumbnail.

private struct CaptureVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Opening recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }
}
