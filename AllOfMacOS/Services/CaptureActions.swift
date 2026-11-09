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
    /// Output boundary shared by menus and automation; replaceable with private
    /// outputs in tests so no real clipboard, save folder or HUD is touched.
    struct Output {
        var copyImage: (CaptureResult) async throws -> Void = { try await ScreenCaptureService.shared.copyToClipboardAsync($0) }
        var writeImage: (CaptureResult) async throws -> URL = { try await ScreenCaptureService.shared.writeToDiskAsync($0) }
        var recognize: (CGImage, Bool) async throws -> String = { try await TextRecognitionService.recognize($0, keepsLineBreaks: $1) }
        var copyText: (String) -> Bool = {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString($0, forType: .string)
        }
        var notify: (String, String?) -> Void = { GestureHUD.shared.show(title: $0, detail: $1) }
    }
    static var output = Output()

    private static func latest() -> CaptureHistoryEntry? {
        guard let entry = CaptureHistory.shared.mostRecent else {
            output.notify("No Capture", "Take a screenshot first.")
            return nil
        }
        return entry
    }

    private static func result(for entry: CaptureHistoryEntry) async -> CaptureResult {
        let image = await entry.loadImage()
        return CaptureResult(image: image, globalRect: .zero, scale: entry.scale, kind: entry.kind,
                      windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
    }

    private static func saveResult(for entry: CaptureHistoryEntry) async throws -> URL {
        let capture = await result(for: entry)
        let revision = entry.imageRevision
        let url = try await output.writeImage(capture)
        guard CaptureHistory.shared.attachFile(url, to: entry, ifRevision: revision) else {
            throw CaptureError.captureFailed("The previous version was saved, but the capture changed. Save the current edit again.")
        }
        return url
    }

    static func copyLastCapture(completion: ((Bool) -> Void)? = nil) {
        guard let entry = latest() else { completion?(false); return }
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL,
                  ScreenCaptureService.shared.copyFileToClipboard(url) else {
                output.notify("Copy Failed", "The MP4 file is unavailable.")
                completion?(false); return
            }
            output.notify("Copied", "MP4 file on the clipboard")
            completion?(true); return
        }
        // F-04A: encode off the main thread so copying a full-resolution
        // capture cannot block the UI; show the HUD only once the pasteboard
        // actually holds the pixels.
        Task { @MainActor in
            do {
                try await output.copyImage(await result(for: entry))
                output.notify("Copied", "Image on the clipboard")
                completion?(true)
            } catch {
                output.notify("Copy Failed", error.localizedDescription)
                completion?(false)
            }
        }
    }

    static func saveLastCapture(completion: ((Bool) -> Void)? = nil) {
        guard let entry = latest() else { completion?(false); return }
        if entry.kind == .videoRecording {
            guard let url = entry.playableVideoURL else {
                output.notify("Recording Unavailable", "The saved MP4 could not be found.")
                completion?(false); return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            completion?(true); return
        }
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            completion?(true); return
        }
        // F-04A: encode/write off the main thread; the history entry can only be
        // given its file once the write has actually landed.
        Task { @MainActor in
            do {
                let url = try await saveResult(for: entry)
                output.notify("Saved", url.lastPathComponent)
                completion?(true)
            } catch {
                output.notify("Save Failed", error.localizedDescription)
                completion?(false)
            }
        }
    }

    static func pinLastCapture(completion: ((Bool) -> Void)? = nil) {
        guard let entry = latest() else { completion?(false); return }
        guard entry.kind != .videoRecording else {
            output.notify("Video Recording", "Only screenshots can be pinned.")
            completion?(false); return
        }
        // Write the file first so the pin has something to hand to another app
        // when it is dragged out. A never-saved capture has to be encoded off
        // the main thread, so the pin is created only once the write finishes.
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            PinnedScreenshotController.shared.pin(entry: entry, url: url)
            completion?(true); return
        }
        Task { @MainActor in
            let pinURL: URL
            do {
                pinURL = try await saveResult(for: entry)
            } catch {
                output.notify("Save Failed", error.localizedDescription)
                completion?(false); return
            }
            PinnedScreenshotController.shared.pin(entry: entry, url: pinURL)
            completion?(true)
        }
    }

    static func copyTextFromLastCapture(keepsLineBreaks override: Bool? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let entry = latest() else { completion?(false); return }
        let keepsLineBreaks = override ?? CaptureSettings.ocrKeepsLineBreaks
        Task { @MainActor in
            do {
                let text = try await output.recognize(await entry.loadImage(), keepsLineBreaks)
                guard !text.isEmpty else {
                    output.notify("No Text Found", nil)
                    completion?(false)
                    return
                }
                guard output.copyText(text) else {
                    completion?(false)
                    output.notify("Copy Failed", "The clipboard could not be updated.")
                    return
                }
                completion?(true)
                output.notify("Text Copied", "\(text.count) characters")
            } catch {
                output.notify("Text Recognition Failed", error.localizedDescription)
                completion?(false)
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
        MediaHistoryOverlayController.shared.toggle()
    }

    func toggle() {
        MediaHistoryOverlayController.shared.toggle()
    }
}
