import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// One preview surface shared by Quick Access and Capture History.
@MainActor
final class QuickAccessExpandedPreview: NSObject, NSWindowDelegate {
    static let shared = QuickAccessExpandedPreview()
    private var windows: [UUID: NSWindow] = [:]

    func open(entry: CaptureHistoryEntry) {
        if let existing = windows[entry.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = CGSize(width: min(visible.width - 48, max(720, min(1100, entry.pointSize.width + 48))),
                          height: min(visible.height - 80, max(480, min(780, entry.pointSize.height + 100))))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = entry.displayName
        window.applyCaptureVisibilityPreference()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 600, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: CapturePreviewContent(entry: entry, fullSizeChrome: true,
            onClose: { [weak window] in window?.close() }))
        window.makeKeyAndOrderFront(nil)
        windows[entry.id] = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

struct CapturePreviewContent: View {
    let entry: CaptureHistoryEntry
    var fullSizeChrome = false
    var onClose: () -> Void = {}
    @State private var zoom: CGFloat? = nil
    @State private var player: AVPlayer?
    private var isVideo: Bool { entry.kind == .videoRecording }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                if fullSizeChrome {
                    Color.clear.frame(width: AOMFeatureSize.trafficLightsInset, height: AOMFeatureSize.barControlHeight)
                }
                Text(entry.displayName).font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: AOMSpace.x2)
                Button { CapturePreviewActions.edit(entry); onClose() } label: {
                    Label(isVideo ? "Edit Recording" : "Annotate", systemImage: isVideo ? "film.stack" : "pencil")
                        .font(AOMFont.callout.weight(.medium))
                        .foregroundStyle(AOMColor.text)
                        .padding(.horizontal, AOMSpace.x3).frame(height: AOMFeatureSize.barControlHeight)
                        .background(AOMColor.track, in: Capsule())
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(isVideo && entry.playableVideoURL == nil)
                Button { saveAs() } label: {
                    Text("Save as…").font(AOMFont.bodyEmphasis)
                        .foregroundStyle(AOMTheme.onAccent(AOMColor.accent))
                        .padding(.horizontal, AOMSpace.x4).frame(height: AOMFeatureSize.barControlHeight)
                        .background(AOMColor.accent, in: Capsule())
                }.keyboardShortcut("s", modifiers: .command)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowDetail)
            .background(.bar)
            AOMDivider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                if !isVideo {
                    Menu {
                        Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                        ForEach([25, 50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percent in
                            Button("\(percent)%") { zoom = CGFloat(percent) / 100 }
                        }
                    } label: {
                        Text(zoom.map { "\(Int($0 * 100))%" } ?? "Fit").font(AOMFont.callout).monospacedDigit()
                            .padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowSingle)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .background(AOMColor.track, in: Capsule())
                    .help("Zoom")
                }
                Spacer(minLength: AOMSpace.x2)
                if !isVideo {
                    Button { pin() } label: {
                        previewAction("pin.fill")
                    }.keyboardShortcut("p", modifiers: .command).help("Pin to Screen (⌘P) · ⌥ keeps the preview open")
                }
                if let url = entry.playableVideoURL ?? entry.fileURL {
                    ShareLink(item: url) { previewAction("square.and.arrow.up") }.help("Share")
                }
                Button { copy() } label: {
                    previewAction("doc.on.doc.fill")
                }.keyboardShortcut("c", modifiers: .command).help("Copy (⌘C) · ⌥ keeps the preview open")
                Button(action: onClose) { previewAction("xmark") }
                    .keyboardShortcut(.escape, modifiers: []).help("Close Preview (Space or Esc)")
            }
            .overlay {
                CaptureDragHandle()
                    .onDrag {
                        if let url = entry.playableVideoURL ?? entry.fileURL { return NSItemProvider(object: url as NSURL) }
                        return NSItemProvider(object: NSImage(cgImage: entry.image, size: entry.pointSize))
                    }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowDetail)
            .background(.bar)
        }
        .background(AOMColor.canvas)
        .background(CaptureKeyEventHandler { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (event.keyCode == 49 && modifiers.isEmpty) ||
                (event.keyCode == 13 && modifiers == .command) {
                if !event.isARepeat { onClose() }
                return true
            }
            guard !isVideo, modifiers == .command else { return false }
            switch event.charactersIgnoringModifiers {
            case "0": zoom = nil
            case "1": zoom = 1
            default: return false
            }
            return true
        })
        .onAppear {
            if let url = entry.playableVideoURL { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    // Same rule as the Quick Access card (QuickAccessPolicy.closesSurface):
    // a completed action closes the preview, ⌥ keeps it, a failure never does.

    private func copy() {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        CapturePreviewActions.copy(entry) { ok in
            if QuickAccessPolicy.closesSurface(afterSucceeded: ok, optionPressed: keepOpen) { onClose() }
        }
    }

    private func saveAs() {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        CapturePreviewActions.saveAs(entry) { ok in
            if QuickAccessPolicy.closesSurface(afterSucceeded: ok, optionPressed: keepOpen) { onClose() }
        }
    }

    private func pin() {
        let keepOpen = NSEvent.modifierFlags.contains(.option)
        PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL)
        if QuickAccessPolicy.closesSurface(afterSucceeded: true, optionPressed: keepOpen) { onClose() }
    }

    private func previewAction(_ symbol: String) -> some View {
        Image(systemName: symbol).font(AOMFont.body.weight(.medium))
            .foregroundStyle(AOMColor.text)
            .frame(width: AOMFeatureSize.barButtonWidth - AOMSpace.x0_5, height: AOMSize.rowSingle)
            .background(AOMColor.track, in: Capsule())
            .contentShape(Capsule())
    }

    @ViewBuilder private var canvas: some View {
        if isVideo {
            if let player {
                VideoPlayer(player: player).padding(AOMSpace.x4)
            } else {
                ContentUnavailableView("Recording Missing", systemImage: "video.slash",
                    description: Text("The recorded MP4 file can no longer be found."))
            }
        } else {
            GeometryReader { geometry in
                let fit = min(max(1, geometry.size.width - AOMSpace.x8) / max(1, entry.pointSize.width),
                              max(1, geometry.size.height - AOMSpace.x8) / max(1, entry.pointSize.height))
                let factor = zoom ?? min(1, fit)
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    captureImage
                        .frame(width: entry.pointSize.width * factor, height: entry.pointSize.height * factor)
                        .background(TransparencyGrid())
                        .padding(AOMSpace.x4)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .background(NativeScrollChrome(.overlay))
                }
            }
        }
    }

    private var captureImage: some View {
        Image(decorative: entry.image, scale: entry.scale)
            .resizable().interpolation(.high)
            .aomElevation(.raised)
    }
}

@MainActor
enum CapturePreviewActions {
    private static func result(_ entry: CaptureHistoryEntry) -> CaptureResult {
        CaptureResult(image: entry.image, globalRect: .zero, scale: entry.scale,
                      kind: entry.kind, windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    static func edit(_ entry: CaptureHistoryEntry) {
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL else { return }
            RecordingExportEditorController.shared.open(source: url)
        } else {
            AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
        }
    }

    static func copy(_ entry: CaptureHistoryEntry, completion: @escaping (Bool) -> Void = { _ in }) {
        if entry.kind == .videoRecording {
            do {
                guard let url = entry.playableVideoURL,
                      ScreenCaptureService.shared.copyFileToClipboard(url) else {
                    throw CaptureError.captureFailed("The MP4 file could not be copied.")
                }
                GestureHUD.shared.show(title: "Copied", detail: "MP4 file copied")
                completion(true)
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
                completion(false)
            }
            return
        }
        // F-04B: encode off the main thread; the HUD still reports the final
        // success/failure exactly once.
        let capture = result(entry)
        Task { @MainActor in
            do {
                try await ScreenCaptureService.shared.copyToClipboardAsync(capture)
                GestureHUD.shared.show(title: "Copied", detail: "Image copied")
                completion(true)
            } catch {
                GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
                completion(false)
            }
        }
    }

    /// `completion(true)` once the capture is on disk; `false` when the
    /// user cancelled the panel or the write failed. Runs exactly once.
    static func save(_ entry: CaptureHistoryEntry, completion: @escaping (Bool) -> Void = { _ in }) {
        let prompt = QuickAccessPolicy.shouldPromptSave(
            asksForName: CaptureSettings.asksForNameAfterCapture,
            optionPressed: NSEvent.modifierFlags.contains(.option))
        if prompt {
            saveAs(entry, completion: completion)
            return
        }
        if entry.kind == .videoRecording {
            guard let file = entry.playableVideoURL else {
                GestureHUD.shared.show(title: "Save Failed", detail: "Recording file is missing.")
                completion(false)
                return
            }
            GestureHUD.shared.show(title: "Saved", detail: file.lastPathComponent)
            completion(true)
            return
        }
        if let file = entry.fileURL, FileManager.default.isReadableFile(atPath: file.path) {
            GestureHUD.shared.show(title: "Saved", detail: file.lastPathComponent)
            completion(true)
            return
        }
        // F-04B: write the never-saved capture off the main thread, then run
        // the caller's completion exactly once on every path.
        let capture = result(entry)
        Task { @MainActor in
            do {
                let url = try await ScreenCaptureService.shared.writeToDiskAsync(capture)
                CaptureHistory.shared.attachFile(url, to: entry.id)
                GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
                completion(true)
            } catch {
                GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                completion(false)
            }
        }
    }

    static func saveAs(_ entry: CaptureHistoryEntry, completion: @escaping (Bool) -> Void = { _ in }) {
        let panel = NSSavePanel()
        let isVideo = entry.kind == .videoRecording
        panel.allowedContentTypes = [isVideo ? .mpeg4Movie : CaptureSettings.format.contentType]
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.nameFieldStringValue = entry.fileURL?.lastPathComponent
            ?? "Screenshot-\(entry.id.uuidString.prefix(8)).\(isVideo ? "mp4" : CaptureSettings.format.fileExtension)"
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else {
                completion(false)
                return
            }
            if isVideo {
                do {
                    guard let source = entry.playableVideoURL else {
                        throw CaptureError.captureFailed("Recording file is missing.")
                    }
                    if source.standardizedFileURL != destination.standardizedFileURL {
                        let temporary = destination.deletingLastPathComponent()
                            .appendingPathComponent(".aom-export-\(UUID().uuidString).mp4")
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try FileManager.default.copyItem(at: source, to: temporary)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                        } else {
                            try FileManager.default.moveItem(at: temporary, to: destination)
                        }
                    }
                    CaptureHistory.shared.attachFile(destination, to: entry.id)
                    GestureHUD.shared.show(title: "Saved", detail: destination.lastPathComponent)
                    completion(true)
                } catch {
                    GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                    completion(false)
                }
                return
            }
            // F-04D: snapshot the pixels, format and entry id on the main actor,
            // then encode and atomically write to the panel's URL off it. The
            // completion runs exactly once, after the write resolves.
            let capture = result(entry)
            let format = CaptureSettings.format
            let entryID = entry.id
            Task { @MainActor in
                do {
                    try await ScreenCaptureService.shared.writeToURLAsync(capture, to: destination, format: format)
                    CaptureHistory.shared.attachFile(destination, to: entryID)
                    GestureHUD.shared.show(title: "Saved", detail: destination.lastPathComponent)
                    completion(true)
                } catch {
                    GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
                    completion(false)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
}

/// Window-scoped keys remain available when a SwiftUI button owns focus.
/// Text entry, modal dialogs, other windows and child sheets keep their own keys.
struct CaptureKeyEventHandler: NSViewRepresentable {
    var handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = handle
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.removeMonitor()
    }

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      (window.firstResponder as? NSTextView)?.isEditable != true else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct CaptureDragHandle: View {
    var body: some View {
        HStack(spacing: AOMSpace.x3 - AOMSpace.x0_5) {
            Image(systemName: "line.3.horizontal").font(AOMFont.badge).foregroundStyle(AOMColor.textTertiary)
            Text("Drag Me").font(AOMFont.callout.weight(.medium))
            Image(systemName: "line.3.horizontal").font(AOMFont.badge).foregroundStyle(AOMColor.textTertiary)
        }
        .foregroundStyle(AOMColor.textSecondary).padding(.horizontal, AOMSpace.x3 + AOMSpace.x0_5)
        .frame(height: AOMFeatureSize.barControlHeight)
        .background(AOMColor.track, in: Capsule())
        .overlay(Capsule().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .accessibilityLabel("Drag image to another app")
    }
}
