import AppKit
import Foundation

/// Files for dragging never-saved captures out of Quick Access and Capture
/// History without encoding on the main thread.
///
/// `.onDrag` and AppKit drag sources must hand over a file synchronously. A
/// saved capture already has one; an unsaved one used to be PNG-encoded and
/// written right there, which stalled the UI for large captures (F-04B). The
/// card now asks for a drag file as soon as the pointer is over it: the pixels
/// are encoded on the capture encoding queue into a private temporary folder,
/// named like a saved capture, so by the time a drag starts the file is
/// ready. The capture itself stays unsaved — dragging is not saving. Only if
/// a drag beats the prefetch does the caller fall back to its synchronous path.
@MainActor
final class CaptureDragFiles {
    static let shared = CaptureDragFiles()

    private struct Key: Hashable { let id: UUID; let revision: Int }
    private var ready: [Key: URL] = [:]
    private var pending: Set<Key> = []
    let directory: URL
    private let writeFile: (CaptureResult, URL) async throws -> URL

    init(directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOMCaptureDrag", isDirectory: true),
         writeFile: @escaping (CaptureResult, URL) async throws -> URL = { result, folder in
             try await ScreenCaptureService.shared.writeToDiskAsync(result, directory: folder)
         }) {
        self.directory = directory
        self.writeFile = writeFile
        // Leftovers from an earlier run are never referenced again.
        try? FileManager.default.removeItem(at: directory)
    }

    /// True when the entry needs a drag file of its own (unsaved screenshot).
    static func needsDragFile(_ entry: CaptureHistoryEntry) -> Bool {
        guard entry.kind != .videoRecording else { return false }
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) { return false }
        return true
    }

    /// A ready drag file for the entry's current pixels, if one exists.
    func readyFile(for entry: CaptureHistoryEntry) -> URL? {
        let key = Key(id: entry.id, revision: entry.imageRevision)
        guard let url = ready[key], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Starts writing a drag file in the background; idempotent per revision.
    func prefetch(_ entry: CaptureHistoryEntry) {
        guard Self.needsDragFile(entry) else { return }
        let key = Key(id: entry.id, revision: entry.imageRevision)
        guard readyFile(for: entry) == nil, !pending.contains(key) else { return }
        pending.insert(key)
        let folder = directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            .appendingPathComponent(String(key.revision), isDirectory: true)
        Task { @MainActor in
            defer { pending.remove(key) }
            let image = await entry.loadImage()
            guard entry.imageRevision == key.revision else { return }
            let result = CaptureResult(image: image, globalRect: CGRect(origin: .zero, size: entry.pointSize),
                                       scale: entry.scale, kind: entry.kind,
                                       windowTitle: entry.windowTitle, capturedAt: entry.capturedAt)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try await writeFile(result, folder)
                // Encoding suspends this actor. A newer revision may already
                // be ready when an older write completes; never evict it.
                guard entry.imageRevision == key.revision else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                // Drop files written for an older revision of the same capture.
                for (old, file) in ready where old.id == key.id && old != key {
                    try? FileManager.default.removeItem(at: file)
                    ready[old] = nil
                }
                ready[key] = url
            } catch {
                // The synchronous fallback reports any real failure at drag time.
            }
        }
    }
}
