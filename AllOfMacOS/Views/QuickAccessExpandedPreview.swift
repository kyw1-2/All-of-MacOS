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
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = entry.displayName
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 600, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: CapturePreviewContent(entry: entry,
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
    var onClose: () -> Void = {}
    @State private var actualSize = false
    @State private var player: AVPlayer?
    private var isVideo: Bool { entry.kind == .videoRecording }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(isVideo ? "Recording" : "Screenshot", systemImage: isVideo ? "video" : "photo")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { CapturePreviewActions.edit(entry); onClose() } label: {
                    Label(isVideo ? "Edit Recording" : "Annotate", systemImage: isVideo ? "film.stack" : "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(isVideo && entry.playableVideoURL == nil)
                if !isVideo {
                    Button { PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL) } label: {
                        Image(systemName: "pin")
                    }.help("Pin to Screen")
                }
                Divider().frame(height: 18).padding(.horizontal, 3)
                Button { CapturePreviewActions.copy(entry) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }.keyboardShortcut("c", modifiers: .command)
                Button { CapturePreviewActions.save(entry) } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }.keyboardShortcut("s", modifiers: .command)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 12) {
                Text(entry.displayName).lineLimit(1).truncationMode(.middle)
                Text("\(entry.image.width) × \(entry.image.height) px").monospacedDigit()
                Spacer(minLength: 8)
                if !isVideo {
                    Picker("Zoom", selection: $actualSize) {
                        Text("Fit").tag(false)
                        Text("100%").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 112)
                    .help("Fit to window or display at original screen size")
                }
                Button("Done", action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let url = entry.playableVideoURL { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    @ViewBuilder private var canvas: some View {
        if isVideo {
            if let player {
                VideoPlayer(player: player).padding(16)
            } else {
                ContentUnavailableView("Recording Missing", systemImage: "video.slash",
                    description: Text("The recorded MP4 file can no longer be found."))
            }
        } else if actualSize {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    captureImage
                        .frame(width: entry.pointSize.width, height: entry.pointSize.height)
                        .padding(24)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
        } else {
            GeometryReader { geometry in
                captureImage.scaledToFit()
                    .frame(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 48))
                    .padding(24)
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

    private static func saveAs(_ entry: CaptureHistoryEntry, completion: @escaping () -> Void) {
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
