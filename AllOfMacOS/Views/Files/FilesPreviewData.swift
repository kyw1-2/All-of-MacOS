import AppKit

/// Sample data for isolated UI previews only (`PresetManager.isUIPreview`):
/// sample downloads, screenshots and shelf files inside the preview's own data
/// folder, never the person's real folders. Flags:
/// `--aom-preview-files-shelf` opens the Drop Shelf, `--aom-preview-files-panel`
/// shows the dialog panel beside an imaginary dialog.
@MainActor
enum FilesPreviewData {
    private static var seeded = false

    static func seed() {
        guard PresetManager.isUIPreview, !seeded, let root = PresetManager.previewDirectory else { return }
        seeded = true
        let base = root.appendingPathComponent("Files/Sample", isDirectory: true)
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        let shots = base.appendingPathComponent("Screenshots", isDirectory: true)
        let shelfFolder = base.appendingPathComponent("Shelf", isDirectory: true)
        let fileManager = FileManager.default
        for folder in [downloads, shots, shelfFolder] { try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true) }

        let now = Date()
        let downloadFiles: [(String, TimeInterval, Int)] = [
            ("Operating Systems - Lecture 7.pdf", 4 * 60, 2_400_000), ("Project Brief.docx", 38 * 60, 182_000),
            ("dataset-2026-10.csv", 2 * 3600, 5_100_000), ("Figma-mockups.zip", 5 * 3600, 48_000_000),
            ("KakaoTalk_Photo_2026-10-31.jpeg", 26 * 3600, 1_300_000), ("Rapidmg.dmg", 50 * 3600, 21_000_000)]
        for (name, age, size) in downloadFiles {
            let url = downloads.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: Data(count: min(size, 4096)))
            }
            try? fileManager.setAttributes([.creationDate: now.addingTimeInterval(-age), .modificationDate: now.addingTimeInterval(-age)],
                                           ofItemAtPath: url.path)
        }
        let shotFiles: [(String, TimeInterval, NSColor)] = [
            ("Screenshot 2026-10-31 at 14.02.11.png", 9 * 60, .systemBlue), ("Screenshot 2026-10-31 at 11.47.30.png", 2.5 * 3600, .systemOrange),
            ("Screenshot 2026-10-30 at 21.15.02.png", 20 * 3600, .systemGreen), ("Screen Recording 2026-10-30 at 18.03.55.png", 24 * 3600, .systemPurple)]
        for (name, age, color) in shotFiles {
            let url = shots.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) { try? sampleImage(color).write(to: url) }
            try? fileManager.setAttributes([.creationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let shelfFiles = ["Reading - Chapter 4.pdf", "Figure 2.png", "Assignment 3 notes.md"]
        var shelfURLs: [URL] = []
        for name in shelfFiles {
            let url = shelfFolder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                if url.pathExtension == "png" { try? sampleImage(.systemTeal).write(to: url) }
                else { fileManager.createFile(atPath: url.path, contents: Data("Sample".utf8)) }
            }
            shelfURLs.append(url)
        }
        if FilesShelfStore.shared.items.isEmpty { FilesShelfStore.shared.add(shelfURLs.reversed()) }

        let settings = FilesSettings.shared
        settings.dialogHelper = true
        settings.shakeOpensShelf = true
        settings.favoriteShortcuts = true
        if settings.excludedApps.isEmpty { settings.excludedApps = ["com.apple.Terminal"] }
        FilesRecentModel.shared.usePreviewFolders(downloads: downloads, screenshots: shots)

        let args = ProcessInfo.processInfo.arguments
        if args.contains("--aom-preview-files-shelf") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    let screen = NSScreen.main?.visibleFrame ?? .zero
                    let controller = FilesShelfPanelController.shared
                    controller.show(at: NSPoint(x: screen.midX + 380, y: screen.maxY - 120))
                    if let second = FilesShelfStore.shared.items.dropFirst().first { controller.model.selection = [second.id] }
                }
            }
        }
        if args.contains("--aom-preview-files-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { showDialogPanel(downloads: downloads) }
            }
        }
    }

    /// The dialog panel with sample lists beside an imaginary dialog at the
    /// screen's centre.
    private static func showDialogPanel(downloads: URL) {
        let model = FilesDialogHelper.shared.model
        let home = NSHomeDirectory()
        model.appName = "Pages"
        model.kind = .save
        model.finder = [FilesFolderEntry(path: home + "/Documents", source: .finder, detail: "Front Finder window"),
                        FilesFolderEntry(path: home + "/Desktop", source: .finder)]
        model.finderState = .ready
        model.favorites = FilesPath.defaultFavorites().map { FilesFolderEntry(path: $0, source: .favorite) }
        model.showsShortcuts = true
        model.recents = [FilesFolderEntry(path: downloads.path, source: .newestFile, date: Date(), detail: "Has Operating Systems - Lecture 7.pdf")]
        model.clipboard = FilesFolderEntry(path: home + "/Library", source: .clipboard, detail: "~/Library")
        model.status = .done("Went to Downloads")
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let dialog = CGRect(x: screen.midX - 420, y: 160, width: 640, height: 420)
        FilesDialogHelper.shared.panel.attach(to: dialog)
    }

    private static func sampleImage(_ color: NSColor) -> Data {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: color, ending: color.blended(withFraction: 0.5, of: .black) ?? color)?
            .draw(in: NSRect(origin: .zero, size: size), angle: -60)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 180, height: 110), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
