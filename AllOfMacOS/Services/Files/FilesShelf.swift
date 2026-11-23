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

/// 7.12 (Codex spec NEW-1, Dropover's named shelves): one named shelf —
/// "제출 자료", "발표 준비" — with its own files. Two shelves may name the
/// same file; each keeps its own item for it.
struct FilesShelfList: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var pinned: Bool
    var created: Date
    var lastUsed: Date
    var items: [FilesShelfItem]

    init(id: UUID = UUID(), name: String, pinned: Bool = false, created: Date, lastUsed: Date? = nil, items: [FilesShelfItem] = []) {
        self.id = id
        self.name = name
        self.pinned = pinned
        self.created = created
        self.lastUsed = lastUsed ?? created
        self.items = items
    }
}

/// What shelves.json holds (version 2; 7.11 and earlier kept one array in shelf.json).
struct FilesShelfLibrary: Codable, Equatable {
    var version = 2
    var activeID: UUID
    var shelves: [FilesShelfList]

    static let defaultName = "Default Shelf"

    /// Pinned first, then the most recently used (the launcher's and the menu's order).
    var ordered: [FilesShelfList] {
        shelves.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastUsed > b.lastUsed
        }
    }
}

/// The Drop Shelf's shelves, saved to
/// Application Support/AllOfMacOS/Files/shelves.json after every change so they
/// survive a relaunch. `items` and the item operations act on the active
/// shelf unless a shelf is named — an operation started on shelf A (a drop
/// whose promised files arrive late, a ZIP, a copy) finishes on A even when
/// the person has switched to B meanwhile.
@MainActor
final class FilesShelfStore: ObservableObject {
    static let shared = FilesShelfStore(fileURL: FilesStorage.shelfFile)

    @Published private(set) var library: FilesShelfLibrary
    /// The active shelf's items, newest first.
    @Published private(set) var items: [FilesShelfItem]
    /// 7.3: the shelf file couldn't be read — kept aside (the shelf starts
    /// empty) or, when it couldn't be moved, nothing is saved over it.
    @Published private(set) var problem: FocusDataProblem?
    /// The 7.11 file (one array); read once to make the Default Shelf.
    let legacyURL: URL
    let fileURL: URL
    private let now: () -> Date
    private var blocksSaving = false

    /// `fileURL` is the 7.11 shelf.json; shelves.json sits beside it.
    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.legacyURL = fileURL
        self.fileURL = fileURL.deletingLastPathComponent().appendingPathComponent("shelves.json")
        self.now = now
        let loaded = Self.loadLibrary(fileURL: self.fileURL, legacyURL: fileURL, now: now())
        self.library = loaded.library
        self.items = loaded.library.shelves.first { $0.id == loaded.library.activeID }?.items ?? []
        self.problem = loaded.problem
        self.blocksSaving = loaded.problem?.blocksSaving == true
        if loaded.migrated { finishMigration() }
    }

    var activeShelf: FilesShelfList { library.shelves.first { $0.id == library.activeID } ?? library.shelves[0] }
    var activeID: UUID { library.activeID }
    var shelves: [FilesShelfList] { library.ordered }

    func shelf(_ id: UUID) -> FilesShelfList? { library.shelves.first { $0.id == id } }

    // MARK: Shelves

    /// Makes `id` the active shelf (the hotkey and the shake open it next time).
    func activate(_ id: UUID) {
        guard let index = library.shelves.firstIndex(where: { $0.id == id }) else { return }
        library.shelves[index].lastUsed = now()
        library.activeID = id
        commit()
    }

    /// A new, empty shelf that becomes the active one. A blank or taken name
    /// becomes "Shelf 2", "제출 자료 2".
    @discardableResult
    func createShelf(named name: String) -> FilesShelfList {
        let shelf = FilesShelfList(name: uniqueName(name), created: now())
        library.shelves.append(shelf)
        library.activeID = shelf.id
        commit()
        return shelf
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = library.shelves.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != library.shelves[index].name else { return }
        library.shelves[index].name = uniqueName(trimmed, excluding: id)
        commit()
    }

    func togglePinned(_ id: UUID) {
        guard let index = library.shelves.firstIndex(where: { $0.id == id }) else { return }
        library.shelves[index].pinned.toggle()
        commit()
    }

    /// Deletes a shelf; the last one can't be deleted (Clear Shelf empties it).
    /// Returns it and its position for Undo.
    @discardableResult
    func deleteShelf(_ id: UUID) -> (index: Int, shelf: FilesShelfList, wasActive: Bool)? {
        guard library.shelves.count > 1, let index = library.shelves.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = library.shelves.remove(at: index)
        let wasActive = library.activeID == id
        if wasActive { library.activeID = library.ordered[0].id }
        commit()
        return (index, removed, wasActive)
    }

    /// Undo of Delete Shelf.
    func restoreShelf(_ entry: (index: Int, shelf: FilesShelfList, wasActive: Bool)) {
        guard shelf(entry.shelf.id) == nil else { return }
        library.shelves.insert(entry.shelf, at: min(entry.index, library.shelves.count))
        if entry.wasActive { library.activeID = entry.shelf.id }
        commit()
    }

    /// Received files (kept in AOM's Received folder) that only `shelfID`
    /// names: deleting that shelf takes them to the Trash.
    func receivedOnlyIn(_ shelfID: UUID) -> [FilesShelfItem] {
        guard let shelf = shelf(shelfID) else { return [] }
        return shelf.items.filter { $0.received && !isReferenced($0.path, outside: shelfID) }
    }

    /// Another shelf than `shelfID` names the file at `path`.
    func isReferenced(_ path: String, outside shelfID: UUID) -> Bool {
        let key = FilesPath.key(path)
        return library.shelves.contains { $0.id != shelfID && $0.items.contains { FilesPath.key($0.path) == key } }
    }

    /// Pure: `name`, or "name 2", "name 3" when another shelf has it.
    nonisolated static func uniqueName(_ name: String, among taken: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shelf" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var number = 2
        while lowered.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        Self.uniqueName(name, among: library.shelves.filter { $0.id != id }.map(\.name))
    }

    // MARK: Items

    /// Adds files at the top of `shelfID` (the active shelf when nil) in the
    /// order given. A file already on that shelf stays where it is and
    /// counts once. Returns the items for the URLs (new or existing).
    @discardableResult
    func add(_ urls: [URL], received: Bool = false, to shelfID: UUID? = nil) -> [FilesShelfItem] {
        guard let index = index(of: shelfID) else { return [] }
        var result: [FilesShelfItem] = []
        var fresh: [FilesShelfItem] = []
        let date = now()
        // 7.3: one map instead of a search of the shelf per added file.
        var known = Dictionary(library.shelves[index].items.map { (FilesPath.key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        for url in urls where url.isFileURL {
            let key = FilesPath.key(url.path)
            if let existing = known[key] {
                result.append(existing)
                continue
            }
            let item = FilesShelfItem(path: key, added: date, received: received)
            known[key] = item
            fresh.append(item)
            result.append(item)
        }
        guard !fresh.isEmpty else { return result }
        library.shelves[index].items.insert(contentsOf: fresh, at: 0)
        library.shelves[index].lastUsed = date
        commit()
        return result
    }

    /// "Also Add to …": the same files on another shelf (one item each there).
    @discardableResult
    func copy(_ ids: Set<UUID>, from source: UUID? = nil, to target: UUID) -> [FilesShelfItem] {
        let originals = items(ids, in: source)
        guard !originals.isEmpty, shelf(target) != nil, target != (source ?? activeID) else { return [] }
        let receivedPaths = Set(originals.filter(\.received).map { FilesPath.key($0.path) })
        let added = add(originals.map(\.url), to: target)
        // A received file stays "received" on every shelf that names it.
        if !receivedPaths.isEmpty, let index = index(of: target) {
            for position in library.shelves[index].items.indices where receivedPaths.contains(FilesPath.key(library.shelves[index].items[position].path)) {
                library.shelves[index].items[position].received = true
            }
            commit()
        }
        return added
    }

    /// Removes items; returns them with their positions so Undo can put them back.
    @discardableResult
    func remove(_ ids: Set<UUID>, from shelfID: UUID? = nil) -> [(index: Int, item: FilesShelfItem)] {
        guard let shelfIndex = index(of: shelfID) else { return [] }
        let list = library.shelves[shelfIndex].items
        let removed = list.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, item: $0.element) }
        guard !removed.isEmpty else { return [] }
        library.shelves[shelfIndex].items.removeAll { ids.contains($0.id) }
        commit()
        return removed
    }

    @discardableResult
    func clear() -> [(index: Int, item: FilesShelfItem)] { remove(Set(items.map(\.id))) }

    /// Puts removed items back where they were (Undo).
    func restore(_ removed: [(index: Int, item: FilesShelfItem)], to shelfID: UUID? = nil) {
        guard let shelfIndex = index(of: shelfID) else { return }
        for entry in removed.sorted(by: { $0.index < $1.index }) where !library.shelves[shelfIndex].items.contains(where: { $0.id == entry.item.id }) {
            library.shelves[shelfIndex].items.insert(entry.item, at: min(entry.index, library.shelves[shelfIndex].items.count))
        }
        commit()
    }

    /// The item now lives at `url` (after Move To or its Undo).
    func relocate(_ id: UUID, to url: URL) { relocate([(id, url)]) }

    /// Several items moved: one change and one save for all of them (7.3).
    /// 7.12 (NEW-1): every shelf that names the same file follows it.
    func relocate(_ moves: [(UUID, URL)]) {
        guard !moves.isEmpty else { return }
        var oldToNew: [String: String] = [:]
        for (id, url) in moves {
            guard let item = library.shelves.lazy.flatMap(\.items).first(where: { $0.id == id }) else { continue }
            oldToNew[FilesPath.key(item.path)] = FilesPath.key(url.path)
        }
        guard !oldToNew.isEmpty else { return }
        let receivedFolder = FilesStorage.receivedFolder
        var changed = false
        for shelfIndex in library.shelves.indices {
            for position in library.shelves[shelfIndex].items.indices {
                guard let new = oldToNew[FilesPath.key(library.shelves[shelfIndex].items[position].path)] else { continue }
                library.shelves[shelfIndex].items[position].path = new
                // Moved out of the Received folder, it is the person's file now (7.3).
                if library.shelves[shelfIndex].items[position].received,
                   !FolderRulesSafety.isInside(URL(fileURLWithPath: new), receivedFolder) {
                    library.shelves[shelfIndex].items[position].received = false
                }
                changed = true
            }
        }
        guard changed else { return }
        commit()
    }

    func items(_ ids: Set<UUID>, in shelfID: UUID? = nil) -> [FilesShelfItem] {
        guard let index = index(of: shelfID) else { return [] }
        return library.shelves[index].items.filter { ids.contains($0.id) }
    }

    private func index(of shelfID: UUID?) -> Int? {
        library.shelves.firstIndex { $0.id == (shelfID ?? library.activeID) }
    }

    // MARK: Files

    static func load(from url: URL) -> [FilesShelfItem] { loadChecked(from: url).value ?? [] }

    /// The 7.11 format: one array of items.
    static func loadChecked(from url: URL) -> FocusStorage.Loaded<[FilesShelfItem]> {
        AOMCheckedFile.load(url, owner: "the Drop Shelf") { data in
            try decoder.decode([FilesShelfItem].self, from: data)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// shelves.json when it is there; else the 7.11 shelf.json becomes the
    /// Default Shelf with its ids, order, paths and received flags.
    static func loadLibrary(fileURL: URL, legacyURL: URL, now: Date) -> (library: FilesShelfLibrary, problem: FocusDataProblem?, migrated: Bool) {
        let loaded = AOMCheckedFile.load(fileURL, owner: "the Drop Shelf") { data in
            let library = try decoder.decode(FilesShelfLibrary.self, from: data)
            guard !library.shelves.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return library
        }
        if var library = loaded.value {
            if !library.shelves.contains(where: { $0.id == library.activeID }) { library.activeID = library.shelves[0].id }
            return (library, nil, false)
        }
        if case .missing = loaded {
            let legacy = loadChecked(from: legacyURL)
            let shelf = FilesShelfList(name: FilesShelfLibrary.defaultName, created: now, items: legacy.value ?? [])
            return (FilesShelfLibrary(activeID: shelf.id, shelves: [shelf]), legacy.problem("Your Drop Shelf"), legacy.value != nil)
        }
        let shelf = FilesShelfList(name: FilesShelfLibrary.defaultName, created: now)
        return (FilesShelfLibrary(activeID: shelf.id, shelves: [shelf]), loaded.problem("Your Drop Shelf"), false)
    }

    /// The new file is written and read back before the 7.11 file is set
    /// aside, so an interrupted migration starts over and still makes one
    /// Default Shelf.
    private func finishMigration() {
        guard !blocksSaving, let data = encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            let back = try Self.decoder.decode(FilesShelfLibrary.self, from: Data(contentsOf: fileURL))
            guard back == library else { throw CocoaError(.fileReadCorruptFile) }
            let aside = legacyURL.deletingLastPathComponent().appendingPathComponent("shelf.v1-migrated.json")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: legacyURL, to: aside)
        } catch {
            GestureLog.shared.logFromAnyThread("Files: shelf migration not finished: \(error.localizedDescription)", level: .error)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(library)
    }

    private func commit() {
        let active = activeShelf.items
        if active != items { items = active }
        guard !blocksSaving, let data = encoded() else { return }
        FilesAtomicWriter.write(data, to: fileURL)
    }
}

/// What Move To and Copy To did.
struct FilesTransfer: Equatable {
    var done: [Move] = []
    var failures: [Failure] = []

    /// `identity` (device and inode) is the file's at `to` when the move
    /// finished. Undo checks it and leaves a different file that took the
    /// name since alone (7.2.3, audit B01). Nil: checked by path only.
    struct Move: Equatable {
        var from: URL
        var to: URL
        var identity: String? = nil
    }
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
                    result.done.append(.init(from: source, to: destination, identity: FolderRulesSafety.identity(destination)))
                } catch {
                    result.failures.append(.init(url: url, reason: reason(error)))
                }
            }
            return result
        }.value
    }

    /// Moves files back to where they came from (Undo Move To, Put Back).
    /// Only the file that was moved, and only while its old place is free:
    /// a different file that took its name since stays where it is
    /// (7.2.3, audit B01; Folder Rules has checked the same since 6.4.0).
    static func moveBack(_ moves: [FilesTransfer.Move]) async -> FilesTransfer {
        await Task.detached(priority: .userInitiated) {
            var result = FilesTransfer()
            for move in moves where move.from != move.to {
                let folder = FileManager.default.displayName(atPath: move.to.deletingLastPathComponent().path)
                guard FolderRulesSafety.exists(move.to.path) else {
                    result.failures.append(.init(url: move.to, reason: "it's no longer in \(folder)"))
                    continue
                }
                if let identity = move.identity, FolderRulesSafety.identity(move.to) != identity {
                    result.failures.append(.init(url: move.to, reason: "the “\(move.to.lastPathComponent)” in \(folder) is a different file now, so it was left alone"))
                    continue
                }
                guard !FolderRulesSafety.exists(move.from.path) else {
                    result.failures.append(.init(url: move.to, reason: "a file named “\(move.from.lastPathComponent)” is back in its old folder"))
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: move.to, to: move.from)
                    result.done.append(.init(from: move.to, to: move.from, identity: FolderRulesSafety.identity(move.from)))
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
    /// 7.12 (Codex FIX-1): ditto writes a hidden working file in the same
    /// folder; only a finished archive gets its name (never replacing a file
    /// that took it meanwhile). Stop, a timeout or a failure leaves no ZIP
    /// and no working file, and Stop is honoured between copied items too.
    static func compress(_ urls: [URL], handle: FilesProcess.Handle) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let first = urls.first else { throw FilesProcess.Failure.couldNotStart("ditto") }
            let folder = first.deletingLastPathComponent()
            let name = FilesNaming.archiveName(for: urls)
            let working = folder.appendingPathComponent(".\(name).aom-partial-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: working) }
            // Large folders take a while; ten minutes is the ceiling.
            let timeout: TimeInterval = 600
            if urls.count == 1 {
                _ = try FilesProcess.checked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                                first.path, working.path], timeout: timeout, handle: handle)
            } else {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AOMFilesArchive-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("Archive", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
                for url in urls {
                    if handle.isCancelled { throw CancellationError() }
                    let target = FilesNaming.uniqueDestination(for: url.lastPathComponent, in: staging)
                    try FileManager.default.copyItem(at: url, to: target)
                }
                if handle.isCancelled { throw CancellationError() }
                _ = try FilesProcess.checked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, working.path],
                                             timeout: timeout, handle: handle)
            }
            if handle.isCancelled { throw CancellationError() }
            return try ZipArchive.commitExclusive(working, in: folder, name: name)
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
                    if let resulting {
                        let place = resulting as URL
                        trashed.append(.init(from: url, to: place, identity: FolderRulesSafety.identity(place)))
                    }
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
