import Foundation

/// Where Focus keeps its files, and small JSON helpers.
///
/// - App: ~/Library/Application Support/AllOfMacOS/Focus/
/// - Isolated UI preview: <preview data folder>/Focus/
/// - Unit tests: a per-process folder in the temporary directory (tests
///   that need a clean folder pass their own).
///
/// Lists people make (distracting apps, idle-app rules, input-source rules)
/// and the logs live here, not in UserDefaults, so Settings › Data › Reset
/// Preferences never deletes them; it only resets `FocusSettings`.
enum FocusStorage {
    static let folderName = "Focus"
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.focus.storage", qos: .utility)

    static var defaultDirectory: URL {
        if let preview = PresetManager.previewDirectory {
            return preview.appendingPathComponent(folderName, isDirectory: true)
        }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AOMTestFocus-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AllOfMacOS", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// For files that hold no history (the timer's state): anything that
    /// can't be read starts fresh. Lists and logs use `loadChecked`.
    static func load<T: Decodable>(_ type: T.Type, named name: String, in directory: URL) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    /// What reading a file found. Only a missing file starts fresh.
    enum Loaded<T> {
        case missing
        case loaded(T)
        /// It couldn't be decoded and was moved aside to `URL`, so saving
        /// a new one loses nothing.
        case setAside(URL)
        /// It is there (at `URL`) but couldn't be read or moved aside:
        /// nothing may be saved over it. Says why.
        case blocked(URL, String)

        var value: T? { if case .loaded(let value) = self { return value }; return nil }

        /// The Focus page's notice; `what` names the data ("Your focus history").
        func problem(_ what: String) -> FocusDataProblem? {
            switch self {
            case .missing, .loaded: return nil
            case .setAside(let aside):
                return FocusDataProblem(title: "\(what) couldn't be read", file: aside, blocksSaving: false,
                                        detail: "It was kept as \(aside.lastPathComponent) in the Focus data folder, and Focus started a new one.")
            case .blocked(let file, let reason):
                return FocusDataProblem(title: "\(what) can't be saved", file: file, blocksSaving: true, detail: reason)
            }
        }
    }

    /// 7.2.3 (audit B08): an unreadable sessions.json was taken for an empty
    /// log and replaced at the next save. As Folder Rules does with
    /// rules.json, a file that can't be decoded is kept as
    /// "<name>.unreadable-<date>.json" before anything is saved, and one that
    /// can't be read at all blocks saving.
    static func loadChecked<T: Decodable>(_ type: T.Type, named name: String, in directory: URL,
                                          now: Date = Date()) -> Loaded<T> {
        let url = directory.appendingPathComponent(name)
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            return .blocked(url, "\(name) is there but couldn't be read, so Focus won't save over it. Check its permissions, then reopen All of MacOS.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(T.self, from: data) { return .loaded(value) }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = (name as NSString).deletingPathExtension
        var aside = directory.appendingPathComponent("\(base).unreadable-\(stamp).json")
        var copy = 2
        while files.fileExists(atPath: aside.path) {
            aside = directory.appendingPathComponent("\(base).unreadable-\(stamp) \(copy).json")
            copy += 1
        }
        do {
            try files.moveItem(at: url, to: aside)
            NSLog("[AOM] Focus couldn't read %@; kept it as %@", name, aside.lastPathComponent)
            return .setAside(aside)
        } catch {
            return .blocked(url, "\(name) couldn't be read or set aside, so Focus won't save over it.")
        }
    }

    /// Encodes on the caller's thread and writes atomically on a utility queue.
    static func save<T: Encodable>(_ value: T, named name: String, in directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let url = directory.appendingPathComponent(name)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[AOM] Focus could not save %@: %@", name, error.localizedDescription)
            }
        }
    }

    /// Waits for every pending write (tests and termination).
    static func flush() { queue.sync {} }
}

/// A Focus file that couldn't be read, shown on the Focus page with Show in
/// Finder (7.2.3, audit B08).
struct FocusDataProblem: Equatable {
    var title: String
    /// The copy that was kept, or the file nothing is saved over.
    var file: URL
    var blocksSaving: Bool
    var detail: String
}
