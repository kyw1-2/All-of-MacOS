import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 7.5: the windows the file tools open (ZIP contents, Compare PDFs,
/// Compare Folders). Each is an ordinary window, so several can be open
/// beside the app; asking for one that is open brings it forward.
@MainActor
final class AOMToolWindows: NSObject, NSWindowDelegate {
    static let shared = AOMToolWindows()
    private var windows: [String: NSWindow] = [:]

    /// Opens `content` in a window keyed by `key` (a file path, or a new id
    /// for one more window of the kind).
    func show<Content: View>(_ key: String, title: String, size: NSSize, minSize: NSSize, autosave: String,
                             @ViewBuilder content: () -> Content) {
        if let window = windows[key] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: content().background(AOMColor.canvas))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(autosave)
        if windows.isEmpty { window.center() } else if let last = windows.values.first {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        window.delegate = self
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        windows[key] = nil
    }

    func close(_ key: String) { windows[key]?.close() }
}

/// A flag one thread sets and another reads (Stop buttons).
final class AOMCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// 7.5: how the file tools open their windows, from the Files page, the
/// shelf and the launcher alike.
@MainActor
enum AOMFileToolsLauncher {
    static func pick(_ message: String, types: [String], multiple: Bool = false, directories: Bool = false) -> [URL]? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        if !types.isEmpty { panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    /// Extract from ZIP: the archive's entries to search and pick from.
    static func openZip(_ url: URL? = nil) {
        guard let archive = url ?? pick("Choose a ZIP archive; pick the files you need from it.", types: ["zip"])?.first else { return }
        let model = ZipExtractModel(archive: archive)
        AOMToolWindows.shared.show("zip:" + archive.path, title: archive.lastPathComponent, size: NSSize(width: 760, height: 560),
                                   minSize: NSSize(width: 560, height: 380), autosave: "AOMZipWindow") {
            ZipExtractView(model: model)
        }
        model.load()
    }

    /// Compare PDFs: two PDFs side by side. With fewer than two given, the rest are asked for.
    static func comparePDFs(_ urls: [URL] = []) {
        var files = Array(urls.prefix(2))
        if files.count < 2 {
            guard let picked = pick(files.isEmpty ? "Choose two PDFs to read side by side (⌘-click the second)." : "Choose the PDF to compare with \(files[0].lastPathComponent).",
                                    types: ["pdf"], multiple: files.isEmpty) else { return }
            files += picked
        }
        let model = PDFCompareModel()
        if let first = files.first { model.open(first, side: .left) }
        if files.count > 1 { model.open(files[1], side: .right) }
        AOMToolWindows.shared.show("pdf:" + UUID().uuidString, title: "Compare PDFs", size: NSSize(width: 1180, height: 780),
                                   minSize: NSSize(width: 760, height: 480), autosave: "AOMPDFCompareWindow") {
            PDFCompareView(model: model)
        }
    }

    /// Compare Folders: what one folder has that the other doesn't.
    static func compareFolders(_ urls: [URL] = []) {
        let model = FolderCompareModel()
        model.left = urls.first
        model.right = urls.count > 1 ? urls[1] : nil
        AOMToolWindows.shared.show("folders:" + UUID().uuidString, title: "Compare Folders", size: NSSize(width: 960, height: 640),
                                   minSize: NSSize(width: 680, height: 420), autosave: "AOMFolderCompareWindow") {
            FolderCompareView(model: model)
        }
        if model.left != nil, model.right != nil { model.compare() }
    }
}
