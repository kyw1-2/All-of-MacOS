import Foundation

struct AOMSharedImages: Equatable {
    enum Mode: String { case annotate, pin }
    let mode: Mode
    let files: [URL]

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "aom", url.host?.lowercased() == "share-images",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/" else { return nil }
        let items = components.queryItems ?? []
        guard items.allSatisfy({ $0.name == "mode" || $0.name == "file" }),
              items.filter({ $0.name == "mode" }).count == 1,
              let value = items.first(where: { $0.name == "mode" })?.value,
              let mode = Mode(rawValue: value) else { return nil }
        let paths = items.filter { $0.name == "file" }.compactMap(\.value)
        guard (1...8).contains(paths.count), items.count == paths.count + 1,
              paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return nil }
        return Self(mode: mode, files: paths.map { URL(fileURLWithPath: $0) })
    }
}
