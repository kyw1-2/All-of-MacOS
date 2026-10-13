import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// CleanShot X-style floating Quick Access Overlay that appears after a capture.
///
/// Features:
/// - Smooth spring slide-in from screen edge upon capture
/// - Native drag & drop to export image directly into Finder/Slack/Discord
/// - Swipe-right to dismiss gesture (like CleanShot X flick-to-close)
/// - Multiple overlays, Save All/Close All and restore-most-recently-closed
/// - Acrylic glassmorphism card with rounded corners and double drop shadow
/// - Rich toolbar with hover feedback, tooltips, and keyboard shortcuts
private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickAccessOverlayController {
    private var panel: NSPanel?
    private var closeTimer: Task<Void, Never>?
    private var localMonitor: Any?
    private let entry: CaptureHistoryEntry
    private var stackIndex: Int
    private var secondsRemaining: TimeInterval?
    private var resumedAt: Date?
    private var hovering = false
    private var dragging = false
    private var wasDeleted = false
    private var recycleInProgress = false
    private var temporarilyHidden = false
    private var visibleStackCount = 1
    private var preferredDisplayID: UInt32?
    private var displayChangeObserver: NSObjectProtocol?
    var onDisplayTopologyChange: (() -> Void)?
    var placementDisplayID: UInt32? { preferredDisplayID }
    private let forcedAutoCloseSeconds: TimeInterval?
    var onDismiss: ((Bool) -> Void)?

    init(entry: CaptureHistoryEntry, stackIndex: Int = 0, forcedAutoCloseSeconds: TimeInterval? = nil) {
        self.entry = entry
        self.stackIndex = stackIndex
        self.forcedAutoCloseSeconds = forcedAutoCloseSeconds
        let displays = QuickAccessGeometry.currentDisplays()
        let selected = QuickAccessGeometry.targetDisplay(
            displays,
            preferredID: nil,
            pointer: NSEvent.mouseLocation,
            followPointer: CaptureSettings.overlayFollowsActiveDisplay)
        preferredDisplayID = selected?.id
    }

    func setStackIndex(_ index: Int, total: Int = 1) {
        stackIndex = index
        visibleStackCount = max(1, total)
        guard let panel else { return }
        position(panel)
    }

    func present() {
        guard panel == nil else { return }
        let width = CaptureSettings.overlaySize.panelWidth
        let height = CaptureSettings.overlaySize.thumbnailSide + 48
        let size = NSSize(width: width, height: height)
        let panel = QuickAccessPanel(contentRect: NSRect(origin: .zero, size: size),
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
            onReveal: { [weak self] in self?.revealInFinder() },
            onSaveAll: { [weak self] in self?.saveAllVisible() },
            onCloseAll: { [weak self] in self?.closeAllVisible() },
            onAnnotate: { [weak self] in self?.annotate() },
            onPin: { [weak self] in self?.pin() },
            onOCR: { [weak self] in self?.recognizeText() },
            onQR: { [weak self] in self?.recognizeQRCode() },
            onDelete: { [weak self] in self?.dismiss(deleteFile: true) },
            onClose: { [weak self] in self?.dismiss(deleteFile: false) },
            onSwipeDismiss: { [weak self] in self?.dismissWithSwipe() },
            onDragOut: { [weak self] success in self?.handleDragOut(success: success) },
            prepareDragFile: { [weak self] in self?.beginDragFile() },
            onHoverChange: { [weak self] hovering in self?.setHovering(hovering) },
            onSaveAs: { [weak self] in self?.saveAs() },
            onPreview: { [weak self] in self?.preview() },
            onTemporarilyHide: { [weak self] in self?.temporarilyHide() },
            onInfo: { [weak self] in self?.showFileInfo() },
            onPrint: { [weak self] in self?.printCapture() },
            onCopyOneX: { [weak self] in
                guard let self else { return }
                self.copyTransformed(QuickAccessImageTools.downscaleToOneX(
                    self.entry.image, pointSize: self.entry.pointSize))
            },
            onFlip: { [weak self] in
                guard let self else { return }
                self.copyTransformed(QuickAccessImageTools.flippedHorizontally(self.entry.image))
            },
            onRotate: { [weak self] in
                guard let self else { return }
                self.copyTransformed(QuickAccessImageTools.rotatedLeft(self.entry.image))
            },
            onShare: { [weak self] in self?.shareCapture() },
            onOpenWith: { [weak self] in self?.openWithDefaultApp() }
        )
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel

        position(panel)

        // Slide in from the configured side of the active display.
        let finalFrame = panel.frame
        let incoming: CGFloat = CaptureSettings.overlayCorner.isLeft ? -50 : 50
        let startFrame = NSRect(x: finalFrame.origin.x + incoming, y: finalFrame.origin.y, width: finalFrame.width, height: finalFrame.height)
        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0
        // Nonactivating panels can become key without activating the main app.
        // Merely ordering front never routes local Cmd-C/S/E/W into this panel.
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        installDismissMonitors()
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onDisplaysChanged()
                }
            }
        scheduleAutoClose()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Quick Access must stay visible while interacting with *other apps*.
        // Only intercept keys actually directed to this overlay, never global
        // Cmd-C/Esc, which would steal shortcuts from the destination app.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard let action = QuickAccessPolicy.shortcut(
                keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command)) else { return event }
            switch action {
            case .close: self.dismiss(deleteFile: false)
            case .copy: self.copyImage()
            case .save: self.save()
            case .edit: self.annotate()
            case .pin: self.pin()
            case .quickLook: self.preview()
            }
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
            self.displayChangeObserver = nil
        }
    }

    private func onDisplaysChanged() {
        guard let panel else { return }
        let previous = preferredDisplayID
        let selected = QuickAccessGeometry.targetDisplay(
            QuickAccessGeometry.currentDisplays(), preferredID: previous,
            pointer: NSEvent.mouseLocation,
            followPointer: CaptureSettings.overlayFollowsActiveDisplay)
        preferredDisplayID = selected?.id
        position(panel)
        onDisplayTopologyChange?()
    }

    func dismiss(deleteFile: Bool) {
        // A failed Finder recycle must not leave a visible panel without key
        // monitoring or a live auto-close timer.
        if deleteFile {
            moveToTrash()
            return
        }
        closeTimer?.cancel()
        closeTimer = nil
        removeDismissMonitors()
        let closing = panel
        panel = nil
        onDismiss?(wasDeleted)
        onDismiss = nil
        guard let closing else { return }

        let currentFrame = closing.frame
        let direction: CGFloat = CaptureSettings.overlayCorner.isLeft ? -60 : 60
        let targetFrame = NSRect(x: currentFrame.origin.x + direction, y: currentFrame.origin.y, width: currentFrame.width, height: currentFrame.height)

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
        onDismiss?(wasDeleted)
        onDismiss = nil
        guard let closing else { return }

        let currentFrame = closing.frame
        let direction: CGFloat = CaptureSettings.overlayCorner.isLeft ? -360 : 360
        let targetFrame = NSRect(x: currentFrame.origin.x + direction, y: currentFrame.origin.y, width: currentFrame.width, height: currentFrame.height)

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
            if !NSEvent.modifierFlags.contains(.option) {
                dismiss(deleteFile: false)
            }
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
        if QuickAccessPolicy.shouldPromptSave(
            asksForName: CaptureSettings.asksForNameAfterCapture,
            optionPressed: NSEvent.modifierFlags.contains(.option)) {
            saveAs()
            return
        }
        guard let url = ensureFile() else { return }
        GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
        dismiss(deleteFile: false)
    }

    private func revealInFinder() {
        guard let url = ensureFile() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        // Revealing a file should not discard a still-useful Quick Access card.
    }

    /// Used by Save All: no popup, no Finder activation per capture.
    @discardableResult
    func saveWithoutPrompt() -> Bool {
        guard ensureFile() != nil else { return false }
        dismiss(deleteFile: false)
        return true
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

    private func saveAs() {
        let type: UTType = entry.kind == .videoRecording ? .mpeg4Movie : CaptureSettings.format.contentType
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.nameFieldStringValue = entry.fileURL?.lastPathComponent
            ?? "Screenshot-\(entry.id.uuidString.prefix(8)).\(entry.kind == .videoRecording ? "mp4" : CaptureSettings.format.fileExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if entry.kind == .videoRecording {
                        guard let source = entry.playableVideoURL else {
                            throw CaptureError.captureFailed("Recording file is missing.")
                        }
                        if source != url { try FileManager.default.copyItem(at: source, to: url) }
                    } else {
                        let result = CaptureResult(image: entry.image, globalRect: .zero,
                            scale: entry.scale, kind: entry.kind, windowTitle: entry.windowTitle,
                            capturedAt: entry.capturedAt)
                        let data = try ScreenCaptureService.shared.encode(result)
                        try data.write(to: url, options: .atomic)
                    }
                    GestureHUD.shared.show(title: "Saved As", detail: url.lastPathComponent)
                    self.dismiss(deleteFile: false)
                } catch {
                    GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                }
            }
        }
    }

    private func preview() {
        QuickAccessExpandedPreview.shared.open(entry: entry)
    }

    private func temporarilyHide() {
        CaptureCoordinator.shared.toggleQuickAccessVisibility()
    }

    func setTemporarilyHidden(_ hidden: Bool) {
        guard let panel, hidden != temporarilyHidden else { return }
        temporarilyHidden = hidden
        if hidden {
            pauseAutoClose()
            let frame = panel.frame
            let offscreenY = (panel.screen?.visibleFrame.minY ?? frame.minY) - frame.height - 18
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrameOrigin(NSPoint(x: frame.minX, y: offscreenY))
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                if self?.temporarilyHidden == true { panel.orderOut(nil) }
            }
        } else {
            position(panel)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            resumeAutoClose()
        }
    }

    private func saveAllVisible() {
        CaptureCoordinator.shared.saveAllQuickAccess()
    }

    private func closeAllVisible() {
        CaptureCoordinator.shared.closeAllQuickAccess()
    }

    private func showFileInfo() {
        let fileSize: String
        if let url = entry.fileURL,
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            fileSize = "Not saved yet"
        }
        GestureHUD.shared.show(title: entry.displayName,
            detail: "\(entry.image.width) × \(entry.image.height) px • \(fileSize)")
    }

    private func printCapture() {
        guard entry.kind != .videoRecording else { return }
        let image = NSImage(cgImage: entry.image, size: entry.pointSize)
        let view = NSImageView(frame: CGRect(origin: .zero, size: entry.pointSize))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        NSPrintOperation(view: view).run()
    }

    private func copyTransformed(_ image: CGImage?) {
        guard let image else {
            GestureHUD.shared.show(title: "Transform Failed", detail: "Unable to render image.")
            return
        }
        do {
            try ScreenCaptureService.shared.copyToClipboard(
                CaptureResult(image: image, globalRect: .zero, scale: 1,
                              kind: entry.kind, windowTitle: entry.windowTitle,
                              capturedAt: entry.capturedAt), format: .png)
            GestureHUD.shared.show(title: "Copied", detail: "Modified image copied.")
            if !NSEvent.modifierFlags.contains(.option) { dismiss(deleteFile: false) }
        } catch {
            GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
        }
    }

    private func shareCapture() {
        guard let url = ensureFile(), let panel, let view = panel.contentView else { return }
        NSSharingServicePicker(items: [url]).show(
            relativeTo: CGRect(x: view.bounds.midX - 1,
                               y: view.bounds.midY - 1, width: 2, height: 2),
            of: view, preferredEdge: .minY)
    }

    private func openWithDefaultApp() {
        guard let url = ensureFile() else { return }
        if !NSWorkspace.shared.open(url) {
            GestureHUD.shared.show(title: "Open Failed", detail: "No compatible application was found.")
        }
    }

    private func moveToTrash() {
        guard !recycleInProgress else { return }
        guard let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            CaptureHistory.shared.remove(entry)
            wasDeleted = true
            dismiss(deleteFile: false)
            return
        }
        recycleInProgress = true
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recycleInProgress = false
                if let error {
                    GestureHUD.shared.show(title: "Move to Trash Failed", detail: error.localizedDescription)
                    return
                }
                CaptureHistory.shared.remove(self.entry)
                self.wasDeleted = true
                self.dismiss(deleteFile: false)
            }
        }
    }

    private func ensureFile() -> URL? {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard entry.kind != .videoRecording else {
            GestureHUD.shared.show(title: "Video Unavailable", detail: "The recording file is missing.")
            return nil
        }
        let result = CaptureResult(image: entry.image, globalRect: .zero, scale: entry.scale, kind: entry.kind,
                                   windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
        guard let url = try? ScreenCaptureService.shared.writeToDisk(result) else {
            GestureHUD.shared.show(title: "Save Failed", detail: "The capture could not be written to disk.")
            return nil
        }
        CaptureHistory.shared.attachFile(url, to: entry.id)
        return url
    }

    private func handleDragOut(success: Bool) {
        dragging = false
        setHovering(hovering)
        if QuickAccessPolicy.shouldCloseAfterDrag(mode: CaptureSettings.overlayAutoClose,
                separateToggle: CaptureSettings.overlayCloseAfterDrag,
                succeeded: success, optionPressed: NSEvent.modifierFlags.contains(.option)) {
            dismiss(deleteFile: false)
        }
    }

    private func beginDragFile() -> URL? {
        let file = ensureFile()
        if file != nil {
            dragging = true
            pauseAutoClose()
        }
        return file
    }

    private func scheduleAutoClose() {
        secondsRemaining = QuickAccessPolicy.effectiveInterval(
            mode: CaptureSettings.overlayAutoClose,
            configured: CaptureSettings.overlayIntervalSeconds,
            forced: forcedAutoCloseSeconds)
        resumeAutoClose()
    }

    private func pauseAutoClose() {
        guard let current = secondsRemaining else { return }
        if let resumedAt { secondsRemaining = max(0.05, current - Date().timeIntervalSince(resumedAt)) }
        resumedAt = nil
        closeTimer?.cancel()
        closeTimer = nil
    }

    private func resumeAutoClose() {
        guard !hovering, !dragging, !temporarilyHidden,
              let remaining = secondsRemaining, remaining > 0 else { return }
        closeTimer?.cancel()
        resumedAt = Date()
        closeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled else { return }
            if CaptureSettings.overlayAutoCloseSave {
                if self?.saveWithoutPrompt() == false {
                    self?.secondsRemaining = nil
                }
            } else {
                self?.dismiss(deleteFile: false)
            }
        }
    }

    private func setHovering(_ value: Bool) {
        hovering = value
        if value { pauseAutoClose() }
        else { resumeAutoClose() }
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel) {
        let selected = QuickAccessGeometry.targetDisplay(
            QuickAccessGeometry.currentDisplays(), preferredID: preferredDisplayID,
            pointer: NSEvent.mouseLocation,
            followPointer: CaptureSettings.overlayFollowsActiveDisplay)
        guard let selected else { return }
        // Save stable screen identity so moving the mouse doesn't teleport
        // older cards across monitors as new captures arrive.
        preferredDisplayID = selected.id
        let frame = QuickAccessGeometry.frame(
            visible: selected.visibleFrame,
            card: panel.frame.size,
            corner: CaptureSettings.overlayCorner,
            index: stackIndex,
            count: visibleStackCount)
        panel.setFrame(frame, display: true)
    }
}

/// Compact CleanShot-style overlay with central Copy / Save controls and corner actions.
/// The implementation is purposefully original; no proprietary icons or assets are copied.
private struct QuickAccessOverlayView: View {
    let entry: CaptureHistoryEntry
    let onCopy: () -> Void
    let onCopyFile: () -> Void
    let onSave: () -> Void
    let onReveal: () -> Void
    let onSaveAll: () -> Void
    let onCloseAll: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onOCR: () -> Void
    let onQR: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onSwipeDismiss: () -> Void
    let onDragOut: (Bool) -> Void
    let prepareDragFile: () -> URL?
    let onHoverChange: (Bool) -> Void
    let onSaveAs: () -> Void
    let onPreview: () -> Void
    let onTemporarilyHide: () -> Void
    let onInfo: () -> Void
    let onPrint: () -> Void
    let onCopyOneX: () -> Void
    let onFlip: () -> Void
    let onRotate: () -> Void
    let onShare: () -> Void
    let onOpenWith: () -> Void

    @State private var hovered = false
    @State private var dragOffset: CGFloat = 0
    private var side: CGFloat { CaptureSettings.overlaySize.thumbnailSide }
    private var width: CGFloat { CaptureSettings.overlaySize.panelWidth }
    private var isVideo: Bool { entry.kind == .videoRecording }
    private var isLeft: Bool { CaptureSettings.overlayCorner.isLeft }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color(nsColor: .controlBackgroundColor))
                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        QuickAccessDragSource(preview: entry.thumbnail,
                                              prepareFile: prepareDragFile,
                                              didFinish: onDragOut,
                                              didDoubleClick: onPreview,
                                              didSwipe: onSwipeDismiss,
                                              isLeftCorner: isLeft)
                    }

                if hovered {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.black.opacity(0.38))
                        .allowsHitTesting(false)
                }
                VStack {
                    HStack {
                        if !isVideo {
                            overlayIcon("pin.fill", hint: "Pin screenshot", onPin)
                        } else {
                            overlayIcon("play.fill", hint: "Preview recording", onPreview)
                        }
                        Spacer(minLength: 4)
                        overlayIcon("xmark", hint: "Close", onClose)
                    }
                    Spacer(minLength: 4)
                    if hovered {
                        VStack(spacing: 10) {
                            centralButton("Copy", action: isVideo ? onCopyFile : onCopy)
                            centralButton("Save", action: onSave)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    Spacer(minLength: 4)
                    HStack {
                        overlayIcon(isVideo ? "film.stack" : "pencil",
                                    hint: isVideo ? "Preview video" : "Annotate", isVideo ? onPreview : onAnnotate)
                        Spacer(minLength: 4)
                        Menu {
                            quickActions
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.50), in: Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28, height: 28)
                        .help("More actions")
                    }
                }
                .padding(8)
            }
            .frame(height: side)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .contextMenu { quickActions }
            HStack(spacing: 6) {
                Image(systemName: isVideo ? "video.fill" : "photo.fill")
                    .font(.system(size: 9))
                Text(entry.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 3)
                Text("\(entry.image.width) × \(entry.image.height)")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
        }
        .padding(7)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17)
            .stroke(Color.white.opacity(0.17), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 15, y: 6)
        .offset(x: dragOffset)
        .onHover { state in
            withAnimation(.easeOut(duration: 0.15)) { hovered = state }
            onHoverChange(state)
        }
        // Trackpad horizontal swipes are handled by QuickAccessDragSource.
        // Do not compete with its mouse-drag session: a file drag must not
        // accidentally dismiss the overlay as a horizontal "swipe".
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Access for \(entry.displayName)")
    }

    private func centralButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.horizontal, 20)
                .frame(minWidth: 92, minHeight: 29)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title == "Copy" ? "Copy (⌘C, Option-click keeps overlay)" : "Save (⌘S)")
    }

    private func overlayIcon(_ symbol: String, hint: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.51), in: Circle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(hint)
    }

    @ViewBuilder private var quickActions: some View {
        Button("Quick Look", action: onPreview)
        Button("Save As…", action: onSaveAs)
        Button("Copy File", action: onCopyFile)
        Button("Show in Finder", action: onReveal)
        Button("File Information", action: onInfo)
        Button("Open with Default App", action: onOpenWith)
        Button("Share…", action: onShare)
        if !isVideo {
            Divider()
            Button("Annotate", action: onAnnotate)
            Button("Pin to Screen", action: onPin)
            Button("Copy Text (OCR)", action: onOCR)
            Button("Copy QR Code", action: onQR)
            Button("Copy Retina as 1×", action: onCopyOneX)
            Button("Copy Flipped Horizontally", action: onFlip)
            Button("Copy Rotated Left", action: onRotate)
            Button("Print…", action: onPrint)
        }
        Divider()
        Button("Temporarily Hide", action: onTemporarilyHide)
        Button("Save All Overlays", action: onSaveAll)
        Button("Close All Overlays", action: onCloseAll)
        Button("Close", action: onClose)
        Button("Move to Trash", role: .destructive, action: onDelete)
    }
}
