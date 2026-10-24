import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// CleanShot X-style floating Quick Access Overlay that appears after a capture.
///
/// Features:
/// - Slide-in from the configured screen edge (fade only with Reduce Motion)
/// - Hover curtain: close at top-left, stacked Copy / Save, Pin and Annotate corners
/// - Native drag & drop to export the file directly into Finder/Slack/Discord
/// - Two-finger swipe toward the screen edge dismisses, swipe down hides all
/// - Multiple overlays, Save All/Close All and restore-most-recently-closed
/// - Right-click menu in CleanShot order; in-place Rotate/Flip/Scale/Resize
private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Accumulates trackpad scroll deltas into one swipe decision per gesture.
@MainActor
final class QuickAccessSwipeTracker {
    private var fingerDX: CGFloat = 0
    private var fingerDY: CGFloat = 0
    private var fired = false
    var isLeftCorner: () -> Bool = { CaptureSettings.overlayCorner.isLeft }
    var onSwipe: ((QuickAccessSwipe) -> Void)?

    /// Returns true when the event was a precise (trackpad) scroll and consumed.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            fingerDX = 0; fingerDY = 0; fired = false
        }
        // Momentum after a decided swipe must not trigger a second action.
        if !fired, event.momentumPhase == [] {
            let inverted = event.isDirectionInvertedFromDevice
            fingerDX += QuickAccessPolicy.fingerDelta(event.scrollingDeltaX, invertedFromDevice: inverted)
            fingerDY += QuickAccessPolicy.fingerDelta(event.scrollingDeltaY, invertedFromDevice: inverted)
            if let swipe = QuickAccessPolicy.swipeGesture(fingerDX: fingerDX, fingerDY: fingerDY,
                                                          isLeftCorner: isLeftCorner()) {
                fired = true
                onSwipe?(swipe)
            }
        }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            fingerDX = 0; fingerDY = 0
            if event.momentumPhase == .ended || event.phase == .cancelled { fired = false }
        }
        return true
    }
}

/// Hosting view that owns the card-wide right-click menu and swipe handling,
/// so both work over the hover buttons as well as over the thumbnail.
private final class QuickAccessHostingView: NSHostingView<QuickAccessOverlayView> {
    var menuProvider: (() -> NSMenu?)?
    var swipeTracker: QuickAccessSwipeTracker?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if swipeTracker?.handle(event) != true { super.scrollWheel(with: event) }
    }
}

/// NSMenuItem target that retains its closure (NSMenuItem.target is weak).
final class QuickAccessMenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: Any?) { handler() }

    static func item(_ title: String, symbol: String?, keyEquivalent: String = "",
                     modifiers: NSEvent.ModifierFlags = [],
                     _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = QuickAccessMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }
}

@MainActor
final class QuickAccessOverlayController {
    private var panel: NSPanel?
    private var hostingView: QuickAccessHostingView?
    private let swipeTracker = QuickAccessSwipeTracker()
    private var sharePicker: NSSharingServicePicker?
    private var closeTimer: Task<Void, Never>?
    private var localMonitor: Any?
    private let entry: CaptureHistoryEntry
    private var stackIndex: Int
    private var secondsRemaining: TimeInterval?
    private var resumedAt: TimeInterval?
    private var hovering = false
    private var dragging = false
    private var wasDeleted = false
    private var recycleInProgress = false
    private var mediaOperationInProgress = false
    var captureID: UUID { entry.id }
    private var temporarilyHidden = false
    private var visibleStackCount = 1
    private var preferredDisplayID: UInt32?
    private var displayChangeObserver: NSObjectProtocol?
    var onDisplayTopologyChange: (() -> Void)?
    var placementDisplayID: UInt32? { preferredDisplayID }
    private let forcedAutoCloseSeconds: TimeInterval?
    var onDismiss: ((Bool) -> Void)?

    private var isVideo: Bool { entry.kind == .videoRecording }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
        let changed = index != stackIndex || max(1, total) != visibleStackCount
        stackIndex = index
        visibleStackCount = max(1, total)
        guard let panel, !temporarilyHidden else { return }
        // Remaining cards glide into the freed slot (CleanShot reflow).
        position(panel, animated: changed && panel.isVisible)
    }

    func present() {
        guard panel == nil else { return }
        let width = CaptureSettings.overlaySize.panelWidth
        let height = CaptureSettings.overlaySize.thumbnailSide + 8
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
        panel.setAccessibilityLabel("Quick Access Overlay")

        swipeTracker.onSwipe = { [weak self] swipe in
            switch swipe {
            case .dismiss: self?.dismissWithSwipe()
            case .hideAll: CaptureCoordinator.shared.toggleQuickAccessVisibility()
            }
        }
        let hosting = QuickAccessHostingView(rootView: makeView())
        hosting.menuProvider = { [weak self] in self?.buildContextMenu() }
        hosting.swipeTracker = swipeTracker
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel

        position(panel)

        // Slide in from the configured side of the active display.
        let finalFrame = panel.frame
        let incoming: CGFloat = Self.reduceMotion ? 0 : (CaptureSettings.overlayCorner.isLeft ? -50 : 50)
        let startFrame = NSRect(x: finalFrame.origin.x + incoming, y: finalFrame.origin.y, width: finalFrame.width, height: finalFrame.height)
        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0
        // Nonactivating panels can become key without activating the main app.
        // Merely ordering front never routes local Cmd-C/S/E/W into this panel.
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0.12 : 0.24
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

    private func makeView() -> QuickAccessOverlayView {
        QuickAccessOverlayView(
            entry: entry,
            thumbnail: entry.thumbnail,
            onCopy: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.save() },
            onAnnotate: { [weak self] in self?.annotate() },
            onPin: { [weak self] in self?.pin() },
            onClose: { [weak self] in self?.dismiss(deleteFile: false) },
            onTrash: { [weak self] in self?.trashFromOverlay() },
            onDragOut: { [weak self] success, option in self?.handleDragOut(success: success, optionPressed: option) },
            prepareDragFile: { [weak self] in self?.beginDragFile() },
            onHoverChange: { [weak self] hovering in self?.setHovering(hovering) },
            onPreview: { [weak self] in self?.preview() },
            onMore: { [weak self] in self?.popUpMoreMenu() },
            swipeTracker: swipeTracker,
            accessibilityActions: [
                ("Copy", { [weak self] in self?.copyImage() }),
                ("Save", { [weak self] in self?.save() }),
                ("Annotate", { [weak self] in self?.annotate() }),
                ("Close", { [weak self] in self?.dismiss(deleteFile: false) }),
                ("Move to Trash", { [weak self] in self?.trashFromOverlay() }),
            ]
        )
    }

    /// Re-render after an in-place image edit (rotate, flip, scale, resize).
    private func refreshView() {
        hostingView?.rootView = makeView()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Quick Access must stay visible while interacting with *other apps*.
        // Only intercept keys actually directed to this overlay, never global
        // Cmd-C/Esc, which would steal shortcuts from the destination app.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel,
                  panel.attachedSheet == nil, NSApp.modalWindow == nil,
                  (panel.firstResponder as? NSTextView)?.isEditable != true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 1, modifiers == [.command, .shift] {
                if !event.isARepeat { self.saveAs() }
                return nil
            }
            guard modifiers.isEmpty || modifiers == .command ||
                    (modifiers == [.command, .option] && [UInt16(8), 1].contains(event.keyCode)) else { return event }
            guard let action = QuickAccessPolicy.shortcut(
                keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command)) else { return event }
            if event.isARepeat { return nil }
            switch action {
            case .close: self.dismiss(deleteFile: false)
            case .copy: self.copyImage()
            case .save: self.save()
            case .edit: self.annotate()
            case .pin: self.pin()
            case .quickLook: self.preview()
            case .trash: self.trashFromOverlay()
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
            guard !mediaOperationInProgress else { return }
            moveToTrash()
            return
        }
        slideOut(distance: 60, duration: 0.16)
    }

    func dismissWithSwipe() {
        slideOut(distance: 360, duration: 0.18)
    }

    private func slideOut(distance: CGFloat, duration: TimeInterval) {
        closeTimer?.cancel()
        closeTimer = nil
        removeDismissMonitors()
        let closing = panel
        panel = nil
        hostingView = nil
        onDismiss?(wasDeleted)
        onDismiss = nil
        guard let closing else { return }

        let currentFrame = closing.frame
        let direction: CGFloat = Self.reduceMotion ? 0
            : (CaptureSettings.overlayCorner.isLeft ? -distance : distance)
        let targetFrame = currentFrame.offsetBy(dx: direction, dy: 0)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            closing.animator().setFrame(targetFrame, display: true)
            closing.animator().alphaValue = 0.0
        } completionHandler: {
            closing.orderOut(nil)
        }
    }

    // MARK: - Actions

    /// Suspend auto-close while an explicit copy/save runs, and serialize clicks.
    private func mediaOperation(_ body: @escaping () async -> Void) {
        guard !mediaOperationInProgress else { return }
        mediaOperationInProgress = true
        pauseAutoClose()
        Task { @MainActor in
            defer {
                mediaOperationInProgress = false
                if panel != nil { resumeAutoClose() }
            }
            await body()
        }
    }

    private func copyImage() {
        if isVideo { copyFile(); return }
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        mediaOperation { [self] in
            let result = await currentResultAsync()
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(result)
                GestureHUD.shared.show(title: "Copied", detail: "Image on the clipboard")
                if !keepOpen { dismiss(deleteFile: false) }
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
            }
        }
    }

    private func copyFile() {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        mediaOperation { [self] in
            guard let url = await ensureFileAsync() else { return }
            guard ScreenCaptureService.shared.copyFileToClipboard(url) else {
                GestureHUD.shared.show(title: "Copy Failed", detail: "Could not copy the capture file.")
                return
            }
            GestureHUD.shared.show(title: "Copied", detail: url.lastPathComponent)
            if !keepOpen { dismiss(deleteFile: false) }
        }
    }

    private func save() {
        if QuickAccessPolicy.shouldPromptSave(
            asksForName: CaptureSettings.asksForNameAfterCapture,
            optionPressed: NSEvent.modifierFlags.contains(.option)) {
            guard !mediaOperationInProgress else { return }
            saveAs()
            return
        }
        mediaOperation { [self] in
            guard let url = await ensureFileAsync() else { return }
            GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
            dismiss(deleteFile: false)
        }
    }

    private func revealInFinder() {
        mediaOperation { [self] in
            guard let url = await ensureFileAsync() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Used by Save All: no popup, no Finder activation per capture.
    @discardableResult
    func saveWithoutPrompt() async -> Bool {
        guard !mediaOperationInProgress else { return false }
        mediaOperationInProgress = true
        pauseAutoClose()
        defer {
            mediaOperationInProgress = false
            if panel != nil { resumeAutoClose() }
        }
        guard await ensureFileAsync() != nil else { return false }
        dismiss(deleteFile: false)
        return true
    }

    /// True when the capture has never been written to disk (Close All warns).
    var hasUnsavedMedia: Bool {
        guard let url = entry.fileURL else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private func annotate() {
        if isVideo {
            guard let url = entry.playableVideoURL else {
                GestureHUD.shared.show(title: "Recording Missing", detail: "The video file could not be found.")
                return
            }
            RecordingExportEditorController.shared.open(source: url)
            dismiss(deleteFile: false)
            return
        }
        mediaOperation { [self] in
            let url = await ensureFileAsync()
            AnnotationEditorController.shared.open(capture: entry, url: url)
            dismiss(deleteFile: false)
        }
    }

    private func pin() {
        guard !isVideo else { return }
        mediaOperation { [self] in
            let url = await ensureFileAsync()
            PinnedScreenshotController.shared.pin(entry: entry, url: url)
            dismiss(deleteFile: false)
        }
    }

    private func recognizeQRCode() {
        guard !isVideo else { return }
        Task { @MainActor in
            do {
                guard let code = try await TextRecognitionService.detectQRCodes(await entry.loadImage()).first else {
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

    /// The cut-out becomes a new capture with its own card; this one is kept.
    private func removeBackground() {
        guard !isVideo else { return }
        mediaOperation { [self] in
            GestureHUD.shared.show(title: "Removing Background…", detail: nil)
            do {
                let output = try await BackgroundRemoval.removingBackground(await entry.loadImage())
                let result = CaptureResult(image: output, globalRect: CGRect(origin: .zero, size: entry.pointSize),
                                           scale: entry.scale, kind: entry.kind,
                                           windowTitle: entry.windowTitle, capturedAt: Date())
                let stored = CaptureHistory.shared.add(result, url: nil)
                CaptureCoordinator.shared.restoreToQuickAccess(stored)
                GestureHUD.shared.show(title: "Background Removed", detail: "Added as a new capture; the original is kept")
            } catch {
                GestureHUD.shared.show(title: "Remove Background Failed", detail: error.localizedDescription)
            }
        }
    }

    private func recognizeText() {
        let keepBreaks = CaptureSettings.ocrKeepsLineBreaks
        Task { @MainActor in
            do {
                let text = try await TextRecognitionService.recognize(await entry.loadImage(), keepsLineBreaks: keepBreaks)
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
        let type: UTType = isVideo ? .mpeg4Movie : CaptureSettings.format.contentType
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.nameFieldStringValue = entry.fileURL?.lastPathComponent
            ?? "Screenshot-\(entry.id.uuidString.prefix(8)).\(isVideo ? "mp4" : CaptureSettings.format.fileExtension)"
        pauseAutoClose()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .OK, let url = panel.url else {
                    self.resumeAutoClose()
                    return
                }
                do {
                    if self.isVideo {
                        guard let source = self.entry.playableVideoURL else {
                            throw CaptureError.captureFailed("Recording file is missing.")
                        }
                        if source != url { try FileManager.default.copyItem(at: source, to: url) }
                    } else {
                        // F-04D: snapshot the pixels and format on the main
                        // actor, then encode/write to the panel's URL off it.
                        let capture = await self.currentResultAsync()
                        let format = CaptureSettings.format
                        try await ScreenCaptureService.shared.writeToURLAsync(capture, to: url, format: format)
                    }
                    GestureHUD.shared.show(title: "Saved As", detail: url.lastPathComponent)
                    self.dismiss(deleteFile: false)
                } catch {
                    GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                    self.resumeAutoClose()
                }
            }
        }
    }

    private func preview() {
        QuickAccessExpandedPreview.shared.open(entry: entry)
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
                if !Self.reduceMotion {
                    panel.animator().setFrameOrigin(NSPoint(x: frame.minX, y: offscreenY))
                }
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    if self?.temporarilyHidden == true { panel?.orderOut(nil) }
                }
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

    private func showFileInfo() {
        let fileSize: String
        if let url = entry.fileURL,
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            fileSize = "Not saved yet"
        }
        GestureHUD.shared.show(title: entry.displayName,
            detail: "\(entry.pixelWidth) × \(entry.pixelHeight) px • \(fileSize)")
    }

    private func printCapture() {
        guard !isVideo else { return }
        // Tall (scrolling) captures are split across pages; see CapturePrintView.
        CapturePrintController.print(image: entry.image, scale: entry.scale,
                                     title: entry.displayName, window: nil)
    }

    private func currentResult() -> CaptureResult {
        CaptureResult(image: entry.image,
                      globalRect: CGRect(origin: .zero, size: entry.pointSize),
                      scale: entry.scale, kind: entry.kind,
                      windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    private func currentResultAsync() async -> CaptureResult {
        let image = await entry.loadImage()
        return CaptureResult(image: image, globalRect: CGRect(origin: .zero, size: entry.pointSize),
                             scale: entry.scale, kind: entry.kind,
                             windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    // MARK: - In-place image edits (CleanShot Rotate Left / Flip / Scale / Resize)

    private func transform(scale: CGFloat? = nil, label: String, render: @escaping @Sendable (CGImage) -> CGImage?) {
        guard !isVideo else { return }
        let revision = entry.imageRevision
        mediaOperation { [self] in
            let source = await entry.loadImage()
            let rendered = await QuickAccessImageTools.renderAsync(source, render: render)
            applyTransform(rendered, scale: scale, label: label, ifRevision: revision)
        }
    }

    private func applyTransform(_ image: CGImage?, scale: CGFloat? = nil, label: String, ifRevision revision: Int? = nil) {
        guard !isVideo else { return }
        guard let image else {
            GestureHUD.shared.show(title: "Transform Failed", detail: "Unable to render image.")
            return
        }
        guard CaptureHistory.shared.replaceImage(of: entry, with: image, scale: scale ?? entry.scale, ifRevision: revision) else {
            GestureHUD.shared.show(title: "Capture Changed", detail: "The newer edit was kept. Try the transform again.")
            return
        }
        refreshView()
        GestureHUD.shared.show(title: label, detail: "\(image.width) × \(image.height) px")
    }

    private var canScaleRetina: Bool {
        !isVideo && entry.scale > 1 && entry.pixelWidth > Int(entry.pointSize.width.rounded())
    }

    private func scaleRetinaToOneX() {
        guard canScaleRetina else { return }
        let pointSize = entry.pointSize
        transform(scale: 1, label: "Scaled to 1x") { QuickAccessImageTools.downscaleToOneX($0, pointSize: pointSize) }
    }

    private func promptResize() {
        guard !isVideo else { return }
        pauseAutoClose()
        defer { resumeAutoClose() }
        let prompt = QuickAccessResizePrompt(width: entry.pixelWidth, height: entry.pixelHeight)
        NSApp.activate(ignoringOtherApps: true)
        guard let size = prompt.run() else { return }
        transform(label: "Resized") { QuickAccessImageTools.resized($0, width: size.width, height: size.height) }
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Quick Access")
        menu.autoenablesItems = false
        for command in QuickAccessMenuCommand.layout(isVideo: isVideo, canScaleRetina: canScaleRetina) {
            guard let command else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            menu.addItem(menuItem(for: command))
        }
        return menu
    }

    private func menuItem(for command: QuickAccessMenuCommand) -> NSMenuItem {
        switch command {
        case .share:
            return shareMenuItem()
        case .openWith:
            return openWithMenuItem()
        default:
            let item = QuickAccessMenuAction.item(command.title, symbol: command.symbol) { [weak self] in
                self?.perform(command)
            }
            if command == .moveToTrash {
                item.keyEquivalent = "\u{8}"
                item.keyEquivalentModifierMask = .command
            } else if command == .quickLook {
                item.keyEquivalent = " "
                item.keyEquivalentModifierMask = []
            } else if command == .annotate || command == .editVideo {
                item.keyEquivalent = "e"; item.keyEquivalentModifierMask = .command
            } else if command == .pin {
                item.keyEquivalent = "p"; item.keyEquivalentModifierMask = .command
            } else if command == .saveAs {
                item.keyEquivalent = "s"; item.keyEquivalentModifierMask = [.command, .shift]
            }
            return item
        }
    }

    private func perform(_ command: QuickAccessMenuCommand) {
        guard !mediaOperationInProgress else { return }
        switch command {
        case .share, .openWith: break
        case .closeAll: CaptureCoordinator.shared.confirmCloseAllQuickAccess()
        case .saveAll: CaptureCoordinator.shared.saveAllQuickAccess()
        case .temporarilyHide: CaptureCoordinator.shared.toggleQuickAccessVisibility()
        case .quickLook: preview()
        case .openInFinder: revealInFinder()
        case .print: printCapture()
        case .saveAs: saveAs()
        case .moveToTrash: trashFromOverlay()
        case .annotate, .editVideo: annotate()
        case .pin: pin()
        case .rotateLeft:
            transform(label: "Rotated Left", render: QuickAccessImageTools.rotatedLeft)
        case .flipHorizontal:
            transform(label: "Flipped Horizontally", render: QuickAccessImageTools.flippedHorizontally)
        case .scaleRetina: scaleRetinaToOneX()
        case .resize: promptResize()
        case .extractText: recognizeText()
        case .removeBackground: removeBackground()
        case .copyQRCode: recognizeQRCode()
        case .copyFile: copyFile()
        case .fileInfo: showFileInfo()
        }
    }

    private func shareMenuItem() -> NSMenuItem {
        // Unsaved screenshots share their pixels; saved files and videos share the file.
        let item: Any
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            item = url
        } else {
            item = NSImage(cgImage: entry.image, size: entry.pointSize)
        }
        let picker = NSSharingServicePicker(items: [item])
        sharePicker = picker
        let menuItem = picker.standardShareMenuItem
        menuItem.image = NSImage(systemSymbolName: QuickAccessMenuCommand.share.symbol, accessibilityDescription: nil)
        return menuItem
    }

    private func openWithMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: QuickAccessMenuCommand.openWith.title, action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: QuickAccessMenuCommand.openWith.symbol, accessibilityDescription: nil)
        let submenu = NSMenu(title: root.title)
        let type: UTType = isVideo ? .mpeg4Movie : CaptureSettings.format.contentType
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: type)
        var apps = workspace.urlsForApplications(toOpen: type)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        for (index, appURL) in apps.prefix(12).enumerated() {
            let name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            let item = QuickAccessMenuAction.item(index == 0 && defaultApp != nil ? "\(name) (default)" : name,
                                                  symbol: nil) { [weak self] in
                self?.open(withApplicationAt: appURL)
            }
            let icon = workspace.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
            if index == 0, defaultApp != nil, apps.count > 1 { submenu.addItem(.separator()) }
        }
        if submenu.items.isEmpty {
            let none = NSMenuItem(title: "No Compatible Apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        root.submenu = submenu
        return root
    }

    private func open(withApplicationAt appURL: URL) {
        mediaOperation { [self] in
            guard let url = await ensureFileAsync() else { return }
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                                     configuration: NSWorkspace.OpenConfiguration())
            } catch {
                GestureHUD.shared.show(title: "Open Failed", detail: error.localizedDescription)
            }
        }
    }

    private func popUpMoreMenu() {
        guard let view = hostingView else { return }
        let menu = buildContextMenu()
        let point = NSPoint(x: view.bounds.maxX - 30, y: view.isFlipped ? view.bounds.maxY - 8 : 8)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: - Files

    /// Hover trash button, ⌘⌫ and the menu item: one path. Recordings ask
    /// first (losing one is expensive); screenshots go straight away — the
    /// saved file to the Trash, an unsaved one out of Capture History.
    func trashFromOverlay() {
        guard !mediaOperationInProgress, !recycleInProgress else { return }
        if QuickAccessPolicy.confirmsTrash(isVideo: isVideo) {
            pauseAutoClose()
            let alert = NSAlert()
            alert.messageText = "Move “\(entry.displayName)” to the Trash?"
            alert.informativeText = "The recording is removed from Capture History and its file goes to the Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { resumeAutoClose(); return }
        }
        dismiss(deleteFile: true)
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

    private func ensureFileAsync() async -> URL? {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard !isVideo else {
            GestureHUD.shared.show(title: "Video Unavailable", detail: "The recording file is missing.")
            return nil
        }
        do {
            let capture = await currentResultAsync()
            let revision = entry.imageRevision
            let url = try await ScreenCaptureService.shared.writeToDiskAsync(capture)
            guard CaptureHistory.shared.attachFile(url, to: entry, ifRevision: revision) else {
                GestureHUD.shared.show(title: "Capture Changed", detail: "The previous version was saved. Save the current edit again.")
                return nil
            }
            return url
        } catch {
            GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
            return nil
        }
    }

    private func ensureFile() -> URL? {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard !isVideo else {
            GestureHUD.shared.show(title: "Video Unavailable", detail: "The recording file is missing.")
            return nil
        }
        guard let url = try? ScreenCaptureService.shared.writeToDisk(currentResult()) else {
            GestureHUD.shared.show(title: "Save Failed", detail: "The capture could not be written to disk.")
            return nil
        }
        CaptureHistory.shared.attachFile(url, to: entry.id)
        entry.fileURL = url
        return url
    }

    private func handleDragOut(success: Bool, optionPressed: Bool) {
        dragging = false
        setHovering(hovering)
        if QuickAccessPolicy.shouldCloseAfterDrag(mode: CaptureSettings.overlayAutoClose,
                separateToggle: CaptureSettings.overlayCloseAfterDrag,
                succeeded: success, optionPressed: optionPressed) {
            dismiss(deleteFile: false)
        }
    }

    private func beginDragFile() -> URL? {
        guard !mediaOperationInProgress else { return nil }
        // Prefer the drag file written off the main thread on hover.
        let file = CaptureDragFiles.shared.readyFile(for: entry) ?? ensureFile()
        if file != nil {
            dragging = true
            pauseAutoClose()
        }
        return file
    }

    // MARK: - Auto-close

    private func scheduleAutoClose() {
        secondsRemaining = QuickAccessPolicy.effectiveInterval(
            mode: CaptureSettings.overlayAutoClose,
            configured: CaptureSettings.overlayIntervalSeconds,
            forced: forcedAutoCloseSeconds)
        resumeAutoClose()
    }

    private func pauseAutoClose() {
        guard let current = secondsRemaining else { return }
        if let resumedAt { secondsRemaining = max(0, current - (ProcessInfo.processInfo.systemUptime - resumedAt)) }
        resumedAt = nil
        closeTimer?.cancel()
        closeTimer = nil
    }

    private func resumeAutoClose() {
        guard panel != nil, !hovering, !dragging, !temporarilyHidden, !mediaOperationInProgress, resumedAt == nil,
              let remaining = secondsRemaining else { return }
        closeTimer?.cancel()
        resumedAt = ProcessInfo.processInfo.systemUptime
        closeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, let self, !self.hovering,
                  !self.dragging, !self.temporarilyHidden else { return }
            self.resumedAt = nil
            self.closeTimer = nil
            self.secondsRemaining = nil
            if CaptureSettings.overlayAutoCloseSave {
                _ = await self.saveWithoutPrompt()
            } else {
                self.dismiss(deleteFile: false)
            }
        }
    }

    private func setHovering(_ value: Bool) {
        hovering = value
        if value {
            CaptureDragFiles.shared.prefetch(entry)
            pauseAutoClose()
            // CleanShot's ⌘C / ⌘S / ⌘W / ⌘E / Space work while the card is
            // hovered, even after focus moved elsewhere since it appeared.
            if let panel, !panel.isKeyWindow, panel.isVisible, NSApp.modalWindow == nil {
                panel.makeKey()
            }
        } else {
            resumeAutoClose()
        }
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel, animated: Bool = false) {
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
        if animated && !Self.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

/// Modal "Resize Image" prompt (pixels, optional proportion lock).
@MainActor
private final class QuickAccessResizePrompt: NSObject, NSTextFieldDelegate {
    private let originalWidth: Int
    private let originalHeight: Int
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let lockBox = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)

    init(width: Int, height: Int) {
        originalWidth = width
        originalHeight = height
        super.init()
    }

    func run() -> (width: Int, height: Int)? {
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Current size: \(originalWidth) × \(originalHeight) pixels"
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 32_768
        for (field, value, label) in [(widthField, originalWidth, "Width"), (heightField, originalHeight, "Height")] {
            field.integerValue = value
            field.formatter = formatter
            field.delegate = self
            field.alignment = .right
            field.setAccessibilityLabel("\(label) in pixels")
        }
        lockBox.state = .on

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), widthField, NSTextField(labelWithString: "px")],
            [NSTextField(labelWithString: "Height:"), heightField, NSTextField(labelWithString: "px")],
            [NSGridCell.emptyContentView, lockBox, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        widthField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        heightField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 240, height: 84)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = widthField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let width = max(1, widthField.integerValue)
        let height = max(1, heightField.integerValue)
        return (width, height)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard lockBox.state == .on, let field = notification.object as? NSTextField else { return }
        if field === widthField {
            heightField.integerValue = QuickAccessImageTools.proportionalSide(
                widthField.integerValue, original: originalWidth, otherOriginal: originalHeight)
        } else if field === heightField {
            widthField.integerValue = QuickAccessImageTools.proportionalSide(
                heightField.integerValue, original: originalHeight, otherOriginal: originalWidth)
        }
    }
}

/// Compact CleanShot-style overlay: on hover a dimmed curtain shows close (×)
/// at the top-left, stacked Copy / Save in the centre, Pin top-right,
/// Annotate bottom-left and a "more" menu bottom-right.
/// The implementation is purposefully original; no proprietary icons or assets are copied.
private struct QuickAccessOverlayView: View {
    let entry: CaptureHistoryEntry
    let thumbnail: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void
    let onTrash: () -> Void
    let onDragOut: (Bool, Bool) -> Void
    let prepareDragFile: () -> URL?
    let onHoverChange: (Bool) -> Void
    let onPreview: () -> Void
    let onMore: () -> Void
    let swipeTracker: QuickAccessSwipeTracker
    let accessibilityActions: [(String, () -> Void)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = QuickAccessOverlayView.takePreviewHover()
    private static var previewHoverUsed = false
    /// Preview-only: the first card starts hovered so the curtain can be inspected.
    private static func takePreviewHover() -> Bool {
        guard CaptureUIPreview.forcesHover, !previewHoverUsed else { return false }
        previewHoverUsed = true
        return true
    }
    private var side: CGFloat { CaptureSettings.overlaySize.thumbnailSide }
    private var width: CGFloat { CaptureSettings.overlaySize.panelWidth }
    private var isVideo: Bool { entry.kind == .videoRecording }
    private var compact: Bool { side < 120 }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                cardShape.fill(Color(nsColor: .controlBackgroundColor))
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        QuickAccessDragSource(preview: thumbnail,
                                              prepareFile: prepareDragFile,
                                              didFinish: { _ in },
                                              didDoubleClick: onAnnotate,
                                              didSwipe: {},
                                              isLeftCorner: CaptureSettings.overlayCorner.isLeft,
                                              didClick: onPreview,
                                              didFinishWithModifiers: onDragOut,
                                              swipeTracker: swipeTracker)
                    }

                // Curtain: dims the capture behind the hover controls.
                if hovered {
                    cardShape
                        .fill(Color.black.opacity(0.46))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if isVideo && !hovered {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: compact ? 26 : 34)).foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4).allowsHitTesting(false)
                }
                hoverControls
                    .padding(compact ? 5 : 7)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                    .accessibilityHidden(!hovered)
            }
            .frame(height: side)
            .clipShape(cardShape)
        }
        .padding(4)
        .frame(width: width)
        // The shared floating material (glass on macOS 26+), so the card
        // matches the shelf, history and HUDs.
        .aomFloatingSurface(.hud, radius: 13)
        .help("Double-click to \(isVideo ? "edit" : "annotate") · Drag to export · Right-click for more")
        .onHover { state in
            onHoverChange(state)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovered = state }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Access for \(entry.displayName)")
        .modifier(QuickAccessAccessibilityActions(actions: accessibilityActions))
    }

    private var hoverControls: some View {
        VStack(spacing: 0) {
            HStack {
                overlayIcon("xmark", label: "Close", hint: "Close (⌘W)", onClose)
                Spacer(minLength: 4)
                if isVideo {
                    overlayIcon("play.fill", label: "Quick Look", hint: "Open Quick Look (Space)", onPreview)
                } else {
                    overlayIcon("pin.fill", label: "Pin to the Screen", hint: "Pin to the Screen (⌘P)", onPin)
                }
            }
            Spacer(minLength: 0)
            centerButtons
            Spacer(minLength: 0)
            HStack {
                if isVideo {
                    overlayIcon("scissors", label: "Edit Video", hint: "Edit video (⌘E or double-click)", onAnnotate)
                } else {
                    overlayIcon("pencil", label: "Annotate", hint: "Open Annotate tool (⌘E or double-click)", onAnnotate)
                }
                Spacer(minLength: 4)
                HStack(spacing: compact ? 4 : 5) {
                    overlayIcon("trash", label: "Move to Trash", hint: "Move to Trash (⌘⌫)", onTrash)
                    overlayIcon("ellipsis", label: "More Actions", hint: "More actions (or right-click)", onMore)
                }
            }
        }
    }

    @ViewBuilder private var centerButtons: some View {
        let saveHint = CaptureSettings.asksForNameAfterCapture
            ? "Save — ask for destination (⌘S). ⌥-click saves to the export location"
            : "Save to export location (⌘S). ⌥-click to choose the destination"
        let copyHint = isVideo ? "Copy file to clipboard (⌘C)" : "Copy to clipboard (⌘C). ⌥-click keeps the overlay"
        if compact {
            HStack(spacing: 6) {
                centralButton("Copy", hint: copyHint, action: onCopy)
                centralButton("Save", hint: saveHint, action: onSave)
            }
        } else {
            VStack(spacing: 6) {
                centralButton("Copy", hint: copyHint, action: onCopy)
                centralButton("Save", hint: saveHint, action: onSave)
            }
        }
    }

    private func centralButton(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: compact ? min(70, (width - 40) / 2) : min(110, width * 0.42),
                       height: compact ? 24 : 28)
        }
        .buttonStyle(QuickAccessPillStyle())
        .accessibilityLabel(title)
        .help(hint)
    }

    private func overlayIcon(_ symbol: String, label: String, hint: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
        }
        .buttonStyle(QuickAccessIconStyle())
        .help(hint)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

/// Exposes the hover-only controls as VoiceOver actions on the card.
private struct QuickAccessAccessibilityActions: ViewModifier {
    let actions: [(String, () -> Void)]
    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: Text(action.0), action.1))
        }
    }
}

private struct QuickAccessIconStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.black.opacity(configuration.isPressed ? 0.75 : hovering ? 0.66 : 0.5), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.35 : 0.15), lineWidth: 0.5))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

private struct QuickAccessPillStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.70 : hovering ? 1 : 0.90), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.8 : 0.25), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
