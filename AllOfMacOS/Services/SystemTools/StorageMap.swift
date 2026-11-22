import CoreGraphics
import Foundation

/// 7.5 (Codex F06, DaisyDisk's map): Folder Sizes as a tree you walk down.
/// One scan reads the whole folder; every folder keeps its largest items
/// (the rest are summed into one "smaller items" entry), so a big home
/// folder stays small in memory. Sizes are allocated space, as Folder
/// Sizes had them, the same number in the list and the map.
///
/// - A hard-linked file counts once (the first path found).
/// - Links are not followed, and a folder on another volume (a mounted
///   disk, a network share) is listed but not entered.
/// - A folder that couldn't be read is marked so; it is not a 0-byte folder.
final class StorageNode: Identifiable, @unchecked Sendable {
    enum Kind: Equatable { case folder, file, link, otherVolume, smallerItems(Int) }

    let id = UUID()
    let name: String
    let url: URL
    let kind: Kind
    private(set) var size: Int64
    private(set) var fileCount: Int
    /// Largest first.
    private(set) var children: [StorageNode] = []
    /// This folder couldn't be listed.
    private(set) var unreadable = false
    /// Folders below that couldn't be listed.
    private(set) var unreadableBelow = 0
    weak private(set) var parent: StorageNode?

    init(name: String, url: URL, kind: Kind, size: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        self.url = url
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
    }

    var isFolder: Bool { kind == .folder }
    var canOpen: Bool { kind == .folder && !children.isEmpty }

    /// The folders from the top down to this one.
    var path: [StorageNode] {
        var nodes: [StorageNode] = [self]
        while let up = nodes.first?.parent { nodes.insert(up, at: 0) }
        return nodes
    }

    fileprivate func finish(children found: [StorageNode], keep: Int, unreadable: Bool) {
        let sorted = found.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var kept = Array(sorted.prefix(keep))
        let rest = sorted.dropFirst(keep)
        if !rest.isEmpty {
            let count = rest.count
            kept.append(StorageNode(name: "\(count) smaller item\(count == 1 ? "" : "s")", url: url, kind: .smallerItems(count),
                                    size: rest.reduce(0) { $0 + $1.size }, fileCount: rest.reduce(0) { $0 + $1.fileCount }))
        }
        for child in kept { child.parent = self }
        children = kept
        size = found.reduce(0) { $0 + $1.size }
        fileCount = found.reduce(0) { $0 + $1.fileCount }
        self.unreadable = unreadable
        unreadableBelow = found.reduce(0) { $0 + $1.unreadableBelow + ($1.unreadable ? 1 : 0) }
    }
}

enum StorageMap {
    /// Items kept per folder before the rest are summed.
    static let keepPerFolder = 120

    struct Progress: Equatable {
        var items = 0
        var bytes: Int64 = 0
        var folder = ""
    }

    struct Scan {
        let root: StorageNode
        /// Hard links found more than once and counted once.
        let hardLinksSkipped: Int
        let elapsed: TimeInterval
    }

    /// Reads `root` and everything below it. Nil when cancelled.
    static func scan(_ root: URL, isCancelled: @escaping () -> Bool = { false },
                     progress: @escaping (Progress) -> Void = { _ in }) -> Scan? {
        let started = Date()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .linkCountKey, .volumeIdentifierKey]
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        var seenLinks = Set<String>()
        var skipped = 0
        var counter = Progress()
        var lastReport = Date.distantPast
        var cancelled = false

        func report(_ folder: URL) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = now
            counter.folder = folder.path
            progress(counter)
        }

        func read(_ folder: URL, name: String) -> StorageNode {
            let node = StorageNode(name: name, url: folder, kind: .folder)
            if cancelled || isCancelled() { cancelled = true; return node }
            report(folder)
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
            } catch {
                node.finish(children: [], keep: 0, unreadable: true)
                return node
            }
            var found: [StorageNode] = []
            found.reserveCapacity(contents.count)
            // In name order, so which path of a hard link counts is the same every time.
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if cancelled { break }
                guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
                counter.items += 1
                let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                if values.isSymbolicLink == true {
                    found.append(StorageNode(name: item.lastPathComponent, url: item, kind: .link, size: allocated, fileCount: 1))
                } else if values.isDirectory == true {
                    if let volume = values.volumeIdentifier as? NSObject, let rootVolume, !volume.isEqual(rootVolume) {
                        found.append(StorageNode(name: item.lastPathComponent, url: item, kind: .otherVolume))
                    } else {
                        found.append(read(item, name: item.lastPathComponent))
                    }
                } else {
                    var size = allocated
                    if (values.linkCount ?? 1) > 1 {
                        var status = stat()
                        if lstat(item.path, &status) == 0, !seenLinks.insert("\(status.st_dev):\(status.st_ino)").inserted {
                            size = 0
                            skipped += 1
                        }
                    }
                    counter.bytes += size
                    found.append(StorageNode(name: item.lastPathComponent, url: item, kind: .file, size: size, fileCount: 1))
                }
            }
            node.finish(children: found, keep: keepPerFolder, unreadable: false)
            return node
        }

        let top = read(root, name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        guard !cancelled else { return nil }
        return Scan(root: top, hardLinksSkipped: skipped, elapsed: Date().timeIntervalSince(started))
    }

    // MARK: Map layout

    /// Pure: squarified treemap (Bruls, Huizing, van Wijk): rectangles for
    /// `sizes` (largest first) filling `rect`, each area in proportion and
    /// as close to square as rows allow. Zero sizes get an empty rect.
    static func squarify(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let order = sizes.indices.filter { sizes[$0] > 0 }.sorted { sizes[$0] > sizes[$1] }
        var free = rect
        var row: [Int] = []

        func worst(_ row: [Int], side: Double) -> Double {
            let areas = row.map { sizes[$0] * scale }
            let sum = areas.reduce(0, +)
            guard let biggest = areas.max(), let smallest = areas.min(), sum > 0, smallest > 0 else { return .infinity }
            let sideSquared = side * side, sumSquared = sum * sum
            return max(sideSquared * biggest / sumSquared, sumSquared / (sideSquared * smallest))
        }

        func place(_ row: [Int]) {
            let areas = row.map { sizes[$0] * scale }
            let sum = areas.reduce(0, +)
            guard sum > 0 else { return }
            if free.width >= free.height {
                // A column along the left edge.
                let width = CGFloat(sum / Double(free.height))
                var y = free.minY
                for (index, area) in zip(row, areas) {
                    let height = CGFloat(area) / width
                    result[index] = CGRect(x: free.minX, y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                // A row along the top edge.
                let height = CGFloat(sum / Double(free.width))
                var x = free.minX
                for (index, area) in zip(row, areas) {
                    let width = CGFloat(area) / height
                    result[index] = CGRect(x: x, y: free.minY, width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
        }

        for index in order {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
