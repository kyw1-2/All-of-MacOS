import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// One capture kept in the session history.
///
/// The pixels are held in memory rather than re-read from disk so the overlay and
/// the annotate editor stay responsive and work even when the user chose "Do
/// Nothing" and no file was ever written.
final class CaptureHistoryEntry: Identifiable {
    let id: UUID
    /// Mutable only through `replaceImage` (Quick Access Rotate/Flip/Resize).
    private(set) var image: CGImage
    let kind: CaptureKind
    let capturedAt: Date
    let windowTitle: String?
    /// The file on disk, once one has been written. Nil until then.
    var fileURL: URL?
    var isPinned: Bool = false
    /// The small preview the overlay draws; built once and reused.
    private var cachedThumbnail: NSImage?
    var thumbnail: NSImage {
        if let cachedThumbnail { return cachedThumbnail }
        let made = Self.makeThumbnail(image)
        cachedThumbnail = made
        return made
    }

    var displayName: String {
        if let windowTitle, !windowTitle.isEmpty { return windowTitle }
        return kind.displayName
    }

    /// An actual recording file for video preview/export, never the thumbnail.
    var playableVideoURL: URL? {
        guard kind == .videoRecording, let fileURL,
              fileURL.isFileURL, fileURL.pathExtension.lowercased() == "mp4",
              FileManager.default.isReadableFile(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    /// The capture's size in points, as it was on screen.
    ///
    /// This is recorded at capture time rather than derived from the pixel size,
    /// because the editor and the pin window size themselves in points and a
    /// derived value would be wrong for any capture that is not 1× or 2×.
    private(set) var pointSize: CGSize
    /// The backing scale the capture was taken at.
    private(set) var scale: CGFloat

    /// Swaps in edited pixels. The on-screen point size follows the new pixel
    /// size at `scale`, and the cached thumbnail is rebuilt on next access.
    func replaceImage(_ newImage: CGImage, scale newScale: CGFloat) {
        image = newImage
        scale = max(1, newScale)
        pointSize = CGSize(width: CGFloat(newImage.width) / scale,
                           height: CGFloat(newImage.height) / scale)
        cachedThumbnail = nil
    }

    init(id: UUID = UUID(), image: CGImage, kind: CaptureKind, capturedAt: Date,
         windowTitle: String?, fileURL: URL?,
         pointSize: CGSize? = nil, scale: CGFloat = 1) {
        self.id = id
        self.image = image
        self.kind = kind
        self.capturedAt = capturedAt
        self.windowTitle = windowTitle
        self.fileURL = fileURL
        self.scale = scale
        self.pointSize = pointSize ?? CGSize(width: CGFloat(image.width) / max(1, scale),
                                             height: CGFloat(image.height) / max(1, scale))
    }

    private static func makeThumbnail(_ image: CGImage, maxSide: CGFloat = 480) -> NSImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, maxSide / max(width, height))
        let target = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return NSImage(cgImage: image, size: NSSize(width: width, height: height)) }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.interpolationQuality = .high
            context.cgContext.draw(image, in: CGRect(origin: .zero, size: target))
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(size: target, flipped: false) { _ in
            rep.draw(in: CGRect(origin: .zero, size: target))
            return true
        }
    }
}

/// Recent captures are retained across app restarts under Application Support.
///
/// Only cache-owned PNGs and the manifest may be removed. Saved user screenshots
/// and MP4s are *referenced*, never moved, overwritten or deleted by the history.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory(directory: defaultDirectory)

    /// Test hosts and `--aom-ui-preview` runs must never read, trim or delete
    /// the installed app's real history cache.
    static var defaultDirectory: URL {
        if let preview = PresetManager.previewDirectory {
            return preview.appendingPathComponent("CaptureHistory", isDirectory: true)
        }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "AOMTestCaptureHistory-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/CaptureHistory", isDirectory: true)
    }

    @Published private(set) var entries: [CaptureHistoryEntry] = []
    private let directory: URL
    private var manifestURL: URL { directory.appendingPathComponent("history-v1.json") }

    private struct Record: Codable {
        let id: UUID
        let kind: CaptureKind
        let capturedAt: Date
        let windowTitle: String?
        let externalFilePath: String?
        let scale: Double
        let width: Double
        let height: Double
        var isPinned: Bool? = nil
    }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    private func imageURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        // The file name is always derived from the validated UUID and stays in
        // our managed folder, even if manifest text was corrupted.
        for record in records {
            let imageFile = imageURL(for: record.id)
            guard let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let external = record.externalFilePath.map { URL(fileURLWithPath: $0) }
            entries.append(CaptureHistoryEntry(
                id: record.id, image: image, kind: record.kind,
                capturedAt: record.capturedAt, windowTitle: record.windowTitle,
                fileURL: external,
                pointSize: CGSize(width: record.width, height: record.height),
                scale: record.scale))
            entries.last?.isPinned = record.isPinned ?? false
        }
        trim()
    }

    private func persistIndex() {
        let records: [Record] = entries.compactMap { entry in
            guard FileManager.default.fileExists(atPath: imageURL(for: entry.id).path) else {
                return nil
            }
            return Record(id: entry.id, kind: entry.kind, capturedAt: entry.capturedAt,
                          windowTitle: entry.windowTitle, externalFilePath: entry.fileURL?.path,
                          scale: Double(entry.scale),
                          width: Double(entry.pointSize.width), height: Double(entry.pointSize.height),
                          isPinned: entry.isPinned)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func cacheImage(_ image: CGImage, id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try png.write(to: imageURL(for: id), options: .atomic)
        } catch {
            NSLog("[CaptureHistory] Could not save history cache: %@", error.localizedDescription)
        }
    }

    @discardableResult
    func add(_ result: CaptureResult, url: URL?) -> CaptureHistoryEntry {
        let entry = CaptureHistoryEntry(image: result.image, kind: result.kind,
                                        capturedAt: result.capturedAt,
                                        windowTitle: result.windowTitle, fileURL: url,
                                        pointSize: result.pointSize, scale: result.scale)
        guard CaptureSettings.historyCapacity > 0 else { return entry }
        entries.insert(entry, at: 0)
        cacheImage(result.image, id: entry.id)
        trim()
        persistIndex()
        return entry
    }

    /// Applies an in-place edit made from Quick Access. A previously written
    /// file is *detached*, never overwritten: the next Save writes a new file
    /// containing the edited pixels, so user files are never silently changed.
    func replaceImage(of entry: CaptureHistoryEntry, with image: CGImage, scale: CGFloat) {
        entry.replaceImage(image, scale: scale)
        if entry.kind != .videoRecording { entry.fileURL = nil }
        guard let stored = entries.first(where: { $0.id == entry.id }) else { return }
        if stored !== entry {
            stored.replaceImage(image, scale: scale)
            if stored.kind != .videoRecording { stored.fileURL = nil }
        }
        objectWillChange.send()
        cacheImage(image, id: entry.id)
        persistIndex()
    }

    func attachFile(_ url: URL, to id: UUID) {
        entries.first { $0.id == id }?.fileURL = url
        persistIndex()
    }

    func remove(_ entry: CaptureHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        try? FileManager.default.removeItem(at: imageURL(for: entry.id))
        persistIndex()
    }

    func removeAll() {
        let removed = entries
        entries.removeAll()
        for entry in removed {
            try? FileManager.default.removeItem(at: imageURL(for: entry.id))
        }
        persistIndex()
    }

    /// Pins are explicit user retention choices, never victims of automatic
    /// count or age cleanup. Removing them remains available in the history UI.
    var retentionDays: Int {
        get {
            guard UserDefaults.standard.object(forKey: "AOMCaptureHistoryRetentionDays") != nil else { return 30 }
            return max(0, UserDefaults.standard.integer(forKey: "AOMCaptureHistoryRetentionDays"))
        }
        set {
            UserDefaults.standard.set(max(0, newValue), forKey: "AOMCaptureHistoryRetentionDays")
            trim()
            objectWillChange.send()
        }
    }

    func togglePin(_ entry: CaptureHistoryEntry) {
        guard let stored = entries.first(where: { $0.id == entry.id }) else { return }
        objectWillChange.send()
        stored.isPinned.toggle()
        trim()
    }

    func removeUnpinned() {
        let removed = entries.filter { !$0.isPinned }
        entries.removeAll { !$0.isPinned }
        for entry in removed { try? FileManager.default.removeItem(at: imageURL(for: entry.id)) }
        persistIndex()
    }

    func applyRetention() { trim() }

    private func trim() {
        let capacity = max(0, CaptureSettings.historyCapacity)
        let cutoff = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86_400) : .distantPast
        var unpinnedCount = 0
        let discarded = entries.filter { entry in
            guard !entry.isPinned else { return false }
            if entry.capturedAt < cutoff { return true }
            unpinnedCount += 1
            return unpinnedCount > capacity
        }
        let removedIDs = Set(discarded.map(\.id))
        entries.removeAll { removedIDs.contains($0.id) }
        for entry in discarded { try? FileManager.default.removeItem(at: imageURL(for: entry.id)) }
        persistIndex()
    }

    var mostRecent: CaptureHistoryEntry? { entries.first }
}
