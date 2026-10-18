import Foundation
import OSLog
import AppKit
import ScreenCaptureKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Runs a capture from start to finish: permission, self-timer, the selection
/// UI, the pixel grab, and whatever the user asked to happen afterwards.
///
/// Every entry point is `@MainActor` because the whole path ends in AppKit UI.
/// The ScreenCaptureKit work is async and hops off the main actor on its own.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private init() {
        // The capture cache already survives app restarts. Persist only UUIDs
        // here: never duplicate media or store absolute file paths in defaults.
        let records = CaptureHistory.shared.entries
        let valid = Set(records.map(\.id))
        let stored = UserDefaults.standard.stringArray(forKey: Self.closedIDsKey) ?? []
        let restored = QuickAccessPolicy.restoredIDs(stored, present: valid)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        recentlyClosed = restored.compactMap { byID[$0] }
    }

    private static let closedIDsKey = "AOMQuickAccessRecentlyClosedIDs"

    private func persistRecentlyClosed() {
        UserDefaults.standard.set(recentlyClosed.map { $0.id.uuidString }, forKey: Self.closedIDsKey)
    }

    /// Guards against a second capture starting while the first is still up —
    /// two selection overlays fighting over the same click is unrecoverable.
    private var isCapturing = false
    private var selectionOverlay: SelectionOverlayController?
    private var overlayControllers: [QuickAccessOverlayController] = []
    private var recentlyClosed: [CaptureHistoryEntry] = []

    var canRestoreQuickAccess: Bool { !recentlyClosed.isEmpty }

    func restoreRecentlyClosedOverlay() {
        guard let restored = recentlyClosed.popLast() else {
            GestureHUD.shared.show(title: "Nothing to Restore", detail: "No recently closed captures.")
            return
        }
        persistRecentlyClosed()
        showOverlay(for: restored, explicit: true)
    }

    var hasVisibleQuickAccess: Bool { !overlayControllers.isEmpty }

    /// Capture History "Restore": reopen any history entry as an overlay.
    /// Works even when "Show Overlay" after capture is off, since it is explicit.
    func restoreToQuickAccess(_ entry: CaptureHistoryEntry) {
        recentlyClosed.removeAll { $0.id == entry.id }
        persistRecentlyClosed()
        showOverlay(for: entry, explicit: true)
    }

    private func reflowOverlaysByDisplay() {
        // Index separately on every physical display: one capture on an
        // external screen must not push a card down on the laptop display.
        let groups = Dictionary(grouping: overlayControllers) {
            $0.placementDisplayID ?? 0
        }
        for overlays in groups.values {
            for (index, controller) in overlays.enumerated() {
                controller.setStackIndex(index, total: overlays.count)
            }
        }
    }
    private(set) var areQuickAccessHidden = false

    func toggleQuickAccessVisibility() {
        guard !overlayControllers.isEmpty else { return }
        areQuickAccessHidden.toggle()
        for overlay in overlayControllers {
            overlay.setTemporarilyHidden(areQuickAccessHidden)
        }
    }


    func closeAllQuickAccess() {
        for overlay in Array(overlayControllers.reversed()) {
            overlay.dismiss(deleteFile: false)
        }
    }

    /// CleanShot's "Close All…" asks first, because unsaved cards disappear
    /// from the screen (they remain restorable from Capture History).
    func confirmCloseAllQuickAccess() {
        guard !overlayControllers.isEmpty else { return }
        let unsaved = overlayControllers.filter(\.hasUnsavedMedia).count
        if unsaved > 0 {
            let alert = NSAlert()
            alert.messageText = "Do you want to close all overlays?"
            alert.informativeText = unsaved == 1
                ? "One capture has not been saved. It stays available in Capture History."
                : "\(unsaved) captures have not been saved. They stay available in Capture History."
            alert.addButton(withTitle: "Close All")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closeAllQuickAccess()
    }

    /// Save only the cards whose files can be written. Keep failed cards on
    /// screen so the user can retry, with no loss of captured pixels.
    func saveAllQuickAccess() {
        let overlays = overlayControllers
        Task { @MainActor in
            var success = 0
            var failure = 0
            for overlay in overlays {
                if await overlay.saveWithoutPrompt() { success += 1 }
                else { failure += 1 }
            }
            GestureHUD.shared.show(title: "Quick Access — Save All",
                detail: "\(success) saved" + (failure > 0 ? ", \(failure) could not be saved" : ""))
        }
    }

    /// Import an existing screenshot or MP4 into the Quick Access stack without
    /// moving, rewriting or claiming ownership of the source file.
    func importQuickAccessFiles(_ urls: [URL]) {
        var added = 0
        for url in urls.prefix(12) {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let ext = url.pathExtension.lowercased()
            let image: CGImage?
            let kind: CaptureKind
            if ext == "mp4" || ext == "mov" || ext == "m4v" {
                // Quick Access video operations currently require an MP4 source.
                guard ext == "mp4" else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                image = try? generator.copyCGImage(at: .zero, actualTime: nil)
                kind = .videoRecording
            } else if ["png", "jpg", "jpeg", "heic", "tiff", "tif", "webp"].contains(ext) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                kind = .area
            } else {
                continue
            }
            guard let image else { continue }
            let size = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let result = CaptureResult(image: image, globalRect: size, scale: 1,
                kind: kind, windowTitle: url.deletingPathExtension().lastPathComponent)
            let entry = CaptureHistory.shared.add(result, url: url)
            showOverlay(for: entry, explicit: true)
            added += 1
        }
        if added == 0 {
            GestureHUD.shared.show(title: "Import Failed", detail: "Select readable PNG, JPEG, HEIC, TIFF, or MP4 files.")
        }
    }

    func chooseQuickAccessFiles() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP, .mpeg4Movie]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.prompt = "Add to Quick Access"
        picker.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor [weak self] in
                self?.importQuickAccessFiles(picker.urls)
            }
        }
    }

    // MARK: - Entry points

    /// One selection surface switches between capture tools before committing.
    func captureAllInOne() {
        run(kind: .area) { [weak self] in
            guard let self else { return nil }
            let choice: (CGRect, IntegratedCaptureMode, CGWindowID?)? = await withCheckedContinuation { continuation in
                let overlay = SelectionOverlayController(integrated: true) { [weak self] rect in
                    guard let rect, let overlay = self?.selectionOverlay else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: (rect, overlay.selectedMode, overlay.selectedWindowID))
                }
                self.selectionOverlay = overlay
                overlay.present()
            }
            guard let (rect, mode, windowID) = choice else { return nil }
            switch mode {
            case .recording:
                try await ScreenRecordingService.shared.startRecording(globalRect: rect)
                return nil
            case .scrolling:
                return (try await ScrollingCaptureService.shared.capture(area: rect), .scrolling)
            case .window:
                let windows = try await ScreenCaptureService.shared.capturableWindows()
                guard let target = windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureError.noWindowFound
                }
                return (try await ScreenCaptureService.shared.captureWindow(target), .window)
            case .timer:
                try await Self.countDown(CaptureSettings.selfTimerInterval)
                return (try await ScreenCaptureService.shared.captureArea(rect), .area)
            case .text:
                let result = try await ScreenCaptureService.shared.captureArea(rect)
                try await self.deliverRecognizedText(result, keepsLineBreaks: TextCaptureSettings.shared.keepsLineBreaks)
                return nil
            case .area, .fullscreen:
                let result = try await ScreenCaptureService.shared.captureArea(rect)
                if mode == .area {
                    let saved = Self.areaRelativeToDisplay(rect)
                    CaptureSettings.lastArea = saved.localRect
                    CaptureSettings.lastAreaDisplayID = saved.displayID
                }
                if mode == .fullscreen {
                    return (CaptureResult(image: result.image, globalRect: result.globalRect,
                        scale: result.scale, kind: .fullscreen), .fullscreen)
                }
                return (result, .area)
            }
        }
    }

    func captureArea(afterCaptureOverride: AfterCaptureAction? = nil, completion: ((Bool) -> Void)? = nil) {
        run(kind: .area, afterCaptureOverride: afterCaptureOverride, completion: completion) { [weak self] in
            guard let self else { return nil }
            guard let rect = await self.presentSelection() else { return nil }
            if self.selectionOverlay?.selectedMode == .window,
               let id = self.selectionOverlay?.selectedWindowID {
                let windows = try await ScreenCaptureService.shared.capturableWindows()
                guard let window = windows.first(where: { $0.windowID == id }) else {
                    throw CaptureError.noWindowFound
                }
                return (try await ScreenCaptureService.shared.captureWindow(window), .window)
            }
            let result = try await ScreenCaptureService.shared.captureArea(rect)
            let saved = Self.areaRelativeToDisplay(rect)
            CaptureSettings.lastArea = saved.localRect
            CaptureSettings.lastAreaDisplayID = saved.displayID
            return (result, CaptureKind.area)
        }
    }

    /// Stores the selection relative to its display's origin, so "Capture
    /// Previous Area" still replays the same region after a display is moved.
    private static func areaRelativeToDisplay(_ global: CGRect) -> (localRect: CGRect, displayID: CGDirectDisplayID?) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { screen -> (NSScreen, CGRect) in
            let screenTop = primaryHeight - screen.frame.maxY
            return (screen, CGRect(x: screen.frame.minX, y: screenTop,
                                   width: screen.frame.width, height: screen.frame.height))
        }
        // Match the largest overlap, not the first intersecting monitor.
        // This agrees with ScreenCaptureService.captureArea's display choice.
        guard let chosen = screens.max(by: {
            Self.overlapArea($0.1, global) < Self.overlapArea($1.1, global)
        }), chosen.1.intersects(global) else { return (global, nil) }
        return (global.offsetBy(dx: -chosen.1.minX, dy: -chosen.1.minY), chosen.0.displayID)
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersect = a.intersection(b)
        return intersect.isNull ? 0 : intersect.width * intersect.height
    }

    func captureFullscreen(completion: ((Bool) -> Void)? = nil) {
        run(kind: .fullscreen, completion: completion) { [weak self] in
            guard let self else { return nil }
            let displays = try await ScreenCaptureService.shared.shareableContentDisplays()
            guard let target = ScreenCaptureService.displayUnderPointer(in: displays) ?? displays.first else {
                throw CaptureError.noDisplays
            }
            let result = try await ScreenCaptureService.shared.captureFullscreen(display: target)
            return (result, CaptureKind.fullscreen)
        }
    }

    /// Replays the last dragged area. Captures the same rectangle even if the
    /// content beneath it has changed — that is the point of the feature.
    func capturePreviousArea(completion: ((Bool) -> Void)? = nil) {
        guard let rect = CaptureSettings.lastArea else {
            GestureHUD.shared.show(title: "No Previous Area", detail: "Drag an area capture first.")
            completion?(false)
            return
        }
        run(kind: .previousArea, completion: completion) { [weak self] in
            guard let self else { return nil }
            let displays = try await ScreenCaptureService.shared.shareableContentDisplays()
            guard let display = displays.first(where: { $0.displayID == CaptureSettings.lastAreaDisplayID })
                    ?? ScreenCaptureService.displayUnderPointer(in: displays) ?? displays.first else {
                throw CaptureError.noDisplays
            }
            // The stored rectangle is display-local. Never pass it to bestDisplay()
            // directly: a secondary display can have the same local coordinates.
            let global = rect.offsetBy(dx: display.frame.origin.x, dy: display.frame.origin.y)
            let result = try await ScreenCaptureService.shared.captureArea(global)
            return (result, CaptureKind.previousArea)
        }
    }

    /// CleanShot "Capture Window": hover to highlight a window, click to capture
    /// (Space switches to area selection). Esc cancels.
    func captureWindowInteractive() {
        run(kind: .window) { [weak self] in
            guard let self else { return nil }
            guard let rect = await self.presentSelection(startInWindowMode: true) else { return nil }
            if self.selectionOverlay?.selectedMode == .window,
               let id = self.selectionOverlay?.selectedWindowID {
                let windows = try await ScreenCaptureService.shared.capturableWindows()
                guard let window = windows.first(where: { $0.windowID == id }) else {
                    throw CaptureError.noWindowFound
                }
                return (try await ScreenCaptureService.shared.captureWindow(window), .window)
            }
            return (try await ScreenCaptureService.shared.captureArea(rect), .area)
        }
    }

    func captureActiveWindow() {
        run(kind: .window) { [weak self] in
            guard let self else { return nil }
            let window = try await ScreenCaptureService.shared.frontmostCapturableWindow()
            let result = try await ScreenCaptureService.shared.captureWindow(window)
            return (result, CaptureKind.window)
        }
    }

    func captureWindowUnderCursor(completion: ((Bool) -> Void)? = nil) {
        run(kind: .windowUnderCursor, completion: completion) { [weak self] in
            guard let self else { return nil }
            let window = try await ScreenCaptureService.shared.windowUnderCursor()
            let result = try await ScreenCaptureService.shared.captureWindow(window)
            return (result, CaptureKind.windowUnderCursor)
        }
    }

    /// Captures every attached display as one entry per screen.
    ///
    /// Each display produces its own history entry rather than being composited
    /// into one image, because the displays may have different scales and a
    /// composite would have to resample at least one of them.
    func captureAllDisplays(completion: ((Bool) -> Void)? = nil) {
        run(kind: .fullscreen, completion: completion) { [weak self] in
            guard let self else { return nil }
            let results = try await ScreenCaptureService.shared.captureAllDisplays()
            guard let first = results.first else { throw CaptureError.noDisplays }
            for extra in results.dropFirst().reversed() {
                guard await self.finish(extra, kind: .fullscreen) else {
                    throw CaptureError.captureFailed("A display was captured but its output could not be delivered.")
                }
            }
            return (first, CaptureKind.fullscreen)
        }
    }

    /// Captures with the configured self-timer, regardless of the stored setting.
    ///
    /// The stored self-timer applies to every capture; this action forces one for
    /// a single binding without changing the global preference.
    func captureWithSelfTimer(seconds: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        let requested = seconds ?? CaptureSettings.selfTimerInterval
        run(kind: .area, appliesSelfTimer: false, completion: completion) { [weak self] in
            guard let self else { return nil }
            // CleanShot order: choose the area first, then count down so menus
            // or hover states can be arranged before the pixels are read.
            guard let rect = await self.presentSelection() else { return nil }
            try await Self.countDown(requested)
            let result = try await ScreenCaptureService.shared.captureArea(rect)
            return (result, CaptureKind.area)
        }
    }

    /// Captures a window chosen from a list rather than by pointing at it.
    func captureWindowFromPicker(completion: ((Bool) -> Void)? = nil) {        run(kind: .window, completion: completion) { [weak self] in
            guard let self else { return nil }
            guard let window = await self.presentWindowPicker() else { return nil }
            let result = try await ScreenCaptureService.shared.captureWindow(window)
            return (result, CaptureKind.window)
        }
    }

    /// Area capture followed immediately by OCR, ending in text on the pasteboard
    /// rather than an image. CleanShot's "Capture Text"; the recognition and
    /// delivery (clipboard, HUD, sound, speech) are TextSniper-style and live
    /// in `TextCaptureController`.
    func captureText(keepsLineBreaks: Bool? = nil, completion: ((Bool) -> Void)? = nil) {
        let keepBreaks = keepsLineBreaks ?? TextCaptureSettings.shared.keepsLineBreaks
        Self.textLog.info("capture-text requested (native selector)")
        run(kind: .area, appliesSelfTimer: false, appliesDesktopSettings: false,
            afterCaptureOverride: .doNothing, completion: completion) {
            let image = try await TextCaptureSelection.capture()
            let captured = Date()
            guard try await TextCaptureController.shared.deliver(image: image, keepsLineBreaks: keepBreaks) != nil else { return nil }
            Self.textLog.info("capture-text selected-to-copy=\(Int(Date().timeIntervalSince(captured) * 1000), privacy: .public)ms")
            let scale = max(1, NSScreen.main?.backingScaleFactor ?? 1)
            let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
                              height: CGFloat(image.height) / scale)
            return (CaptureResult(image: image, globalRect: rect, scale: scale, kind: .area), .area)
        }
    }

    static let textLog = Logger(subsystem: "com.kyw.allofmacos", category: "capture-text")

    /// Shared tail of every screen text capture (menu, shortcut, All-In-One).
    private func deliverRecognizedText(_ result: CaptureResult, keepsLineBreaks: Bool) async throws {
        guard try await TextCaptureController.shared.deliver(image: result.image, keepsLineBreaks: keepsLineBreaks,
                                                             anchor: result.globalRect) != nil else { return }
        let added = Date()
        CaptureHistory.shared.add(result, url: nil)
        Self.textLog.info("history add=\(Int(Date().timeIntervalSince(added) * 1000), privacy: .public)ms")
    }

    /// "Capture Text from Clipboard Image" (no selection needed).
    func captureTextFromClipboardImage() {
        TextCaptureController.shared.captureFromClipboardImage()
    }

    /// "Read QR / Barcode": select an area, copy every code payload in it.
    func captureQRCode() {
        run(kind: .area) { [weak self] in
            guard let self else { return nil }
            guard let rect = await self.presentSelection() else { return nil }
            let result = try await ScreenCaptureService.shared.captureArea(rect)
            await TextCaptureController.shared.deliverBarcodes(image: result.image, anchor: result.globalRect)
            return nil
        }
    }

    /// Scrolling capture: stitches a tall region by repeatedly scrolling and
    /// grabbing, then trims the overlap.
    func captureScrolling(completion: ((Bool) -> Void)? = nil) { captureScrolling(direction: .vertical, completion: completion) }

    func captureScrollingHorizontal() { captureScrolling(direction: .horizontal) }

    private func captureScrolling(direction: ScrollingCaptureService.Direction, completion: ((Bool) -> Void)? = nil) {
        run(kind: .scrolling, completion: completion) { [weak self] in
            guard let self else { return nil }
            guard let rect = await self.presentSelection() else { return nil }
            let result = try await ScrollingCaptureService.shared.capture(area: rect,
                                                                           direction: direction)
            return (result, CaptureKind.scrolling)
        }
    }

    // MARK: - Pipeline

    /// Shared prologue and epilogue for every capture kind.
    ///
    /// `body` returns the capture plus its kind, or `nil` when the user cancelled
    /// — a cancel is not an error and must not surface as one.
    private func run(kind: CaptureKind, appliesSelfTimer: Bool = true, appliesDesktopSettings: Bool = true,
                     afterCaptureOverride: AfterCaptureAction? = nil, completion: ((Bool) -> Void)? = nil,
                     _ body: @escaping () async throws -> (CaptureResult, CaptureKind)?) {
        guard !isCapturing else {
            GestureHUD.shared.show(title: "Capture In Progress", detail: "Finish or cancel the current capture first.")
            completion?(false)
            return
        }
        guard ScreenCaptureService.hasPermission else {
            ScreenCaptureService.requestPermission()
            GestureHUD.shared.show(title: "Screen Recording Needed",
                                   detail: "Grant All of MacOS access in System Settings › Privacy & Security.")
            completion?(false)
            return
        }

        isCapturing = true
        Task { @MainActor in
            var succeeded = false
            defer {
                isCapturing = false
                completion?(succeeded)
            }
            do {
                if appliesSelfTimer { try await runSelfTimerIfNeeded() }
                let hiddenIcons = appliesDesktopSettings ? try hideDesktopIconsIfNeeded() : nil
                defer { restoreDesktopIconsIfNeeded(hiddenIcons) }

                guard let (result, resolvedKind) = try await body() else { return }
                succeeded = await finish(result, kind: resolvedKind, actionOverride: afterCaptureOverride)
            } catch CaptureError.cancelled {
                // A cancelled capture is a normal outcome, not a failure to report.
            } catch {
                GestureHUD.shared.show(title: "Capture Failed", detail: error.localizedDescription)
            }
        }
    }

    /// A self-timer gives the user time to arrange a menu or hover state, so it
    /// counts down on screen rather than silently waiting.
    private func runSelfTimerIfNeeded() async throws {
        try await Self.countDown(CaptureSettings.selfTimerSeconds)
    }

    /// On-screen countdown; Escape cancels (the HUD is not key, so a global
    /// monitor is used and removed again).
    private static func countDown(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelled = true }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelled = true; return nil }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let local { NSEvent.removeMonitor(local) }
        }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            GestureHUD.shared.show(title: "\(remaining)", detail: "Capturing… · Esc to cancel")
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if cancelled {
                    GestureHUD.shared.dismiss()
                    throw CaptureError.cancelled
                }
            }
        }
        // Clear the countdown before the selection UI appears underneath it.
        GestureHUD.shared.dismiss()
        // Let the HUD fade out before ScreenCaptureKit reads the pixels.
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func finish(_ captured: CaptureResult, kind: CaptureKind,
                        actionOverride: AfterCaptureAction? = nil) async -> Bool {
        if CaptureSettings.playsSound { playCaptureSound() }

        let action = actionOverride ?? CaptureSettings.afterCapture
        let result = Self.applyingAutomaticBackground(captured, action: action)
        let stored = CaptureHistory.shared.add(result, url: nil)

        // Annotate and Pin both need the file on disk, because the editor and the
        // pin window reload from a URL and can outlive this process's memory of
        // the capture.
        switch action {
        case .doNothing:
            break
        case .copyToClipboard:
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(result)
                if CaptureSettings.overlayEnabled { showOverlay(for: stored) }
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
                showOverlay(for: stored, explicit: true)
                return false
            }
        case .saveToDisk:
            do {
                let url = try await ScreenCaptureService.shared.writeToDiskAsync(result)
                CaptureHistory.shared.attachFile(url, to: stored.id)
                if CaptureSettings.overlayEnabled { showOverlay(for: stored) }
            } catch {
                GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                showOverlay(for: stored, explicit: true)
                return false
            }
        case .openAnnotate:
            // Annotation is still useful even if persisting the original fails;
            // never silently disguise that failure as a successful save.
            var url: URL?
            do {
                url = try await ScreenCaptureService.shared.writeToDiskAsync(result)
                if let url { CaptureHistory.shared.attachFile(url, to: stored.id) }
            } catch {
                GestureHUD.shared.show(title: "Original Save Failed", detail: error.localizedDescription)
            }
            AnnotationEditorController.shared.open(capture: stored, url: url)
        case .showOverlay:
            showOverlay(for: stored)
        }
        return true
    }

    /// CleanShot's "Automatically apply preset to all screenshots": the
    /// chosen Background Tool preset is rendered into every new screenshot.
    /// Holding ⇧ while capturing skips it; the editor applies it itself, so
    /// screenshots opened straight into Annotate are left untouched here.
    static func applyingAutomaticBackground(_ result: CaptureResult, action: AfterCaptureAction,
                                            shiftHeld: Bool = NSEvent.modifierFlags.contains(.shift)) -> CaptureResult {
        guard action != .openAnnotate, result.kind != .videoRecording, !shiftHeld,
              let background = AnnotationBackgroundPresetStore.automaticBackground() else { return result }
        var document = AnnotationDocument(baseImage: result.image)
        document.background = background
        guard let rendered = document.render(scale: result.scale) else { return result }
        return CaptureResult(image: rendered, globalRect: result.globalRect, scale: result.scale, kind: result.kind,
                             windowTitle: result.windowTitle, capturedAt: result.capturedAt)
    }

    func showRecordingOverlay(for entry: CaptureHistoryEntry) {
        // Respect the same Quick Access close preference for screenshots and
        // recordings; a recording must not mysteriously vanish after 10 sec.
        showOverlay(for: entry)
    }

    private func showOverlay(for entry: CaptureHistoryEntry, forcedAutoCloseSeconds: TimeInterval? = nil,
                             explicit: Bool = false) {
        guard explicit || CaptureSettings.overlayEnabled else { return }
        if let existing = overlayControllers.first(where: { $0.captureID == entry.id }) {
            if areQuickAccessHidden {
                areQuickAccessHidden = false
                overlayControllers.forEach { $0.setTemporarilyHidden(false) }
            } else { existing.setTemporarilyHidden(false) }
            return
        }
        let controller = QuickAccessOverlayController(
            entry: entry, stackIndex: overlayControllers.count,
            forcedAutoCloseSeconds: forcedAutoCloseSeconds)
        controller.onDismiss = { [weak self, weak controller] deleted in
            guard let self, let controller else { return }
            self.overlayControllers.removeAll { $0 === controller }
            if !deleted {
                self.recentlyClosed.append(entry)
                if self.recentlyClosed.count > QuickAccessPolicy.maximumRestoreHistory {
                    self.recentlyClosed.removeFirst()
                }
                self.persistRecentlyClosed()
            }
            self.reflowOverlaysByDisplay()
        }
        controller.onDisplayTopologyChange = { [weak self] in
            self?.reflowOverlaysByDisplay()
        }
        overlayControllers.append(controller)
        if areQuickAccessHidden {
            areQuickAccessHidden = false
            for visible in overlayControllers.dropLast() {
                visible.setTemporarilyHidden(false)
            }
        }
        if overlayControllers.count > QuickAccessPolicy.maximumVisible,
           let oldest = overlayControllers.first {
            oldest.dismiss(deleteFile: false)
        }
        reflowOverlaysByDisplay()
        controller.present()
    }

    /// The system's own screenshot sound, so the capture sounds like a macOS one.
    private func playCaptureSound() {
        AOMSystemSound.play("Grab")
    }

    // MARK: - Desktop icons

    /// Whether Finder currently draws desktop icons (`CreateDesktop`, default true).
    var desktopIconsVisible: Bool {
        (CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool) ?? true
    }

    /// CleanShot's menu-bar "Hide Desktop Icons / Show Desktop Icons" toggle.
    /// Same Finder mechanism as the capture-time option; restarts Finder.
    func toggleDesktopIcons() {
        let domain = "com.apple.finder" as CFString
        let hide = desktopIconsVisible
        CFPreferencesSetAppValue("CreateDesktop" as CFString, (!hide) as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        Self.restartFinder()
        GestureHUD.shared.show(title: "Desktop Icons", detail: hide ? "Hidden" : "Visible")
    }

    /// Hides the desktop icons for the duration of the capture.
    ///
    /// This writes a Finder preference and restarts Finder, which is why it is
    /// opt-in: it is visible to the user and briefly interrupts any Finder window
    /// they have open. The previous value is returned so it can be put back.
    private func hideDesktopIconsIfNeeded() throws -> Bool? {
        guard CaptureSettings.hidesDesktopIcons else { return nil }
        let domain = "com.apple.finder" as CFString
        let previous = (CFPreferencesCopyAppValue("CreateDesktop" as CFString, domain) as? Bool) ?? true
        CFPreferencesSetAppValue("CreateDesktop" as CFString, false as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        Self.restartFinder()
        return previous
    }

    private func restoreDesktopIconsIfNeeded(_ previous: Bool?) {
        guard let previous else { return }
        let domain = "com.apple.finder" as CFString
        CFPreferencesSetAppValue("CreateDesktop" as CFString, previous as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        Self.restartFinder()
    }

    private static func restartFinder() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Finder"]
        // A failure here means Finder was not running, which is not a problem.
        try? task.run()
    }

    // MARK: - Selection UI

    /// Presents the area-selection overlay and returns the chosen global rect, or
    /// `nil` when the user pressed Escape.
    private func presentSelection(startInWindowMode: Bool = false) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let controller = SelectionOverlayController(startInWindowMode: startInWindowMode) { rect in
                continuation.resume(returning: rect)
            }
            selectionOverlay = controller
            controller.present()
        }
    }

    private func presentWindowPicker() async -> SCWindow? {
        do {
            let windows = try await ScreenCaptureService.shared.capturableWindows()
            guard !windows.isEmpty else { throw CaptureError.noWindowFound }
            return await WindowPickerController.present(windows: windows)
        } catch {
            GestureHUD.shared.show(title: "No Windows", detail: error.localizedDescription)
            return nil
        }
    }
}

extension ScreenCaptureService {
    /// Displays only, for callers that need the list before choosing a filter.
    func shareableContentDisplays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }
}
