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
        return "\(count) capture\(count == 1 ? "" : "s") in history · last \(AOMRelativeTime.string(latest.capturedAt))"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                    AOMPageHeader("Capture Studio", subtitle: subtitle, systemImage: "camera.viewfinder", tint: .orange) {
                        headerControls
                    }
                    if recordingService.isRecording {
                        activeRecordingBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    launchpadSection
                    gallerySection
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(AOMDesign.pagePadding)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .suppressScrollerReservation()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMWorkspaceBackground())
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

    // MARK: - Header controls

    private var headerControls: some View {
        HStack(spacing: 8) {
            Button {
                AnnotationEditorController.shared.chooseImageOrProject()
            } label: {
                Label("Open Image…", systemImage: "pencil.tip.crop.circle")
            }
            .help("Open an image or annotation project in the editor")
            Button {
                CaptureHistoryWindowController.shared.present()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Open the full capture history overlay")
            Menu {
                Button("Toggle Desktop Icons") {
                    CaptureCoordinator.shared.toggleDesktopIcons()
                    showToast("Toggled desktop icons")
                }
                if CaptureCoordinator.shared.canRestoreQuickAccess {
                    Button("Restore Last Closed Overlay") { CaptureCoordinator.shared.restoreRecentlyClosedOverlay() }
                }
                Divider()
                Button("Capture Settings…") { showingSettingsSheet = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More capture options")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
    }

    // MARK: - Active Recording Banner

    private var activeRecordingBanner: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(recordingService.isPaused ? Color.yellow : Color.red)
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
            .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMDesign.surfaceRadius, style: .continuous)
            .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: - Launchpad Section

    private var launchpadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Capture", systemImage: "sparkles", caption: "Start any capture; results open in Quick Access")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: AOMDesign.gridSpacing)],
                      spacing: AOMDesign.gridSpacing) {
                AOMActionTile(title: "All-In-One", systemImage: "rectangle.dashed.badge.record", tint: .orange,
                              subtitle: "Area, window, screen or video") { CaptureCoordinator.shared.captureAllInOne() }
                AOMActionTile(title: "Area", systemImage: "viewfinder", tint: .blue,
                              subtitle: "Drag to select a region") { CaptureCoordinator.shared.captureArea() }
                AOMActionTile(title: "Window", systemImage: "macwindow", tint: .indigo,
                              subtitle: "Pick a window with shadow") { CaptureCoordinator.shared.captureWindowInteractive() }
                AOMActionTile(title: "Fullscreen", systemImage: "display", tint: .purple,
                              subtitle: "Every pixel of a display") { CaptureCoordinator.shared.captureFullscreen() }
                AOMActionTile(title: "Scrolling", systemImage: "arrow.up.and.down.text.horizontal", tint: .teal,
                              subtitle: "Stitch long pages") { CaptureCoordinator.shared.captureScrolling() }
                AOMActionTile(title: "Record Screen", systemImage: "record.circle", tint: .red,
                              subtitle: "MP4 or GIF with audio") { recordingService.promptAndStartRecording() }
                AOMActionTile(title: "Capture Text", systemImage: "text.viewfinder", tint: .green,
                              subtitle: "Instant OCR to clipboard") { CaptureCoordinator.shared.captureText() }
                AOMActionTile(title: "Previous Area", systemImage: "arrow.uturn.backward.square", tint: .gray,
                              subtitle: "Repeat the last region") { CaptureCoordinator.shared.capturePreviousArea() }
                AOMActionTile(title: "Self-Timer", systemImage: "timer", tint: .pink,
                              subtitle: "Countdown, then capture") { CaptureCoordinator.shared.captureWithSelfTimer() }
                AOMActionTile(title: "QR / Barcode", systemImage: "qrcode.viewfinder", tint: .brown,
                              subtitle: "Read codes in a region") { CaptureCoordinator.shared.captureQRCode() }
            }
        }
    }

    // MARK: - Gallery Section

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Recent Captures", systemImage: "photo.stack") {
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(CaptureFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if !history.entries.isEmpty {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help("Clear capture history")
                }
            }

            if filteredEntries.isEmpty {
                AOMEmptyState(selectedFilter == .all ? "No Captures Yet" : "Nothing in \(selectedFilter.rawValue)",
                              systemImage: "camera.badge.ellipsis",
                              message: "Screenshots and recordings you take appear here, ready to annotate, pin, copy or reopen.") {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 240)
                .aomSurface(padding: nil)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)], spacing: 14) {
                    ForEach(filteredEntries) { entry in
                        CaptureCard(
                            entry: entry,
                            isHovered: hoveredEntryID == entry.id,
                            onAnnotate: {
                                AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
                            },
                            onCopy: { copyToPasteboard(entry) },
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
            }
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ entry: CaptureHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let fileURL = entry.fileURL {
            pasteboard.writeObjects([fileURL as NSURL])
        }
        let rep = NSBitmapImageRep(cgImage: entry.image)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        showToast("Copied capture to clipboard")
    }

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
    let onPin: () -> Void
    let onRestoreOverlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if entry.kind == .videoRecording { badge("Video", "play.fill", .red) }
                    if entry.isPinned { badge("Pinned", "pin.fill", .orange) }
                }
                .padding(8)
            }
            .overlay(alignment: .bottom) {
                if isHovered {
                    HStack(spacing: 6) {
                        hoverButton("pencil", "Annotate", action: onAnnotate)
                        hoverButton("doc.on.doc", "Copy", action: onCopy)
                        hoverButton("pin", "Pin to Screen", action: onPin)
                        hoverButton("arrow.up.forward.app", "Reopen in Quick Access", action: onRestoreOverlay)
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

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.kind.displayName)
                    Text("·")
                    Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))").monospacedDigit()
                    Spacer(minLength: 4)
                    Text(AOMRelativeTime.string(entry.capturedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .aomSurface(radius: AOMDesign.tileRadius, padding: nil, highlighted: isHovered)
        .animation(AOMDesign.animation(.easeOut(duration: 0.15)), value: isHovered)
        .contextMenu {
            Button("Annotate", action: onAnnotate)
            Button("Copy", action: onCopy)
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
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
