import AppKit
import SwiftUI

// AOM 7.2: what the launcher's new screens load while they are open —
// Spotlight file results, a folder being browsed, the network snapshot, a
// folder rule's dry run and a script's output. Like PaletteRouteModels it
// lives outside the view, so the result cache is rebuilt when it changes,
// and every load carries a ticket so a late answer never replaces a newer one.

/// One file or folder row.
struct PaletteFileHit: Identifiable, Hashable {
    let url: URL
    let date: Date?
    let isFolder: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@MainActor
final class PaletteLauncherData: ObservableObject {
    // MARK: Spotlight

    @Published private(set) var files: [PaletteFileHit] = []
    @Published private(set) var fileStatus: FileStatus = .idle
    /// 7.12: `unavailable` — the search's folder is gone or can't be read,
    /// told apart from "nothing found".
    enum FileStatus: Equatable { case idle, searching, done(total: Int), failed, unavailable(String) }
    /// 7.12 (saved searches): the conditions of the search shown.
    @Published private(set) var fileQuery = PaletteFileQuery()

    private var metadataQuery: NSMetadataQuery?
    private var metadataObserver: NSObjectProtocol?
    private var fileTicket = 0
    private(set) var fileTerm = ""

    /// Names that contain `term`, anywhere in the home folder, newest first;
    /// 180 ms after the last keystroke.
    func searchFiles(_ term: String) {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != fileTerm || fileStatus == .idle else { return }
        fileTerm = text
        stopFileSearch()
        fileTicket &+= 1
        let ticket = fileTicket
        files = []
        let parsed = PaletteFileQuery.parse(text)
        fileQuery = parsed
        guard !parsed.isEmpty else { fileStatus = .idle; return }
        if PresetManager.isUIPreview { files = Self.sampleFiles(); fileStatus = .done(total: files.count); return }
        // 7.12: a folder that's gone or closed to AOM says so instead of "no file".
        if let folder = parsed.folderURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                fileStatus = .unavailable("\((folder.path as NSString).abbreviatingWithTildeInPath) isn't there any more")
                return
            }
            guard FileManager.default.isReadableFile(atPath: folder.path),
                  (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
                fileStatus = .unavailable("All of MacOS isn't allowed to read \((folder.path as NSString).abbreviatingWithTildeInPath)")
                return
            }
        }
        fileStatus = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.fileTicket == ticket else { return }
            let query = NSMetadataQuery()
            query.searchScopes = parsed.folderURL.map { [$0] } ?? [NSMetadataQueryUserHomeScope]
            query.predicate = parsed.predicate()
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            self.metadataQuery = query
            self.metadataObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                           object: query, queue: .main) { [weak self, weak query] _ in
                MainActor.assumeIsolated {
                    guard let self, let query, self.fileTicket == ticket else { return }
                    query.disableUpdates()
                    let total = query.resultCount
                    self.files = (0..<min(total, 80)).compactMap { index in
                        guard let item = query.result(at: index) as? NSMetadataItem,
                              let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
                        let kind = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                        return PaletteFileHit(url: url, date: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                                              isFolder: kind == "public.folder")
                    }
                    self.fileStatus = .done(total: total)
                    self.stopFileSearch()
                }
            }
            if !query.start() { self.fileStatus = .failed; self.stopFileSearch() }
        }
    }

    func stopFileSearch() {
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
        metadataObserver = nil
        metadataQuery?.stop()
        metadataQuery = nil
    }

    func resetFiles() {
        fileTicket &+= 1
        stopFileSearch()
        files = []
        fileTerm = ""
        fileQuery = PaletteFileQuery()
        fileStatus = .idle
    }

    // MARK: Browse

    /// A folder being browsed. 7.3 (Codex 7.2.3 report, reproduced): 7.2.3
    /// listed the folder on the main actor, kept the first 2,000 entries in
    /// the file system's order and only then sorted them, so a folder of
    /// 2,400 files lost 400 — searching couldn't find them. The listing now
    /// runs in the background, every entry is kept and sorted, a late
    /// answer for a folder left since is dropped, and the screen draws the
    /// first `shown` rows while typing searches them all.
    struct Folder: Equatable {
        var url: URL
        var items: [PaletteFileHit] = []
        var error: String?
        var loading = true
        var shown = PaletteLauncherData.folderPage

        static func == (a: Folder, b: Folder) -> Bool {
            a.url == b.url && a.items.count == b.items.count && a.error == b.error && a.loading == b.loading && a.shown == b.shown
        }
    }

    nonisolated static let folderPage = 400

    @Published private(set) var folder: Folder?
    private var folderTicket = 0

    /// A folder's visible items, folders first, then by name.
    func browse(_ url: URL) {
        folderTicket &+= 1
        let ticket = folderTicket
        folder = Folder(url: url)
        Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { Self.listing(of: url) }.value
            guard let self, self.folderTicket == ticket, self.folder?.url == url else { return }
            self.folder = Folder(url: url, items: listed.items, error: listed.error, loading: false)
        }
    }

    /// Draws the next page of rows.
    func showMoreOfFolder() {
        guard var current = folder else { return }
        current.shown += Self.folderPage
        folder = current
    }

    nonisolated static func listing(of url: URL) -> (items: [PaletteFileHit], error: String?) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            let items = urls.map { item -> PaletteFileHit in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return PaletteFileHit(url: item, date: values?.contentModificationDate,
                                      isFolder: values?.isDirectory == true && values?.isPackage != true)
            }
            return (sortedForBrowsing(items), nil)
        } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoPermissionError {
                return ([], "macOS didn't let AOM read this folder. Allow it in System Settings › Privacy & Security › Files and Folders.")
            }
            if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError {
                return ([], "This folder isn't there any more (moved, renamed or its disk was ejected).")
            }
            let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
            if local == false { return ([], "The network volume didn't answer: \(error.localizedDescription)") }
            return ([], error.localizedDescription)
        }
    }

    /// Pure: the hits whose names hold every word of `query` (a first cut
    /// before the launcher's ranking, for folders too big to rank whole).
    nonisolated static func folderMatches(_ items: [PaletteFileHit], query: String) -> [PaletteFileHit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        let matching = items.filter { hit in
            let name = hit.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        // The name itself, then names that start with it, then the rest —
        // so an exact name survives the 2,000-row cut (7.3, Codex probe).
        let whole = query.lowercased().trimmingCharacters(in: .whitespaces)
        func rank(_ hit: PaletteFileHit) -> Int {
            let name = hit.name.lowercased()
            let base = (name as NSString).deletingPathExtension
            if name == whole || base == whole { return 0 }
            return name.hasPrefix(whole) ? 1 : 2
        }
        return matching.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Pure: folders first, then names in Finder's order.
    nonisolated static func sortedForBrowsing(_ items: [PaletteFileHit]) -> [PaletteFileHit] {
        items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Network

    struct Network: Equatable {
        var local: String?
        var interface: String?
        var publicIP: String?
        var publicError: String?
        var checkingPublic = false
        var wifi: [String] = []
        var dns: [String] = []
    }

    @Published private(set) var network: Network?
    private var networkTicket = 0

    func loadNetwork() {
        networkTicket &+= 1
        let ticket = networkTicket
        let address = SystemStatus.preferredAddress(SystemStatus.ipv4Addresses())
        var snapshot = Network(local: address?.address, interface: address?.interface, checkingPublic: true)
        if PresetManager.isUIPreview {
            snapshot.wifi = NetworkTools.wifiDetails()?.lines ?? []
            snapshot.checkingPublic = false
            snapshot.publicIP = "203.0.113.24"
            network = snapshot
            return
        }
        network = snapshot
        Task { [weak self] in
            // 7.3 (Codex 7.2.3 report): Wi-Fi details and scutil's DNS list
            // were read on the main actor while the screen opened.
            let (wifi, dns) = await Task.detached(priority: .userInitiated) {
                (NetworkTools.wifiDetails()?.lines ?? [], NetworkTools.dnsServers())
            }.value
            guard let self, self.networkTicket == ticket else { return }
            snapshot.wifi = wifi
            snapshot.dns = dns
            self.network = snapshot
            var finished = snapshot
            do { finished.publicIP = try await NetworkTools.publicIP() } catch { finished.publicError = error.localizedDescription }
            finished.checkingPublic = false
            guard self.networkTicket == ticket else { return }
            self.network = finished
        }
    }

    // MARK: Folder rule dry run

    @Published private(set) var rulePreview: FolderRulePreview?
    private var ruleTicket = 0

    func previewRule(_ id: UUID) {
        ruleTicket &+= 1
        let ticket = ruleTicket
        rulePreview = nil
        guard let rule = FolderRulesEngine.shared.config.rules.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            let preview = await FolderRulesEngine.shared.preview(rule)
            guard let self, self.ruleTicket == ticket else { return }
            self.rulePreview = preview
        }
    }

    // MARK: Script commands

    struct ScriptRun: Equatable {
        var scriptID: String
        var title: String
        var running = true
        var outcome: PaletteScripts.Outcome?
    }

    @Published private(set) var scripts: [PaletteScript] = []
    @Published private(set) var scriptRun: ScriptRun?
    private var scriptCommand: StreamingCommand?

    func loadScripts() { scripts = PaletteScripts.scan() }

    func run(_ script: PaletteScript, argument: String?, done: @escaping (PaletteScripts.Outcome) -> Void) {
        scriptCommand?.cancel()
        let command = PaletteScripts.command(for: script, argument: argument)
        scriptCommand = command
        scriptRun = ScriptRun(scriptID: script.id, title: script.title)
        Task { [weak self] in
            let result: StreamingCommand.Result
            do { result = try await command.run(onLine: nil) }
            catch { result = .init(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
            let outcome = PaletteScripts.outcome(result)
            guard let self, self.scriptCommand === command else { return }
            self.scriptCommand = nil
            self.scriptRun?.running = false
            self.scriptRun?.outcome = outcome
            done(outcome)
        }
    }

    func cancelScript() {
        scriptCommand?.cancel()
    }

    // MARK: Lifetime

    func end() {
        resetFiles()
        folder = nil
        network = nil
        networkTicket &+= 1
        rulePreview = nil
        ruleTicket &+= 1
        cancelScript()
        scriptRun = nil
    }

    nonisolated static func sampleFiles() -> [PaletteFileHit] {
        let now = Date()
        return [
            PaletteFileHit(url: URL(fileURLWithPath: "/Users/Shared/Reports/Quarterly report.pdf"), date: now.addingTimeInterval(-3600), isFolder: false),
            PaletteFileHit(url: URL(fileURLWithPath: "/Users/Shared/Reports"), date: now.addingTimeInterval(-7200), isFolder: true),
            PaletteFileHit(url: URL(fileURLWithPath: "/Users/Shared/Lecture notes/Report outline.md"), date: now.addingTimeInterval(-86_400), isFolder: false),
        ]
    }
}

/// Alfred's Large Type: the text across the screen, any key or click to close.
@MainActor
enum AOMLargeType {
    private static var window: NSPanel?
    private static var monitor: Any?

    static func show(_ text: String) {
        hide()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.08, dy: screen.visibleFrame.height * 0.2)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LargeTypeView(text: text, size: frame.size))
        panel.orderFrontRegardless()
        window = panel
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { hide() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if window === panel { hide() } }
    }

    static func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
    }

    private struct LargeTypeView: View {
        let text: String
        let size: CGSize

        var body: some View {
            Text(text)
                .font(.system(size: Self.fontSize(for: text, in: size), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.2)
                .padding(40)
                .frame(width: size.width, height: size.height)
                .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .onTapGesture { AOMLargeType.hide() }
        }

        static func fontSize(for text: String, in size: CGSize) -> CGFloat {
            let longest = max(1, text.split(separator: "\n").map(\.count).max() ?? text.count)
            return min(220, max(28, size.width / CGFloat(longest) * 1.6))
        }
    }
}

/// 7.3 (Codex 7.2.3 report, recommended feature 5; 7.2.1 audit N05): a
/// folder and the filter typed in it, saved under a name and opened again
/// from the launcher's root search.
struct PaletteFolderFavorite: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var query: String

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@MainActor
final class PaletteFolderFavorites: ObservableObject {
    static let shared = PaletteFolderFavorites()
    static let key = "AOMLauncherFolderFavorites.v1"

    @Published private(set) var items: [PaletteFolderFavorite] = []
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview) ? nil : .standard)
        if let data = self.defaults?.data(forKey: Self.key), let saved = try? JSONDecoder().decode([PaletteFolderFavorite].self, from: data) {
            items = saved
        }
    }

    /// Returns the favorite dropped to make room (the oldest, past 30), if any.
    @discardableResult
    func add(_ url: URL, query: String) -> PaletteFolderFavorite? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        let name = trimmed.isEmpty ? base : "\(base) · \(trimmed)"
        items.removeAll { $0.path == url.path && $0.query == trimmed }
        items.insert(PaletteFolderFavorite(name: name, path: url.standardizedFileURL.path, query: trimmed), at: 0)
        var dropped: PaletteFolderFavorite?
        if items.count > 30 { dropped = items.last; items.removeLast(items.count - 30) }
        save()
        return dropped
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    func relocate(_ id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].path = url.standardizedFileURL.path
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
