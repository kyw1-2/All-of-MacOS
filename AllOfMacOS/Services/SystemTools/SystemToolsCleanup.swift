import AppKit

/// One file or folder a cleanup scan proposes. Nothing is touched until the
/// user reviews the list and moves the selected items to the Trash.
struct CleanupCandidate: Identifiable, Equatable, Hashable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    /// Why it is listed ("Preferences", "Not opened for 94 days").
    let note: String
}

/// Scans for the AppCleaner / Pearcleaner style tools and moves what the
/// user picked to the Trash. The new cleanup tools never delete permanently:
/// everything goes through `FileManager.trashItem`, so Put Back works.
enum CleanupTools {
    struct TrashOutcome: Equatable {
        var moved: [URL] = []
        var freed: Int64 = 0
        /// "name: reason" per item that stayed.
        var failures: [String] = []

        var summary: String {
            let base = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") (\(SystemStatus.size(freed))) to the Trash"
            guard !failures.isEmpty else { return base }
            return base + "; \(failures.count) could not be moved: " + failures.prefix(3).joined(separator: "; ")
                + (failures.count > 3 ? "; …" : "")
        }
    }

    static func moveToTrash(_ candidates: [CleanupCandidate], fileManager: FileManager = .default) -> TrashOutcome {
        var outcome = TrashOutcome()
        for candidate in candidates {
            do {
                try fileManager.trashItem(at: candidate.url, resultingItemURL: nil)
                outcome.moved.append(candidate.url)
                outcome.freed += candidate.size
            } catch {
                let reason = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? error.localizedDescription
                outcome.failures.append("\(candidate.url.lastPathComponent): \(reason)")
            }
        }
        return outcome
    }

    /// Allocated size of a file or a whole folder tree (packages included).
    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            let size = (try? file.resourceValues(forKeys: keys)).flatMap { $0.totalFileAllocatedSize ?? $0.fileAllocatedSize } ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - App uninstaller

    /// Decides which ~/Library entries belong to an app. Bundle-ID matches
    /// need a dot boundary ("com.foo.app" matches "com.foo.app.plist" and
    /// "ABCDE12345.com.foo.app" but never "com.foo.application"). Name
    /// matches are exact (case-insensitive) and only in the folders that are
    /// named after apps, and only for names of four or more characters.
    struct LeftoverMatcher: Equatable {
        let bundleID: String
        let appName: String

        /// Folders under ~/Library and whether app-name matches count there.
        static let locations: [(path: String, label: String, matchesName: Bool)] = [
            ("Application Support", "Application Support", true),
            ("Caches", "Caches", true),
            ("Preferences", "Preferences", false),
            ("Preferences/ByHost", "Preferences", false),
            ("Containers", "Container", false),
            ("Group Containers", "Group Container", false),
            ("Saved Application State", "Saved State", false),
            ("Logs", "Logs", true),
            ("HTTPStorages", "Web Data", false),
            ("WebKit", "Web Data", false),
            ("Cookies", "Cookies", false),
            ("LaunchAgents", "Launch Agent", false),
            ("Application Scripts", "Scripts", false)
        ]

        func matches(_ fileName: String, allowNameMatch: Bool) -> Bool {
            let id = bundleID.lowercased()
            let name = fileName.lowercased()
            guard id.count >= 3 else { return false }
            // A two-part ID ("com.foo") could be a vendor prefix shared by
            // other apps, so it only matches itself plus a file extension.
            if id.split(separator: ".").count < 3 {
                if name == id || [".plist", ".savedstate", ".binarycookies"].contains(where: { name == id + $0 }) { return true }
            } else if containsAtBoundary(name, id) {
                return true
            }
            guard allowNameMatch else { return false }
            let app = appName.lowercased().trimmingCharacters(in: .whitespaces)
            return app.count >= 4 && name == app
        }

        /// `id` appears in `name` with a dot (or the string edge) on both sides.
        private func containsAtBoundary(_ name: String, _ id: String) -> Bool {
            var searchRange = name.startIndex..<name.endIndex
            while let found = name.range(of: id, range: searchRange) {
                let beforeOK = found.lowerBound == name.startIndex || name[name.index(before: found.lowerBound)] == "."
                let afterOK = found.upperBound == name.endIndex || name[found.upperBound] == "."
                if beforeOK && afterOK { return true }
                searchRange = name.index(after: found.lowerBound)..<name.endIndex
            }
            return false
        }
    }

    enum UninstallRefusal: LocalizedError, Equatable {
        case notAnApp, systemApp, isAOM, running(String)
        var errorDescription: String? {
            switch self {
            case .notAnApp: return "That isn't an app bundle with a bundle identifier."
            case .systemApp: return "Apps that ship with macOS can't be removed."
            case .isAOM: return "All of MacOS can't uninstall itself from here."
            case .running(let name): return "\(name) is running. Quit it first, then uninstall it."
            }
        }
    }

    /// The app bundle plus its leftovers under `library` (the user's
    /// ~/Library; tests pass a temporary folder). Nothing is moved here.
    static func uninstallPlan(for app: URL, library: URL,
                              isRunning: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) throws -> [CleanupCandidate] {
        guard app.pathExtension == "app", let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier else {
            throw UninstallRefusal.notAnApp
        }
        let path = app.standardizedFileURL.path
        if path.hasPrefix("/System/") || bundleID.hasPrefix("com.apple.") { throw UninstallRefusal.systemApp }
        if bundleID.hasPrefix("com.kyw.allofmacos") { throw UninstallRefusal.isAOM }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? app.deletingPathExtension().lastPathComponent
        if isRunning(bundleID) { throw UninstallRefusal.running(name) }

        var plan = [CleanupCandidate(url: app, size: allocatedSize(app), note: "App")]
        plan += leftovers(bundleID: bundleID, appName: name, library: library)
        return plan
    }

    static func leftovers(bundleID: String, appName: String, library: URL) -> [CleanupCandidate] {
        let matcher = LeftoverMatcher(bundleID: bundleID, appName: appName)
        var found: [CleanupCandidate] = []
        var seen = Set<String>()
        for location in LeftoverMatcher.locations {
            let folder = library.appendingPathComponent(location.path, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for entry in names.sorted() where matcher.matches(entry, allowNameMatch: location.matchesName) {
                let url = folder.appendingPathComponent(entry)
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                found.append(CleanupCandidate(url: url, size: allocatedSize(url), note: location.label))
            }
        }
        return found
    }

    // MARK: - Large files

    /// Files at least `minimumBytes` under `root`, largest first, at most
    /// `limit`. Hidden items and package contents are skipped (an .app or a
    /// Photos library is one item for Finder too), and so is ~/Library.
    static func largeFiles(in root: URL, minimumBytes: Int64, limit: Int = 200,
                           isCancelled: () -> Bool = { false }) -> [CleanupCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let skipped = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return [] }
        var found: [CleanupCandidate] = []
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            if url.standardizedFileURL.path == skipped { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if size >= minimumBytes {
                found.append(CleanupCandidate(url: url, size: size, note: url.deletingLastPathComponent().path
                    .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")))
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }

    // MARK: - Old downloads

    /// An item is old when neither added, modified nor opened within `days`.
    static func isOld(added: Date?, modified: Date?, opened: Date?, now: Date, days: Int) -> Bool {
        let newest = [added, modified, opened].compactMap { $0 }.max()
        guard let newest else { return false }
        return now.timeIntervalSince(newest) >= TimeInterval(days) * 86_400
    }

    static func oldDownloads(in folder: URL, days: Int, now: Date = Date()) -> [CleanupCandidate] {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> CleanupCandidate? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  isOld(added: values.addedToDirectoryDate, modified: values.contentModificationDate,
                        opened: values.contentAccessDate, now: now, days: days) else { return nil }
            let newest = [values.addedToDirectoryDate, values.contentModificationDate, values.contentAccessDate].compactMap { $0 }.max() ?? now
            let age = Int(now.timeIntervalSince(newest) / 86_400)
            return CleanupCandidate(url: url, size: allocatedSize(url), note: "Untouched for \(age) days")
        }.sorted { $0.size > $1.size }
    }

    // MARK: - Developer junk

    /// Rebuildable Xcode data: build products, simulator caches and device
    /// support files Xcode downloads again when a device is connected.
    /// Archives (signed builds) are never listed.
    static let developerJunkFolders: [(path: String, note: String)] = [
        ("Developer/Xcode/DerivedData", "Xcode build data"),
        ("Developer/CoreSimulator/Caches", "Simulator caches"),
        ("Developer/Xcode/iOS DeviceSupport", "iOS device support"),
        ("Developer/Xcode/watchOS DeviceSupport", "watchOS device support"),
        ("Caches/com.apple.dt.Xcode", "Xcode caches")
    ]

    static func developerJunk(library: URL) -> [CleanupCandidate] {
        developerJunkFolders.flatMap { folder -> [CleanupCandidate] in
            let url = library.appendingPathComponent(folder.path, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
            return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
                let item = url.appendingPathComponent(name)
                return CleanupCandidate(url: item, size: allocatedSize(item), note: folder.note)
            }
        }.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }
}
