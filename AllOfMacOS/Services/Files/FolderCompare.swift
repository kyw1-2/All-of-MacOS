import Foundation

/// 7.5 (Codex F08, ForkLift's Sync preview): what one folder has that the
/// other doesn't. Both trees are walked by relative path; files of the
/// same size are compared byte by byte (equal size and date isn't taken as
/// equal), and only what's missing on one side is offered for copying —
/// nothing that's there already is replaced.
///
/// Names are matched the way the destination sees them: without regard to
/// case unless both volumes are case-sensitive, and always in Unicode's
/// composed form (a Korean name stored decomposed matches the composed one).
/// Links are compared by where they point and never followed; a folder on
/// another volume and `.DS_Store` are left out.
extension Result {
    var value: Success? { if case .success(let value) = self { return value }; return nil }
}

enum FolderCompare {
    enum Status: String, CaseIterable, Identifiable {
        case leftOnly, rightOnly, differs, same, problem
        var id: String { rawValue }
        var title: String {
            switch self {
            case .leftOnly: return "Only on the Left"
            case .rightOnly: return "Only on the Right"
            case .differs: return "Contents Differ"
            case .same: return "Same"
            case .problem: return "Couldn't Compare"
            }
        }
    }

    struct Side: Equatable {
        let url: URL
        let size: Int64
        let modified: Date?
        let isFolder: Bool
        let isLink: Bool
        /// A folder's files and their total.
        var files = 1
        let fingerprint: FileTools.Fingerprint?
    }

    struct Item: Identifiable, Equatable {
        /// The relative path as matched ("docs/readme.md").
        let id: String
        /// As spelled on the side that has it (the left one when both do).
        let path: String
        var left: Side?
        var right: Side?
        var status: Status
        var note: String?
        /// The folder on the other side a missing item would go into.
        var otherParent: URL?

        /// Only a missing file or folder (not a link) can be copied.
        var canCopy: Bool { (status == .leftOnly || status == .rightOnly) && !(left?.isLink ?? right?.isLink ?? false) && otherParent != nil }
    }

    struct Comparison {
        let left: URL
        let right: URL
        var items: [Item]
        let ignoresCase: Bool
        func count(_ status: Status) -> Int { items.filter { $0.status == status }.count }
    }

    enum Failure: LocalizedError, Equatable {
        case notFolder(String)
        case sameFolder
        case nested
        var errorDescription: String? {
            switch self {
            case .notFolder(let name): return "“\(name)” isn't a folder that can be read"
            case .sameFolder: return "Both sides are the same folder"
            case .nested: return "One folder is inside the other; pick two separate folders"
            }
        }
    }

    // MARK: Comparing

    /// Pure: the name as matched.
    static func key(_ name: String, ignoresCase: Bool) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        return ignoresCase ? composed.lowercased() : composed
    }

    static func caseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    static func compare(_ left: URL, _ right: URL, isCancelled: @escaping () -> Bool = { false },
                        progress: @escaping (String) -> Void = { _ in }) throws -> Comparison? {
        for root in [left, right] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: root.path) else { throw Failure.notFolder(root.lastPathComponent) }
        }
        let a = left.resolvingSymlinksInPath().standardizedFileURL.path, b = right.resolvingSymlinksInPath().standardizedFileURL.path
        guard a != b else { throw Failure.sameFolder }
        guard !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else { throw Failure.nested }
        let ignoresCase = !(caseSensitive(left) && caseSensitive(right))
        var items: [Item] = []
        var cancelled = false
        let volumes = (volume(left), volume(right))

        func walk(_ l: URL?, _ r: URL?, relative: String) {
            if cancelled || isCancelled() { cancelled = true; return }
            progress(relative.isEmpty ? "/" : relative)
            let leftList = l.map(list), rightList = r.map(list)
            if case .failure? = leftList, let l {
                items.append(Item(id: relative, path: relative, left: side(l), right: r.flatMap(side), status: .problem, note: "The left folder couldn't be read"))
                return
            }
            if case .failure? = rightList, let r {
                items.append(Item(id: relative, path: relative, left: l.flatMap(side), right: side(r), status: .problem, note: "The right folder couldn't be read"))
                return
            }
            let leftNames = (try? leftList?.get()) ?? [], rightNames = (try? rightList?.get()) ?? []
            var leftByKey: [String: [URL]] = [:], rightByKey: [String: [URL]] = [:]
            for url in leftNames { leftByKey[key(url.lastPathComponent, ignoresCase: ignoresCase), default: []].append(url) }
            for url in rightNames { rightByKey[key(url.lastPathComponent, ignoresCase: ignoresCase), default: []].append(url) }
            let keys = Set(leftByKey.keys).union(rightByKey.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in keys {
                if cancelled { return }
                let ls = leftByKey[name] ?? [], rs = rightByKey[name] ?? []
                let id = relative.isEmpty ? name : relative + "/" + name
                let shown = (ls.first ?? rs.first).map { (relative.isEmpty ? "" : relative + "/") + $0.lastPathComponent } ?? id
                // Two names that differ only in case on a case-sensitive side.
                if ls.count > 1 || rs.count > 1 {
                    items.append(Item(id: id, path: shown, left: ls.first.flatMap(side), right: rs.first.flatMap(side), status: .problem,
                                      note: "\((ls.count > 1 ? ls : rs).map(\.lastPathComponent).joined(separator: ", ")) differ only in case; the other side can't hold both"))
                    continue
                }
                let lu = ls.first, ru = rs.first
                let lv = lu.flatMap(side), rv = ru.flatMap(side)
                switch (lv, rv) {
                case let (lv?, rv?):
                    let renamed = lu!.lastPathComponent != ru!.lastPathComponent ? "Named “\(ru!.lastPathComponent)” on the right" : nil
                    if lv.isLink || rv.isLink {
                        let same = lv.isLink && rv.isLink && linkTarget(lu!) == linkTarget(ru!)
                        items.append(Item(id: id, path: shown, left: lv, right: rv, status: same ? .same : .differs,
                                          note: same ? renamed : "Links are compared by where they point"))
                    } else if lv.isFolder && rv.isFolder {
                        if volume(lu!) != volumes.0 || volume(ru!) != volumes.1 {
                            items.append(Item(id: id, path: shown, left: lv, right: rv, status: .problem, note: "On another volume; not compared"))
                        } else {
                            walk(lu, ru, relative: id)
                        }
                    } else if lv.isFolder != rv.isFolder {
                        items.append(Item(id: id, path: shown, left: lv, right: rv, status: .problem,
                                          note: "A folder on one side and a file on the other"))
                    } else {
                        // Same size: compared later, byte by byte.
                        items.append(Item(id: id, path: shown, left: lv, right: rv, status: lv.size == rv.size ? .same : .differs,
                                          note: renamed))
                    }
                case let (lv?, nil):
                    items.append(Item(id: id, path: shown, left: lv.isFolder ? folderTotals(lv) : lv, right: nil, status: .leftOnly,
                                      note: lv.isLink ? "A link; links aren't copied" : nil, otherParent: r))
                case let (nil, rv?):
                    items.append(Item(id: id, path: shown, left: nil, right: rv.isFolder ? folderTotals(rv) : rv, status: .rightOnly,
                                      note: rv.isLink ? "A link; links aren't copied" : nil, otherParent: l))
                default:
                    break
                }
            }
        }

        walk(left, right, relative: "")
        // Same-size files: the contents decide.
        for index in items.indices where items[index].status == .same {
            if cancelled || isCancelled() { cancelled = true; break }
            guard let l = items[index].left, let r = items[index].right, !l.isFolder, !l.isLink else { continue }
            progress(items[index].path)
            switch sameContents(l.url, r.url, isCancelled: isCancelled) {
            case .some(true): break
            case .some(false): items[index].status = .differs
            case nil:
                if isCancelled() { cancelled = true; break }
                items[index].status = .problem
                items[index].note = "One of the two couldn't be read"
            }
        }
        guard !cancelled else { return nil }
        return Comparison(left: left, right: right, items: items, ignoresCase: ignoresCase)
    }

    private static func list(_ folder: URL) -> Result<[URL], Error> {
        Result {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                                                .fileSizeKey, .contentModificationDateKey],
                                                        options: []).filter { $0.lastPathComponent != ".DS_Store" }
        }
    }

    private static func side(_ url: URL) -> Side? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        let isLink = values.isSymbolicLink == true
        return Side(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate,
                    isFolder: !isLink && values.isDirectory == true, isLink: isLink, fingerprint: FileTools.fingerprint(url))
    }

    private static func folderTotals(_ side: Side) -> Side {
        var copy = side
        var files = 0
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: side.url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        copy.files = files
        return Side(url: copy.url, size: bytes, modified: copy.modified, isFolder: true, isLink: false, files: files, fingerprint: copy.fingerprint)
    }

    private static func volume(_ url: URL) -> String {
        var status = stat()
        return lstat(url.path, &status) == 0 ? "\(status.st_dev)" : ""
    }

    private static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Byte by byte, stopping at the first difference; nil when unreadable or cancelled.
    static func sameContents(_ a: URL, _ b: URL, isCancelled: () -> Bool = { false }) -> Bool? {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else { return nil }
        defer { try? first.close(); try? second.close() }
        while true {
            if isCancelled() { return nil }
            // read(upToCount:) gives nil at the end of the file.
            guard let x = Result(catching: { try first.read(upToCount: 1 << 20) ?? Data() }).value,
                  let y = Result(catching: { try second.read(upToCount: 1 << 20) ?? Data() }).value else { return nil }
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }

    // MARK: Copying what's missing

    enum Direction: String, CaseIterable, Identifiable {
        case leftToRight, rightToLeft
        var id: String { rawValue }
        var title: String { self == .leftToRight ? "Left → Right" : "Right → Left" }
        var copies: Status { self == .leftToRight ? .leftOnly : .rightOnly }
    }

    struct CopyResult: Equatable {
        /// Item ids copied.
        var copied: [String] = []
        var written: [URL] = []
        /// Item id → why it wasn't copied.
        var skipped: [String: String] = [:]
        var cancelled = false
    }

    /// Copies the picked items that are missing on the other side. Each is
    /// checked again first (the source still what was compared, the name
    /// still free on the other side), copied to a hidden temporary name
    /// and renamed with RENAME_EXCL, so an existing file is never replaced
    /// and a copy cut short leaves no partial file.
    static func copyMissing(_ picked: [Item], direction: Direction, isCancelled: () -> Bool = { false },
                            progress: (Int) -> Void = { _ in }) -> CopyResult {
        var result = CopyResult()
        for (number, item) in picked.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            progress(number)
            guard item.status == direction.copies, item.canCopy,
                  let source = direction == .leftToRight ? item.left : item.right, let parent = item.otherParent else {
                result.skipped[item.id] = "Not missing on the other side"
                continue
            }
            if !source.isFolder, FileTools.fingerprint(source.url) != source.fingerprint {
                result.skipped[item.id] = "Changed since the comparison; compare again"
                continue
            }
            if source.isFolder, !FileManager.default.fileExists(atPath: source.url.path) {
                result.skipped[item.id] = "Gone since the comparison"
                continue
            }
            let destination = parent.appendingPathComponent(source.url.lastPathComponent)
            if FolderRulesSafety.exists(destination.path) {
                result.skipped[item.id] = "Something with this name is there now; nothing was replaced"
                continue
            }
            let temporary = parent.appendingPathComponent(".aom-copy-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: source.url, to: temporary)
                if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                    let code = errno
                    if (code == ENOTSUP || code == EXDEV), !FolderRulesSafety.exists(destination.path) {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    } else {
                        try? FileManager.default.removeItem(at: temporary)
                        result.skipped[item.id] = code == EEXIST ? "Something with this name appeared meanwhile; nothing was replaced"
                            : String(cString: strerror(code))
                        continue
                    }
                }
                result.copied.append(item.id)
                result.written.append(destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                result.skipped[item.id] = (error as NSError).localizedDescription
            }
        }
        return result
    }
}
