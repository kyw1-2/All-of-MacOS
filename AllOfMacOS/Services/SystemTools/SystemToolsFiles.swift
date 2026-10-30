import Foundation
import CryptoKit

/// File hashing, duplicate grouping and folder-size aggregation for the
/// Files tools. Scans only read; anything the user removes afterwards goes
/// through `CleanupTools.moveToTrash`. The grouping and aggregation steps are
/// pure so they are unit tested on plain values.
enum FileTools {
    // MARK: SHA-256

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file in 1 MB chunks so a multi-gigabyte file never sits in
    /// memory. `isCancelled` is polled between chunks.
    static func sha256Hex(fileAt url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A 64-character hex SHA-256 found in the text, for "matches the
    /// clipboard" checks after hashing a download.
    static func expectedHash(in text: String?) -> String? {
        guard let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              candidate.count == 64, candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate
    }

    // MARK: Duplicates

    struct SizedFile: Equatable, Hashable {
        let url: URL
        let size: Int64
        /// Used to pick the copy to keep: the oldest one stays unchecked.
        let created: Date?
    }

    /// Files with equal size and equal content hash, each group ordered with
    /// the copy to keep first (oldest, then shortest path). Sizes are compared
    /// first so only same-size files are ever hashed; empty files are ignored
    /// (every empty file "matches"). Groups are sorted by wasted space.
    static func duplicateGroups(_ files: [SizedFile], hash: (URL) throws -> String) -> [[SizedFile]] {
        let bySize = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        var groups: [[SizedFile]] = []
        for sameSize in bySize {
            var byHash: [String: [SizedFile]] = [:]
            for file in sameSize {
                guard let digest = try? hash(file.url) else { continue }
                byHash[digest, default: []].append(file)
            }
            for group in byHash.values where group.count > 1 {
                groups.append(group.sorted { lhs, rhs in
                    switch (lhs.created, rhs.created) {
                    case let (l?, r?) where l != r: return l < r
                    default: return lhs.url.path.count != rhs.url.path.count
                        ? lhs.url.path.count < rhs.url.path.count : lhs.url.path < rhs.url.path
                    }
                })
            }
        }
        return groups.sorted { wasted($0) > wasted($1) }
    }

    /// Bytes freed by keeping one copy.
    static func wasted(_ group: [SizedFile]) -> Int64 {
        guard let first = group.first else { return 0 }
        return first.size * Int64(group.count - 1)
    }

    /// Regular files of at least `minimumBytes` under `root`, skipping hidden
    /// items, package contents and ~/Library (like Large Files).
    static func sizedFiles(in root: URL, minimumBytes: Int64, isCancelled: () -> Bool = { false }) -> [SizedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey]
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return [] }
        var files: [SizedFile] = []
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            if url.standardizedFileURL.path == library { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) >= minimumBytes else { continue }
            files.append(SizedFile(url: url, size: Int64(size), created: values.creationDate))
        }
        return files
    }

    /// Review rows: every copy listed, the one to keep unchecked.
    static func duplicateCandidates(_ groups: [[SizedFile]], home: String = FileManager.default.homeDirectoryForCurrentUser.path)
        -> (items: [CleanupCandidate], preselected: Set<String>) {
        var items: [CleanupCandidate] = []
        var selected = Set<String>()
        for (index, group) in groups.enumerated() {
            for (position, file) in group.enumerated() {
                let folder = file.url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
                let note = position == 0 ? "Set \(index + 1) · keep (oldest) · \(folder)" : "Set \(index + 1) · copy · \(folder)"
                let item = CleanupCandidate(url: file.url, size: file.size, note: note)
                items.append(item)
                if position > 0 { selected.insert(item.id) }
            }
        }
        return (items, selected)
    }

    // MARK: Folder sizes

    struct FolderSize: Equatable {
        let name: String
        let size: Int64
        let files: Int
    }

    /// Adds file sizes up per top-level entry of the scanned folder. Paths
    /// are relative to it ("Movies/a.mov" counts towards "Movies"); a file at
    /// the top level is its own entry. Largest first.
    static func aggregateSizes(_ files: [(relativePath: String, size: Int64)]) -> [FolderSize] {
        var totals: [String: (size: Int64, files: Int)] = [:]
        for file in files {
            guard let top = file.relativePath.split(separator: "/", omittingEmptySubsequences: true).first else { continue }
            let key = String(top)
            totals[key, default: (0, 0)].size += file.size
            totals[key, default: (0, 0)].files += 1
        }
        return totals.map { FolderSize(name: $0.key, size: $0.value.size, files: $0.value.files) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
    }

    /// Allocated sizes under `root` per top-level item, packages included
    /// (an .app counts with its contents), hidden items included because
    /// they take space too.
    static func folderSizes(in root: URL, isCancelled: () -> Bool = { false }) -> [FolderSize] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return [] }
        // Depth-first: every item below a level-1 entry belongs to it, so no
        // path arithmetic (and no /private symlink surprises) is needed.
        var top = ""
        var files: [(relativePath: String, size: Int64)] = []
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            if enumerator.level == 1 { top = url.lastPathComponent }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let relative = enumerator.level == 1 ? top : top + "/" + url.lastPathComponent
            files.append((relative, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)))
        }
        return aggregateSizes(files)
    }

    // MARK: Saved application state

    /// The folder macOS restores an app's windows from.
    static func savedStateFolder(bundleID: String, library: URL) -> URL {
        library.appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent(bundleID + ".savedState", isDirectory: true)
    }

    /// Bundle IDs that have saved window state, from the folder names.
    static func savedStateBundleIDs(library: URL) -> [String] {
        let folder = library.appendingPathComponent("Saved Application State", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".savedState") }.map { String($0.dropLast(".savedState".count)) }.sorted()
    }

    /// A new file name in `folder` that doesn't exist yet: "untitled.txt",
    /// then "untitled 2.txt", … (Finder's own numbering).
    static func freeName(_ base: String, ext: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
