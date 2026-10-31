import AppKit
import Foundation

/// Where Files keeps its data: Application Support/AllOfMacOS/Files, an
/// isolated folder in UI previews and a per-process temp folder in tests.
enum FilesStorage {
    static var directory: URL {
        if let preview = PresetManager.previewDirectory {
            return preview.appendingPathComponent("Files", isDirectory: true)
        }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AOMTestFiles-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/Files", isDirectory: true)
    }

    static var shelfFile: URL { directory.appendingPathComponent("shelf.json") }
    static var recentFoldersFile: URL { directory.appendingPathComponent("recent-folders.json") }
    /// Files the shelf received from apps that promise files (an image dragged
    /// out of Safari) rather than handing over a file that already exists.
    static var receivedFolder: URL { directory.appendingPathComponent("Received", isDirectory: true) }
}

/// Path rules shared by the dialog helper, the shelf and the recent lists.
enum FilesPath {
    /// `~` and `~/…` expanded against `home`; other text unchanged.
    static func expandTilde(_ raw: String, home: String = NSHomeDirectory()) -> String {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + raw.dropFirst(1) }
        if raw.hasPrefix("~") { return (raw as NSString).expandingTildeInPath }
        return raw
    }

    /// The comparable form of a path: absolute, `.` and `..` removed, symbolic
    /// links resolved, no trailing slash. Two spellings of one folder share it.
    static func key(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = expandTilde(path, home: home)
        guard expanded.hasPrefix("/") else { return expanded }
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// The folder a jump goes to: `~` expanded, symbolic links resolved, and a
    /// file (or a package such as an app) replaced by the folder it is in.
    /// Nil when nothing exists at the path or it is not absolute.
    static func jumpFolder(for raw: String, fileManager: FileManager = .default,
                           home: String = NSHomeDirectory()) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = expandTilde(trimmed, home: home)
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: key(expanded, home: home))
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue && !isPackage(url) { return url }
        let parent = url.deletingLastPathComponent()
        return parent.path.isEmpty ? URL(fileURLWithPath: "/") : parent
    }

    /// Bundles (apps, .rtfd, Photos libraries) open like files in a dialog.
    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// "Downloads", or the Finder's name for the folder ("iCloud Drive").
    static func displayName(_ path: String) -> String {
        if path == "/" { return FileManager.default.displayName(atPath: "/") }
        if path == iCloudDrivePath { return "iCloud Drive" }
        return FileManager.default.displayName(atPath: path)
    }

    /// "~/Downloads/Invoices" for paths inside the home folder; "iCloud Drive/…"
    /// for iCloud Drive, as the Finder names it.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloud { return "iCloud Drive" }
        if path.hasPrefix(iCloud + "/") { return "iCloud Drive" + path.dropFirst(iCloud.count) }
        // UI previews keep their sample folders in the preview's data folder;
        // they read like the home folder they stand in for.
        if let sample = previewSampleRoot {
            let resolved = key(path, home: home)
            if resolved == sample || resolved.hasPrefix(sample + "/") { return "~" + resolved.dropFirst(sample.count) }
        }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static var previewSampleRoot: String? {
        guard let preview = PresetManager.previewDirectory else { return nil }
        return key(preview.appendingPathComponent("Files/Sample").path)
    }

    static var iCloudDrivePath: String {
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    /// The default favourites: Desktop, Documents, Downloads and iCloud Drive
    /// (iCloud Drive only when it is set up on this Mac).
    static func defaultFavorites(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [String] {
        var paths = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if fileManager.fileExists(atPath: iCloud) { paths.append(iCloud) }
        return paths
    }
}

/// The clipboard's path for the dialog helper: a file URL on the clipboard, or
/// one line of text that is a POSIX path ("/…", "~/…", "file:///…", quoted or
/// with shell escapes) to an item that exists. The result is the item's folder
/// (the item itself when it is a folder). The text is parsed and forgotten;
/// nothing is stored.
enum FilesClipboardPath {
    static let maximumLength = 2048

    static func folder(fileURLs: [URL], string: String?, fileManager: FileManager = .default,
                       home: String = NSHomeDirectory()) -> URL? {
        if let url = fileURLs.first(where: \.isFileURL) {
            return FilesPath.jumpFolder(for: url.path, fileManager: fileManager, home: home)
        }
        guard let string else { return nil }
        for candidate in candidates(from: string) {
            if let folder = FilesPath.jumpFolder(for: candidate, fileManager: fileManager, home: home) { return folder }
        }
        return nil
    }

    /// The spellings worth checking, most literal first. Empty when the text
    /// is not a single-line absolute or home-relative path.
    static func candidates(from string: String) -> [String] {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength, !text.contains("\n"), !text.contains("\r") else { return [] }
        for quote in ["\"", "'", "“"] {
            let closing = quote == "“" ? "”" : quote
            if text.count >= 2, text.hasPrefix(quote), text.hasSuffix(closing) {
                text = String(text.dropFirst().dropLast())
                break
            }
        }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return [] }
            return [url.path]
        }
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return [] }
        var result = [text]
        let unescaped = unescapeShell(text)
        if unescaped != text { result.append(unescaped) }
        return result
    }

    /// "My\ Folder/It\'s" → "My Folder/It's" (Terminal's drag-and-drop style).
    static func unescapeShell(_ text: String) -> String {
        var output = ""
        var escaping = false
        for character in text {
            if escaping { output.append(character); escaping = false }
            else if character == "\\" { escaping = true }
            else { output.append(character) }
        }
        if escaping { output.append("\\") }
        return output
    }

    /// Reads the general pasteboard without asking: on macOS 15.4 and later
    /// only when the system already allows this app to read it, so the dialog
    /// helper never causes a paste alert.
    @MainActor
    static func current(pasteboard: NSPasteboard = .general) -> URL? {
        if #available(macOS 15.4, *) {
            guard pasteboard.accessBehavior == .alwaysAllow else { return nil }
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let text = urls.isEmpty ? pasteboard.string(forType: .string) : nil
        return folder(fileURLs: urls, string: text)
    }
}

/// File-name rules for Move To, Copy To and Compress: never overwrite.
enum FilesNaming {
    /// "Report.pdf" → "Report 2.pdf" → "Report 3.pdf" (the Finder's style)
    /// until nothing exists at the name; `exists` is injectable for tests.
    static func uniqueDestination(for name: String, in folder: URL,
                                  exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// The archive name the Finder uses: "Report.pdf.zip" for one item,
    /// "Archive.zip" for several.
    static func archiveName(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
    }
}
