import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 7.23: the two-pane browser (Files › Tools › Two-Pane Browser…, or ⌘K).
/// Each side lists one folder; drag files across to copy them, hold ⌘ while
/// dropping to move them. Transfers run one at a time in the bar below.
struct FilesDualPaneView: View {
    @StateObject private var left = FilesPaneModel(side: "left")
    @StateObject private var right = FilesPaneModel(side: "right")
    @ObservedObject private var queue = FilesTransferQueue.shared
    @State private var pending: PendingDrop?
    @State private var showsQueue = false

    struct PendingDrop: Identifiable {
        let id = UUID()
        let sources: [URL]
        let folder: URL
        let move: Bool
        let names: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                FilesPaneColumn(model: left, drop: { drop($0, into: left.folder) },
                                send: { urls, move in send(urls, into: right.folder, move: move) })
                    .frame(minWidth: 280)
                FilesPaneColumn(model: right, drop: { drop($0, into: right.folder) },
                                send: { urls, move in send(urls, into: left.folder, move: move) })
                    .frame(minWidth: 280)
            }
            Divider()
            transferBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { drop in
            ForEach(FilesConflictChoice.allCases) { choice in
                Button(choice.title, role: choice == .replace ? .destructive : nil) {
                    queue.enqueue(drop.sources, to: drop.folder, move: drop.move, choice: choice)
                    pending = nil
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { drop in
            Text(drop.names.count == 1 ? "“\(drop.names[0])” is already in \(drop.folder.lastPathComponent). Replace moves the old one to the Trash."
                 : "\(drop.names.count) items are already in \(drop.folder.lastPathComponent). Replace moves the old ones to the Trash.")
        }
        .onReceive(NotificationCenter.default.publisher(for: FilesTransferQueue.didFinish)) { note in
            guard let folder = note.object as? URL else { return }
            for model in [left, right] where model.folder.standardizedFileURL == folder.standardizedFileURL { model.reload() }
        }
    }

    private var dialogTitle: String {
        guard let pending else { return "" }
        return pending.names.count == 1 ? "An item with that name exists" : "\(pending.names.count) names are taken"
    }

    private func drop(_ urls: [URL], into folder: URL) -> Bool {
        send(urls, into: folder, move: NSEvent.modifierFlags.contains(.command))
    }

    @discardableResult
    private func send(_ urls: [URL], into folder: URL, move: Bool) -> Bool {
        let sources = urls.filter { !FilesDualPanePlan.isNoOp($0, into: folder) }
        guard !sources.isEmpty else { return false }
        let names = FilesDualPanePlan.conflicts(sources, in: folder) { FileManager.default.fileExists(atPath: $0.path) }
        if names.isEmpty {
            queue.enqueue(sources, to: folder, move: move, choice: nil)
        } else {
            pending = PendingDrop(sources: sources, folder: folder, move: move, names: names)
        }
        showsQueue = true
        return true
    }

    private var transferBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AOMMotion.standard) { showsQueue.toggle() }
            } label: {
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: showsQueue ? "chevron.down" : "chevron.right").font(AOMFont.caption)
                    Text(queueTitle).font(AOMFont.callout)
                    if queue.failed > 0 {
                        AOMStatusPill("\(queue.failed) failed", tone: .warning, symbol: "exclamationmark.triangle.fill")
                    }
                    Spacer()
                    if queue.active > 0 { ProgressView().controlSize(.small) }
                    Text("Drag to copy · ⌘ while dropping moves").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                }
                .padding(.horizontal, AOMSpace.x3)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsQueue, !queue.jobs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(queue.jobs.reversed()) { job in jobRow(job) }
                    }
                }
                .frame(maxHeight: 150)
                HStack {
                    Spacer()
                    Button("Clear Finished") { queue.clearFinished() }.controlSize(.small)
                }
                .padding(.horizontal, AOMSpace.x3).padding(.bottom, AOMSpace.x2)
            }
        }
        .background(AOMColor.surface)
    }

    private var queueTitle: String {
        if queue.jobs.isEmpty { return "Transfers" }
        return queue.active > 0 ? "Transferring \(queue.active) of \(queue.jobs.count)" : "Transfers · \(queue.jobs.count)"
    }

    private func jobRow(_ job: FilesTransferJob) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol(job.state)).foregroundStyle(tint(job.state))
            Text("\(job.verb) \(job.source.lastPathComponent) → \(job.folder.lastPathComponent)")
                .font(AOMFont.callout).lineLimit(1).truncationMode(.middle)
            if case .failed(let reason) = job.state {
                Text("— \(reason)").font(AOMFont.caption).foregroundStyle(AOMColor.warningText).lineLimit(1)
                Spacer()
                Button("Try Again") { queue.retry(job.id) }.controlSize(.small)
            } else {
                Spacer()
                Text(label(job.state)).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: 26)
    }

    private func symbol(_ state: FilesTransferJob.State) -> String {
        switch state {
        case .waiting: "clock"
        case .running: "arrow.right.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .skipped: "forward.circle"
        }
    }

    private func tint(_ state: FilesTransferJob.State) -> Color {
        switch state {
        case .done: AOMColor.successText
        case .failed: AOMColor.warningText
        default: AOMColor.textSecondary
        }
    }

    private func label(_ state: FilesTransferJob.State) -> String {
        switch state {
        case .waiting: "Waiting"
        case .running: "Working…"
        case .done: "Done"
        case .skipped: "Skipped"
        case .failed: ""
        }
    }
}

@MainActor
final class FilesPaneModel: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        let size: Int64
        let modified: Date?
        var id: String { url.path }
    }

    let side: String
    @Published private(set) var folder: URL
    @Published private(set) var items: [Item] = []
    @Published var selection: Set<String> = []
    @Published private(set) var problem: String?

    init(side: String) {
        self.side = side
        folder = FilesDualPaneStore.folder(side)
        reload()
    }

    func open(_ url: URL) {
        folder = url.standardizedFileURL
        FilesDualPaneStore.save(folder, side: side)
        selection = []
        reload()
    }

    func up() {
        let parent = folder.deletingLastPathComponent()
        if parent.path != folder.path { open(parent) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            items = urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url, isFolder: values?.isDirectory == true && values?.isPackage != true,
                            size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
            }
            items = Self.sorted(items)
            problem = nil
        } catch {
            items = []
            problem = FilesFileActions.reason(error)
        }
    }

    /// Folders first, then by name as Finder sorts it.
    nonisolated static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    func urls(for item: Item) -> [URL] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) }.map(\.url) : [item.url]
    }
}

struct FilesPaneColumn: View {
    @ObservedObject var model: FilesPaneModel
    let drop: ([URL]) -> Bool
    /// Copy (false) or move (true) the selection to the other side.
    let send: ([URL], Bool) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x1) {
                Button { model.up() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help("Enclosing folder")
                Text(FolderRulesSafety.display(model.folder))
                    .font(AOMFont.callout).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
                Button("Choose…") { model.choose() }.controlSize(.small)
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 32)
            Divider()
            if let problem = model.problem {
                AOMNotice(.warning, "Can't list this folder", detail: "Because \(problem).")
                    .padding(AOMSpace.x3)
                Spacer()
            } else {
                List(model.items, selection: $model.selection) { item in
                    HStack(spacing: AOMSpace.x2) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !item.isFolder {
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                        }
                    }
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if item.isFolder { model.open(item.url) } else { NSWorkspace.shared.open(item.url) }
                    }
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
                    .contextMenu {
                        Button("Copy to Other Side") { send(model.urls(for: item), false) }
                        Button("Move to Other Side") { send(model.urls(for: item), true) }
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.urls(for: item)) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .aomDropTarget(targeted, radius: AOMRadius.dropZone)
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { targeted = $0 }
    }
}
