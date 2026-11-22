import AppKit

/// Isolated previews only (`--aom-preview-snapshot <folder>`): once the
/// windows have settled (`--aom-preview-snapshot-delay <seconds>`, 4 by
/// default) every visible window draws its own view hierarchy into
/// `<folder>/window-<n>.png`, so a review needs no Screen Recording
/// permission for another process. The image is AppKit's own rendering
/// (`cacheDisplay`): the behind-window blur and system glass are not in it,
/// so it shows layout, type, panes and colours over a transparent backdrop.
/// The folder must be inside the temporary directory, like the preview's.
/// The delay counts from `start`, the end of any `--aom-preview-visit`.
@MainActor
enum AOMPreviewSnapshot {
    static func scheduleIfRequested(after start: TimeInterval = 0) {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-snapshot"),
              args.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.path.hasPrefix(temporary) else { return }
        var delay: TimeInterval = 4
        if let i = args.firstIndex(of: "--aom-preview-snapshot-delay"), args.indices.contains(i + 1),
           let value = Double(args[i + 1]), (0.5...60).contains(value) { delay = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + start + delay) {
            MainActor.assumeIsolated { write(to: folder) }
        }
    }

    private static func write(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 32 }
        for (number, window) in windows.enumerated() {
            // The frame view includes the toolbar and title bar.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("window-\(number).png"))
        }
    }
}

/// Isolated previews only. `--aom-preview-visit 2,5,6,2` selects those pages
/// (1-based, as `--aom-preview-tab`) 0.8 s apart, ending on the last, so a
/// review sees pages that were kept alive. `--aom-preview-search <text>` then
/// types the text into the selected page's toolbar search field.
@MainActor
enum AOMPreviewVisit {
    static let interval: TimeInterval = 0.8
    /// Time for the last page's toolbar to appear before searching.
    static let searchDelay: TimeInterval = 0.4

    static var pages: [AOMMainTab] {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-visit"),
              args.indices.contains(index + 1) else { return [] }
        return args[index + 1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { AOMMainTab.allCases.indices.contains($0 - 1) }
            .map { AOMMainTab.allCases[$0 - 1] }
    }

    static var searchText: String? {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-search"),
              args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    /// Starts the visits and the search; returns when the sequence ends,
    /// in seconds from now.
    static func runIfRequested(_ appState: AppState) -> TimeInterval {
        let pages = pages
        for (position, tab) in pages.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(position) * interval) {
                MainActor.assumeIsolated { appState.selectedMainTab = tab }
            }
        }
        var end = pages.isEmpty ? 0 : Double(pages.count - 1) * interval
        if let text = searchText {
            end += searchDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + end) {
                NotificationCenter.default.post(name: AOMToolbarSearchField.previewSearch, object: text)
            }
        }
        return end
    }
}
