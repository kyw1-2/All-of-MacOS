import AppKit
import SwiftUI

/// CleanShot X-style Unified Capture Studio Dashboard.
/// Provides a fast visual launchpad, live recording status banner,
/// and a recent captures gallery with in-place annotation, pinning, and copy.
struct CaptureStudioView: View {
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var recordingService = ScreenRecordingService.shared
    @State private var selectedFilter: CaptureFilter = .all
    @State private var hoveredEntryID: UUID?
    @State private var showingSettingsSheet = false
    @State private var showingClearConfirmation = false
    @StateObject private var toast = AOMToastModel()

    enum CaptureFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case screenshots = "Screenshots"
        case recordings = "Recordings"
        case pinned = "Pinned"

        var id: String { rawValue }
    }

    private var filteredEntries: [CaptureHistoryEntry] {
        history.entries.filter { entry in
            switch selectedFilter {
            case .all: return true
            case .screenshots: return entry.kind != .videoRecording
            case .recordings: return entry.kind == .videoRecording
            case .pinned: return entry.isPinned
            }
        }
    }

    /// The header title already counts the captures and the chips count each
    /// filter, so the context line only says when the last one was taken.
    private var subtitle: String {
        guard let latest = history.entries.first else { return "Screenshots, recordings, annotation and text recognition" }
        return "Last capture \(AOMRelativeTime.string(latest.capturedAt).lowercased())"
    }

    /// Library thumbnail size: 0 small, 1 medium, 2 large (Bear, Nova).
    @AppStorage("AOMCaptureGridDensity") private var density = 1

    private var gridMinimum: CGFloat { CaptureGalleryMetrics.columnMinimum[min(2, max(0, density))] }

    private func count(_ filter: CaptureFilter) -> Int {
        switch filter {
        case .all: return history.entries.count
        case .screenshots: return history.entries.filter { $0.kind != .videoRecording }.count
        case .recordings: return history.entries.filter { $0.kind == .videoRecording }.count
        case .pinned: return history.entries.filter(\.isPinned).count
        }
    }

    var body: some View {
        AOMPage {
            header
            if recordingService.isRecording {
                activeRecordingBanner
            }
            // A bare strip: the toolbar's Capture menu lists the same tools,
            // so the strip needs no title of its own (VoiceOver keeps one).
            AOMSection(padding: AOMSpace.x1) {
                captureLaunchpad
            }
            .accessibilityLabel("Capture tools")
            VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                // Nothing to filter or size before the first capture.
                if !history.entries.isEmpty { filterBar }
                gallerySection
            }
        }
        .aomPage("Capture")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettingsSheet) {
            ModuleSettingsSheet("Capture Settings", done: { showingSettingsSheet = false }) {
                CaptureSettingsView()
            }
        }
        .alert("Clear capture history?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                history.removeAll()
                showToast("Capture history cleared")
            }
        } message: {
            Text("Recent captures are removed from history. Screenshot and video files saved in Finder are not deleted.")
        }
        .aomToast(toast.message)
    }

    /// d.9: what Capture holds and when it last ran; recording is a status
    /// (the pill and the strip below), not an error (e.6).
    private var header: some View {
        let count = history.entries.count
        return AOMPageHeader(recordingService.isRecording ? "Recording the screen"
                             : (count == 0 ? "No captures yet" : "\(count) capture\(count == 1 ? "" : "s") in history"),
                             module: .capture, subtitle: subtitle,
                             status: recordingService.isRecording
                                ? AOMStatus(recordingService.isPaused ? "Paused" : "Rec",
                                            tone: recordingService.isPaused ? .neutral : .recording, symbol: "record.circle")
                                : nil,
                             help: "Capture takes screenshots, recordings and text from any app. Each capture opens in Quick Access to copy, save, annotate or drag, and stays in history until you remove it.")
    }

    // MARK: - Toolbar (capture tools; CleanShot keeps them one click away)

    private func keys(_ action: CaptureShortcutAction) -> String {
        CaptureShortcuts.shared.shortcut(for: action).map { "  \($0.displayString)" } ?? ""
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                AnnotationEditorController.shared.chooseImageOrProject()
            } label: {
                Label("Open Image…", systemImage: "photo.badge.plus")
            }
            .help("Open an image or annotation project in the editor")
            Button {
                CaptureHistoryWindowController.shared.present()
            } label: {
                Label("History Overlay", systemImage: "clock.arrow.circlepath")
            }
            .help("Open the floating capture history")
            Menu {
                Button("Toggle Desktop Icons") {
                    CaptureCoordinator.shared.toggleDesktopIcons()
                    showToast("Toggled desktop icons")
                }
                if CaptureCoordinator.shared.canRestoreQuickAccess {
                    Button("Restore Last Closed Overlay") { CaptureCoordinator.shared.restoreRecentlyClosedOverlay() }
                }
                Divider()
                if !history.entries.isEmpty {
                    Button("Clear History…", role: .destructive) { showingClearConfirmation = true }
                    Divider()
                }
                Button("Capture Settings…") { showingSettingsSheet = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More capture options")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // The same names as the strip on the page, one name per mode.
                Button("All-In-One\(keys(.allInOne))") { CaptureCoordinator.shared.captureAllInOne() }
                Button("Area\(keys(.captureArea))") { CaptureCoordinator.shared.captureArea() }
                Button("Window\(keys(.captureWindow))") { CaptureCoordinator.shared.captureWindowInteractive() }
                Button("Full Screen\(keys(.captureFullscreen))") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Scrolling\(keys(.scrollingCapture))") { CaptureCoordinator.shared.captureScrolling() }
                Divider()
                Button("Record Screen\(keys(.recordScreen))") { recordingService.promptAndStartRecording() }
                Divider()
                Button("Text\(keys(.ocr))") { CaptureCoordinator.shared.captureText() }
                Button("Previous Area\(keys(.capturePreviousArea))") { CaptureCoordinator.shared.capturePreviousArea() }
                Button("Self-Timer") { CaptureCoordinator.shared.captureWithSelfTimer() }
                Button("QR Code") { CaptureCoordinator.shared.captureQRCode() }
            } label: {
                Label("Capture Area", systemImage: "viewfinder")
            } primaryAction: {
                CaptureCoordinator.shared.captureArea()
            }
            .help("Capture an area\(keys(.captureArea)) — open the menu for every capture tool")
        }
    }

    private func shortcut(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    /// Every capture mode one click away, in CleanShot's order, the way the
    /// system screenshot toolbar lays them out: glyph, name, shortcut.
    private var captureLaunchpad: some View {
        // One row of equal tools (3.3.5): an adaptive grid left a ragged gap
        // after QR Code; narrow windows show the glyphs alone (AOMModeButton).
        HStack(spacing: AOMSpace.x0_5) {
            AOMModeButton("All-In-One", symbol: "rectangle.dashed.badge.record", shortcut: shortcut(.allInOne), compact: true) {
                CaptureCoordinator.shared.captureAllInOne()
            }
            AOMModeButton("Area", symbol: "viewfinder", shortcut: shortcut(.captureArea), compact: true) {
                CaptureCoordinator.shared.captureArea()
            }
            AOMModeButton("Window", symbol: "macwindow", shortcut: shortcut(.captureWindow), compact: true) {
                CaptureCoordinator.shared.captureWindowInteractive()
            }
            AOMModeButton("Full Screen", symbol: "menubar.dock.rectangle", shortcut: shortcut(.captureFullscreen), compact: true) {
                CaptureCoordinator.shared.captureFullscreen()
            }
            AOMModeButton("Scrolling", symbol: "arrow.up.and.down.text.horizontal", shortcut: shortcut(.scrollingCapture), compact: true) {
                CaptureCoordinator.shared.captureScrolling()
            }
            AOMModeButton("Self-Timer", symbol: "timer", compact: true) {
                CaptureCoordinator.shared.captureWithSelfTimer()
            }
            AOMModeButton(recordingService.isRecording ? "Recording" : "Record Screen", symbol: "record.circle",
                          tint: AOMTheme.danger, shortcut: shortcut(.recordScreen), compact: true) {
                recordingService.promptAndStartRecording()
            }
            .disabled(recordingService.isRecording)
            AOMModeButton("Text", symbol: "text.viewfinder", shortcut: shortcut(.ocr), compact: true) {
                CaptureCoordinator.shared.captureText()
            }
            AOMModeButton("QR Code", symbol: "qrcode.viewfinder", compact: true) {
                CaptureCoordinator.shared.captureQRCode()
            }
        }
    }

    /// What the gallery shows, with the thumbnail size at the trailing end of
    /// the same row (one control row above the grid, not two).
    private var filterBar: some View {
        HStack(spacing: AOMSpace.x3) {
            AOMScopeBar(items: CaptureFilter.allCases.map { filter in
                AOMScopeItem(id: filter, title: filter.rawValue, count: count(filter))
            }, selection: $selectedFilter, accessibilityLabel: "Show")
            Picker("Thumbnail size", selection: $density) {
                Image(systemName: "square.grid.3x3").tag(0).help("Small thumbnails")
                Image(systemName: "square.grid.2x2").tag(1).help("Medium thumbnails")
                Image(systemName: "rectangle.grid.1x2").tag(2).help("Large thumbnails")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: AOMSize.rowDense)
    }

    // MARK: - Active Recording Banner

    /// A long-running capture adds a strip under the header (d.2): the
    /// recording colour on the glyph only, the controls beside it. The header
    /// and its pill already say recording or paused, so the strip holds one
    /// line: the elapsed time and the controls.
    private var activeRecordingBanner: some View {
        HStack(spacing: AOMSpace.x3) {
            Image(systemName: "record.circle")
                .font(AOMFont.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recordingService.isPaused ? AOMColor.paused : AOMColor.recording)
                .symbolEffect(.pulse, options: .repeating, isActive: !recordingService.isPaused)
                .accessibilityHidden(true)
            Text(formatElapsed(recordingService.elapsedSeconds))
                .font(AOMFont.headline.monospacedDigit())
                .foregroundStyle(AOMColor.text)
                .accessibilityLabel("\(recordingService.isPaused ? "Paused" : "Recording"), \(formatElapsed(recordingService.elapsedSeconds))")
            Spacer(minLength: AOMSpace.x3)
            Button {
                recordingService.togglePause()
            } label: {
                Label(recordingService.isPaused ? "Resume" : "Pause",
                      systemImage: recordingService.isPaused ? "play.fill" : "pause.fill")
            }
            Button("Cancel") {
                recordingService.cancelRecording()
                showToast("Recording cancelled")
            }
            Button {
                Task {
                    _ = try? await recordingService.stopRecording()
                    showToast("Recording saved")
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AOMColor.recording)
        }
        .controlSize(.small)
        .aomCard()
    }

    // MARK: - Gallery Section

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            if filteredEntries.isEmpty {
                // An empty history says so whatever the filter; a filter with
                // nothing in it names the filter.
                AOMCompactEmptyState(history.entries.isEmpty || selectedFilter == .all ? "No Captures Yet" : "Nothing in \(selectedFilter.rawValue)",
                                     systemImage: "camera.badge.ellipsis",
                                     message: "Screenshots and recordings you take appear here, ready to annotate, pin, copy or reopen.") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: CaptureGalleryMetrics.emptyMinHeight)
            } else {
                // Wide enough that the title and the time share one line.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum,
                                                       maximum: gridMinimum * CaptureGalleryMetrics.columnStretch),
                                             spacing: AOMSpace.x2)],
                          spacing: AOMSpace.x2) {
                    ForEach(filteredEntries) { entry in
                        CaptureCard(
                            entry: entry,
                            isHovered: hoveredEntryID == entry.id,
                            onAnnotate: {
                                AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
                            },
                            onCopy: {
                                CaptureItemActions.copy(entry)
                                showToast("Copied capture")
                            },
                            onShowInFinder: entry.fileURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
                            onPin: {
                                PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL)
                                showToast("Pinned to screen")
                            },
                            onRestoreOverlay: { CaptureCoordinator.shared.restoreToQuickAccess(entry) },
                            onDelete: {
                                withAnimation(AOMDesign.animation()) { history.remove(entry) }
                                showToast("Removed from history")
                            }
                        )
                        .onHover { isHovering in
                            if isHovering { hoveredEntryID = entry.id } else if hoveredEntryID == entry.id { hoveredEntryID = nil }
                        }
                    }
                }
                Text("Drag a capture into any app · double-click to edit · right-click for more")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, AOMSpace.x1)
            }
        }
    }

    // MARK: - Helpers

    private func showToast(_ message: String) { toast.show(message) }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Subviews

private struct CaptureCard: View {
    let entry: CaptureHistoryEntry
    let isHovered: Bool
    let onAnnotate: () -> Void
    let onCopy: () -> Void
    var onShowInFinder: (() -> Void)?
    let onPin: () -> Void
    let onRestoreOverlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // A quiet well like every other inset surface on the sheet.
                AOMColor.sunken
                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(AOMSpace.x1)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: AOMSpace.x1) {
                    if entry.kind == .videoRecording { badge("Video", "play.fill", AOMColor.recording) }
                    if entry.isPinned { badge("Pinned", "pin.fill", AOMColor.warning) }
                }
                .padding(AOMSpace.x1)
            }
            .overlay(alignment: .bottom) {
                if isHovered {
                    HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                        hoverButton("doc.on.doc", "Copy", action: onCopy)
                        hoverButton("pencil", "Edit", action: onAnnotate)
                        if let onShowInFinder { hoverButton("folder", "Show in Finder", action: onShowInFinder) }
                        hoverButton("pin", "Pin to Screen", action: onPin)
                        Spacer(minLength: 0)
                        hoverButton("trash", "Remove from History", role: .destructive, action: onDelete)
                    }
                    .padding(AOMSpace.x1)
                    .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: AOMRadius.well, topTrailingRadius: AOMRadius.well,
                                              style: .continuous))
            .onTapGesture(count: 2, perform: onAnnotate)
            .onDrag { CaptureItemActions.dragProvider(entry) }

            // One line under the picture: the name, the time and the menu.
            // The kind and pixel size are in the tooltip and the VoiceOver label.
            HStack(spacing: AOMSpace.x2) {
                Text(entry.displayName)
                    .font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AOMSpace.x1)
                Text(AOMRelativeTime.string(entry.capturedAt))
                    .font(AOMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Menu {
                    Button("Copy", action: onCopy)
                    Button("Edit", action: onAnnotate)
                    Button("Pin to Screen", action: onPin)
                    Button("Reopen in Quick Access", action: onRestoreOverlay)
                    if let onShowInFinder { Button("Show in Finder", action: onShowInFinder) }
                    Divider()
                    Button("Remove from History", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(AOMColor.textSecondary)
                .accessibilityLabel("Actions for \(entry.displayName)")
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: AOMSize.rowDense)
        }
        // Hover shifts the fill only; cards never lift or outline (c.6).
        .aomCardStyle(.paper, radius: AOMRadius.well, padding: 0, hovering: isHovered)
        .aomAnimation(.quick, value: isHovered)
        .help(details)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Edit", action: onAnnotate)
            Button("Pin to Screen", action: onPin)
            Button("Reopen in Quick Access", action: onRestoreOverlay)
            if let url = entry.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Remove from History", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.displayName), \(entry.kind.displayName), \(pixelSizeText)")
    }

    private var pixelSizeText: String { "\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))" }

    /// The card's tooltip: the name, the kind when the name doesn't already
    /// say it, and the pixel size (the footer keeps to one line).
    private var details: String {
        let kind = entry.kind.displayName == entry.displayName ? nil : entry.kind.displayName
        return [entry.displayName, kind, pixelSizeText].compactMap { $0 }.joined(separator: " · ")
    }

    private func badge(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(AOMFont.badge.weight(.bold))
            .foregroundStyle(AOMFeatureColor.onMedia)
            .frame(width: AOMFeatureSize.thumbnailBadge, height: AOMFeatureSize.thumbnailBadge)
            .background(tint, in: Circle())
            .help(title)
    }

    /// Actions over the thumbnail: opaque plates, so they read on any capture
    /// (no material over media in a scrolling grid).
    private func hoverButton(_ symbol: String, _ help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(role == .destructive ? AOMColor.dangerText : AOMColor.text)
                .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                .background(AOMColor.raised, in: Circle())
                .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Gallery metrics

/// Gallery sizes the shared scale has no token for.
private enum CaptureGalleryMetrics {
    /// The thumbnail column minimum at the small, medium and large sizes
    /// (3.3.5: 168 / 220 / 300 → 128 / 164 / 240, so a 1320 pt window shows
    /// six medium thumbnails a row instead of four).
    static let columnMinimum: [CGFloat] = [128, 164, 240]
    /// How far a column may grow past its minimum before another one fits.
    static let columnStretch: CGFloat = 1.5
    /// The empty gallery keeps the page from collapsing under the strip.
    static let emptyMinHeight: CGFloat = 180
}

// MARK: - Settings sheet

/// The settings sheet the Capture and Clipboard pages open: the size and the
/// title bar with Done that Settings uses for the same views
/// (`SettingsSheetHost`), so Capture Settings and Clipboard Settings look the
/// same wherever they are opened.
struct ModuleSettingsSheet<Content: View>: View {
    let title: String
    let done: () -> Void
    @ViewBuilder var content: Content

    init(_ title: String, done: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Text(title)
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AOMSpace.x2)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x2)
            AOMDivider()
            content
        }
        .frame(minWidth: AOMSize.readableWidth, idealWidth: AOMSize.readableWidth, maxWidth: .infinity,
               minHeight: ModuleSettingsSheetMetrics.minHeight, idealHeight: ModuleSettingsSheetMetrics.idealHeight,
               maxHeight: .infinity)
    }
}

/// The settings sheet's height in Settings (`SettingsHub`), which has no token.
private enum ModuleSettingsSheetMetrics {
    static let minHeight: CGFloat = 560
    static let idealHeight: CGFloat = 620
}
