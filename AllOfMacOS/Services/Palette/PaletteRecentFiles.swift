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

    static let recentWindow: TimeInterval = 7 * 24 * 3600
    static let recentLimit = 40

    private var queries: [NSMetadataQuery] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard queries.isEmpty, !PresetManager.isUIPreview, NSClassFromString("XCTestCase") == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()

        run(predicate: NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, now.addingTimeInterval(-Self.recentWindow) as NSDate),
            scopes: [NSMetadataQueryUserHomeScope], sortKey: NSMetadataItemLastUsedDateKey) { [weak self] items in
            let files = items.compactMap { item -> (url: URL, contentType: String?, date: Date)? in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let date = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date else { return nil }
                return (URL(fileURLWithPath: path), item.value(forAttribute: NSMetadataItemContentTypeKey) as? String, date)
            }
            self?.recent = Array(PaletteRecentFilter.usable(files, home: home, now: now, window: Self.recentWindow)
                .prefix(Self.recentLimit))
        }

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        run(predicate: NSPredicate(format: "%K >= %@", "kMDItemDateAdded", now.addingTimeInterval(-30 * 24 * 3600) as NSDate),
            scopes: [downloads], sortKey: "kMDItemDateAdded") { [weak self] items in
            let files = items.compactMap { item -> (url: URL, contentType: String?, date: Date)? in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      (path as NSString).deletingLastPathComponent == downloads.path,
                      let date = item.value(forAttribute: "kMDItemDateAdded") as? Date else { return nil }
                return (URL(fileURLWithPath: path), item.value(forAttribute: NSMetadataItemContentTypeKey) as? String, date)
            }
            self?.latestDownload = PaletteRecentFilter.usable(files, home: home, now: now, window: 30 * 24 * 3600).first
        }

        run(predicate: NSPredicate(format: "kMDItemIsScreenCapture == 1"),
            scopes: [NSMetadataQueryUserHomeScope], sortKey: NSMetadataItemFSCreationDateKey) { [weak self] items in
            let files = items.prefix(20).compactMap { item -> (url: URL, contentType: String?, date: Date)? in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let date = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date else { return nil }
                return (URL(fileURLWithPath: path), item.value(forAttribute: NSMetadataItemContentTypeKey) as? String, date)
            }
            self?.latestScreenshot = PaletteRecentFilter.usable(Array(files), home: home, now: now, window: 365 * 24 * 3600).first
        }
    }

    func stop() {
        for query in queries { query.stop() }
        queries.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Preview-only rows for isolated screenshots.
    func showSamples(_ recent: [PaletteFile], download: PaletteFile?, screenshot: PaletteFile?) {
        self.recent = recent
        latestDownload = download
        latestScreenshot = screenshot
    }

    private func run(predicate: NSPredicate, scopes: [Any], sortKey: String,
                     deliver: @escaping @MainActor ([NSMetadataItem]) -> Void) {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: false)]
        query.notificationBatchingInterval = 0.2
        let observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                              queue: .main) { [weak query] _ in
            MainActor.assumeIsolated {
                guard let query else { return }
                query.disableUpdates()
                let items = (0..<min(query.resultCount, 200)).compactMap { query.result(at: $0) as? NSMetadataItem }
                query.stop()
                deliver(items)
            }
        }
        observers.append(observer)
        queries.append(query)
        query.start()
    }
}
