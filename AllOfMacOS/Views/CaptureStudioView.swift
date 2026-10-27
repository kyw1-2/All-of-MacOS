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
        let count = history.entries.count
        return "\(count) capture\(count == 1 ? "" : "s") in history · last \(AOMRelativeTime.string(latest.capturedAt).lowercased())"
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
        VStack(spacing: 0) {
            if recordingService.isRecording {
                activeRecordingBanner.padding(AOMSpace.s)
                AOMDivider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.m) {
                    captureLaunchpad
                    filterBar
                    gallerySection
                }
                .padding(.horizontal, AOMSpace.l)
                .padding(.top, AOMSpace.m)
                .padding(.bottom, AOMSpace.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AOMWorkspaceBackground())
        .navigationTitle("Capture")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettingsSheet) {
            VStack(spacing: 0) {
                CaptureSettingsView()
                Divider()
                HStack { Spacer(); Button("Done") { showingSettingsSheet = false }.keyboardShortcut(.defaultAction) }
                    .padding(12)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 4)], spacing: 4) {
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
        .padding(.horizontal, AOMSpace.xs)
        .padding(.vertical, AOMSpace.xxs)
        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
    }

    private var filterBar: some View {
        HStack(spacing: AOMSpace.s) {
            AOMScopeBar(items: CaptureFilter.allCases.map { filter in
                AOMScopeItem(id: filter, title: filter.rawValue, count: count(filter))
            }, selection: $selectedFilter, accessibilityLabel: "Show")
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AOMSpace.xs)
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
        .frame(minHeight: 28)
    }

    // MARK: - Active Recording Banner

    private var activeRecordingBanner: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(recordingService.isPaused ? AOMTheme.warning : AOMTheme.danger)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recordingService.isPaused ? "Recording Paused" : "Recording Screen")
                    .font(.headline)
                Text(formatElapsed(recordingService.elapsedSeconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            .tint(AOMTheme.danger)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AOMTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
            .strokeBorder(AOMTheme.danger.opacity(0.3), lineWidth: 0.5))
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
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, AOMSpace.xs)
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
                AOMTheme.cardAlt
                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if entry.kind == .videoRecording { badge("Video", "play.fill", AOMTheme.danger) }
                    if entry.isPinned { badge("Pinned", "pin.fill", AOMTheme.warning) }
                }
                .padding(8)
            }
            .overlay(alignment: .bottom) {
                if isHovered {
                    HStack(spacing: 6) {
                        hoverButton("doc.on.doc", "Copy", action: onCopy)
                        hoverButton("pencil", "Edit", action: onAnnotate)
                        if let onShowInFinder { hoverButton("folder", "Show in Finder", action: onShowInFinder) }
                        hoverButton("pin", "Pin to Screen", action: onPin)
                        Spacer(minLength: 0)
                        hoverButton("trash", "Remove from History", role: .destructive, action: onDelete)
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: AOMDesign.tileRadius, topTrailingRadius: AOMDesign.tileRadius,
                                              style: .continuous))
            .onTapGesture(count: 2, perform: onAnnotate)
            .onDrag { CaptureItemActions.dragProvider(entry) }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.displayName)
                        .font(AOMType.bodyEmphasis)
                        .foregroundStyle(AOMTheme.text)
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
                HStack(spacing: 6) {
                    // The kind only when the title does not already say it.
                    if entry.kind.displayName != entry.displayName {
                        Text(entry.kind.displayName)
                        Text("·")
                    }
                    Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))").monospacedDigit()
                    Spacer(minLength: 4)
                    Text(AOMRelativeTime.string(entry.capturedAt))
                }
                .font(AOMType.caption)
                .foregroundStyle(AOMTheme.textTertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .aomSurface(radius: AOMDesign.tileRadius, padding: nil, highlighted: isHovered)
        .animation(AOMDesign.animation(.easeOut(duration: 0.15)), value: isHovered)
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
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint, in: Circle())
            .help(title)
    }

    private func hoverButton(_ symbol: String, _ help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .destructive ? AOMTheme.danger : Color.primary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
