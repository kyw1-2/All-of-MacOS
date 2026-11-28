import AppKit
import Combine

// 7.23 (DeepSeek design reference 2026-11-25 §2.6, Transmit's dual pane and
// transfer queue, the reduced scope the report proposes): two folders side
// by side, drag between them to copy (⌘ while dropping moves), a name that
// is taken asks Replace / Keep Both / Skip, and every transfer is a row in a
// queue that says why it failed and can be tried again. A replaced file goes
// to the Trash first, never overwritten in place.

enum FilesConflictChoice: String, CaseIterable, Identifiable {
    case replace, keepBoth, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .replace: "Replace"
        case .keepBoth: "Keep Both"
        case .skip: "Skip"
        }
    }
}

enum FilesDualPanePlan {
    /// Pure: the names in `sources` already taken in the destination.
    static func conflicts(_ sources: [URL], in folder: URL, exists: (URL) -> Bool) -> [String] {
        sources.map(\.lastPathComponent).filter { exists(folder.appendingPathComponent($0)) }
    }

    /// Pure: where one item goes, or nil when it is skipped.
    static func destination(for source: URL, in folder: URL, choice: FilesConflictChoice?, exists: (URL) -> Bool) -> URL? {
        let plain = folder.appendingPathComponent(source.lastPathComponent)
        guard exists(plain) else { return plain }
        switch choice ?? .keepBoth {
        case .replace: return plain
        case .keepBoth: return FilesNaming.uniqueDestination(for: source.lastPathComponent, in: folder, exists: exists)
        case .skip: return nil
        }
    }

    /// Pure: dropping an item on its own folder, or a folder into itself, does nothing.
    static func isNoOp(_ source: URL, into folder: URL) -> Bool {
        let from = source.standardizedFileURL.path, to = folder.standardizedFileURL.path
        return source.deletingLastPathComponent().standardizedFileURL.path == to || to == from || to.hasPrefix(from + "/")
    }
}

/// One row of the transfer queue.
struct FilesTransferJob: Identifiable, Equatable {
    enum State: Equatable { case waiting, running, done, failed(String), skipped }

    let id = UUID()
    let source: URL
    let folder: URL
    let move: Bool
    let choice: FilesConflictChoice?
    var state: State = .waiting

    var verb: String { move ? "Move" : "Copy" }
}

@MainActor
final class FilesTransferQueue: ObservableObject {
    static let shared = FilesTransferQueue()

    @Published private(set) var jobs: [FilesTransferJob] = []
    private var working = false

    var active: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }
    var failed: Int { jobs.filter { if case .failed = $0.state { return true } else { return false } }.count }

    func enqueue(_ sources: [URL], to folder: URL, move: Bool, choice: FilesConflictChoice?) {
        for source in sources where !FilesDualPanePlan.isNoOp(source, into: folder) {
            jobs.append(FilesTransferJob(source: source, folder: folder, move: move, choice: choice))
        }
        if jobs.count > 200 { jobs.removeFirst(jobs.count - 200) }
        runNext()
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .waiting
        runNext()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .skipped }
    }

    private func runNext() {
        guard !working, let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        working = true
        jobs[index].state = .running
        let job = jobs[index]
        Task.detached(priority: .userInitiated) {
            let state = Self.perform(job)
            await MainActor.run {
                if let i = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[i].state = state }
                self.working = false
                NotificationCenter.default.post(name: Self.didFinish, object: job.folder)
                if job.move { NotificationCenter.default.post(name: Self.didFinish, object: job.source.deletingLastPathComponent()) }
                self.runNext()
            }
        }
    }

    static let didFinish = Notification.Name("AOMFilesTransferDidFinish")

    nonisolated static func perform(_ job: FilesTransferJob) -> FilesTransferJob.State {
        let fileManager = FileManager.default
        let exists: (URL) -> Bool = { fileManager.fileExists(atPath: $0.path) }
        guard exists(job.source) else { return .failed("it no longer exists") }
        guard let destination = FilesDualPanePlan.destination(for: job.source, in: job.folder, choice: job.choice, exists: exists) else {
            return .skipped
        }
        do {
            if exists(destination) {
                // Replace: the old one goes to the Trash, so Put Back works.
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            if job.move { try fileManager.moveItem(at: job.source, to: destination) }
            else { try fileManager.copyItem(at: job.source, to: destination) }
            return .done
        } catch {
            return .failed(FilesFileActions.reason(error))
        }
    }
}

/// One side's folder, kept between launches.
enum FilesDualPaneStore {
    static func folder(_ side: String) -> URL {
        let key = "AOMFilesDualPane_\(side)"
        if let path = UserDefaults.standard.string(forKey: key), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(side == "left" ? "Downloads" : "Desktop", isDirectory: true)
    }

    static func save(_ url: URL, side: String) {
        UserDefaults.standard.set(url.path, forKey: "AOMFilesDualPane_\(side)")
    }
}
