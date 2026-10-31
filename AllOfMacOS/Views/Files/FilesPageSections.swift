import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Favorites

/// One favorite folder: the Finder icon, name and ~ path, its ⌘⌥ shortcut,
/// Remove. Finder folders dropped on the row are added before it; Move Up and
/// Move Down reorder (context menu and VoiceOver actions).
struct FilesFavoriteRow: View {
    let path: String
    let index: Int
    let count: Int
    let shortcut: String?
    /// Moves this favorite so it ends up before the item at the index given.
    let move: (Int) -> Void
    let insert: ([URL]) -> Bool
    let remove: () -> Void
    @State private var targeted = false

    private var name: String { FilesPath.displayName(path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Image(nsImage: FilesIcons.icon(path))
                .resizable()
                .interpolation(.high)
                .frame(width: AOMIcon.row + AOMSpace.x1, height: AOMIcon.row + AOMSpace.x1)
                .opacity(exists ? 1 : 0.4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1).truncationMode(.middle)
                Text(FilesPath.abbreviated(path))
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            if !exists { AOMStatusPill("Missing", tone: .warning) }
            if let shortcut {
                Text(shortcut)
                    .font(AOMFont.callout.monospacedDigit())
                    .foregroundStyle(AOMColor.textTertiary)
                    .accessibilityHidden(true)
            }
            AOMIconButton("minus.circle", label: "Remove \(name) from favorites", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { if index > 0 { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x1) } }
        .contentShape(Rectangle())
        .aomDropTarget(targeted, radius: AOMRadius.well)
        .dropDestination(for: URL.self) { urls, _ in insert(urls) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Show in Finder") { FilesFileActions.reveal([URL(fileURLWithPath: path)]) }
            Button("Copy Path") { FilesFileActions.copyPaths([URL(fileURLWithPath: path)]) }
            Divider()
            Button("Move Up") { move(index - 1) }.disabled(index == 0)
            Button("Move Down") { move(index + 2) }.disabled(index >= count - 1)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(FilesPath.abbreviated(path))")
        .accessibilityValue(shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityAction(named: "Move Up") { if index > 0 { move(index - 1) } }
        .accessibilityAction(named: "Move Down") { if index < count - 1 { move(index + 2) } }
        .accessibilityAction(named: "Remove", remove)
    }
}

// MARK: - Drop Shelf

/// The Drop Shelf's settings and what is on it now.
struct FilesShelfSection: View {
    @ObservedObject var settings: FilesSettings
    @ObservedObject var shelf: FilesShelfStore
    let toast: AOMToastModel
    let openShortcutSettings: () -> Void
    let quickLook: ([URL], Int) -> Void
    @State private var targeted = false
    @ObservedObject private var shortcuts = CaptureShortcuts.shared

    var body: some View {
        FilesAdaptiveColumns(minimumColumnWidth: 440) {
            settingsCard
            itemsCard
        }
    }

    private var settingsCard: some View {
        AOMSection("Drop Shelf",
                   help: "The shelf holds files on their way somewhere else: drop files on it, switch apps or desktops, then drag them out. Files stay where they are; only Move To moves them.") {
            AOMToggleRow("Shake while dragging opens the shelf", detail: "Shake the pointer left and right during a file drag",
                         symbol: "hand.draw", isOn: $settings.shakeOpensShelf)
            AOMSettingRow("Shake sensitivity", detail: sensitivityDetail, indent: true) {
                Picker("Shake sensitivity", selection: $settings.sensitivity) {
                    ForEach(FilesShakeSensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            .disabled(!settings.shakeOpensShelf)
            AOMToggleRow("Shift while dragging opens it too", detail: "Press ⇧ during a file drag instead of shaking",
                         indent: true, isOn: $settings.shiftOpensShelf)
            AOMSettingRow("Keyboard shortcut", detail: shortcutDetail, symbol: "command") {
                Button("Change…", action: openShortcutSettings)
            }
        }
    }

    private var sensitivityDetail: String {
        switch settings.sensitivity {
        case .low: return "Four wide shakes"
        case .medium: return "Three quick shakes"
        case .high: return "Three small shakes"
        }
    }

    private var shortcutDetail: String {
        if let shortcut = shortcuts.shortcut(for: .showDropShelf) { return "\(shortcut.displayString) shows the shelf anywhere" }
        return "None yet; Settings › Shortcuts › Productivity"
    }

    private var itemsCard: some View {
        AOMSection("On the shelf", detail: shelf.items.isEmpty ? nil : "\(shelf.items.count)") {
            if shelf.items.isEmpty {
                AOMInlineEmpty(symbol: "tray", message: "Empty. Drop files here, or shake while dragging.",
                               actionTitle: "Show Drop Shelf") { FilesModule.showShelf() }
            } else {
                let items = Array(shelf.items.prefix(6))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    FilesShelfItemRow(item: item, showsDivider: index > 0, quickLook: {
                        let urls = shelf.items.filter(\.exists).map(\.url)
                        quickLook(urls, urls.firstIndex(of: item.url) ?? 0)
                    }, remove: { remove([item]) })
                }
                if shelf.items.count > items.count {
                    Text("and \(shelf.items.count - items.count) more on the shelf")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, AOMSpace.rowInset)
                        .frame(minHeight: AOMSize.rowStandard)
                        .overlay(alignment: .top) { AOMRowDivider() }
                }
                HStack(spacing: AOMSpace.x2) {
                    Button("Show Drop Shelf") { FilesModule.showShelf() }
                    Spacer()
                    Button("Clear Shelf") { remove(shelf.items) }
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x2)
                .overlay(alignment: .top) { AOMRowDivider() }
            }
        }
        .aomDropTarget(targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            shelf.add(files)
            toast.show(files.count == 1 ? "Added “\(files[0].lastPathComponent)” to the shelf" : "Added \(files.count) items to the shelf")
            return true
        } isTargeted: { targeted = $0 }
    }

    /// Off the shelf only; the files stay. The shelf's own received files go
    /// to the Trash through the shelf controller.
    private func remove(_ items: [FilesShelfItem]) {
        let controller = FilesShelfPanelController.shared
        controller.remove(Set(items.map(\.id)))
        let removedAll = shelf.items.isEmpty
        toast.show(removedAll && items.count > 1 ? "Cleared the shelf" : "Removed \(FilesShelfPanelController.count(items.count)) from the shelf",
                   action: { controller.model.undo?() })
    }
}

/// A file on the shelf, in the Files page.
struct FilesShelfItemRow: View {
    let item: FilesShelfItem
    let showsDivider: Bool
    let quickLook: () -> Void
    let remove: () -> Void

    var body: some View {
        let exists = item.exists
        HStack(spacing: AOMSpace.x2) {
            FilesThumbnail(url: item.url, size: AOMIcon.row + AOMSpace.x2)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1).truncationMode(.middle)
                Text(exists ? FilesShelfView.detail(item) : "Not found")
                    .font(AOMFont.callout)
                    .foregroundStyle(exists ? AOMColor.textSecondary : AOMColor.warningText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            AOMIconButton("minus.circle", label: "Remove \(item.name) from the shelf", action: remove)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x2) } }
        .aomHoverHighlight(radius: AOMRadius.well)
        .background { if exists { FilesFileDragSource(urls: { [item.url] }) } }
        .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { FilesFileActions.open([item.url]) } }
        .help(item.path)
        .contextMenu {
            if exists {
                Button("Open") { FilesFileActions.open([item.url]) }
                Button("Quick Look", action: quickLook)
                Button("Show in Finder") { FilesFileActions.reveal([item.url]) }
            }
            Button("Copy Path") { FilesFileActions.copyPaths([item.url]) }
            Divider()
            Button("Remove from Shelf", action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(exists ? FilesShelfView.detail(item) : "Not found")
        .accessibilityAction(named: "Quick Look", quickLook)
        .accessibilityAction(named: "Remove from Shelf", remove)
    }
}

// MARK: - Recent downloads and screenshots

struct FilesRecentSection: View {
    @ObservedObject var recent: FilesRecentModel
    let toast: AOMToastModel
    let quickLook: ([URL], Int) -> Void

    var body: some View {
        FilesAdaptiveColumns(minimumColumnWidth: 400) {
            downloads
            screenshots
        }
    }

    private var downloads: some View {
        AOMSection("Recent downloads", detail: FilesPath.abbreviated(recent.downloadsFolder.path),
                   help: "The newest items in Downloads by the date they arrived. Drag one out, press Space for Quick Look, double-click to open.") {
            refreshButton
        } content: {
            FilesRecentList(files: recent.downloads, loaded: recent.loaded, readable: recent.downloadsReadable,
                            emptyMessage: "No downloads yet.", emptySymbol: "arrow.down.circle",
                            toast: toast, quickLook: quickLook, refresh: { recent.refresh() })
        }
    }

    private var screenshots: some View {
        AOMSection("Recent screenshots", detail: FilesPath.abbreviated(recent.screenshotFolder.path),
                   help: "Screenshots in the folder the Screenshot app saves to (Options › Save to), or the Desktop. Files are recognised by the screenshot mark macOS gives them.") {
            EmptyView()
        } content: {
            FilesRecentList(files: recent.screenshots, loaded: recent.loaded, readable: true,
                            emptyMessage: "No screenshots here yet.", emptySymbol: "camera.viewfinder",
                            toast: toast, quickLook: quickLook, refresh: { recent.refresh() })
        }
    }

    private var refreshButton: some View {
        AOMIconButton("arrow.clockwise", label: "Refresh") { recent.refresh() }
    }
}

/// Up to eight recent files with selection: click selects, double-click
/// opens, Space shows Quick Look, ↑ ↓ move, Return opens.
struct FilesRecentList: View {
    let files: [FilesRecentFile]
    let loaded: Bool
    let readable: Bool
    let emptyMessage: String
    let emptySymbol: String
    let toast: AOMToastModel
    let quickLook: ([URL], Int) -> Void
    let refresh: () -> Void
    @State private var selection: String?
    @FocusState private var focused: Bool

    private var shown: [FilesRecentFile] { Array(files.prefix(8)) }

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                Text("…")
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: AOMSize.rowDetail)
                    .accessibilityLabel("Loading")
            } else if !readable {
                AOMInlineEmpty(symbol: "lock", message: "macOS doesn't let All of MacOS read this folder.",
                               actionTitle: "Open Settings") { _ = AOMPermission.filesAndFolders.openSettings() }
            } else if files.isEmpty {
                AOMInlineEmpty(symbol: emptySymbol, message: emptyMessage)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                    FilesRecentRow(file: file, selected: selection == file.id && focused, showsDivider: index > 0,
                                   select: { selection = file.id; focused = true },
                                   open: { FilesFileActions.open([file.url]) },
                                   quickLook: { lookAt(file) },
                                   trash: { trash(file) })
                }
            }
        }
        .focusable(loaded && !files.isEmpty)
        .focused($focused)
        .focusEffectDisabled()
        .aomFocusRing(focused, radius: AOMRadius.card)
        .onKeyPress(.space) {
            guard let file = selected else { return .ignored }
            lookAt(file)
            return .handled
        }
        .onKeyPress(.return) {
            guard let file = selected else { return .ignored }
            FilesFileActions.open([file.url])
            return .handled
        }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
    }

    private var selected: FilesRecentFile? { shown.first { $0.id == selection } }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let index = shown.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : shown.count)
        let next = min(max(index + delta, 0), shown.count - 1)
        selection = shown[next].id
        return .handled
    }

    private func lookAt(_ file: FilesRecentFile) {
        let urls = shown.map(\.url)
        quickLook(urls, urls.firstIndex(of: file.url) ?? 0)
    }

    private func trash(_ file: FilesRecentFile) {
        guard !PresetManager.isUIPreview else { return }
        Task {
            let result = await FilesFileActions.trash([file.url])
            if let failure = result.failures.first {
                toast.show("Couldn't move “\(file.name)” to the Trash because \(failure.reason)", tone: .danger)
            } else {
                let moves = result.trashed
                toast.show("Moved “\(file.name)” to the Trash", actionTitle: "Undo") {
                    Task {
                        let back = await FilesFileActions.moveBack(moves)
                        if let failure = back.failures.first {
                            toast.show("Couldn't put “\(file.name)” back because \(failure.reason)", tone: .danger)
                        }
                        refresh()
                    }
                }
            }
            refresh()
        }
    }
}

/// One recent file: thumbnail, name, when it arrived and its size.
struct FilesRecentRow: View {
    let file: FilesRecentFile
    let selected: Bool
    let showsDivider: Bool
    let select: () -> Void
    let open: () -> Void
    let quickLook: () -> Void
    let trash: () -> Void

    private var detail: String {
        let when = AOMRelativeTime.string(file.added)
        guard let size = file.size else { return file.isFolder ? "\(when) · Folder" : when }
        return "\(when) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            FilesThumbnail(url: file.url, size: AOMIcon.row + AOMSpace.x2)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(AOMFont.body)
                    .foregroundStyle(selected ? Color.white : AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : AOMColor.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: AOMSize.rowDetail)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous).fill(AOMColor.selection)
                    .padding(.horizontal, AOMSpace.x1)
            }
        }
        .overlay(alignment: .top) { if showsDivider && !selected { AOMRowDivider(inset: AOMSpace.rowSymbolInset + AOMSpace.x2) } }
        .aomHoverHighlight(radius: AOMRadius.well, enabled: !selected)
        .contentShape(Rectangle())
        .background { FilesFileDragSource(urls: { [file.url] }) }
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 { open() } else { select() }
        }
        .help(file.url.path)
        .contextMenu {
            Button("Open", action: open)
            Button("Quick Look", action: quickLook)
            Button("Show in Finder") { FilesFileActions.reveal([file.url]) }
            Button("Copy") { FilesFileActions.copyFiles([file.url]) }
            Button("Copy Path") { FilesFileActions.copyPaths([file.url]) }
            Divider()
            Button("Move to Trash", role: .destructive, action: trash)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Quick Look", quickLook)
        .accessibilityAction(named: "Show in Finder") { FilesFileActions.reveal([file.url]) }
        .accessibilityAction(named: "Move to Trash", trash)
    }
}

/// A Quick Look thumbnail for images and documents, the Finder icon until it
/// arrives (and for files without one).
struct FilesThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FilesIcons.icon(url.path)).resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: image == nil ? 0 : AOMRadius.keycap, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) { image = await FilesThumbnails.thumbnail(for: url, size: size, scale: scale) }
    }
}

@MainActor
enum FilesThumbnails {
    private static var cache: [String: NSImage] = [:]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "pdf", "mov", "mp4"]

    static func thumbnail(for url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        guard imageTypes.contains(url.pathExtension.lowercased()) else { return nil }
        let key = "\(url.path)#\(Int(size))"
        if let cached = cache[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: max(1, scale), representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
