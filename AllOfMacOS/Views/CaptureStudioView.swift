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

    private var subtitle: String {
        guard let latest = history.entries.first else { return "Screenshots, recordings, annotation and text recognition" }
        return "Last capture \(AOMRelativeTime.string(latest.capturedAt).lowercased()) · screenshots, recordings and text"
    }

    /// Library thumbnail size: 0 small, 1 medium, 2 large (Bear, Nova).
    @AppStorage("AOMCaptureGridDensity") private var density = 1

    private var gridMinimum: CGFloat { [168, 220, 300][min(2, max(0, density))] }

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
            AOMSection("Capture tools", padding: AOMSpace.x1) {
                captureLaunchpad
            }
            VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                AOMSectionTitle("Recent captures", detail: history.entries.isEmpty ? nil : "\(history.entries.count)") {
                    Picker("Thumbnail Size", selection: $density) {
                        Image(systemName: "square.grid.3x3").tag(0).help("Small thumbnails")
                        Image(systemName: "square.grid.2x2").tag(1).help("Medium thumbnails")
                        Image(systemName: "rectangle.grid.1x2").tag(2).help("Large thumbnails")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                filterBar
                gallerySection
            }
        }
        .aomPage("Capture")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettingsSheet) {
            VStack(spacing: 0) {
                CaptureSettingsView()
                Divider()
                HStack { Spacer(); Button("Done") { showingSettingsSheet = false }.keyboardShortcut(.defaultAction) }
                    .padding(AOMSpace.x3)
            }
            .frame(minWidth: 620, idealWidth: 680, minHeight: 540, idealHeight: 640)
        }
        .alert("Clear Capture History?", isPresented: $showingClearConfirmation) {
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
                Button("All-in-One\(keys(.allInOne))") { CaptureCoordinator.shared.captureAllInOne() }
                Button("Area\(keys(.captureArea))") { CaptureCoordinator.shared.captureArea() }
                Button("Window\(keys(.captureWindow))") { CaptureCoordinator.shared.captureWindowInteractive() }
                Button("Full Screen\(keys(.captureFullscreen))") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Scrolling\(keys(.scrollingCapture))") { CaptureCoordinator.shared.captureScrolling() }
                Divider()
                Button("Record Screen\(keys(.recordScreen))") { recordingService.promptAndStartRecording() }
                Divider()
                Button("Extract Text\(keys(.ocr))") { CaptureCoordinator.shared.captureText() }
                Button("Previous Area\(keys(.capturePreviousArea))") { CaptureCoordinator.shared.capturePreviousArea() }
                Button("Self-Timer") { CaptureCoordinator.shared.captureWithSelfTimer() }
                Button("QR / Barcode") { CaptureCoordinator.shared.captureQRCode() }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMFeatureSize.modeButtonMin), spacing: AOMSpace.x1)], spacing: AOMSpace.x1) {
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
            AOMModeButton(recordingService.isRecording ? "Recording" : "Record", symbol: "record.circle",
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

    /// What the gallery shows; the thumbnail size sits in the section title.
    private var filterBar: some View {
        AOMScopeBar(items: CaptureFilter.allCases.map { filter in
            AOMScopeItem(id: filter, title: filter.rawValue, count: count(filter))
        }, selection: $selectedFilter, accessibilityLabel: "Show")
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: AOMSize.rowDense)
    }

    // MARK: - Active Recording Banner

    /// A long-running capture adds a strip under the header (d.2): the
    /// recording colour on the glyph only, the controls beside it.
    private var activeRecordingBanner: some View {
        HStack(spacing: AOMSpace.x3) {
            Image(systemName: "record.circle")
                .font(AOMFont.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recordingService.isPaused ? AOMColor.paused : AOMColor.recording)
                .symbolEffect(.pulse, options: .repeating, isActive: !recordingService.isPaused)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recordingService.isPaused ? "Recording Paused" : "Recording Screen")
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                Text(formatElapsed(recordingService.elapsedSeconds))
                    .font(AOMFont.callout.monospacedDigit())
                    .foregroundStyle(AOMColor.textSecondary)
            }
            Spacer()
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
                AOMEmptyState(selectedFilter == .all ? "No Captures Yet" : "Nothing in \(selectedFilter.rawValue)",
                              systemImage: "camera.badge.ellipsis",
                              message: "Screenshots and recordings you take appear here, ready to annotate, pin, copy or reopen.") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 320)
            } else {
                // Wide enough that the caption (kind, size, time) never truncates.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum, maximum: gridMinimum * 1.6), spacing: AOMSpace.m)],
                          spacing: AOMSpace.m) {
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
                    .padding(.top, AOMSpace.x2)
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
                    .padding(AOMSpace.x2)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: AOMSpace.x1) {
                    if entry.kind == .videoRecording { badge("Video", "play.fill", AOMColor.recording) }
                    if entry.isPinned { badge("Pinned", "pin.fill", AOMColor.warning) }
                }
                .padding(AOMSpace.x2)
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
                    .padding(AOMSpace.x2)
                    .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: AOMRadius.card, topTrailingRadius: AOMRadius.card,
                                              style: .continuous))
            .onTapGesture(count: 2, perform: onAnnotate)
            .onDrag { CaptureItemActions.dragProvider(entry) }

            VStack(alignment: .leading, spacing: AOMSpace.x0_5 + 1) {
                HStack(spacing: AOMSpace.x2) {
                    Text(entry.displayName)
                        .font(AOMFont.bodyEmphasis)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
                    .accessibilityLabel("Actions for \(entry.displayName)")
                }
                HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    // The kind only when the title does not already say it.
                    if entry.kind.displayName != entry.displayName {
                        Text(entry.kind.displayName)
                        Text("·")
                    }
                    Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))").monospacedDigit()
                    Spacer(minLength: AOMSpace.x1)
                    Text(AOMRelativeTime.string(entry.capturedAt)).monospacedDigit()
                }
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
            }
            .padding(.horizontal, AOMSpace.x3 + AOMSpace.x0_5)
            .padding(.vertical, AOMSpace.x3)
        }
        // Hover shifts the fill only; cards never lift or outline (c.6).
        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, hovering: isHovered)
        .aomAnimation(.quick, value: isHovered)
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
        .accessibilityLabel("\(entry.displayName), \(entry.kind.displayName)")
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
