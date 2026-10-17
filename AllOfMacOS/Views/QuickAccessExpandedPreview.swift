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
            HStack(spacing: 9) {
                if fullSizeChrome { Color.clear.frame(width: 68, height: 32) }
                Text(entry.displayName).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { CapturePreviewActions.edit(entry); onClose() } label: {
                    Label(isVideo ? "Edit Recording" : "Annotate", systemImage: isVideo ? "film.stack" : "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(isVideo && entry.playableVideoURL == nil)
                Button { CapturePreviewActions.saveAs(entry) } label: {
                    Text("Save as…").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 15).frame(height: 32)
                        .background(Color.accentColor, in: Capsule())
                }.keyboardShortcut("s", modifiers: .command)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).frame(height: 50)
            .background(.regularMaterial)
            Divider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 9) {
                if !isVideo {
                    Menu {
                        Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                        ForEach([25, 50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percent in
                            Button("\(percent)%") { zoom = CGFloat(percent) / 100 }
                        }
                    } label: {
                        Text(zoom.map { "\(Int($0 * 100))%" } ?? "Fit").font(.system(size: 12))
                            .padding(.horizontal, 12).frame(height: 30)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .help("Zoom")
                }
                Spacer(minLength: 8)
                if !isVideo {
                    Button { PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL) } label: {
                        previewAction("pin.fill")
                    }.help("Pin to Screen")
                }
                if let url = entry.playableVideoURL ?? entry.fileURL {
                    ShareLink(item: url) { previewAction("square.and.arrow.up") }.help("Share")
                }
                Button { CapturePreviewActions.copy(entry) } label: {
                    previewAction("doc.on.doc.fill")
                }.keyboardShortcut("c", modifiers: .command).help("Copy")
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
            .padding(.horizontal, 12).frame(height: 50)
            .background(.regularMaterial)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private func previewAction(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            .frame(width: 36, height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    @ViewBuilder private var canvas: some View {
        if isVideo {
            if let player {
                VideoPlayer(player: player).padding(16)
            } else {
                ContentUnavailableView("Recording Missing", systemImage: "video.slash",
                    description: Text("The recorded MP4 file can no longer be found."))
            }
        } else {
            GeometryReader { geometry in
                let fit = min(max(1, geometry.size.width - 32) / max(1, entry.pointSize.width),
                              max(1, geometry.size.height - 32) / max(1, entry.pointSize.height))
                let factor = zoom ?? min(1, fit)
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    captureImage
                        .frame(width: entry.pointSize.width * factor, height: entry.pointSize.height * factor)
                        .background(TransparencyGrid())
                        .padding(16)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .background(NativeScrollChrome(.overlay))
                }
            }
        }
    }

    private var captureImage: some View {
        Image(decorative: entry.image, scale: entry.scale)
            .resizable().interpolation(.high)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
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

    static func copy(_ entry: CaptureHistoryEntry) {
        do {
            if entry.kind == .videoRecording {
                guard let url = entry.playableVideoURL,
                      ScreenCaptureService.shared.copyFileToClipboard(url) else {
                    throw CaptureError.captureFailed("The MP4 file could not be copied.")
                }
            } else {
                try ScreenCaptureService.shared.copyToClipboard(result(entry))
            }
            GestureHUD.shared.show(title: "Copied", detail: entry.kind == .videoRecording ? "MP4 file copied" : "Image copied")
        } catch {
            GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
        }
    }

    static func save(_ entry: CaptureHistoryEntry, completion: @escaping () -> Void = {}) {
        let prompt = QuickAccessPolicy.shouldPromptSave(
            asksForName: CaptureSettings.asksForNameAfterCapture,
            optionPressed: NSEvent.modifierFlags.contains(.option))
        if prompt {
            saveAs(entry, completion: completion)
            return
        }
        defer { completion() }
        do {
            let url: URL
            if entry.kind == .videoRecording {
                guard let file = entry.playableVideoURL else {
                    throw CaptureError.captureFailed("Recording file is missing.")
                }
                url = file
            } else if let file = entry.fileURL, FileManager.default.isReadableFile(atPath: file.path) {
                url = file
            } else {
                url = try ScreenCaptureService.shared.writeToDisk(result(entry))
                CaptureHistory.shared.attachFile(url, to: entry.id)
            }
            GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
        } catch {
            GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
        }
    }

    static func saveAs(_ entry: CaptureHistoryEntry, completion: @escaping () -> Void = {}) {
        let panel = NSSavePanel()
        let isVideo = entry.kind == .videoRecording
        panel.allowedContentTypes = [isVideo ? .mpeg4Movie : CaptureSettings.format.contentType]
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.nameFieldStringValue = entry.fileURL?.lastPathComponent
            ?? "Screenshot-\(entry.id.uuidString.prefix(8)).\(isVideo ? "mp4" : CaptureSettings.format.fileExtension)"
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            defer { completion() }
            guard response == .OK, let destination = panel.url else { return }
            do {
                if isVideo {
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
                } else {
                    try ScreenCaptureService.shared.encode(result(entry)).write(to: destination, options: .atomic)
                }
                CaptureHistory.shared.attachFile(destination, to: entry.id)
                GestureHUD.shared.show(title: "Saved", detail: destination.lastPathComponent)
            } catch {
                GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
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
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).opacity(0.35)
            Text("Drag Me").font(.system(size: 12, weight: .medium))
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).opacity(0.35)
        }
        .foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .accessibilityLabel("Drag image to another app")
    }
}
