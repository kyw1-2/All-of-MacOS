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
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

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
            case .all:
                return true
            case .screenshots:
                return entry.kind != .videoRecording
            case .recordings:
                return entry.kind == .videoRecording
            case .pinned:
                return entry.isPinned
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    if recordingService.isRecording {
                        activeRecordingBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    launchpadSection
                    gallerySection
                }
                .padding(20)
            }
            .suppressScrollerReservation()
        }
        .toolbar { ToolbarItemGroup(placement: .automatic) { headerBar } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.18))
        .sheet(isPresented: $showingSettingsSheet) {
            CaptureSettingsView()
                .frame(width: 580, height: 520)
        }
        .alert("Clear Capture History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                history.removeAll()
                showToast("Capture history cleared")
            }
        } message: {
            Text("This will remove all recent capture entries from history. Saved screenshot files in Finder will not be deleted.")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {


            HStack(spacing: 8) {
                Button {
                    CaptureCoordinator.shared.toggleDesktopIcons()
                    showToast("Toggled desktop icons")
                } label: {
                    Label("Desktop Icons", systemImage: "macwindow.on.rectangle")
                }
                .help("Hide or show icons on the desktop")

                Button {
                    AnnotationEditorController.shared.chooseImageOrProject()
                } label: {
                    Label("Open Image…", systemImage: "pencil.tip.crop.circle")
                }
                .help("Open any image or project file in Annotation Editor")

                Button {
                    showingSettingsSheet = true
                } label: {
                    Label("Options", systemImage: "gearshape")
                }
                .help("Capture and overlay preferences")
            }
        }
        .labelStyle(.iconOnly)
    }

    // MARK: - Active Recording Banner

    private var activeRecordingBanner: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recordingService.isPaused ? Color.yellow : Color.red)
                    .frame(width: 12, height: 12)
                    .opacity(recordingService.isPaused ? 0.7 : 1.0)

                Text(recordingService.isPaused ? "Recording Paused" : "Recording Screen")
                    .font(.system(size: 13, weight: .bold))

                Text(formatElapsed(recordingService.elapsedSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    recordingService.togglePause()
                } label: {
                    Label(recordingService.isPaused ? "Resume" : "Pause",
                          systemImage: recordingService.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task {
                        _ = try? await recordingService.stopRecording()
                        showToast("Recording saved")
                    }
                } label: {
                    Label("Stop & Finish", systemImage: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)

                Button("Cancel") {
                    recordingService.cancelRecording()
                    showToast("Recording cancelled")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Launchpad Section

    private var launchpadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Capture", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if CaptureCoordinator.shared.canRestoreQuickAccess {
                    Button("Restore Last Closed") {
                        CaptureCoordinator.shared.restoreRecentlyClosedOverlay()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)], spacing: 12) {
                LaunchpadCard(
                    title: "Area",
                    icon: "viewfinder",
                    accentColor: .blue
                ) {
                    CaptureCoordinator.shared.captureArea()
                }

                LaunchpadCard(
                    title: "Window",
                    icon: "macwindow",
                    accentColor: .indigo
                ) {
                    CaptureCoordinator.shared.captureWindowInteractive()
                }

                LaunchpadCard(
                    title: "Fullscreen",
                    icon: "display",
                    accentColor: .purple
                ) {
                    CaptureCoordinator.shared.captureFullscreen()
                }

                LaunchpadCard(
                    title: "Scrolling",
                    icon: "arrow.up.and.down.text.horizontal",
                    accentColor: .teal
                ) {
                    CaptureCoordinator.shared.captureScrolling()
                }

                LaunchpadCard(
                    title: "Record Video",
                    icon: "video.fill",
                    accentColor: .red
                ) {
                    recordingService.promptAndStartRecording()
                }

                LaunchpadCard(
                    title: "OCR Text",
                    icon: "text.viewfinder",
                    accentColor: .orange
                ) {
                    CaptureCoordinator.shared.captureText()
                }
            }
        }
    }

    // MARK: - Gallery Section

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent Captures", systemImage: "photo.stack")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Filter pills
                HStack(spacing: 4) {
                    ForEach(CaptureFilter.allCases) { filter in
                        let isSelected = selectedFilter == filter
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                selectedFilter = filter
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

                if !history.entries.isEmpty {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Clear capture history")
                }
            }

            if filteredEntries.isEmpty {
                emptyGalleryView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(filteredEntries) { entry in
                        CaptureCard(
                            entry: entry,
                            isHovered: hoveredEntryID == entry.id,
                            onAnnotate: {
                                AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
                            },
                            onCopy: {
                                copyToPasteboard(entry)
                            },
                            onPin: {
                                PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL)
                                showToast("Pinned to screen")
                            },
                            onRestoreOverlay: {
                                CaptureCoordinator.shared.restoreToQuickAccess(entry)
                            },
                            onDelete: {
                                withAnimation {
                                    history.remove(entry)
                                    showToast("Removed from history")
                                }
                            }
                        )
                        .onHover { isHovering in
                            hoveredEntryID = isHovering ? entry.id : nil
                        }
                    }
                }
            }
        }
    }

    private var emptyGalleryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No Captures in History")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Screenshots and screen recordings you capture will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(Color.secondary.opacity(0.2))
        )
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

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Subviews

private struct LaunchpadCard: View {
    let title: String
    let icon: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

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
            // Preview Image Container
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .underPageBackgroundColor)
                    .frame(height: 140)

                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 140)
                    .clipped()

                // Corner indicators
                HStack(spacing: 4) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.orange))
                    }
                    if entry.kind == .videoRecording {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.red))
                    }
                }
                .padding(6)

                // Hover Actions Curtain
                if isHovered {
                    Color.black.opacity(0.35)
                        .transition(.opacity)

                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Button(action: onAnnotate) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(6)
                                    .background(Circle().fill(Color.white))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                            .help("Annotate in editor")

                            Button(action: onCopy) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(6)
                                    .background(Circle().fill(Color.white))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")

                            Button(action: onPin) {
                                Image(systemName: "pin")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(6)
                                    .background(Circle().fill(Color.white))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                            .help("Pin to screen")

                            Button(action: onRestoreOverlay) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(6)
                                    .background(Circle().fill(Color.white))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                            .help("Reopen Quick Access overlay")

                            Spacer()

                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(6)
                                    .background(Circle().fill(Color.red))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .help("Delete from history")
                        }
                        .padding(8)
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Info Strip
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(entry.kind.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)

                    Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(timeAgo(entry.capturedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
