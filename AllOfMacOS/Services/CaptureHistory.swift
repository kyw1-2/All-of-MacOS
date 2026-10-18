import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One capture kept in the session history.
///
/// The pixels are resident while the entry is within the history's byte budget
/// and are lazily re-read from the managed PNG once evicted, so the overlay and
/// the annotate editor still get full fidelity on demand. A capture with no
/// managed PNG yet (the user chose "Do Nothing", or the async write is still in
/// flight) stays resident and is never evictable, so nothing is lost.
final class CaptureHistoryEntry: Identifiable {
    let id: UUID
    let kind: CaptureKind
    let capturedAt: Date
    let windowTitle: String?
    /// The file on disk, once one has been written. Nil until then.
    var fileURL: URL?
    var isPinned: Bool = false

    /// The capture's size in points, as it was on screen.
    ///
    /// This is recorded at capture time rather than derived from the pixel size,
    /// because the editor and the pin window size themselves in points and a
    /// derived value would be wrong for any capture that is not 1x or 2x.
    private(set) var pointSize: CGSize
    /// The backing scale the capture was taken at.
    private(set) var scale: CGFloat
    /// Pixel dimensions kept as metadata so the history UI can size a card
    /// without decoding the bitmap.
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int

    /// The managed PNG that holds the current pixels, once one exists. Only
    /// cache-owned files are read back here; user screenshots are not.
    private var cacheURL: URL?
    /// True only while `cacheURL` holds the *current* pixels. An in-place edit
    /// clears it until the replacement PNG has been written, so a stale cache
    /// can never be rehydrated as if it were the edit.
    private var cacheIsCurrent = false
    /// Bumped by every cache write so a late completion cannot mark pixels from
    /// an older edit as current.
    private var cacheGeneration = 0
    private(set) var imageRevision = 0
    /// The decoded bitmap, or nil once the memory policy has evicted it. It is
    /// lazily re-read from `cacheURL`, which keeps full fidelity on demand.
    private var residentImage: CGImage?
    /// The small preview the overlay draws; built once and reused while the
    /// entry is resident.
    private var cachedThumbnail: NSImage?
    /// The deterministic location of this entry's managed PNG, assigned by the
    /// owning history. Keeping it independent of `cacheURL` means the file can
    /// still be deleted from `deinit` even if the write that would have set
    /// `cacheURL` never completed (for example the entry was removed mid-write).
    private var managedCacheURL: URL?
    /// True only once the history has removed the entry. The managed PNG is
    /// deleted when the last strong reference to the entry goes away, not at
    /// removal time, so a Quick Access card, the annotate editor or the preview
    /// that still holds a detached entry keeps full-fidelity pixels.
    private var cacheIsRetired = false
    /// Called after a lazy rehydration so the owning history can re-apply its
    /// byte budget. Set by `CaptureHistory`; nil for detached entries.
    var onResidencyChange: (() -> Void)?

    /// Full-fidelity pixels. Resident when in memory; otherwise decoded on
    /// demand from the managed PNG and kept until the budget evicts it again.
    var image: CGImage {
        if let residentImage { return residentImage }
        if cacheIsCurrent, let cacheURL, let loaded = Self.decode(cacheURL) {
            residentImage = loaded
            onResidencyChange?()
            return loaded
        }
        // Only reachable when the managed PNG is genuinely unavailable: a write
        // that never landed, or a file deleted outside the app. The history
        // never removes a managed PNG while any entry still references it.
        return Self.placeholderImage
    }

    private static let decodeQueue = DispatchQueue(label: "com.kyw.allofmacos.capture-decode", qos: .userInitiated)

    /// Rehydrate evicted captures without decoding a full Retina PNG on the UI
    /// thread. Publish only if an edit did not supersede this disk snapshot.
    @MainActor
    func loadImage() async -> CGImage {
        if let residentImage { return residentImage }
        guard cacheIsCurrent, let cacheURL else { return Self.placeholderImage }
        let generation = cacheGeneration
        let loaded: CGImage? = await withCheckedContinuation { continuation in
            Self.decodeQueue.async { continuation.resume(returning: Self.decode(cacheURL)) }
        }
        if generation != cacheGeneration { return await loadImage() }
        if let residentImage { return residentImage }
        guard let loaded else { return Self.placeholderImage }
        residentImage = loaded
        onResidencyChange?()
        return loaded
    }

    var isResident: Bool { residentImage != nil }

    /// A resident bitmap may be dropped only when the managed PNG already holds
    /// the current pixels; otherwise dropping it would lose an unsaved capture.
    var canEvictResidentImage: Bool { residentImage != nil && cacheIsCurrent && cacheURL != nil }

    /// Bytes of decoded surface this entry keeps resident (4 bytes per pixel).
    var residentByteCost: Int { residentImage == nil ? 0 : pixelWidth * pixelHeight * 4 }

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

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

    var thumbnail: NSImage {
        if let cachedThumbnail { return cachedThumbnail }
        if let residentImage {
            let made = Self.makeThumbnail(residentImage)
            cachedThumbnail = made
            return made
        }
        // Evicted entries build a downscaled preview straight from the PNG, so
        // the full bitmap is never decoded just to draw a card. It is not kept,
        // which bounds the thumbnail cache to the resident set.
        if cacheIsCurrent, let cacheURL, let made = Self.makeThumbnail(from: cacheURL) { return made }
        let made = Self.makeThumbnail(image)
        cachedThumbnail = made
        return made
    }

    /// Drops the decoded bitmap, keeping the managed PNG for later rehydration.
    func evictResidentImage() {
        guard canEvictResidentImage else { return }
        residentImage = nil
        cachedThumbnail = nil
    }

    /// Marks the start of a managed-PNG write and returns its generation.
    func beginCacheWrite() -> Int {
        cacheGeneration += 1
        return cacheGeneration
    }

    /// Marks the managed PNG current only if no newer edit superseded it.
    func markCacheCurrent(url: URL, generation: Int) {
        guard generation == cacheGeneration else { return }
        cacheURL = url
        cacheIsCurrent = true
    }

    /// Records the managed-PNG path this entry owns. Called by `CaptureHistory`
    /// as soon as the entry is created, so the file has an owner even before
    /// the asynchronous write that would set `cacheURL` completes.
    func assignManagedCache(_ url: URL) {
        managedCacheURL = url
    }

    /// Marks the entry as removed from the history.
    ///
    /// This deliberately does *not* delete the managed PNG. A controller can
    /// still hold the entry (a Quick Access card, an open annotate window, the
    /// expanded preview), and deleting now would make its lazily rehydrated
    /// `image` silently fall back to the 1x1 placeholder — exactly the copy/save
    /// a 1x1 screenshot bug this type is meant to prevent. `deinit` schedules
    /// the delete once the last owner lets go, on the same serial queue as the
    /// cache writes so a write still in flight always lands before the delete.
    func retireManagedCache() {
        cacheIsRetired = true
    }

    deinit {
        guard cacheIsRetired, let managedCacheURL else { return }
        scheduleCaptureHistoryCacheDeletion(at: managedCacheURL)
    }

    /// Swaps in edited pixels. The on-screen point size follows the new pixel
    /// size at `scale`, and the cached thumbnail is rebuilt on next access.
    /// The managed PNG stays stale until the replacement write lands.
    func replaceImage(_ newImage: CGImage, scale newScale: CGFloat) {
        cacheGeneration += 1
        imageRevision += 1
        residentImage = newImage
        cacheIsCurrent = false
        scale = max(1, newScale)
        pixelWidth = newImage.width
        pixelHeight = newImage.height
        pointSize = CGSize(width: CGFloat(newImage.width) / scale,
                           height: CGFloat(newImage.height) / scale)
        cachedThumbnail = nil
    }

    init(id: UUID = UUID(), image: CGImage, kind: CaptureKind, capturedAt: Date,
         windowTitle: String?, fileURL: URL?,
         pointSize: CGSize? = nil, scale: CGFloat = 1) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.windowTitle = windowTitle
        self.fileURL = fileURL
        self.scale = scale
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.pointSize = pointSize ?? CGSize(width: CGFloat(image.width) / max(1, scale),
                                             height: CGFloat(image.height) / max(1, scale))
        self.residentImage = image
    }

    /// Metadata-only entry for a managed PNG already on disk. No pixels are
    /// decoded until `image` (or another full-fidelity consumer) asks for them,
    /// which is what keeps startup from loading the whole history into RAM.
    init(id: UUID, kind: CaptureKind, capturedAt: Date, windowTitle: String?,
         fileURL: URL?, pointSize: CGSize, scale: CGFloat,
         pixelWidth: Int, pixelHeight: Int, cacheURL: URL) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.windowTitle = windowTitle
        self.fileURL = fileURL
        self.scale = scale
        self.pointSize = pointSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cacheURL = cacheURL
        self.managedCacheURL = cacheURL
        self.cacheIsCurrent = true
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func makeThumbnail(from url: URL, maxSide: CGFloat = 480) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static let placeholderImage: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    private static func makeThumbnail(_ image: CGImage, maxSide: CGFloat = 480) -> NSImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, maxSide / max(width, height))
        let target = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        // Under memory pressure NSBitmapImageRep can fail to allocate its backing
        // store. Fall back to a lightweight wrapper around the existing CGImage
        // rather than trapping the whole app on a force unwrap.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(cgImage: image, size: NSSize(width: width, height: height))
        }
        rep.size = target
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

/// Encoding and disk I/O for the capture history run on one serial utility
/// queue, in order, so a capture never stalls the main thread while the HUD or
/// overlay appears. Keeping it at file scope lets a retired entry schedule its
/// managed-PNG deletion on the very same queue from `deinit`; because the queue
/// is serial, a cache write still in flight for that file always lands before
/// the delete runs. Every `CaptureHistory` instance shares it, and opening a
/// history first drains any pending writes.
private let captureHistoryIOQueue = DispatchQueue(
    label: "com.kyw.allofmacos.capture-history-io", qos: .utility)

/// Schedules deletion of one managed cache PNG behind any queued write for it.
private func scheduleCaptureHistoryCacheDeletion(at url: URL) {
    captureHistoryIOQueue.async { try? FileManager.default.removeItem(at: url) }
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
    /// Upper bound on decoded bitmap bytes kept resident across all entries.
    ///
    /// Pinned entries are never *removed* for this budget and their managed
    /// PNGs are never deleted; only their decoded bitmap may be dropped and
    /// lazily rehydrated, which keeps an unbounded pin set from exhausting RAM
    /// while pins stay durable.
    private let residentByteBudget: Int
    /// Cache writes still awaiting their managed PNG and main-actor completion.
    private var pendingCacheCompletions = 0
    private var cacheCompletionWaiters: [CheckedContinuation<Void, Never>] = []

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

    init(directory: URL, residentByteBudget: Int = 512 * 1_024 * 1_024) {
        self.directory = directory
        self.residentByteBudget = max(0, residentByteBudget)
        load()
    }

    private func imageURL(for id: UUID) -> URL { Self.imageURL(for: id, in: directory) }

    private nonisolated static func imageURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    private func load() {
        captureHistoryIOQueue.sync {}
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        // The file name is always derived from the validated UUID and stays in
        // our managed folder, even if manifest text was corrupted. Only the PNG
        // header is read here: pixels are decoded lazily on demand, so startup
        // no longer loads the whole history into RAM.
        for record in records {
            let imageFile = imageURL(for: record.id)
            guard FileManager.default.fileExists(atPath: imageFile.path),
                  let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { continue }
            let external = record.externalFilePath.map { URL(fileURLWithPath: $0) }
            let scale = max(1, CGFloat(record.scale))
            let entry = CaptureHistoryEntry(
                id: record.id, kind: record.kind,
                capturedAt: record.capturedAt, windowTitle: record.windowTitle,
                fileURL: external,
                pointSize: CGSize(width: record.width, height: record.height),
                scale: scale,
                pixelWidth: Int((record.width * Double(scale)).rounded()),
                pixelHeight: Int((record.height * Double(scale)).rounded()),
                cacheURL: imageFile)
            entry.isPinned = record.isPinned ?? false
            entry.onResidencyChange = residencyChangeHandler()
            entries.append(entry)
        }
        trim()
    }

    /// A rehydration runs off whatever thread first needs the pixels, so hop
    /// back to the main actor before re-applying the budget.
    private func residencyChangeHandler() -> () -> Void {
        { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.enforceResidentBudget() }
        }
    }

    private func persistIndex() {
        let records: [Record] = entries.map { entry in
            Record(id: entry.id, kind: entry.kind, capturedAt: entry.capturedAt,
                   windowTitle: entry.windowTitle, externalFilePath: entry.fileURL?.path,
                   scale: Double(entry.scale),
                   width: Double(entry.pointSize.width), height: Double(entry.pointSize.height),
                   isPinned: entry.isPinned)
        }
        let directory = directory, manifestURL = manifestURL
        captureHistoryIOQueue.async {
            let kept = records.filter {
                FileManager.default.fileExists(atPath: Self.imageURL(for: $0.id, in: directory).path)
            }
            guard let data = try? JSONEncoder().encode(kept) else { return }
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func cacheImage(_ image: CGImage, id: UUID) {
        let directory = directory, url = imageURL(for: id)
        let generation = entries.first(where: { $0.id == id })?.beginCacheWrite() ?? 0
        pendingCacheCompletions += 1
        captureHistoryIOQueue.async { [weak self] in
            var wrote = false
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    wrote = CGImageDestinationFinalize(destination)
                }
            } catch {
                NSLog("[CaptureHistory] Could not save history cache: %@", error.localizedDescription)
            }
            guard let self else { return }
            Task { @MainActor in
                if wrote, let stored = self.entries.first(where: { $0.id == id }) {
                    stored.markCacheCurrent(url: url, generation: generation)
                    self.trim()
                }
                self.cacheDidComplete()
            }
        }
    }

    private func cacheDidComplete() {
        pendingCacheCompletions = max(0, pendingCacheCompletions - 1)
        guard pendingCacheCompletions == 0, !cacheCompletionWaiters.isEmpty else { return }
        let waiters = cacheCompletionWaiters
        cacheCompletionWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Testing seam: waits until every queued managed-PNG write has finished
    /// and its main-actor completion has run.
    func flushPendingCacheWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureHistoryIOQueue.async { continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if pendingCacheCompletions == 0 {
                continuation.resume()
            } else {
                cacheCompletionWaiters.append(continuation)
            }
        }
    }

    @discardableResult
    func add(_ result: CaptureResult, url: URL?) -> CaptureHistoryEntry {
        let entry = CaptureHistoryEntry(image: result.image, kind: result.kind,
                                        capturedAt: result.capturedAt,
                                        windowTitle: result.windowTitle, fileURL: url,
                                        pointSize: result.pointSize, scale: result.scale)
        guard CaptureSettings.historyCapacity > 0 else { return entry }
        entry.assignManagedCache(imageURL(for: entry.id))
        entry.onResidencyChange = residencyChangeHandler()
        entries.insert(entry, at: 0)
        cacheImage(result.image, id: entry.id)
        trim()
        persistIndex()
        return entry
    }

    /// Applies an in-place edit made from Quick Access. A previously written
    /// file is *detached*, never overwritten: the next Save writes a new file
    /// containing the edited pixels, so user files are never silently changed.
    @discardableResult
    func replaceImage(of entry: CaptureHistoryEntry, with image: CGImage, scale: CGFloat,
                      ifRevision revision: Int? = nil) -> Bool {
        guard revision == nil || revision == entry.imageRevision else { return false }
        entry.replaceImage(image, scale: scale)
        if entry.kind != .videoRecording { entry.fileURL = nil }
        guard let stored = entries.first(where: { $0.id == entry.id }) else { return true }
        if stored !== entry {
            stored.replaceImage(image, scale: scale)
            if stored.kind != .videoRecording { stored.fileURL = nil }
        }
        objectWillChange.send()
        cacheImage(image, id: entry.id)
        persistIndex()
        enforceResidentBudget()
        return true
    }

    /// An export of old pixels must not become the file of a newer edit.
    @discardableResult
    func attachFile(_ url: URL, to entry: CaptureHistoryEntry, ifRevision revision: Int) -> Bool {
        guard entry.imageRevision == revision else { return false }
        entry.fileURL = url
        attachFile(url, to: entry.id)
        return true
    }

    func attachFile(_ url: URL, to id: UUID) {
        entries.first { $0.id == id }?.fileURL = url
        persistIndex()
    }

    func remove(_ entry: CaptureHistoryEntry) {
        entries.first { $0.id == entry.id }?.retireManagedCache()
        entries.removeAll { $0.id == entry.id }
        persistIndex()
    }

    func removeAll() {
        let removed = entries
        removed.forEach { $0.retireManagedCache() }
        entries.removeAll()
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
        removed.forEach { $0.retireManagedCache() }
        entries.removeAll { !$0.isPinned }
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
        // Tombstone first: the file is deleted only when the last controller
        // still holding a discarded entry lets go, never while it is readable.
        discarded.forEach { $0.retireManagedCache() }
        entries.removeAll { removedIDs.contains($0.id) }
        enforceResidentBudget()
        persistIndex()
    }

    /// Total decoded bitmap bytes currently held across all entries.
    var residentPixelBytes: Int { entries.reduce(0) { $0 + $1.residentByteCost } }

    /// Drops decoded bitmaps (oldest first, unpinned before pinned) until the
    /// resident set fits the byte budget. Entries, pins and managed PNGs are
    /// never removed here, so nothing is lost and pins stay durable; evicted
    /// pixels are rehydrated on demand.
    private func enforceResidentBudget() {
        var total = residentPixelBytes
        guard total > residentByteBudget else { return }
        let oldestFirst = entries.sorted { $0.capturedAt < $1.capturedAt }
        for pinnedPass in [false, true] {
            for entry in oldestFirst where entry.isPinned == pinnedPass {
                guard total > residentByteBudget else { return }
                guard entry.canEvictResidentImage else { continue }
                total -= entry.residentByteCost
                entry.evictResidentImage()
            }
        }
    }

    var mostRecent: CaptureHistoryEntry? { entries.first }
}
