import Foundation

/// One line of the activity log: which rule did what to which file, when,
/// and how it went. Undo works from `steps`.
struct FolderRuleActivity: Codable, Identifiable, Equatable {
    enum Result: String, Codable { case succeeded, skipped, failed, info }

    var id: UUID
    var date: Date
    var ruleID: UUID?
    var ruleName: String
    var folderName: String
    var fileName: String
    var result: Result
    /// What happened, step by step ("Moved to ~/Pictures/Screenshots · Tagged “Receipt”").
    var detail: String
    var steps: [FolderRuleStepRecord]
    var originalPath: String?
    var finalPath: String?
    var undone = false

    init(id: UUID = UUID(), date: Date, ruleID: UUID?, ruleName: String, folderName: String, fileName: String,
         result: Result, detail: String, steps: [FolderRuleStepRecord] = [], originalPath: String? = nil,
         finalPath: String? = nil) {
        self.id = id
        self.date = date
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.folderName = folderName
        self.fileName = fileName
        self.result = result
        self.detail = detail
        self.steps = steps
        self.originalPath = originalPath
        self.finalPath = finalPath
    }

    /// The activity line for a finished run.
    init(_ record: FolderRuleRunRecord, date: Date) {
        let outcome = record.outcome
        let result: Result
        if outcome.failed {
            result = .failed
        } else if outcome.steps.allSatisfy({ $0.result == .skipped }) {
            result = .skipped
        } else {
            result = .succeeded
        }
        let detail = outcome.failed
            ? "Couldn't finish: " + (outcome.failure ?? "a step failed.")
            : outcome.steps.map(\.summary).joined(separator: " · ")
        self.init(date: date, ruleID: record.ruleID, ruleName: record.ruleName, folderName: record.folderName,
                  fileName: record.fileName, result: result, detail: detail, steps: outcome.steps,
                  originalPath: record.originalPath, finalPath: outcome.finalURL?.path)
    }

    enum CodingKeys: String, CodingKey {
        case id, date, ruleID, ruleName, folderName, fileName, result, detail, steps, originalPath, finalPath, undone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        ruleID = try c.decodeIfPresent(UUID.self, forKey: .ruleID)
        ruleName = try c.decodeIfPresent(String.self, forKey: .ruleName) ?? ""
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        result = (try? c.decodeIfPresent(Result.self, forKey: .result)) ?? .info
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        steps = (try? c.decodeIfPresent([FolderRuleStepRecord].self, forKey: .steps)) ?? []
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
        finalPath = try c.decodeIfPresent(String.self, forKey: .finalPath)
        undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
    }

    var canUndo: Bool { !undone && steps.contains(where: \.canUndo) }
}

/// Reads and writes rules.json, activity.json and state.json under
/// Application Support/AllOfMacOS/FolderRules (a throwaway folder in UI
/// previews and tests). Writes are atomic; an unreadable rules.json is kept
/// beside the new one, never deleted.
final class FolderRulesStore: Sendable {
    let directory: URL

    init(directory: URL = FolderRulesStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        if let preview = PresetManager.previewDirectory {
            return preview.appendingPathComponent("FolderRules", isDirectory: true)
        }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AOMTestFolderRules-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/FolderRules", isDirectory: true)
    }

    var configURL: URL { directory.appendingPathComponent("rules.json") }
    var activityURL: URL { directory.appendingPathComponent("activity.json") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// The most activity kept: the newest 1,000 lines from the last 30 days.
    static let activityLimit = 1_000
    static let activityRetention: TimeInterval = 30 * 86_400

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    struct LoadedConfig {
        var config: FolderRulesConfig
        /// False on first launch (no rules.json yet).
        var existed: Bool
        /// Where an unreadable rules.json was set aside.
        var setAside: URL?
    }

    func loadConfig(defaults: () -> FolderRulesConfig) -> LoadedConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return LoadedConfig(config: defaults(), existed: false, setAside: nil)
        }
        if let config = try? Self.decoder().decode(FolderRulesConfig.self, from: data) {
            return LoadedConfig(config: config, existed: true, setAside: nil)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = directory.appendingPathComponent("rules.unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: configURL, to: aside)
        return LoadedConfig(config: defaults(), existed: false, setAside: aside)
    }

    func save(_ config: FolderRulesConfig) throws {
        try write(Self.encoder().encode(config), to: configURL)
    }

    func loadActivity() -> [FolderRuleActivity] {
        guard let data = try? Data(contentsOf: activityURL),
              let activity = try? Self.decoder().decode([FolderRuleActivity].self, from: data) else { return [] }
        return activity
    }

    func save(activity: [FolderRuleActivity]) throws {
        try write(Self.encoder().encode(activity), to: activityURL)
    }

    func loadMemory() -> FolderRuleMemory {
        guard let data = try? Data(contentsOf: stateURL),
              let memory = try? Self.decoder().decode(FolderRuleMemory.self, from: data) else { return FolderRuleMemory() }
        return memory
    }

    func save(memory: FolderRuleMemory) throws {
        try write(Self.encoder().encode(memory), to: stateURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Newest first, at most `activityLimit`, none older than the retention.
    static func trimmed(_ activity: [FolderRuleActivity], now: Date) -> [FolderRuleActivity] {
        Array(activity.filter { now.timeIntervalSince($0.date) < activityRetention }
            .sorted { $0.date > $1.date }
            .prefix(activityLimit))
    }
}

/// The folders Folder Rules starts with and the templates use. In isolated
/// UI previews they are sample folders inside the preview's data folder, so
/// a preview never reads or changes the real Downloads or Desktop.
enum FolderRulesLocations {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The preview's stand-ins for the user's folders, nil outside previews.
    static var sampleRoot: URL? {
        PresetManager.previewDirectory?.appendingPathComponent("FolderRulesSamples", isDirectory: true)
    }

    private static func sample(_ name: String) -> URL? {
        guard let root = sampleRoot else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var downloads: URL {
        sample("Downloads")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")
    }
    static var desktop: URL {
        sample("Desktop")
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop")
    }
    static var documents: URL {
        sample("Documents")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Documents")
    }
    static var pictures: URL {
        sample("Pictures")
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Pictures")
    }

    /// Where macOS saves screenshots (Screenshot app › Options › Save to),
    /// read from its preferences; the Desktop when unset.
    static var screenshots: URL {
        if sampleRoot != nil { return desktop }
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let path = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return desktop
    }

    static func defaultConfig() -> FolderRulesConfig {
        FolderRulesConfig(isEnabled: false, folders: [FolderRuleFolder(path: downloads.path), FolderRuleFolder(path: desktop.path)])
    }
}
