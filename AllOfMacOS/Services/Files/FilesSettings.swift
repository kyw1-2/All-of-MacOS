import Combine
import Foundation

/// How hard a shake has to be before the Drop Shelf opens.
enum FilesShakeSensitivity: String, CaseIterable, Identifiable, Codable {
    case low, medium, high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// The Files module's settings. Keys start with "AOMFiles" so Settings › Data ›
/// Reset Preferences resets them. Tests and UI previews use a private suite so
/// they never change the installed app's settings.
@MainActor
final class FilesSettings: ObservableObject {
    static let shared = FilesSettings()

    enum Key {
        static let dialogHelper = "AOMFilesDialogHelper"
        static let finderWindows = "AOMFilesDialogFinderWindows"
        static let recentFolders = "AOMFilesDialogRecentFolders"
        static let newestFiles = "AOMFilesDialogNewestFiles"
        static let clipboardPath = "AOMFilesDialogClipboardPath"
        static let shortcuts = "AOMFilesDialogShortcuts"
        static let favorites = "AOMFilesFavorites"
        static let excludedApps = "AOMFilesExcludedApps"
        static let shake = "AOMFilesShelfShake"
        static let shiftWhileDragging = "AOMFilesShelfShift"
        static let sensitivity = "AOMFilesShakeSensitivity"
    }

    /// The Open and Save dialog helper (off until turned on).
    @Published var dialogHelper: Bool { didSet { store(dialogHelper, Key.dialogHelper) } }
    @Published var showsFinderWindows: Bool { didSet { store(showsFinderWindows, Key.finderWindows) } }
    @Published var showsRecentFolders: Bool { didSet { store(showsRecentFolders, Key.recentFolders) } }
    /// Recent folders include the folders of the newest files in Downloads and on the Desktop.
    @Published var includesNewestFiles: Bool { didSet { store(includesNewestFiles, Key.newestFiles) } }
    @Published var showsClipboardPath: Bool { didSet { store(showsClipboardPath, Key.clipboardPath) } }
    /// ⌘⌥1–9 jump to the first nine favourites while a dialog is open.
    @Published var favoriteShortcuts: Bool { didSet { store(favoriteShortcuts, Key.shortcuts) } }
    /// Folder paths in the person's order.
    @Published var favorites: [String] { didSet { defaults.set(favorites, forKey: Key.favorites); changed() } }
    /// Bundle identifiers where neither the dialog panel nor the shake shelf appears.
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: Key.excludedApps); changed() } }
    /// Shaking the pointer while dragging files opens the Drop Shelf (off until turned on).
    @Published var shakeOpensShelf: Bool { didSet { store(shakeOpensShelf, Key.shake) } }
    /// Pressing Shift while dragging files also opens it.
    @Published var shiftOpensShelf: Bool { didSet { store(shiftOpensShelf, Key.shiftWhileDragging) } }
    @Published var sensitivity: FilesShakeSensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Key.sensitivity); changed() }
    }

    let defaults: UserDefaults
    /// Every change, after it is stored (the module restarts what it changes).
    let didChange = PassthroughSubject<Void, Never>()
    private static let isolatedDefaults = UserDefaults(suiteName: "AOMFiles-Isolated-\(UUID().uuidString)")!

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview) ? Self.isolatedDefaults : .standard)
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        dialogHelper = flag(Key.dialogHelper, false)
        showsFinderWindows = flag(Key.finderWindows, true)
        showsRecentFolders = flag(Key.recentFolders, true)
        includesNewestFiles = flag(Key.newestFiles, true)
        showsClipboardPath = flag(Key.clipboardPath, true)
        favoriteShortcuts = flag(Key.shortcuts, false)
        favorites = defaults.stringArray(forKey: Key.favorites) ?? FilesPath.defaultFavorites()
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        shakeOpensShelf = flag(Key.shake, false)
        shiftOpensShelf = flag(Key.shiftWhileDragging, false)
        sensitivity = defaults.string(forKey: Key.sensitivity).flatMap(FilesShakeSensitivity.init(rawValue:)) ?? .medium
    }

    private func store(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        changed()
    }

    private func changed() { didChange.send() }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func exclude(_ bundleID: String) {
        guard !bundleID.isEmpty, !isExcluded(bundleID) else { return }
        excludedApps.append(bundleID)
    }

    // MARK: Favourites

    func addFavorite(_ folder: URL) {
        let key = FilesPath.key(folder.path)
        guard !favorites.contains(where: { FilesPath.key($0) == key }) else { return }
        favorites.append(key)
    }

    func removeFavorite(_ path: String) {
        let key = FilesPath.key(path)
        favorites.removeAll { FilesPath.key($0) == key }
    }

    func isFavorite(_ path: String) -> Bool {
        let key = FilesPath.key(path)
        return favorites.contains { FilesPath.key($0) == key }
    }

    func moveFavorite(from source: Int, to destination: Int) {
        guard favorites.indices.contains(source), destination >= 0, destination <= favorites.count else { return }
        var list = favorites
        let item = list.remove(at: source)
        list.insert(item, at: min(destination, list.count))
        favorites = list
    }

    func resetFavorites() { favorites = FilesPath.defaultFavorites() }
}
