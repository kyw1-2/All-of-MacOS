import AppKit

/// Isolated previews only (`--aom-preview-snapshot <folder>`): once the
/// windows have settled (`--aom-preview-snapshot-delay <seconds>`, 4 by
/// default) every visible window draws its own view hierarchy into
/// `<folder>/window-<n>.png`, so a review needs no Screen Recording
/// permission for another process. The image is AppKit's own rendering
/// (`cacheDisplay`): the behind-window blur and system glass are not in it,
/// so it shows layout, type, panes and colours over a transparent backdrop.
/// The folder must be inside the temporary directory, like the preview's.
@MainActor
enum AOMPreviewSnapshot {
    static func scheduleIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-snapshot"),
              args.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.path.hasPrefix(temporary) else { return }
        var delay: TimeInterval = 4
        if let i = args.firstIndex(of: "--aom-preview-snapshot-delay"), args.indices.contains(i + 1),
           let value = Double(args[i + 1]), (0.5...60).contains(value) { delay = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { write(to: folder) }
        }
    }

    private static func write(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 100 }
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
