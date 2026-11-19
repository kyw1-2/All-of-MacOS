import AppKit
import Foundation

/// A file the palette lists: recent, the latest download, the latest screenshot.
struct PaletteFile: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let date: Date
}

enum PaletteRecentFilter {
    /// Spotlight's recently used items worth listing: no folders, apps or
    /// packages, nothing hidden or inside a Library folder, newest first,
    /// one row per path.
    static func usable(_ files: [(url: URL, contentType: String?, date: Date)], home: URL,
                       now: Date, window: TimeInterval) -> [PaletteFile] {
        var seen = Set<String>()
        let library = home.appendingPathComponent("Library", isDirectory: true).path + "/"
        return files
            .filter { file in
                let path = file.url.path
                guard now.timeIntervalSince(file.date) <= window, file.date <= now.addingTimeInterval(60) else { return false }
                guard !path.hasPrefix(library), !path.contains("/."), !path.hasPrefix("/System/"),
                      !path.hasPrefix("/Library/") else { return false }
                let type = file.contentType ?? ""
                if type == "public.folder" || type == "com.apple.application-bundle" || type == "public.volume" { return false }
                let ext = file.url.pathExtension.lowercased()
                return !["app", "download", "crdownload", "part"].contains(ext)
            }
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.url.path).inserted }
            .map { PaletteFile(url: $0.url, name: FileManager.default.displayName(atPath: $0.url.path), date: $0.date) }
    }
}

/// Spotlight queries for the palette, run only while it is open: files used
/// in the last 7 days (kMDItemLastUsedDate), the newest download in
/// ~/Downloads (kMDItemDateAdded) and the newest screenshot
/// (kMDItemIsScreenCapture). Each query gathers once and stops; nothing
/// watches the disk afterwards.
@MainActor
final class PaletteRecentFiles: ObservableObject {
    @Published private(set) var recent: [PaletteFile] = []
    @Published private(set) var latestDownload: PaletteFile?
    @Published private(set) var latestScreenshot: PaletteFile?
    /// While any of the three Spotlight queries has not answered (6.5: the
    /// palette shows a small spinner, report 04 §5.5).
    @Published private(set) var isLoading = false
    private var pending = 0

    static let recentWindow: TimeInterval = 7 * 24 * 3600
    static let recentLimit = 40

    private var queries: [NSMetadataQuery] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard queries.isEmpty, !PresetManager.isUIPreview, NSClassFromString("XCTestCase") == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()

        pending = 3
        isLoading = true
        let month: TimeInterval = 30 * 86_400
        let year: TimeInterval = 365 * 86_400
        run(predicate: NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, now.addingTimeInterval(-Self.recentWindow) as NSDate),
            scope: NSMetadataQueryUserHomeScope, sortKey: NSMetadataItemLastUsedDateKey,
            home: home, now: now, window: Self.recentWindow, limit: Self.recentLimit) { [weak self] in self?.recent = $0 }

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        run(predicate: NSPredicate(format: "%K >= %@", "kMDItemDateAdded", now.addingTimeInterval(-month) as NSDate),
            scope: downloads, sortKey: "kMDItemDateAdded", home: home, now: now,
            window: month, limit: 1, parent: downloads) { [weak self] in self?.latestDownload = $0.first }

        run(predicate: NSPredicate(format: "kMDItemIsScreenCapture == 1 AND %K >= %@", NSMetadataItemFSCreationDateKey,
                                   now.addingTimeInterval(-year) as NSDate),
            scope: NSMetadataQueryUserHomeScope, sortKey: NSMetadataItemFSCreationDateKey,
            home: home, now: now, window: year, limit: 1) { [weak self] in self?.latestScreenshot = $0.first }
    }

    func stop() {
        for query in queries { query.stop() }
        queries.removeAll()
        pending = 0
        isLoading = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Preview-only rows for isolated screenshots.
    func showSamples(_ recent: [PaletteFile], download: PaletteFile?, screenshot: PaletteFile?) {
        self.recent = recent
        latestDownload = download
        latestScreenshot = screenshot
    }

    private func run(predicate: NSPredicate, scope: Any, sortKey: String, home: URL, now: Date,
                     window: TimeInterval, limit: Int, parent: URL? = nil,
                     deliver: @escaping @MainActor ([PaletteFile]) -> Void) {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [scope]
        query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: false)]
        query.notificationBatchingInterval = 0.2
        let observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                              queue: .main) { [weak self, weak query] _ in
            Task { @MainActor in
                guard let self, let query, self.queries.contains(where: { $0 === query }) else { return }
                query.disableUpdates()
                var files: [PaletteFile] = []
                var seen = Set<String>()
                let count = query.resultCount
                // Spotlight has already sorted the hits. Advance past hidden or nested
                // items until enough eligible files are found. Yield between batches.
                for start in stride(from: 0, to: count, by: 64) {
                    guard self.queries.contains(where: { $0 === query }) else { return }
                    let batch = (start..<min(start + 64, count)).compactMap { index -> (url: URL, contentType: String?, date: Date)? in
                        guard let item = query.result(at: index) as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                              let date = item.value(forAttribute: sortKey) as? Date else { return nil }
                        let url = URL(fileURLWithPath: path)
                        if let parent, url.deletingLastPathComponent().path != parent.path { return nil }
                        return (url, item.value(forAttribute: NSMetadataItemContentTypeKey) as? String, date)
                    }
                    let usable = PaletteRecentFilter.usable(batch, home: home, now: now, window: window)
                    for file in usable where seen.insert(file.id).inserted {
                        files.append(file)
                        if files.count == limit { break }
                    }
                    if files.count == limit { break }
                    await Task.yield()
                }
                guard self.queries.contains(where: { $0 === query }) else { return }
                query.stop()
                deliver(files)
                self.pending = max(0, self.pending - 1)
                if self.pending == 0 { self.isLoading = false }
            }
        }
        observers.append(observer)
        queries.append(query)
        query.start()
    }
}
