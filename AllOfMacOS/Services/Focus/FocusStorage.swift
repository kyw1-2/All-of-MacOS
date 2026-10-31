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

    static func load<T: Decodable>(_ type: T.Type, named name: String, in directory: URL) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
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

    static func remove(named name: String, in directory: URL) {
        let url = directory.appendingPathComponent(name)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for every pending write (tests and termination).
    static func flush() { queue.sync {} }
}
