import Foundation

/// The CLI owns model availability. Read only its public picker fields and keep
/// the CLI default usable before the first catalog refresh or after a format change.
enum CodexModelCatalog {
    private struct Catalog: Decodable {
        struct Model: Decodable {
            let slug: String
            let display_name: String?
            let visibility: String?
        }
        let models: [Model]
    }

    static func options(_ data: Data) -> [AOMAIModelOption] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        var seen: Set<String> = ["default"]
        return catalog.models.compactMap { model in
            guard model.visibility == "list", !model.slug.isEmpty, seen.insert(model.slug).inserted else { return nil }
            return .init(id: model.slug, title: model.display_name ?? model.slug, detail: "Codex · " + model.slug)
        }
    }

    private static let lock = NSLock()
    private static var cachedDate: Date?
    private static var cachedOptions: [AOMAIModelOption] = []
    private static let file: URL = {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("models_cache.json")
    }()

    static func current() -> [AOMAIModelOption] {
        lock.lock()
        defer { lock.unlock() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let date = attributes[.modificationDate] as? Date else { return [] }
        if date != cachedDate {
            guard let data = try? Data(contentsOf: file) else { return [] }
            cachedOptions = options(data)
            cachedDate = date
        }
        return cachedOptions
    }
}
