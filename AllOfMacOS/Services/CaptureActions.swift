import Foundation
import AppKit
import SwiftUI

/// Actions that operate on the most recent capture rather than taking a new one.
///
/// These exist because the common flow is "capture, then decide" — the user takes
/// a screenshot and only afterwards wants it copied, pinned or read. Splitting
/// them from the capture actions keeps a single capture from being taken twice.
@MainActor
enum CaptureActions {
    private static func latest() -> CaptureHistoryEntry? {
        guard let entry = CaptureHistory.shared.mostRecent else {
            GestureHUD.shared.show(title: "No Capture", detail: "Take a screenshot first.")
            return nil
        }
        return entry
    }

    private static func result(for entry: CaptureHistoryEntry) -> CaptureResult {
        CaptureResult(image: entry.image, globalRect: .zero, scale: entry.scale, kind: entry.kind,
                      windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    static func copyLastCapture() {
        guard let entry = latest() else { return }
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL,
                  ScreenCaptureService.shared.copyFileToClipboard(url) else {
                GestureHUD.shared.show(title: "Copy Failed", detail: "The MP4 file is unavailable.")
                return
            }
            GestureHUD.shared.show(title: "Copied", detail: "MP4 file on the clipboard")
            return
        }
        do {
            try ScreenCaptureService.shared.copyToClipboard(result(for: entry))
            GestureHUD.shared.show(title: "Copied", detail: "Image on the clipboard")
        } catch {
            GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
        }
    }

    static func saveLastCapture() {
        guard let entry = latest() else { return }
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL else {
                GestureHUD.shared.show(title: "Recording Unavailable", detail: "The saved MP4 could not be found.")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        do {
            let url = try ScreenCaptureService.shared.writeToDisk(result(for: entry))
            CaptureHistory.shared.attachFile(url, to: entry.id)
            GestureHUD.shared.show(title: "Saved", detail: url.lastPathComponent)
        } catch {
            GestureHUD.shared.show(title: "Save Failed", detail: error.localizedDescription)
        }
    }

    static func pinLastCapture() {
        guard let entry = latest() else { return }
        guard entry.kind != .videoRecording else {
            GestureHUD.shared.show(title: "Video Recording", detail: "Only screenshots can be pinned.")
            return
        }
        // Write the file first so the pin has something to hand to another app
        // when it is dragged out.
        var url = entry.fileURL
        if url == nil || !FileManager.default.fileExists(atPath: url?.path ?? "") {
            url = try? ScreenCaptureService.shared.writeToDisk(result(for: entry))
            if let url { CaptureHistory.shared.attachFile(url, to: entry.id) }
        }
        PinnedScreenshotController.shared.pin(entry: entry, url: url)
    }

    static func copyTextFromLastCapture() {
        guard let entry = latest() else { return }
        let keepsLineBreaks = CaptureSettings.ocrKeepsLineBreaks
        Task { @MainActor in
            do {
                let text = try await TextRecognitionService.recognize(entry.image, keepsLineBreaks: keepsLineBreaks)
                guard !text.isEmpty else {
                    GestureHUD.shared.show(title: "No Text Found", detail: nil)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                GestureHUD.shared.show(title: "Text Copied", detail: "\(text.count) characters")
            } catch {
                GestureHUD.shared.show(title: "Text Recognition Failed", detail: error.localizedDescription)
            }
        }
    }
}

/// A window listing recent captures, so a closed overlay can be recovered.
///
/// CleanShot's "Capture History" does the same thing: once the overlay is gone,
/// the capture is still in this session's memory, and this is how it is reached.
@MainActor
final class CaptureHistoryWindowController {
    static let shared = CaptureHistoryWindowController()
    private init() {}

    private var window: NSWindow?

    func present() {
        MediaHistoryOverlayController.shared.present()
    }
}

private struct CaptureHistoryView: View {
    @ObservedObject private var history = CaptureHistory.shared

    var body: some View {
        Group {
            if history.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No captures yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(history.entries) { entry in
                            HistoryCell(entry: entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Clear All") { CaptureHistory.shared.removeAll() }
                    .disabled(history.entries.isEmpty)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

private struct HistoryCell: View {
    let entry: CaptureHistoryEntry
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))

            Text(entry.displayName)
                .font(.caption).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
            Text(entry.capturedAt, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(isHovering ? Color.accentColor.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .contextMenu {
            if entry.kind == .videoRecording {
                Button("Copy MP4 File") {
                    guard let url = entry.playableVideoURL,
                          ScreenCaptureService.shared.copyFileToClipboard(url) else {
                        GestureHUD.shared.show(title: "Copy Failed", detail: "The recording file is unavailable.")
                        return
                    }
                    GestureHUD.shared.show(title: "Copied", detail: "MP4 file copied.")
                }
                if let url = entry.playableVideoURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } else {
                Button("Copy Image") {
                    let result = CaptureResult(image: entry.image, globalRect: .zero, scale: entry.scale,
                                               kind: entry.kind, windowTitle: entry.windowTitle,
                                               capturedAt: entry.capturedAt)
                    do {
                        try ScreenCaptureService.shared.copyToClipboard(result)
                    } catch {
                        GestureHUD.shared.show(title: "Copy Failed", detail: error.localizedDescription)
                    }
                }
                Button("Annotate") {
                    AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL)
                }
                Button("Pin to Screen") {
                    PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL)
                }
            }
            Divider()
            Button("Remove from History", role: .destructive) { CaptureHistory.shared.remove(entry) }
        }
        .accessibilityLabel("Capture \(entry.displayName)")
    }
}
