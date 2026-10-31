import AppKit
import Foundation

/// What one opening of the ⌘K palette reads: the app that was in front
/// before it (for menu search and Copy Link), that app's menus, the
/// browsers' bookmarks and recent files. Everything starts when the palette
/// opens and stops when it closes; nothing runs while it is closed.
@MainActor
final class PaletteSession: ObservableObject {
    struct TargetApp: Equatable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        let version: String?
        let url: URL?
    }

    enum MenuState {
        case idle
        case loading
        case ready(PaletteMenuSnapshot)
        case failed(PaletteMenuIndex.Failure)
    }

    @Published private(set) var target: TargetApp?
    @Published private(set) var menu: MenuState = .idle
    @Published private(set) var bookmarks: [PaletteBookmark] = []
    @Published private(set) var safariAccess: PaletteBookmarkLoader.SafariAccess = .readable
    private var tasks: [Task<Void, Never>] = []
    private var icons: [String: NSImage] = [:]

    /// The most recently active app other than AOM.
    static func previousApp() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        for pid in AppActivationHistory.shared.recentPIDs() where pid != own {
            if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.activationPolicy == .regular {
                return app
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own,
           front.activationPolicy == .regular {
            return front
        }
        return nil
    }

    func begin() {
        guard tasks.isEmpty else { return }
        if PresetManager.isUIPreview {
            loadPreviewSamples()
            return
        }
        guard NSClassFromString("XCTestCase") == nil else { return }
        if let app = Self.previousApp() {
            let version = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            let target = TargetApp(pid: app.processIdentifier, name: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
                                   version: version, url: app.bundleURL)
            self.target = target
            menu = .loading
            tasks.append(Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    PaletteMenuIndex.shared.snapshot(pid: target.pid, appName: target.name, bundleID: target.bundleID,
                                                     version: target.version)
                }.value
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .success(let snapshot): self.menu = .ready(snapshot)
                case .failure(let failure): self.menu = .failed(failure)
                }
            })
        }
        tasks.append(Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { PaletteBookmarkLoader.shared.load() }.value
            guard let self, !Task.isCancelled else { return }
            self.bookmarks = snapshot.bookmarks
            self.safariAccess = snapshot.safari
        })
    }

    func end() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    var menuSnapshot: PaletteMenuSnapshot? {
        if case .ready(let snapshot) = menu { return snapshot }
        return nil
    }

    /// The icon for a file or app, read once per opening.
    func icon(forPath path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    // MARK: Actions (the palette has closed when these run)

    /// Activates the app the item belongs to and chooses the item.
    func choose(_ item: PaletteMenuItem) {
        guard let snapshot = menuSnapshot, let target else { return }
        guard !PresetManager.isUIPreview else { return }
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            let result = PaletteMenuIndex.shared.press(item, in: snapshot)
            guard result != .success else { return }
            await MainActor.run {
                GestureHUD.shared.show(title: "Couldn't Choose “\(item.title)”",
                                       detail: "Because \(PaletteMenuIndex.failureReason(result)).")
            }
        }
    }

    /// Copies a link to the item in front of the palette (a tab, files, a
    /// message, a document or the app).
    func copyLink(style: PaletteLinkFormat.Style) {
        guard let target, !PresetManager.isUIPreview else {
            GestureHUD.shared.show(title: "No Item to Link", detail: "Open a page, a file or a message first.")
            return
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                await PaletteLinkResolver.resolve(pid: target.pid, bundleID: target.bundleID, appName: target.name,
                                                  appURL: target.url)
            }.value
            guard !outcome.links.isEmpty, PaletteLinkFormat.write(outcome.links, style: style) else {
                GestureHUD.shared.show(title: "Couldn't Copy a Link", detail: outcome.note.map { "Because \($0)." })
                return
            }
            let what = outcome.links.count == 1 ? "“\(outcome.links[0].title)”" : "\(outcome.links.count) items"
            let detail = [what, outcome.note.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            GestureHUD.shared.show(title: style == .plainURL ? "Copied URL" : "Copied Link", detail: detail)
        }
    }

    // MARK: Preview

    /// Isolated screenshots show made-up menus, bookmarks and files, never
    /// the user's.
    private func loadPreviewSamples() {
        target = TargetApp(pid: 0, name: "Safari", bundleID: "com.apple.Safari", version: nil,
                           url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let nodes = [
            PaletteMenuNode(title: "File", children: [
                PaletteMenuNode(title: "New Window", commandCharacter: "N"),
                PaletteMenuNode(title: "New Private Window", commandCharacter: "N", commandModifiers: 1),
                PaletteMenuNode(title: "Export", children: [PaletteMenuNode(title: "Export as PDF…")]),
                PaletteMenuNode(title: "Print…", commandCharacter: "P"),
            ]),
            PaletteMenuNode(title: "Edit", children: [
                PaletteMenuNode(title: "Copy", commandCharacter: "C"),
                PaletteMenuNode(title: "Paste and Match Style", commandCharacter: "V", commandModifiers: 3),
            ]),
            PaletteMenuNode(title: "View", children: [
                PaletteMenuNode(title: "Show Tab Overview", commandCharacter: "\\", commandModifiers: 1),
                PaletteMenuNode(title: "Enter Full Screen", commandCharacter: "F", commandModifiers: 4),
            ]),
            PaletteMenuNode(title: "History", children: [PaletteMenuNode(title: "Show All History", commandCharacter: "Y")]),
            PaletteMenuNode(title: "Bookmarks", children: [
                PaletteMenuNode(title: "Add Bookmark…", commandCharacter: "D"),
                PaletteMenuNode(title: "Edit Bookmarks", commandCharacter: "B", commandModifiers: 2),
            ]),
        ]
        let items = PaletteMenuFlattener.flatten(nodes).map(\.item)
        menu = .ready(PaletteMenuSnapshot(pid: 0, appName: "Safari", bundleID: "com.apple.Safari", version: nil,
                                          items: items, elements: [:], readAt: Date()))
        let chrome = PaletteBrowser.chromiumFamily[0]
        func sample(_ title: String, _ url: String, _ folder: [String], _ browser: PaletteBrowser, _ profile: String?) -> PaletteBookmark {
            PaletteBookmark(id: url, title: title, url: URL(string: url)!, folder: folder, browser: browser,
                            profileDirectory: browser.isChromium ? "Default" : nil, profileName: profile)
        }
        bookmarks = [
            sample("University of Seoul Portal", "https://portal.uos.ac.kr/", ["Favorites", "School"], .safari, nil),
            sample("GitHub", "https://github.com/", ["Bookmarks bar"], chrome, "Work"),
            sample("Swift Forums", "https://forums.swift.org/", ["Bookmarks bar", "Dev"], chrome, "Work"),
            sample("Naver", "https://www.naver.com/", ["Bookmarks bar"], chrome, "Personal"),
        ]
        safariAccess = .readable
    }
}
