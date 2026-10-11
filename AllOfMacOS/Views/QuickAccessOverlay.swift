import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// CleanShot X-style floating Quick Access Overlay that appears after a capture.
///
/// Features:
/// - Smooth spring slide-in from screen edge upon capture
/// - Native drag & drop to export image directly into Finder/Slack/Discord
/// - Swipe-right to dismiss gesture (like CleanShot X flick-to-close)
/// - Instant dismiss upon Copy, Save, OCR, Pin, or Delete actions
/// - Acrylic glassmorphism card with rounded corners and double drop shadow
/// - Rich toolbar with hover feedback, tooltips, and keyboard shortcuts
@MainActor
final class QuickAccessOverlayController {
    private var panel: NSPanel?
    private var closeTimer: Task<Void, Never>?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var escapeMonitor: Any?
    private let entry: CaptureHistoryEntry
    private let forcedAutoCloseSeconds: TimeInterval?
    var onDismiss: (() -> Void)?

    init(entry: CaptureHistoryEntry, forcedAutoCloseSeconds: TimeInterval? = nil) {
        self.entry = entry
        self.forcedAutoCloseSeconds = forcedAutoCloseSeconds
    }

    func present() {
        guard panel == nil else { return }
        let width = max(270, CaptureSettings.overlaySize.panelWidth)
        let height = CaptureSettings.overlaySize.thumbnailSide + 105
        let size = NSSize(width: width, height: height)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        let view = QuickAccessOverlayView(
            entry: entry,
            onCopy: { [weak self] in self?.copyImage() },
            onCopyFile: { [weak self] in self?.copyFile() },
            onSave: { [weak self] in self?.save() },
            onAnnotate: { [weak self] in self?.annotate() },
            onPin: { [weak self] in self?.pin() },
            onOCR: { [weak self] in self?.recognizeText() },
            onQR: { [weak self] in self?.recognizeQRCode() },
            onDelete: { [weak self] in self?.dismiss(deleteFile: true) },
            onClose: { [weak self] in self?.dismiss(deleteFile: false) },
            onSwipeDismiss: { [weak self] in self?.dismissWithSwipe() },
            onDragOut: { [weak self] in self?.handleDragOut() }
        )
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel

        position(panel)

        // Slide in from right edge
        let finalFrame = panel.frame
        let startFrame = NSRect(x: finalFrame.origin.x + 50, y: finalFrame.origin.y, width: finalFrame.width, height: finalFrame.height)
        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        installDismissMonitors()
        scheduleAutoClose()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.dismiss(deleteFile: false) }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.dismiss(deleteFile: false)
                return nil
            }
            if event.type != .keyDown, event.window !== panel, !panel.frame.contains(NSEvent.mouseLocation) {
                self.dismiss(deleteFile: false)
            }
            return event
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.dismiss(deleteFile: false) }
        }
    }

    private func removeDismissMonitors() {
        for monitor in [outsideMonitor, localMonitor, escapeMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        outsideMonitor = nil
        localMonitor = nil
        escapeMonitor = nil
    }

    func dismiss(deleteFile: Bool) {
        closeTimer?.cancel()
        closeTimer = nil
        removeDismissMonitors()
        if deleteFile, let url = entry.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        if deleteFile { CaptureHistory.shared.remove(entry) }
        let closing = panel
        panel = nil
        onDismiss?()
        onDismiss = nil
        guard let closing else { return }

        let currentFrame = closing.frame
        let targetFrame = NSRect(x: currentFrame.origin.x + 60, y: currentFrame.origin.y, width: currentFrame.width, height: currentFrame.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            closing.animator().setFrame(targetFrame, display: true)
            closing.animator().alphaValue = 0.0
        } completionHandler: {
            closing.orderOut(nil)
        }
    }

    func dismissWithSwipe() {
        closeTimer?.cancel()
        closeTimer = nil
        removeDismissMonitors()
        let closing = panel
        panel = nil
        onDismiss?()
        onDismiss = nil
        guard let closing else { return }

        let currentFrame = closing.frame
        let targetFrame = NSRect(x: currentFrame.origin.x + 360, y: currentFrame.origin.y, width: currentFrame.width, height: currentFrame.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            closing.animator().setFrame(targetFrame, display: true)
            closing.animator().alphaValue = 0.0
        } completionHandler: {
            closing.orderOut(nil)
        }
    }

    // MARK: - Actions

    private func copyImage() {
        if entry.kind == .videoRecording { copyFile(); return }
        do {
            try ScreenCaptureService.shared.copyToClipboard(
                CaptureResult(image: entry.image, globalRect: .zero, scale: entry.scale, kind: entry.kind,
                              windowTitle: entry.windowTitle, capturedAt: entry.capturedAt))
            GestureHUD.shared.show(title: "Copied", detail: "Image on the clipboard")
            dismiss(deleteFile: false)
        } catch {
            GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
        }
    }

    private func copyFile() {
        guard let url = ensureFile() else { return }
        guard ScreenCaptureService.shared.copyFileToClipboard(url) else {
            GestureHUD.shared.show(title: "Copy Failed", detail: "Could not copy the capture file.")
            return
        }
        GestureHUD.shared.show(title: "Copied", detail: url.lastPathComponent)
        dismiss(deleteFile: false)
    }

    private func save() {
        guard let url = ensureFile() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
        dismiss(deleteFile: false)
    }

    private func annotate() {
        guard entry.kind != .videoRecording else { save(); return }
        let url = ensureFile()
        AnnotationEditorController.shared.open(capture: entry, url: url)
        dismiss(deleteFile: false)
    }

    private func pin() {
        guard entry.kind != .videoRecording else { return }
        let url = ensureFile()
        PinnedScreenshotController.shared.pin(entry: entry, url: url)
        dismiss(deleteFile: false)
    }

    private func recognizeQRCode() {
        guard entry.kind != .videoRecording else { return }
        Task { @MainActor in
            do {
                guard let code = try await TextRecognitionService.detectQRCodes(entry.image).first else {
                    GestureHUD.shared.show(title: "No QR Code", detail: "No QR code was detected.")
                    return
                }
                let board = NSPasteboard.general
                board.clearContents()
                guard board.setString(code, forType: .string) else {
                    GestureHUD.shared.show(title: "Copy Failed", detail: "Unable to copy QR contents.")
                    return
                }
                GestureHUD.shared.show(title: "QR Copied", detail: "QR contents copied as text.")
                dismiss(deleteFile: false)
            } catch {
                GestureHUD.shared.show(title: "QR Detection Failed", detail: error.localizedDescription)
            }
        }
    }

    private func recognizeText() {
        let keepBreaks = CaptureSettings.ocrKeepsLineBreaks
        Task { @MainActor in
            do {
                let text = try await TextRecognitionService.recognize(entry.image, keepsLineBreaks: keepBreaks)
                guard !text.isEmpty else {
                    GestureHUD.shared.show(title: "No Text Found", detail: nil)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                GestureHUD.shared.show(title: "Text Copied", detail: "\(text.count) characters")
                self.dismiss(deleteFile: false)
            } catch {
                GestureHUD.shared.show(title: "Text Recognition Failed", detail: error.localizedDescription)
            }
        }
    }

    private func ensureFile() -> URL? {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard entry.kind != .videoRecording else {
            GestureHUD.shared.show(title: "Video Unavailable", detail: "The recording file is missing.")
            return nil
        }
        let result = CaptureResult(image: entry.image, globalRect: .zero, scale: 1, kind: entry.kind,
                                   windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
        guard let url = try? ScreenCaptureService.shared.writeToDisk(result) else {
            GestureHUD.shared.show(title: "Save Failed", detail: "The capture could not be written to disk.")
            return nil
        }
        CaptureHistory.shared.attachFile(url, to: entry.id)
        return url
    }

    private func handleDragOut() {
        if CaptureSettings.overlayAutoClose == .afterDrag {
            dismiss(deleteFile: false)
        }
    }

    private func scheduleAutoClose() {
        let interval: TimeInterval
        if let forcedAutoCloseSeconds { interval = forcedAutoCloseSeconds }
        else if CaptureSettings.overlayAutoClose == .afterInterval { interval = TimeInterval(CaptureSettings.overlayIntervalSeconds) }
        else { return }
        guard interval > 0 else { return }
        closeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss(deleteFile: false)
        }
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel) {
        let corner = CaptureSettings.overlayCorner
        let screen: NSScreen
        if CaptureSettings.overlayFollowsActiveDisplay {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        } else {
            screen = NSScreen.main ?? NSScreen.screens[0]
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 20
        let x = corner.isLeft ? visible.minX + margin : visible.maxX - size.width - margin
        let y = corner.isTop ? visible.maxY - size.height - margin : visible.minY + margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The overlay card's SwiftUI content.
private struct QuickAccessOverlayView: View {
    let entry: CaptureHistoryEntry
    let onCopy: () -> Void
    let onCopyFile: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onOCR: () -> Void
    let onQR: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onSwipeDismiss: () -> Void
    let onDragOut: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragOffsetX: CGFloat = 0
    @State private var isSwipeTriggered = false

    private var side: CGFloat { CaptureSettings.overlaySize.thumbnailSide }
    private var width: CGFloat { max(270, CaptureSettings.overlaySize.panelWidth) }

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
            caption
            actionBar
        }
        .padding(10)
        .frame(width: width)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                Color(nsColor: .windowBackgroundColor).opacity(0.35)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.32), radius: 20, x: 0, y: 8)
        .offset(x: max(0, dragOffsetX))
        .opacity(isSwipeTriggered ? 0.0 : max(0.2, 1.0 - Double(max(0, dragOffsetX) / 200.0) * 0.6))
        .gesture(swipeGesture)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture overlay for \(entry.displayName)")
    }

    // MARK: - Swipe to Dismiss Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Only allow swiping to the right
                if value.translation.width > 0 {
                    dragOffsetX = value.translation.width
                }
            }
            .onEnded { value in
                let flickDistance = value.translation.width
                let flickVelocity = value.predictedEndTranslation.width
                if flickDistance > 55 || flickVelocity > 140 {
                    isSwipeTriggered = true
                    withAnimation(.easeIn(duration: 0.15)) {
                        dragOffsetX = 350
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onSwipeDismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                        dragOffsetX = 0
                    }
                }
            }
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {
        ZStack {
            // Background canvas
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))

            // Capture preview
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: width - 24, maxHeight: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Hover close badge (top-right)
            VStack {
                HStack {
                    // Type badge (top-left)
                    HStack(spacing: 3) {
                        Image(systemName: iconForKind(entry.kind))
                            .font(.system(size: 8, weight: .bold))
                        Text(entry.kind.displayName)
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))

                    Spacer()

                    // Mini Close Button
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc or swipe right)")
                }
                .padding(6)
                Spacer()
            }
        }
        .frame(height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .onDrag {
            isDragging = true
            defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { isDragging = false } }
            guard let url = fileURL() else { return NSItemProvider() }
            onDragOut()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) { onAnnotate() }
        .help("Double-click to annotate · drag to export · swipe right to dismiss")
    }

    // MARK: - Caption

    private var caption: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text("\(Int(entry.pixelSize.width)) × \(Int(entry.pixelSize.height))")
                        .font(.system(size: 10).monospacedDigit())
                    Text("•")
                        .opacity(0.5)
                    Text(entry.kind == .videoRecording ? "MP4" : "PNG")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Swipe hint indicator
            HStack(spacing: 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .help("Swipe right to dismiss")
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 4) {
            if entry.kind == .videoRecording {
                actionButton("doc.on.doc", "Copy Video File", onCopyFile)
                actionButton("folder", "Show Recording in Finder", onSave)
            } else {
                actionButton("doc.on.doc", "Copy Image", onCopy)
                actionButton("folder", "Save to Disk", onSave)
                actionButton("pencil.tip.crop.circle", "Annotate", onAnnotate)
                actionButton("pin.fill", "Pin to Screen", onPin)
                actionButton("text.viewfinder", "Copy Text (OCR)", onOCR)
            }

            Spacer(minLength: 2)

            actionButton("trash", "Delete", onDelete, tint: .red.opacity(0.9), isDestructive: true)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void,
                              tint: Color = .primary, isDestructive: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 28, height: 26)
                .background(
                    isDestructive
                        ? Color.red.opacity(0.12)
                        : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
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

    @ViewBuilder
    private var contextMenu: some View {
        if entry.kind == .videoRecording {
            Button("Copy Video File", action: onCopyFile)
            Button("Reveal Video in Finder", action: onSave)
        } else {
            Button("Copy Image", action: onCopy)
            Button("Copy File", action: onCopyFile)
            Button("Show in Finder", action: onSave)
            Divider()
            Button("Annotate", action: onAnnotate)
            Button("Pin to Screen", action: onPin)
            Button("Copy Text (OCR)", action: onOCR)
            Button("Copy QR Code", action: onQR)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }

    private func fileURL() -> URL? {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard entry.kind != .videoRecording else { return nil }
        let result = CaptureResult(image: entry.image, globalRect: .zero, scale: 1, kind: entry.kind,
                                   windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
        guard let url = try? ScreenCaptureService.shared.writeToDisk(result) else { return nil }
        CaptureHistory.shared.attachFile(url, to: entry.id)
        return url
    }
}
