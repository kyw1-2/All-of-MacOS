import AppKit
import Foundation

/// A browser AOM reads bookmarks from.
struct PaletteBrowser: Equatable, Hashable {
    let name: String
    let bundleID: String
    /// The Chromium user-data folder under ~/Library/Application Support;
    /// nil for Safari.
    let dataDirectory: String?

    var isChromium: Bool { dataDirectory != nil }

    static let safari = PaletteBrowser(name: "Safari", bundleID: "com.apple.Safari", dataDirectory: nil)
    /// Browsers that keep Chrome's `Bookmarks` JSON in each profile folder.
    static let chromiumFamily: [PaletteBrowser] = [
        PaletteBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", dataDirectory: "Google/Chrome"),
        PaletteBrowser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta", dataDirectory: "Google/Chrome Beta"),
        PaletteBrowser(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", dataDirectory: "Google/Chrome Canary"),
        PaletteBrowser(name: "Naver Whale", bundleID: "com.naver.Whale", dataDirectory: "Naver/Whale"),
        PaletteBrowser(name: "Brave", bundleID: "com.brave.Browser", dataDirectory: "BraveSoftware/Brave-Browser"),
        PaletteBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", dataDirectory: "Microsoft Edge"),
        PaletteBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", dataDirectory: "Vivaldi"),
        PaletteBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", dataDirectory: "Arc/User Data"),
        PaletteBrowser(name: "Chromium", bundleID: "org.chromium.Chromium", dataDirectory: "Chromium"),
    ]
}

struct PaletteBookmark: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
    /// Folders from the root: ["Bookmarks bar", "Dev"].
    let folder: [String]
    let browser: PaletteBrowser
    /// Chrome's profile folder ("Default", "Profile 1"), nil for Safari.
    let profileDirectory: String?
    /// The profile's display name ("Work"), when Chrome has more than one.
    let profileName: String?

    var folderPath: String { folder.joined(separator: " › ") }
}

enum PaletteBookmarkError: Error, Equatable {
    case notBookmarks
    /// Reading Safari's file needs Full Disk Access.
    case permissionDenied
}

enum PaletteBookmarkParser {
    /// Only web pages: bookmarklets (javascript:) and local or browser
    /// pages are left out, so choosing a result never runs a script.
    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(url.host ?? "").isEmpty
    }

    /// Chrome's `Bookmarks` JSON: roots bookmark_bar, other and synced, each a
    /// tree of `{"type": "folder", "children": […]}` and `{"type": "url"}`.
    static func chrome(_ data: Data, browser: PaletteBrowser, profileDirectory: String,
                       profileName: String?) throws -> [PaletteBookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw PaletteBookmarkError.notBookmarks }
        var result: [PaletteBookmark] = []
        let fallbackNames = ["bookmark_bar": "Bookmarks bar", "other": "Other bookmarks", "synced": "Mobile bookmarks"]
        func walk(_ node: [String: Any], folder: [String]) {
            guard result.count < 20_000 else { return }
            let type = node["type"] as? String
            if type == "url" {
                guard let raw = node["url"] as? String, let url = URL(string: raw), isOpenable(url) else { return }
                let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? raw
                let key = node["guid"] as? String ?? node["id"] as? String ?? "\(result.count)"
                result.append(PaletteBookmark(id: "\(browser.bundleID)|\(profileDirectory)|\(key)", title: name, url: url,
                                              folder: folder, browser: browser, profileDirectory: profileDirectory,
                                              profileName: profileName))
            } else if let children = node["children"] as? [[String: Any]] {
                let name = node["name"] as? String ?? ""
                let path = name.isEmpty ? folder : folder + [name]
                for child in children { walk(child, folder: path) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            guard var node = roots[key] as? [String: Any] else { continue }
            if (node["name"] as? String ?? "").isEmpty { node["name"] = fallbackNames[key] }
            walk(node, folder: [])
        }
        return result
    }

    /// Safari's Bookmarks.plist: WebBookmarkTypeList folders (BookmarksBar is
    /// Favorites), WebBookmarkTypeLeaf pages, and the Reading List.
    static func safari(_ data: Data) throws -> [PaletteBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["WebBookmarkType"] != nil || root["Children"] != nil else { throw PaletteBookmarkError.notBookmarks }
        var result: [PaletteBookmark] = []
        let folderNames = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]
        func walk(_ node: [String: Any], folder: [String]) {
            guard result.count < 20_000 else { return }
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let raw = node["URLString"] as? String, let url = URL(string: raw), isOpenable(url) else { return }
                let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? url.host ?? raw
                let key = node["WebBookmarkUUID"] as? String ?? "\(result.count)"
                result.append(PaletteBookmark(id: "\(PaletteBrowser.safari.bundleID)|\(key)", title: title, url: url,
                                              folder: folder, browser: .safari, profileDirectory: nil, profileName: nil))
            case "WebBookmarkTypeProxy":
                return // History
            default:
                let title = node["Title"] as? String ?? ""
                let path = title.isEmpty ? folder : folder + [folderNames[title] ?? title]
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, folder: path) }
            }
        }
        walk(root, folder: [])
        return result
    }

    /// Profile folders that hold bookmarks, with their names from Chrome's
    /// `Local State` (`profile.info_cache.<folder>.name`). Guest and System
    /// profiles are left out.
    static func chromeProfiles(localState: Data?, folders: [String]) -> [(directory: String, name: String?)] {
        var names: [String: String] = [:]
        if let localState, let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
           let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
            }
        }
        return folders
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, names[$0]) }
    }
}

enum PaletteBookmarkSearch {
    /// Bookmarks matching `query`: the title first, then the host, then the
    /// folder; one result per URL and browser profile; at most `limit`.
    static func results(_ bookmarks: [PaletteBookmark], query: String, limit: Int = 20) -> [PaletteBookmark] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var seen = Set<String>()
        let scored: [(PaletteBookmark, Int, Int)] = bookmarks.enumerated().compactMap { order, bookmark in
            guard let score = PaletteFuzzy.bestScore(trimmed, fields: [
                (bookmark.title, 0), (bookmark.url.host ?? "", 40), (bookmark.folderPath, 120),
            ]), score >= PaletteFuzzy.subsequenceFloor + 40 else { return nil }
            return (bookmark, score, order)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
            .filter { seen.insert("\($0.url.absoluteString)|\($0.browser.bundleID)|\($0.profileDirectory ?? "")").inserted }
            .prefix(limit).map { $0 }
    }
}

/// Reads every installed browser's bookmarks off the main thread and keeps
/// each file's result until the file changes (modification date and size).
final class PaletteBookmarkLoader: @unchecked Sendable {
    static let shared = PaletteBookmarkLoader()

    enum SafariAccess: Equatable {
        case readable
        /// The file exists but macOS refused it: Full Disk Access is off.
        case needsFullDiskAccess
        /// No Safari bookmarks file (or Safari isn't installed).
        case missing
    }

    struct Snapshot {
        var bookmarks: [PaletteBookmark]
        var safari: SafariAccess
    }

    private struct CacheEntry {
        let modified: Date?
        let size: Int?
        let bookmarks: [PaletteBookmark]
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    /// Files larger than this are not bookmarks worth parsing.
    static let maximumFileSize = 32 * 1024 * 1024

    /// Test seams.
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }

    func load() -> Snapshot {
        var all: [PaletteBookmark] = []
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for browser in PaletteBrowser.chromiumFamily where isInstalled(browser.bundleID) {
            guard let directory = browser.dataDirectory else { continue }
            let root = support.appendingPathComponent(directory, isDirectory: true)
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let localState = try? Data(contentsOf: root.appendingPathComponent("Local State"))
            let profiles = PaletteBookmarkParser.chromeProfiles(localState: localState, folders: folders)
            for profile in profiles {
                let file = root.appendingPathComponent(profile.directory, isDirectory: true).appendingPathComponent("Bookmarks")
                let name = profiles.count > 1 ? profile.name ?? profile.directory : nil
                all += cached(file) { data in
                    try PaletteBookmarkParser.chrome(data, browser: browser, profileDirectory: profile.directory, profileName: name)
                } ?? []
            }
        }
        var safari = SafariAccess.missing
        if isInstalled(PaletteBrowser.safari.bundleID) {
            // Read it directly: without Full Disk Access even a stat of the
            // file can fail, so "exists" can't tell missing from refused.
            let file = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
            do {
                all += try cachedThrowing(file) { try PaletteBookmarkParser.safari($0) }
                safari = .readable
            } catch PaletteBookmarkError.permissionDenied {
                safari = .needsFullDiskAccess
            } catch {
                safari = .missing // no file, or not a bookmarks file
            }
        }
        return Snapshot(bookmarks: all, safari: safari)
    }

    private func cached(_ file: URL, parse: (Data) throws -> [PaletteBookmark]) -> [PaletteBookmark]? {
        try? cachedThrowing(file, parse: parse)
    }

    private func cachedThrowing(_ file: URL, parse: (Data) throws -> [PaletteBookmark]) throws -> [PaletteBookmark] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        lock.lock()
        if let entry = cache[file.path], entry.modified == modified, entry.size == size {
            lock.unlock()
            return entry.bookmarks
        }
        lock.unlock()
        if let size, size > Self.maximumFileSize { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw PaletteBookmarkError.permissionDenied
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) {
            throw PaletteBookmarkError.permissionDenied
        }
        let bookmarks = try parse(data)
        lock.lock()
        cache[file.path] = CacheEntry(modified: modified, size: size, bookmarks: bookmarks)
        lock.unlock()
        return bookmarks
    }
}

enum PaletteBookmarkOpener {
    /// System Settings › Privacy & Security › Full Disk Access.
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Opens the bookmark in the browser it came from; a Chrome bookmark in
    /// its own profile (`--profile-directory`, handed to the running Chrome).
    @MainActor
    static func open(_ bookmark: PaletteBookmark, completion: @escaping (Error?) -> Void = { _ in }) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bookmark.browser.bundleID) else {
            NSWorkspace.shared.open(bookmark.url)
            completion(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if bookmark.browser.isChromium, let profile = bookmark.profileName != nil ? bookmark.profileDirectory : nil {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--profile-directory=\(profile)", bookmark.url.absoluteString]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        } else {
            NSWorkspace.shared.open([bookmark.url], withApplicationAt: app, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}
