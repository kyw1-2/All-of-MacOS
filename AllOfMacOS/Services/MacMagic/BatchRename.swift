import Foundation

/// 7.2.2 (audit N01, B02, B07): Batch Rename shows every new name before
/// anything moves, refuses the whole set when one name is a problem, puts
/// the moved files back if a later move fails, and can be undone.
///
/// The name template: `{name}` is the original name without its extension,
/// `{n}` the number (`{nn}`, `{nnn}` pad it to two or three digits), `{date}`
/// today as 2026-11-21. With text to find, only that text is replaced (then
/// the tokens in the result are filled in); with nothing to find, the
/// template is the whole new name — so "{n}" alone numbers the files, which
/// 7.2.1 silently ignored (B07). Extensions always stay.
enum BatchRename {
    struct Row: Identifiable, Equatable {
        var id: URL { source }
        let source: URL
        /// The new file name, extension included.
        let newName: String
        /// Why this row can't be renamed; the set runs only with none.
        var problem: String?

        var target: URL { source.deletingLastPathComponent().appendingPathComponent(newName) }
        var changes: Bool { newName != source.lastPathComponent }
    }

    struct Preset: Identifiable, Equatable {
        let id: String
        let title: String
        let find: String
        let replace: String
    }

    static let presets: [Preset] = [
        .init(id: "replace", title: "Replace Text", find: "", replace: ""),
        .init(id: "number", title: "Add Numbers", find: "", replace: "{name} {n}"),
        .init(id: "sequence", title: "Number Only", find: "", replace: "{nn}"),
        .init(id: "date", title: "Date in Front", find: "", replace: "{date} {name}"),
        .init(id: "dashes", title: "Spaces to Dashes", find: " ", replace: "-")
    ]

    /// Pure: the new name for one file.
    static func newBaseName(_ name: String, find: String, template: String, number: Int, date: Date) -> String {
        newBaseName(name, find: find, template: template, number: number, dateText: { dateString(date) })
    }

    static func newBaseName(_ name: String, find: String, template: String, number: Int, dateText: () -> String) -> String {
        let replaced = find.isEmpty ? (template.isEmpty ? name : template) : name.replacingOccurrences(of: find, with: template)
        return expand(replaced, name: name, number: number, dateText: dateText)
    }

    static func expand(_ text: String, name: String, number: Int, date: Date) -> String {
        expand(text, name: name, number: number, dateText: { dateString(date) })
    }

    /// 7.3 (Codex 7.2.3 audit, efficiency): 7.2.3 made a DateFormatter for
    /// every name with a brace in it, "{name}-{n}" included — 92 ms for a
    /// 1,000-file preview against 29 ms now. The date is asked for only when
    /// the template has {date}, and the preview asks once per set.
    static func expand(_ text: String, name: String, number: Int, dateText: () -> String) -> String {
        guard text.contains("{") else { return text }
        var result = text.replacingOccurrences(of: "{name}", with: name)
        if result.contains("{n") {
            result = result
                .replacingOccurrences(of: "{nnn}", with: String(format: "%03d", number))
                .replacingOccurrences(of: "{nn}", with: String(format: "%02d", number))
                .replacingOccurrences(of: "{n}", with: String(number))
        }
        if result.contains("{date}") { result = result.replacingOccurrences(of: "{date}", with: dateText()) }
        return result
    }

    /// Pure: 2026-11-21 in the Mac's time zone, without a formatter.
    static func dateString(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Pure: the preview. `exists` answers whether a path is taken on disk.
    static func plan(_ urls: [URL], find: String, template: String, startingNumber: Int = 1, date: Date = Date(),
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(urls.count)
        var cachedDate: String?
        let dateText = { () -> String in
            if let cachedDate { return cachedDate }
            let text = dateString(date)
            cachedDate = text
            return text
        }
        for (index, url) in urls.enumerated() {
            let (number, overflow) = startingNumber.addingReportingOverflow(index)
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let base = overflow ? "" : newBaseName(name, find: find, template: template, number: number, dateText: dateText)
                .trimmingCharacters(in: .whitespaces)
            let filename = ext.isEmpty ? base : "\(base).\(ext)"
            var row = Row(source: url, newName: filename)
            if base.isEmpty || base == "." || base == ".." { row.problem = "The new name is empty" }
            else if base.contains("/") || base.contains(":") || base.contains("\0") { row.problem = "Names can't contain / or :" }
            else if filename.utf8.count > 255 { row.problem = "The new name is too long" }
            rows.append(row)
        }
        // Case-insensitive like APFS: "a.txt" and "A.txt" are one name.
        let sources = Set(urls.map { key($0) })
        var seen: [String: Int] = [:]
        for index in rows.indices where rows[index].problem == nil {
            let target = key(rows[index].target)
            if let first = seen[target] {
                rows[index].problem = "Same new name as “\(rows[first].source.lastPathComponent)”"
                continue
            }
            seen[target] = index
            // Another file already has the name (a file of this set that is
            // being renamed away still counts: the moves aren't reordered).
            if rows[index].changes, target != key(rows[index].source), exists(rows[index].target) {
                rows[index].problem = sources.contains(target) ? "Another file here has this name now" : "A file with this name exists"
            }
        }
        return rows
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// The moves that were made, for Undo. `identity` (device and inode) is
    /// the file's at `to` right after its move.
    struct Move: Equatable {
        var from: URL
        var to: URL
        var identity: String?
    }

    struct Done: Equatable {
        var moves: [Move]
    }

    enum Failure: LocalizedError {
        case problems(Int)
        case moveFailed(name: String, reason: String, restored: Bool)

        var errorDescription: String? {
            switch self {
            case .problems(let count): return count == 1 ? "One new name is a problem." : "\(count) new names are problems."
            case .moveFailed(let name, let reason, let restored):
                return "“\(name)” couldn't be renamed (\(reason))." + (restored ? " The files renamed before it were put back." : " Some files couldn't be put back.")
            }
        }
    }

    /// Renames every changing row, or none: a failed move puts the earlier
    /// ones back (B02) — each only while it is still the file that was
    /// renamed (7.3).
    @discardableResult
    static func apply(_ rows: [Row], move: (URL, URL) throws -> Void = defaultMove) throws -> Done {
        let problems = rows.filter { $0.problem != nil }.count
        guard problems == 0 else { throw Failure.problems(problems) }
        var done: [Move] = []
        for row in rows where row.changes {
            do {
                try move(row.source, row.target)
                done.append(Move(from: row.source, to: row.target, identity: FolderRulesSafety.identity(row.target)))
            } catch {
                let back = undoResult(Done(moves: done), move: move)
                throw Failure.moveFailed(name: row.source.lastPathComponent, reason: error.localizedDescription, restored: back.failures.isEmpty)
            }
        }
        return Done(moves: done)
    }

    /// Puts the names back (newest move first); returns how many couldn't be.
    @discardableResult
    static func undo(_ done: Done, move: (URL, URL) throws -> Void = defaultMove) -> Int {
        undoResult(done, move: move).failures.count
    }

    /// 7.3 (Codex 7.2.3 audit, reproduced): Undo checked paths only, so after
    /// the renamed file was put away and a new file took its name, Undo
    /// "succeeded" and renamed the new file. Each file now goes back only
    /// while it is the one that was renamed (same device and inode — an
    /// edit in place keeps it, a replacement doesn't) and its old name is
    /// free; the others are listed with where they are now.
    static func undoResult(_ done: Done, move: (URL, URL) throws -> Void = defaultMove) -> FilesTransfer {
        var result = FilesTransfer()
        for entry in done.moves.reversed() {
            let name = entry.to.lastPathComponent
            guard FolderRulesSafety.exists(entry.to.path) else {
                result.failures.append(.init(url: entry.to, reason: "“\(name)” is no longer there"))
                continue
            }
            if let identity = entry.identity, FolderRulesSafety.identity(entry.to) != identity {
                result.failures.append(.init(url: entry.to, reason: "“\(name)” is a different file now, so it was left alone"))
                continue
            }
            let caseOnly = key(entry.from) == key(entry.to)
            guard caseOnly || !FolderRulesSafety.exists(entry.from.path) else {
                result.failures.append(.init(url: entry.to, reason: "a file named “\(entry.from.lastPathComponent)” is there again"))
                continue
            }
            do {
                try move(entry.to, entry.from)
                result.done.append(.init(from: entry.to, to: entry.from, identity: FolderRulesSafety.identity(entry.from)))
            } catch {
                result.failures.append(.init(url: entry.to, reason: FilesFileActions.reason(error)))
            }
        }
        return result
    }

    /// A move that also handles a change of case only ("a.txt" → "A.txt"),
    /// which goes through a temporary name.
    static func defaultMove(_ from: URL, _ to: URL) throws {
        if key(from) == key(to) {
            let temporary = from.deletingLastPathComponent().appendingPathComponent(".aom-rename-\(UUID().uuidString)")
            try exclusiveMove(from, temporary)
            do { try exclusiveMove(temporary, to) } catch {
                try? exclusiveMove(temporary, from)
                throw error
            }
        } else {
            try exclusiveMove(from, to)
        }
    }

    /// A rename that never replaces a file (RENAME_EXCL): a name taken
    /// between the preview and the move fails instead of losing that file.
    /// Across volumes it falls back to FileManager, which never replaces either.
    static func exclusiveMove(_ from: URL, _ to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == EXDEV || code == ENOTSUP {
            try FileManager.default.moveItem(at: from, to: to)
            return
        }
        throw NSError(domain: NSCocoaErrorDomain, code: code == EEXIST ? NSFileWriteFileExistsError : NSFileWriteUnknownError,
                      userInfo: [NSFilePathErrorKey: to.path,
                                 NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
    }
}
