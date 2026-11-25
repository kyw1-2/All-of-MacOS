import Foundation

/// One selection across the three lists; the same path can appear in more than one.
enum FilesLocationSelection: Equatable {
    case favorite(String)
    case download(URL)
    case screenshot(URL)

    var url: URL {
        switch self {
        case .favorite(let path): URL(fileURLWithPath: path, isDirectory: true)
        case .download(let url), .screenshot(let url): url
        }
    }
}

/// In-memory fixtures. Never substitute paths from the person’s real home folder.
enum FilesPageSamples {
    static var enabled: Bool {
        PresetManager.isUIPreview && CommandLine.arguments.contains("--aom-preview-sample-data")
    }

    static let downloadsFolder = URL(fileURLWithPath: "/Sample Files/Downloads", isDirectory: true)
    static let screenshotFolder = URL(fileURLWithPath: "/Sample Files/Screenshots", isDirectory: true)
    static let favorites = ["/Sample Files/Projects", "/Sample Files/References", "/Sample Files/Archive"]
    private static let now = Date()
    static let downloads = [
        FilesRecentFile(url: downloadsFolder.appendingPathComponent("Project brief.pdf"), added: now.addingTimeInterval(-420), size: 420_000, isFolder: false),
        FilesRecentFile(url: downloadsFolder.appendingPathComponent("Reference notes.txt"), added: now.addingTimeInterval(-1_200), size: 2_560, isFolder: false)
    ]
    static let screenshots = [
        FilesRecentFile(url: screenshotFolder.appendingPathComponent("Workbench.png"), added: now.addingTimeInterval(-3_600), size: 820_000, isFolder: false)
    ]

    static func info(for url: URL) -> FilesItemInfo? {
        guard enabled else { return nil }
        if let file = (downloads + screenshots).first(where: { $0.url == url }) {
            return FilesItemInfo(kind: file.url.pathExtension.uppercased() + " document", bytes: file.size, modified: file.added)
        }
        return FilesItemInfo(kind: "Folder", exists: url.path != favorites.last)
    }
}
