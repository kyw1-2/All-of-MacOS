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

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                AOMPageHeader("Capture Library", subtitle: subtitle, systemImage: "camera.viewfinder", tint: AOMTheme.blue) {
                    headerControls
                }.padding(.horizontal, AOMDesign.pagePadding).padding(.top, AOMDesign.pagePadding)
                if recordingService.isRecording {
                    activeRecordingBanner.padding(.horizontal, AOMDesign.pagePadding).padding(.top, 14)
                }
                Group {
                    if geometry.size.width >= 760 {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView { launchpadSection.padding(12) }
                                .frame(width: 220)
                                .suppressScrollerReservation()
                            AOMDivider(axis: .vertical)
                            ScrollView { gallerySection.padding(20) }
                                .frame(maxWidth: .infinity).suppressScrollerReservation()
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Menu("Capture Tools", systemImage: "plus.viewfinder") {
                                    Button("All-in-One Capture") { CaptureCoordinator.shared.captureAllInOne() }
                                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                                    Button("Capture Window") { CaptureCoordinator.shared.captureWindowInteractive() }
                                    Button("Full Screen") { CaptureCoordinator.shared.captureFullscreen() }
                                    Button("Scrolling Capture") { CaptureCoordinator.shared.captureScrolling() }
                                    Button("Record Screen") { recordingService.promptAndStartRecording() }
                                    Button("Extract Text") { CaptureCoordinator.shared.captureText() }
                                    Button("Previous Area") { CaptureCoordinator.shared.capturePreviousArea() }
                                    Button("Self-Timer") { CaptureCoordinator.shared.captureWithSelfTimer() }
                                    Button("QR / Barcode") { CaptureCoordinator.shared.captureQRCode() }
                                }.controlSize(.small)
                                gallerySection
                            }.padding(20)
                        }.suppressScrollerReservation()
                    }
                }
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .aomCardStyle(.paper, radius: 22, padding: 0)
                .padding(.horizontal, AOMDesign.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Capture").aomSectionCaps().padding(.leading, 12).padding(.bottom, 6)
            AOMToolButton(title: "All-in-One", systemImage: "viewfinder.circle", prominent: true) { CaptureCoordinator.shared.captureAllInOne() }
            AOMToolButton(title: "Area", systemImage: "viewfinder") { CaptureCoordinator.shared.captureArea() }
            AOMToolButton(title: "Window", systemImage: "macwindow") { CaptureCoordinator.shared.captureWindowInteractive() }
            AOMToolButton(title: "Full screen", systemImage: "display") { CaptureCoordinator.shared.captureFullscreen() }
            AOMToolButton(title: "Scrolling", systemImage: "arrow.up.and.down.text.horizontal") { CaptureCoordinator.shared.captureScrolling() }
            AOMToolButton(title: "Record screen", systemImage: "record.circle") { recordingService.promptAndStartRecording() }
            Text("Utilities").aomSectionCaps().padding(.leading, 12).padding(.top, 18).padding(.bottom, 6)
            AOMToolButton(title: "Extract text", systemImage: "text.viewfinder") { CaptureCoordinator.shared.captureText() }
            AOMToolButton(title: "Previous area", systemImage: "arrow.uturn.backward.square") { CaptureCoordinator.shared.capturePreviousArea() }
            AOMToolButton(title: "Self-timer", systemImage: "timer") { CaptureCoordinator.shared.captureWithSelfTimer() }
            AOMToolButton(title: "QR / Barcode", systemImage: "qrcode.viewfinder") { CaptureCoordinator.shared.captureQRCode() }
        }
    }

    // MARK: - Gallery Section

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Library") {
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
                .frame(minHeight: 320)
            } else {
                // Wide enough that the caption (kind, size, time) never truncates.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)], spacing: 12) {
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
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
                .font(.system(size: 12))
                .foregroundStyle(AOMTheme.textTertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
