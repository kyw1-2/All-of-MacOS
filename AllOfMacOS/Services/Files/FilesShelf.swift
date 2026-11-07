import AppKit
import Foundation

/// One file on the Drop Shelf. The shelf keeps a path, never the file: the
/// file stays where it is until the person chooses Move To.
struct FilesShelfItem: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var added: Date
    /// AOM received this file from an app that promised it (an image dragged
    /// out of Safari); it lives in the module's Received folder.
    var received: Bool

    init(id: UUID = UUID(), path: String, added: Date, received: Bool = false) {
        self.id = id
        self.path = path
        self.added = added
        self.received = received
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { FileManager.default.displayName(atPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// The Drop Shelf's items, newest first, saved to
/// Application Support/AllOfMacOS/Files/shelf.json after every change so they
/// survive a relaunch.
@MainActor
final class FilesShelfStore: ObservableObject {
    static let shared = FilesShelfStore(fileURL: FilesStorage.shelfFile)

    @Published private(set) var items: [FilesShelfItem]
    let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        self.items = Self.load(from: fileURL)
    }

    /// Adds files at the top in the order given. A file already on the shelf
    /// stays where it is. Returns the items for the URLs (new or existing).
    @discardableResult
    func add(_ urls: [URL], received: Bool = false) -> [FilesShelfItem] {
        var result: [FilesShelfItem] = []
        var fresh: [FilesShelfItem] = []
        let date = now()
        for url in urls where url.isFileURL {
            let key = FilesPath.key(url.path)
            if let existing = items.first(where: { FilesPath.key($0.path) == key }) ?? fresh.first(where: { $0.path == key }) {
                result.append(existing)
                continue
            }
            let item = FilesShelfItem(path: key, added: date, received: received)
            fresh.append(item)
            result.append(item)
        }
        guard !fresh.isEmpty else { return result }
        items.insert(contentsOf: fresh, at: 0)
        save()
        return result
    }

    /// Removes items; returns them with their positions so Undo can put them back.
    @discardableResult
    func remove(_ ids: Set<UUID>) -> [(index: Int, item: FilesShelfItem)] {
        let removed = items.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, item: $0.element) }
        guard !removed.isEmpty else { return [] }
        items.removeAll { ids.contains($0.id) }
        save()
        return removed
    }

    @discardableResult
    func clear() -> [(index: Int, item: FilesShelfItem)] { remove(Set(items.map(\.id))) }

    /// Puts removed items back where they were (Undo).
    func restore(_ removed: [(index: Int, item: FilesShelfItem)]) {
        for entry in removed.sorted(by: { $0.index < $1.index }) where !items.contains(where: { $0.id == entry.item.id }) {
            items.insert(entry.item, at: min(entry.index, items.count))
        }
        save()
    }

    /// The item now lives at `url` (after Move To or its Undo).
    func relocate(_ id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].path = FilesPath.key(url.path)
        save()
    }

    func items(_ ids: Set<UUID>) -> [FilesShelfItem] { items.filter { ids.contains($0.id) } }

    static func load(from url: URL) -> [FilesShelfItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FilesShelfItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        FilesAtomicWriter.write(data, to: fileURL)
    }
}

/// What Move To and Copy To did.
struct FilesTransfer: Equatable {
    var done: [Move] = []
    var failures: [Failure] = []

    struct Move: Equatable { var from: URL; var to: URL }
    struct Failure: Equatable { var url: URL; var reason: String }
}

/// The shelf's file actions. Files are only ever moved by Move To; every
/// other action leaves them where they are. Copies and archives never
/// overwrite: a taken name becomes "Name 2".
enum FilesFileActions {
    /// Moves or copies on a background thread; one failure never stops the rest.
    static func transfer(_ urls: [URL], to folder: URL, move: Bool) async -> FilesTransfer {
        await Task.detached(priority: .userInitiated) {
            var result = FilesTransfer()
            let fileManager = FileManager.default
            for url in urls {
                let source = url.standardizedFileURL
                guard fileManager.fileExists(atPath: source.path) else {
                    result.failures.append(.init(url: url, reason: "it no longer exists"))
                    continue
                }
                if move, source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    result.done.append(.init(from: source, to: source))
                    continue
                }
                let destination = FilesNaming.uniqueDestination(for: source.lastPathComponent, in: folder)
                do {
                    if move { try fileManager.moveItem(at: source, to: destination) }
                    else { try fileManager.copyItem(at: source, to: destination) }
                    result.done.append(.init(from: source, to: destination))
                } catch {
                    result.failures.append(.init(url: url, reason: reason(error)))
                }
            }
            return result
        }.value
    }

    /// Moves files back to where they came from (Undo Move To). Only when the
    /// old place is still free.
    static func moveBack(_ moves: [FilesTransfer.Move]) async -> FilesTransfer {
        await Task.detached(priority: .userInitiated) {
            var result = FilesTransfer()
            for move in moves where move.from != move.to {
                guard !FileManager.default.fileExists(atPath: move.from.path) else {
                    result.failures.append(.init(url: move.to, reason: "a file named “\(move.from.lastPathComponent)” is back in its old folder"))
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: move.to, to: move.from)
                    result.done.append(.init(from: move.to, to: move.from))
                } catch {
                    result.failures.append(.init(url: move.to, reason: reason(error)))
                }
            }
            return result
        }.value
    }

    /// A ZIP of the items next to the first one, made by ditto like the
    /// Finder's Compress: "Report.pdf.zip" for one item, "Archive.zip" for
    /// several (copied into a temporary folder first, as clones on APFS).
    static func compress(_ urls: [URL], handle: FilesProcess.Handle) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let first = urls.first else { throw FilesProcess.Failure.couldNotStart("ditto") }
            let folder = first.deletingLastPathComponent()
            let destination = FilesNaming.uniqueDestination(for: FilesNaming.archiveName(for: urls), in: folder)
            // Large folders take a while; ten minutes is the ceiling.
            let timeout: TimeInterval = 600
            if urls.count == 1 {
                _ = try FilesProcess.checked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                                first.path, destination.path], timeout: timeout, handle: handle)
                return destination
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("AOMFilesArchive-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Archive", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
            for url in urls {
                let target = FilesNaming.uniqueDestination(for: url.lastPathComponent, in: staging)
                try FileManager.default.copyItem(at: url, to: target)
            }
            _ = try FilesProcess.checked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, destination.path],
                                         timeout: timeout, handle: handle)
            return destination
        }.value
    }

    /// Moves files to the Trash (Finder's Put Back works); returns where each
    /// one went so Undo can bring it back.
    static func trash(_ urls: [URL]) async -> (trashed: [FilesTransfer.Move], failures: [FilesTransfer.Failure]) {
        await Task.detached(priority: .userInitiated) {
            var trashed: [FilesTransfer.Move] = []
            var failures: [FilesTransfer.Failure] = []
            for url in urls {
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                    if let resulting { trashed.append(.init(from: url, to: resulting as URL)) }
                } catch {
                    failures.append(.init(url: url, reason: reason(error)))
                }
            }
            return (trashed, failures)
        }.value
    }

    static func reason(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code))).lowercased()
        }
        switch nsError.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "All of MacOS doesn't have permission"
        case NSFileWriteOutOfSpaceError: return "the disk is full"
        case NSFileWriteVolumeReadOnlyError: return "the disk is read-only"
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "it no longer exists"
        default: return nsError.localizedDescription
        }
    }

    // MARK: Main-thread actions

    @MainActor
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Copies the files themselves, like ⌘C in the Finder.
    @MainActor
    static func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @MainActor
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty, !PresetManager.isUIPreview else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @MainActor
    @discardableResult
    static func open(_ urls: [URL]) -> Bool {
        guard !PresetManager.isUIPreview else { return false }
        var opened = true
        for url in urls where !NSWorkspace.shared.open(url) { opened = false }
        return opened
    }

    /// The system AirDrop window for the files. False when AirDrop can't send them.
    @MainActor
    @discardableResult
    static func airDrop(_ urls: [URL]) -> Bool {
        guard !PresetManager.isUIPreview, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return false }
        AOMOverlayActivation.activateForOverlay()
        service.perform(withItems: urls)
        return true
    }
}
