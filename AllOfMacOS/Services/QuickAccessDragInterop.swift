import AppKit

/// Use standard macOS file URL pasteboard types. Finder, Mail, webviews and
/// messenger attachment targets can inspect the same NSURL drag writer.
enum QuickAccessDragInterop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }
    }

}
