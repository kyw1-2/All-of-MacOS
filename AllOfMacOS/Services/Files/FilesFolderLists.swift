import Foundation

/// One folder the dialog helper offers.
struct FilesFolderEntry: Identifiable, Equatable {
    enum Source: String, Equatable {
        case finder, favorite, recent, newestFile, clipboard
    }

    let path: String
    let source: Source
    /// When it became recent (a jump, or the newest file's date added).
    var date: Date?
    /// One line under the name: "Has report.pdf", "Front Finder window".
    var detail: String?

    var id: String { "\(source.rawValue):\(path)" }
    var name: String { FilesPath.displayName(path) }
}

/// A folder the dialog helper jumped to.
struct FilesRecentJump: Codable, Equatable {
    var path: String
    var date: Date
}

/// A recently added item in Downloads or on the Desktop, for the dialog
/// helper's recent folders.
struct FilesNewestFile: Equatable {
    var url: URL
    var added: Date
    /// A folder (not a package) is its own destination; a file goes to the
    /// folder it is in.
    var isFolder = false
}

/// Ordering and de-duplication for the dialog helper's lists. Pure: every
/// input is a value, so the rules are unit-tested.
enum FilesFolderLists {
    static let recentJumpLimit = 12
    static let recentLimit = 8

    /// Favourites in the person's order, each folder once (the first wins),
    /// spelled in their comparable form.
    static func favorites(_ paths: [String], home: String = NSHomeDirectory()) -> [String] {
        unique(paths.map { FilesPath.key($0, home: home) })
    }

    /// Finder windows front to back, one entry per folder.
    static func finderFolders(_ paths: [String], home: String = NSHomeDirectory()) -> [String] {
        unique(paths.map { FilesPath.key($0, home: home) }.filter { !$0.isEmpty })
    }

    /// Records a jump: the folder moves to the front, the list keeps at most
    /// `limit` folders.
    static func noting(_ path: String, at date: Date, in list: [FilesRecentJump],
                       limit: Int = recentJumpLimit, home: String = NSHomeDirectory()) -> [FilesRecentJump] {
        let key = FilesPath.key(path, home: home)
        var result = list.filter { FilesPath.key($0.path, home: home) != key }
        result.insert(FilesRecentJump(path: key, date: date), at: 0)
        return Array(result.prefix(max(1, limit)))
    }

    /// Recent folders: jumps and the folders of the newest files, newest
    /// first, each folder once (its newest date wins), leaving out folders the
    /// panel already lists (favourites, Finder windows) and at most `limit`.
    static func recents(jumps: [FilesRecentJump], newestFiles: [FilesNewestFile], excluding: Set<String>,
                        limit: Int = recentLimit, home: String = NSHomeDirectory()) -> [FilesFolderEntry] {
        struct Candidate { var path: String; var date: Date; var detail: String?; var source: FilesFolderEntry.Source }
        var best: [String: Candidate] = [:]
        func offer(_ candidate: Candidate) {
            if let existing = best[candidate.path], existing.date >= candidate.date { return }
            best[candidate.path] = candidate
        }
        for jump in jumps {
            offer(Candidate(path: FilesPath.key(jump.path, home: home), date: jump.date, detail: nil, source: .recent))
        }
        for file in newestFiles {
            if file.isFolder {
                let folder = FilesPath.key(file.url.path, home: home)
                let parent = FilesPath.displayName(file.url.deletingLastPathComponent().path)
                offer(Candidate(path: folder, date: file.added, detail: "Added to \(parent)", source: .newestFile))
            } else {
                let folder = FilesPath.key(file.url.deletingLastPathComponent().path, home: home)
                offer(Candidate(path: folder, date: file.added, detail: "Has \(file.url.lastPathComponent)", source: .newestFile))
            }
        }
        let excludedKeys = Set(excluding.map { FilesPath.key($0, home: home) })
        return best.values
            .filter { !excludedKeys.contains($0.path) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.path < $1.path }
            .prefix(max(0, limit))
            .map { FilesFolderEntry(path: $0.path, source: $0.source, date: $0.date, detail: $0.detail) }
    }

    /// Order kept, later duplicates dropped.
    static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// The folders the dialog helper jumped to, persisted in
/// Application Support/AllOfMacOS/Files/recent-folders.json.
@MainActor
final class FilesRecentFolderStore: ObservableObject {
    static let shared = FilesRecentFolderStore(fileURL: FilesStorage.recentFoldersFile)

    @Published private(set) var jumps: [FilesRecentJump]
    let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        self.jumps = Self.load(from: fileURL)
    }

    func note(_ folder: URL) {
        jumps = FilesFolderLists.noting(folder.path, at: now(), in: jumps)
        save()
    }

    func remove(_ path: String) {
        let key = FilesPath.key(path)
        jumps.removeAll { FilesPath.key($0.path) == key }
        save()
    }

    func clear() {
        jumps = []
        save()
    }

    static func load(from url: URL) -> [FilesRecentJump] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FilesRecentJump].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jumps) else { return }
        FilesAtomicWriter.write(data, to: fileURL)
    }
}

/// Small JSON files written off the main thread, one at a time, atomically.
enum FilesAtomicWriter {
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.files.writer", qos: .utility)

    static func write(_ data: Data, to url: URL) {
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Waits for pending writes (tests).
    static func flush() { queue.sync {} }
}
