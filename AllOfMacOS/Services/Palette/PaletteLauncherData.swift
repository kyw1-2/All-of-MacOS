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
    enum FileStatus: Equatable { case idle, searching, done(total: Int), failed }

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
        guard !text.isEmpty else { fileStatus = .idle; return }
        if PresetManager.isUIPreview { files = Self.sampleFiles(); fileStatus = .done(total: files.count); return }
        fileStatus = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.fileTicket == ticket else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
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
        fileStatus = .idle
    }

    // MARK: Browse

    @Published private(set) var folder: (url: URL, items: [PaletteFileHit], error: String?)?

    /// A folder's visible items, folders first, then by name.
    func browse(_ url: URL) {
        let listed = Self.listing(of: url)
        folder = (url, listed.items, listed.error)
    }

    nonisolated static func listing(of url: URL) -> (items: [PaletteFileHit], error: String?) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                                                                   options: [.skipsHiddenFiles])
            let items = urls.prefix(2_000).map { item -> PaletteFileHit in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
                return PaletteFileHit(url: item, date: values?.contentModificationDate,
                                      isFolder: values?.isDirectory == true && values?.isPackage != true)
            }
            return (sortedForBrowsing(items), nil)
        } catch {
            return ([], (error as NSError).code == NSFileReadNoPermissionError
                ? "macOS didn't let AOM read this folder. Allow it in System Settings › Privacy & Security › Files and Folders."
                : error.localizedDescription)
        }
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
        var snapshot = Network(local: address?.address, interface: address?.interface, checkingPublic: true,
                               wifi: NetworkTools.wifiDetails()?.lines ?? [], dns: NetworkTools.dnsServers())
        if PresetManager.isUIPreview {
            snapshot.checkingPublic = false
            snapshot.publicIP = "203.0.113.24"
            network = snapshot
            return
        }
        network = snapshot
        Task { [weak self] in
            var finished = snapshot
            do { finished.publicIP = try await NetworkTools.publicIP() } catch { finished.publicError = error.localizedDescription }
            finished.checkingPublic = false
            guard let self, self.networkTicket == ticket else { return }
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
