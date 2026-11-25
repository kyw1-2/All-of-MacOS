import AppKit
import SwiftUI

// Native Workbench 2 (D25, after Transmit's info inspector): Files keeps its
// places (favorites, recent folders) on the page and shows the selected
// file's information, path and commands in a trailing inspector, so where a
// file is, what it is and what can be done with it are read in one place.

/// A path as clickable folders, home shortened to "~".
enum FilesBreadcrumb {
    struct Crumb: Equatable, Identifiable {
        let name: String
        let url: URL
        var id: String { url.path }
    }

    /// The folders from the volume (or home) down to `url`'s parent, then the
    /// item itself. Home and the folders above it collapse into one "~".
    static func crumbs(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Crumb] {
        let standardized = url.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        var parts: [Crumb] = []
        var current = standardized
        while true {
            let path = current.path
            if path == homePath { parts.append(Crumb(name: "~", url: current)); break }
            if path == "/" { parts.append(Crumb(name: "/", url: current)); break }
            parts.append(Crumb(name: current.lastPathComponent, url: current))
            let parent = current.deletingLastPathComponent()
            if parent.path == path { break }
            current = parent
        }
        return parts.reversed()
    }
}

/// What the inspector reads about a file, once per selection, off the main thread.
struct FilesItemInfo: Equatable {
    var kind: String?
    var bytes: Int64?
    var created: Date?
    var modified: Date?
    var exists = true

    static func read(_ url: URL) -> FilesItemInfo {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return FilesItemInfo(exists: false) }
        let size = values.isDirectory == true ? nil : (values.fileSize ?? values.totalFileAllocatedSize).map { Int64($0) }
        return FilesItemInfo(kind: values.localizedTypeDescription, bytes: size,
                             created: values.creationDate, modified: values.contentModificationDate)
    }
}

struct FilesInfoInspector: View {
    let url: URL
    var sampleInfo: FilesItemInfo? = nil
    let quickLook: () -> Void
    let close: () -> Void
    @State private var info: FilesItemInfo?

    var body: some View {
        let info = sampleInfo ?? info
        let canOpen = info?.exists == true && sampleInfo == nil
        return AOMInspector {
            AOMInspectorSection("Selected Path", showsDivider: false) {
                AOMInspectorRow("Name", text: url.path == "/" ? "/" : url.lastPathComponent)
                if let info, !info.exists {
                    Label("This path is unavailable.", systemImage: "questionmark.folder")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.warningText)
                } else {
                    AOMInspectorRow("Kind", text: info?.kind ?? "…")
                    if let bytes = info?.bytes {
                        AOMInspectorRow("Size", text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                    if let created = info?.created {
                        AOMInspectorRow("Created", text: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let modified = info?.modified {
                        AOMInspectorRow("Modified", text: modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            AOMInspectorSection("Where") {
                // Each folder reveals itself in the Finder.
                AOMFlowLayout(spacing: AOMSpace.x0_5, lineSpacing: AOMSpace.x1) {
                    let crumbs = FilesBreadcrumb.crumbs(for: url)
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                        HStack(spacing: AOMSpace.x0_5) {
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(AOMFont.caption)
                                    .foregroundStyle(AOMColor.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            Button(crumb.name) { NSWorkspace.shared.activateFileViewerSelecting([crumb.url]) }
                                .buttonStyle(.link)
                                .font(AOMFont.callout)
                                .disabled(sampleInfo != nil || (crumb.url.path == url.path && !canOpen))
                                .help("Show “\(crumb.name)” in the Finder")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Path")
            }
            AOMInspectorSection("Actions") {
                HStack(spacing: AOMSpace.x2) {
                    Button("Open") { FilesFileActions.open([url]) }
                    Button("Quick Look", action: quickLook)
                }
                .disabled(!canOpen)
                HStack(spacing: AOMSpace.x2) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .disabled(!canOpen)
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
                Button("Close Inspector", action: close)
                    .buttonStyle(.link)
                    .font(AOMFont.callout)
            }
        }
        .task(id: url) {
            guard sampleInfo == nil else { return }
            self.info = nil
            let target = url
            let read = await Task.detached(priority: .utility) { FilesItemInfo.read(target) }.value
            guard !Task.isCancelled else { return }
            self.info = read
        }
    }
}
