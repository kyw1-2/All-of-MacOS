import Foundation

class PresetManager {
    private static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AllOfMacOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A throwaway directory used instead of the real one when running under a
    /// test host.
    ///
    /// Detected from the loaded XCTest host,
    /// because the decision has to hold for every path into this type —
    /// `loadPreset`, `save`, and the trackpad database all resolve their
    /// location here.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var previewDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--aom-ui-preview"), args.indices.contains(index + 1) else { return nil }
        let directory = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return directory.path.hasPrefix(temporary) ? directory : nil
    }
    static var isUIPreview: Bool { previewDirectory != nil }
    private static let isolatedDirectory: URL? = {
        if let previewDirectory { return previewDirectory }
        guard isRunningTests else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOMTestPresets-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return dir
    }()

    static var backupDirectory: URL {
        // A test host must not write into the user's real backup folder; a run
        // of the suite would otherwise bury the genuine backups in noise and
        // push them out through the rolling limit.
        if let isolated = isolatedDirectory {
            return isolated
        }
        if let custom = UserDefaults.standard.string(forKey: "AOMBackupPath"),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".allofmacos_backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var backupsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "AOMBackupsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AOMBackupsEnabled") }
    }

    /// Maximum number of rolling backups to keep
    static var maxBackups: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "AOMMaxBackups")
            return stored > 0 ? stored : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: "AOMMaxBackups") }
    }

    /// Returns info about existing backups (date and file size)
    static func listBackups() -> [(date: Date, size: Int64, url: URL)] {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "json" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
            return files.compactMap { url in
                let vals = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let date = vals?.creationDate ?? .distantPast
                let size = Int64(vals?.fileSize ?? 0)
                return (date: date, size: size, url: url)
            }
        } catch {
            return []
        }
    }

    static var presetFilePath: String {
        (isolatedDirectory ?? defaultDirectory).appendingPathComponent("master_preset.json").path
    }

    private let persistenceQueue = DispatchQueue(label: "com.kyw.allofmacos.preset-io", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingSave: (preset: Preset, backup: Bool)?
    private var saveGeneration = 0

    private let presetsDirectory: URL
    private lazy var trackpadStore: TrackpadPresetStore? = {
        do { return try TrackpadPresetStore(url: presetsDirectory.appendingPathComponent("trackpad-v1.sqlite")) }
        catch { NSLog("[AOM] Trackpad database unavailable: %@", error.localizedDescription); return nil }
    }()
    private var masterPresetURL: URL {
        presetsDirectory.appendingPathComponent("master_preset.json")
    }

    init(directory: URL? = nil) {
        if let dir = directory {
            self.presetsDirectory = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else if let isolated = Self.isolatedDirectory {
            // A test host must never reach the user's real preset. Creating an
            // AppState in a test used to load the live master_preset.json and
            // then write it back, which destroyed the real configuration.
            self.presetsDirectory = isolated
            try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        } else {
            self.presetsDirectory = Self.defaultDirectory
        }
    }


    // MARK: - Backup

    /// All UserDefaults keys used by the app
    private static let userDefaultsKeys: [String] = {
        var keys = [
            "AOMGlobalEnabled",
            "AOMAccentColor",
            "AOMAppearance",
            "AOMPressDragThreshold",
            "AOMTipTapMinRestTime",
            "AOMSuppressMouseDuringDrawing",
            "launchAtLogin",
            "showMenuBarIcon"
        ]
        // Add per-gesture swipe velocity keys
        for gesture in TrackpadGesture.allCases {
            keys.append("AOMSwipeMinVelocity_\(gesture.rawValue)")
        }
        return keys
    }()

    private static func saveBackup(data: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let backupURL = backupDirectory.appendingPathComponent("preset_backup_\(timestamp).json")
        do {
            try data.write(to: backupURL, options: .atomic)
            NSLog("[AOM] Backup saved to %@", backupURL.path)
            pruneOldBackups()
        } catch {
            NSLog("[AOM] Failed to save backup: %@", error.localizedDescription)
        }
        // Also back up UserDefaults
        saveUserDefaultsBackup()
    }

    private static func saveUserDefaultsBackup() {
        var dict: [String: Any] = [:]
        for key in userDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                dict[key] = value
            }
        }
        guard !dict.isEmpty else { return }
        let url = backupDirectory.appendingPathComponent("settings_backup.plist")
        (dict as NSDictionary).write(to: url, atomically: true)
    }

    static func restoreUserDefaultsFromBackup() {
        let url = backupDirectory.appendingPathComponent("settings_backup.plist")
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return }
        NSLog("[AOM] Restoring UserDefaults from backup (%d keys)", dict.count)
        for (key, value) in dict {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private static func pruneOldBackups() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db // newest first
                }
            if files.count > maxBackups {
                for file in files.dropFirst(maxBackups) {
                    try? FileManager.default.removeItem(at: file)
                    NSLog("[AOM] Pruned old backup: %@", file.lastPathComponent)
                }
            }
        } catch {
            NSLog("[AOM] Failed to prune backups: %@", error.localizedDescription)
        }
    }

    /// Returns the most recent backup, if any.
    static func loadLatestBackup() -> Preset? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
            guard let latest = files.first else { return nil }
            NSLog("[AOM] Restoring from backup: %@", latest.path)
            let data = try Data(contentsOf: latest)
            return try PresetCodec.decode(data)
        } catch {
            NSLog("[AOM] Failed to load backup: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Load

    static func loadPreset() -> Preset? {
        let manager = PresetManager()
        defer { manager.flushPendingWrites() }
        return manager.loadPreset()
    }

    func loadPreset() -> Preset? {
        flushPendingWrites()
        return persistenceQueue.sync { readPreset() }
    }

    private func readPreset() -> Preset? {
        if let data = try? Data(contentsOf: masterPresetURL), let preset = try? PresetCodec.decode(data) {
            trackpadStore?.saveAsync(preset)
            return preset
        }
        // Recover the last fully committed graph before looking at rolling JSON backups.
        if let restored = try? trackpadStore?.load() {
            if FileManager.default.fileExists(atPath: masterPresetURL.path) {
                let preserved = presetsDirectory.appendingPathComponent("unreadable-preset-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at: masterPresetURL, to: preserved) }
                catch { return restored } // Never overwrite input that could not be preserved.
            }
            if let data = try? PresetCodec.encode(restored) { try? data.write(to: masterPresetURL, options: .atomic) }
            return restored
        }
        return Self.loadLatestBackup()
    }

    func flushPendingWrites() {
        pendingLock.lock()
        let pending = pendingSave
        pendingSave = nil
        saveGeneration += 1
        pendingLock.unlock()
        persistenceQueue.sync {
            if let pending { persist(pending.preset, createBackup: pending.backup) }
            trackpadStore?.flushPendingWrites()
        }
    }

    /// Text editors and sliders update runtime bindings immediately, but disk
    /// encoding, SQLite and rolling backups are coalesced on a serial worker.
    func scheduleSave(_ preset: Preset) {
        let backup = Self.backupsEnabled
        pendingLock.lock()
        saveGeneration += 1
        let generation = saveGeneration
        pendingSave = (preset, backup)
        pendingLock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + 0.25) { [self] in
            pendingLock.lock()
            let pending = generation == saveGeneration ? pendingSave : nil
            if pending != nil { pendingSave = nil }
            pendingLock.unlock()
            if let pending { persist(pending.preset, createBackup: pending.backup) }
        }
    }

    // MARK: - Save

    func save(_ preset: Preset, createBackup: Bool = true) {
        flushPendingWrites()
        persistenceQueue.sync { persist(preset, createBackup: createBackup) }
    }

    private func persist(_ preset: Preset, createBackup: Bool) {
        do {
            let data = try PresetCodec.encode(preset)
            _ = try PresetCodec.decode(data)
            try data.write(to: masterPresetURL, options: .atomic)
            trackpadStore?.saveAsync(preset)
            if createBackup {
                Self.saveBackup(data: data)
            }
        } catch {
            print("Failed to save preset: \(error)")
        }
    }

    func save(_ preset: Preset) {
        save(preset, createBackup: Self.backupsEnabled)
    }

    func exportPreset(_ preset: Preset, to url: URL) {
        do {
            let data = try PresetCodec.encode(preset, envelope: true)
            _ = try PresetCodec.decode(data)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to export preset: \(error)")
        }
    }

    func importPreset(from url: URL) -> Preset? {
        do {
            let data = try Data(contentsOf: url)
            return try PresetCodec.decode(data)
        } catch {
            print("Failed to import preset: \(error)")
            return nil
        }
    }
}
