import AppKit
import Foundation

/// 7.3 (Codex 7.2.3 report, recommended feature 1): what the file tools did
/// this session — Drop Shelf moves, Batch Rename, conversions — in one
/// list, so a result is still there after its toast is gone. Each entry
/// keeps the files it touched and the ones that failed with why; an entry
/// that can still be undone or retried keeps that action. Nothing is
/// written to disk: the list lives until AOM quits.
@MainActor
final class FilesActivityLog: ObservableObject {
    static let shared = FilesActivityLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let tool: String
        let title: String
        let files: [URL]
        let failures: [FilesTransfer.Failure]
        /// Undo for the files that are still the ones this changed.
        var undo: (() -> Void)?
        /// Runs the failed part again.
        var retry: (() -> Void)?

        var summary: String {
            failures.isEmpty ? "\(files.count) file\(files.count == 1 ? "" : "s")"
                : "\(files.count) done · \(failures.count) failed"
        }
    }

    @Published private(set) var entries: [Entry] = []
    static let limit = 50

    func record(_ title: String, tool: String, files: [URL], failures: [FilesTransfer.Failure],
                undo: (() -> Void)? = nil, retry: (() -> Void)? = nil, date: Date = Date()) {
        entries.insert(Entry(date: date, tool: tool, title: title, files: files, failures: failures, undo: undo, retry: retry), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// An entry's Undo or Retry can run once; afterwards the entry stays as a record.
    func run(_ id: UUID, retry: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let action = retry ? entries[index].retry : entries[index].undo
        entries[index].undo = nil
        entries[index].retry = nil
        action?()
    }

    func clear() { entries.removeAll() }
}
