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
        let replaced = find.isEmpty ? (template.isEmpty ? name : template) : name.replacingOccurrences(of: find, with: template)
        return expand(replaced, name: name, number: number, date: date)
    }

    static func expand(_ text: String, name: String, number: Int, date: Date) -> String {
        guard text.contains("{") else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return text
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{nnn}", with: String(format: "%03d", number))
            .replacingOccurrences(of: "{nn}", with: String(format: "%02d", number))
            .replacingOccurrences(of: "{n}", with: String(number))
            .replacingOccurrences(of: "{date}", with: formatter.string(from: date))
    }

    /// Pure: the preview. `exists` answers whether a path is taken on disk.
    static func plan(_ urls: [URL], find: String, template: String, startingNumber: Int = 1, date: Date = Date(),
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Row] {
        var rows: [Row] = []
        for (index, url) in urls.enumerated() {
            let (number, overflow) = startingNumber.addingReportingOverflow(index)
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let base = overflow ? "" : newBaseName(name, find: find, template: template, number: number, date: date)
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

    /// The moves that were made, for Undo.
    struct Done: Equatable {
        var moves: [(from: URL, to: URL)]
        static func == (a: Done, b: Done) -> Bool { a.moves.map(\.from) == b.moves.map(\.from) && a.moves.map(\.to) == b.moves.map(\.to) }
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
    /// ones back (B02).
    @discardableResult
    static func apply(_ rows: [Row], move: (URL, URL) throws -> Void = defaultMove) throws -> Done {
        let problems = rows.filter { $0.problem != nil }.count
        guard problems == 0 else { throw Failure.problems(problems) }
        var done: [(from: URL, to: URL)] = []
        for row in rows where row.changes {
            do {
                try move(row.source, row.target)
                done.append((row.source, row.target))
            } catch {
                var restored = true
                for (from, to) in done.reversed() {
                    do { try move(to, from) } catch { restored = false }
                }
                throw Failure.moveFailed(name: row.source.lastPathComponent, reason: error.localizedDescription, restored: restored)
            }
        }
        return Done(moves: done)
    }

    /// Puts the names back (newest move first); returns how many couldn't be.
    @discardableResult
    static func undo(_ done: Done, move: (URL, URL) throws -> Void = defaultMove,
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Int {
        var failed = 0
        for (from, to) in done.moves.reversed() {
            guard exists(to), key(from) == key(to) || !exists(from) else { failed += 1; continue }
            do { try move(to, from) } catch { failed += 1 }
        }
        return failed
    }

    /// A move that also handles a change of case only ("a.txt" → "A.txt"),
    /// which goes through a temporary name.
    static func defaultMove(_ from: URL, _ to: URL) throws {
        if key(from) == key(to) {
            let temporary = from.deletingLastPathComponent().appendingPathComponent(".aom-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: from, to: temporary)
            do { try FileManager.default.moveItem(at: temporary, to: to) } catch {
                try? FileManager.default.moveItem(at: temporary, to: from)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: from, to: to)
        }
    }
}
