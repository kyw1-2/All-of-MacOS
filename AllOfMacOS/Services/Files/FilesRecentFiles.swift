import AppKit
import Combine
import CoreServices
import Foundation

/// A recent download or screenshot.
struct FilesRecentFile: Identifiable, Equatable {
    var url: URL
    /// When it arrived in its folder (creation date when the system has none).
    var added: Date
    var size: Int64?
    var isFolder: Bool

    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }
}

/// Lists the newest items of a folder. Pure apart from the directory read;
/// sorting and the screenshot-folder rule are unit-tested.
enum FilesRecentScanner {
    static let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey,
                                         .isDirectoryKey, .isPackageKey, .isHiddenKey]

    /// Newest first by date added, then by name; at most `limit`. Skips hidden
    /// files and downloads still in progress.
    static func newest(in folder: URL, limit: Int, include: (URL) -> Bool = { _ in true },
                       fileManager: FileManager = .default) -> [FilesRecentFile] {
        read(folder, limit: limit, include: include, fileManager: fileManager) ?? []
    }

    /// `newest`, or nil when the folder can't be read (missing, or privacy
    /// settings don't allow it).
    static func read(_ folder: URL, limit: Int, include: (URL) -> Bool = { _ in true },
                     fileManager: FileManager = .default) -> [FilesRecentFile]? {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        let files = urls.compactMap { url -> FilesRecentFile? in
            guard !isInProgressDownload(url), include(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isHidden != true else { return nil }
            // The date added can't be set, so preview samples use their creation date.
            let previewDate = PresetManager.isUIPreview ? values?.creationDate : nil
            let added = previewDate ?? values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
            let folderLike = values?.isDirectory == true && values?.isPackage != true
            return FilesRecentFile(url: url, added: added, size: folderLike ? nil : values?.fileSize.map(Int64.init),
                                   isFolder: folderLike)
        }
        return Array(sorted(files).prefix(max(0, limit)))
    }

    static func sorted(_ files: [FilesRecentFile]) -> [FilesRecentFile] {
        files.sorted { lhs, rhs in
            if lhs.added != rhs.added { return lhs.added > rhs.added }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    static let inProgressExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]

    static func isInProgressDownload(_ url: URL) -> Bool {
        inProgressExtensions.contains(url.pathExtension.lowercased())
    }

    /// Where macOS saves screenshots: `location` in com.apple.screencapture
    /// (Screenshot app › Options › Save to), else the Desktop. A location that
    /// no longer exists also means the Desktop.
    static func screenshotFolder(store: SystemPreferenceStore, home: URL,
                                 fileManager: FileManager = .default) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = store.value("location", domain: "com.apple.screencapture") as? String else { return desktop }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktop }
        let expanded = FilesPath.expandTilde(trimmed, home: home.path)
        guard expanded.hasPrefix("/") else { return desktop }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return desktop }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// Screenshots carry the Spotlight attribute kMDItemIsScreenCapture. When
    /// Spotlight has nothing for the file (indexing off), the Screenshot
    /// app's own names stand in.
    static func isScreenshot(_ url: URL, metadata: (URL) -> Bool? = spotlightScreenCapture) -> Bool {
        if let flag = metadata(url) { return flag }
        let name = url.deletingPathExtension().lastPathComponent
        let prefixes = ["Screenshot ", "Screen Shot ", "Screen Recording ", "스크린샷 ", "화면 기록 ", "스크린샷"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    static func spotlightScreenCapture(_ url: URL) -> Bool? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "pdf", "gif", "mov", "mp4"]
}

/// The Files page's live recent downloads and screenshots, and the status
/// menu's Recent Downloads. Folder watchers run only while something shows the
/// lists; reading happens off the main thread.
@MainActor
final class FilesRecentModel: ObservableObject {
    static let shared = FilesRecentModel()

    @Published private(set) var downloads: [FilesRecentFile] = []
    @Published private(set) var screenshots: [FilesRecentFile] = []
    @Published private(set) var downloadsFolder: URL
    @Published private(set) var screenshotFolder: URL
    /// True after the first read finished (until then the page shows "…").
    @Published private(set) var loaded = false
    /// Downloads added in the last 24 hours (the Workspace tile's count).
    @Published private(set) var downloadsToday = 0
    /// The last read of Downloads succeeded (privacy settings allow it).
    @Published private(set) var downloadsReadable = false

    static let downloadLimit = 12
    static let screenshotLimit = 12
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watching = 0
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date?
    var onChange: (() -> Void)?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        screenshotFolder = home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Preview sample folders (UI previews only).
    func usePreviewFolders(downloads: URL, screenshots: URL) {
        guard PresetManager.isUIPreview else { return }
        downloadsFolder = downloads
        screenshotFolder = screenshots
        previewFolders = true
        refresh()
    }
    private var previewFolders = false

    /// Starts watching while a view shows the lists; balanced by `endWatching`.
    func beginWatching() {
        watching += 1
        if watching == 1 { refresh(); armWatchers() }
    }

    func endWatching() {
        watching = max(0, watching - 1)
        if watching == 0 { disarmWatchers() }
    }

    /// Re-reads both folders when the last read is older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        if !previewFolders {
            screenshotFolder = FilesRecentScanner.screenshotFolder(store: CFPreferenceStore(),
                                                                   home: FileManager.default.homeDirectoryForCurrentUser)
        }
        let downloadsURL = downloadsFolder
        let shotsURL = screenshotFolder
        let downloadLimit = Self.downloadLimit
        let screenshotLimit = Self.screenshotLimit
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> ([FilesRecentFile]?, [FilesRecentFile], Int) in
                let downloads = FilesRecentScanner.read(downloadsURL, limit: 200)
                let dayAgo = Date().addingTimeInterval(-86_400)
                let today = (downloads ?? []).filter { $0.added >= dayAgo }.count
                let candidates = FilesRecentScanner.newest(in: shotsURL, limit: 400) { url in
                    FilesRecentScanner.screenshotExtensions.contains(url.pathExtension.lowercased())
                }
                // Newest first, so Spotlight is asked only until the list is full.
                var shots: [FilesRecentFile] = []
                for file in candidates where shots.count < screenshotLimit {
                    if FilesRecentScanner.isScreenshot(file.url) { shots.append(file) }
                }
                return (downloads.map { Array($0.prefix(downloadLimit)) }, shots, today)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.downloads = result.0 ?? []
            self.downloadsReadable = result.0 != nil
            self.screenshots = result.1
            self.downloadsToday = result.2
            self.loaded = true
            self.lastRefresh = Date()
            self.onChange?()
        }
    }

    /// Reads Downloads now, for the status menu (bounded by the folder size).
    func downloadsNow(limit: Int = 10) -> [FilesRecentFile] {
        let read = FilesRecentScanner.read(downloadsFolder, limit: limit)
        downloadsReadable = read != nil
        let items = read ?? []
        downloads = Array(items.prefix(Self.downloadLimit))
        lastRefresh = Date()
        return items
    }

    private func armWatchers() {
        disarmWatchers()
        for folder in [downloadsFolder, screenshotFolder] {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete, .link], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func disarmWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
    }

    private var pendingRefresh: DispatchWorkItem?
    /// Downloads write in bursts; one read after the burst settles.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
