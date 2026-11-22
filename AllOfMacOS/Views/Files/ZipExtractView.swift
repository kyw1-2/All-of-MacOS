import AppKit
import SwiftUI

/// 7.5 (Codex F03): a ZIP's files to search and pick from, extracted into
/// a folder you choose without unpacking the rest.
@MainActor
final class ZipExtractModel: ObservableObject {
    let archive: URL
    @Published private(set) var entries: [ZipArchive.Entry] = []
    @Published private(set) var problem: String?
    @Published private(set) var loading = false
    @Published var query = ""
    @Published var picked: Set<Int> = []
    @Published var keepFolders = true
    @Published private(set) var extracting = false
    @Published private(set) var written: Int64 = 0
    @Published private(set) var result: (message: String, files: [URL], failed: Bool)?
    private var stop: AOMCancelFlag?

    init(archive: URL) { self.archive = archive }

    /// Files only (folders come with the files inside them).
    var files: [ZipArchive.Entry] { entries.filter { !$0.isDirectory } }

    var shown: [ZipArchive.Entry] { Self.filter(files, query: query) }

    /// Pure: entries whose path holds every word of the query (case and
    /// Unicode form ignored).
    nonisolated static func filter(_ entries: [ZipArchive.Entry], query: String) -> [ZipArchive.Entry] {
        let words = query.precomposedStringWithCanonicalMapping.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let path = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            return words.allSatisfy { path.contains($0) }
        }
    }

    var pickedEntries: [ZipArchive.Entry] { files.filter { picked.contains($0.id) && $0.unsupported == nil } }
    /// Nil when the sizes add up past Int64 (Codex Z01).
    var pickedSize: Int64? { ZipArchive.totalSize(pickedEntries) }

    func load() {
        guard !loading else { return }
        loading = true
        let archive = archive
        Task.detached(priority: .userInitiated) {
            let read = Result { try ZipArchive.entries(of: archive) }
            await MainActor.run {
                self.loading = false
                switch read {
                case .success(let entries):
                    // Folder by folder, names in Finder's order (IMG_2 before IMG_10).
                    self.entries = entries.sorted {
                        $0.folder != $1.folder ? $0.folder.localizedStandardCompare($1.folder) == .orderedAscending
                            : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .failure(let error): self.problem = error.localizedDescription
                }
            }
        }
    }

    func toggle(_ entry: ZipArchive.Entry) {
        guard entry.unsupported == nil else { return }
        if picked.contains(entry.id) { picked.remove(entry.id) } else { picked.insert(entry.id) }
    }

    func pickShown(_ on: Bool) {
        let ids = shown.filter { $0.unsupported == nil }.map(\.id)
        if on { picked.formUnion(ids) } else { picked.subtract(ids) }
    }

    func chooseFolderAndExtract() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = archive.deletingLastPathComponent()
        panel.prompt = "Extract Here"
        panel.message = "Choose where the \(pickedEntries.count) file\(pickedEntries.count == 1 ? "" : "s") go. Files already there are kept; a taken name gets a number."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        extract(into: folder)
    }

    func extract(into folder: URL) {
        let entries = pickedEntries
        guard !entries.isEmpty, !extracting else { return }
        extracting = true
        written = 0
        result = nil
        let flag = AOMCancelFlag()
        stop = flag
        let archive = archive, keep = keepFolders
        Task.detached(priority: .userInitiated) {
            var last = Date.distantPast
            let outcome = ZipArchive.extract(entries, from: archive, into: folder, keepFolders: keep, isCancelled: { flag.isSet }) { bytes in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.1 else { return }
                last = now
                Task { @MainActor in self.written = bytes }
            }
            await MainActor.run {
                self.extracting = false
                self.stop = nil
                var message = "Extracted \(outcome.written.count) of \(entries.count) into \(folder.lastPathComponent)"
                if outcome.cancelled { message = "Stopped: " + message }
                if !outcome.failures.isEmpty { message += " · not extracted: " + outcome.failures.prefix(3).joined(separator: "; ") }
                self.result = (message, outcome.written, !outcome.failures.isEmpty || outcome.cancelled)
                FilesActivityLog.shared.record("Extracted \(outcome.written.count) from \(archive.lastPathComponent)", tool: "Extract from ZIP",
                                               files: outcome.written,
                                               failures: outcome.failures.map { FilesTransfer.Failure(url: archive, reason: $0) })
            }
        }
    }

    func cancel() { stop?.set() }

    // MARK: Quick Look before extracting (BetterZip)

    /// The entry shown in Quick Look, extracted alone into a temporary folder.
    @Published var previewURL: URL?
    @Published private(set) var previewURLs: [URL] = []
    private var previewFolder: URL?
    /// 7.6 (Codex Z04): the newest Quick Look request; older ones are dropped.
    private var previewGeneration = 0
    private var closed = false
    /// Stops the preview unpacking when another file is picked or the window closes.
    private var previewStop: AOMCancelFlag?

    func quickLook(_ entry: ZipArchive.Entry) {
        guard entry.unsupported == nil, !closed else { return }
        if previewURL != nil { previewURL = nil; return }
        previewGeneration += 1
        let generation = previewGeneration
        previewStop?.set()
        let stop = AOMCancelFlag()
        previewStop = stop
        let folder = previewFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("AOMZipPreview-\(UUID().uuidString)", isDirectory: true)
        previewFolder = folder
        // The preview folder is made here, on main; the work below never makes it
        // again, so a window closed meanwhile leaves nothing behind (Gemini 7.6).
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = archive
        Task.detached(priority: .userInitiated) {
            let own = folder.appendingPathComponent("\(generation)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: false)) != nil else { return }
            let outcome = ZipArchive.extract([entry], from: archive, into: own, keepFolders: false, budget: ZipArchive.previewBudget,
                                             isCancelled: { stop.isSet })
            await MainActor.run {
                guard !self.closed, generation == self.previewGeneration else {
                    try? FileManager.default.removeItem(at: own)
                    return
                }
                guard let file = outcome.written.first else {
                    self.result = ("Couldn't preview \(entry.name): \(outcome.failures.first ?? "")", [], true)
                    return
                }
                self.previewURLs = [file]
                self.previewURL = file
            }
        }
    }

    /// The window closed: stop work and remove preview copies.
    func close() {
        closed = true
        cancel()
        previewStop?.set()
        previewGeneration += 1
        previewURL = nil
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
        previewFolder = nil
    }

    /// Preview folders left by a crash, older than a day, go when a ZIP window opens.
    static func sweepOldPreviews(now: Date = Date()) {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("AOMZipPreview-") {
            let url = temp.appendingPathComponent(name)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }
}

struct ZipExtractView: View {
    @ObservedObject var model: ZipExtractModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x3) {
                AOMModuleBadge(symbol: "doc.zipper", size: AOMIcon.headerBadge)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(model.archive.lastPathComponent).font(AOMFont.pageStatus).lineLimit(1)
                    Text(summary).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer()
            }
            if let problem = model.problem {
                AOMNotice(.error, "Can't Read This Archive", detail: problem)
                Spacer()
            } else if model.loading {
                ProgressView("Reading the archive…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: AOMSpace.x2) {
                    TextField("Search names and folders inside the archive", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                    Button("Pick Shown") { model.pickShown(true) }
                    Button("Clear") { model.pickShown(false) }.disabled(model.picked.isEmpty)
                }
                Table(model.shown) {
                    TableColumn("") { entry in
                        Toggle("", isOn: Binding(get: { model.picked.contains(entry.id) }, set: { _ in model.toggle(entry) }))
                            .labelsHidden()
                            .disabled(entry.unsupported != nil)
                            .accessibilityLabel("Pick \(entry.name)")
                    }
                    .width(24)
                    TableColumn("Name") { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                                .foregroundStyle(entry.unsupported == nil ? AOMColor.text : AOMColor.textTertiary)
                            if let why = entry.unsupported {
                                Text(why).font(AOMFont.caption).foregroundStyle(AOMColor.warningText).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle(entry) }
                    }
                    TableColumn("Folder in the Archive") { entry in
                        Text(entry.folder.isEmpty ? "—" : entry.folder).lineLimit(1).foregroundStyle(AOMColor.textSecondary)
                            .help(entry.path)
                    }
                    TableColumn("Size") { entry in
                        Text(SystemStatus.size(entry.size)).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                    }
                    .width(80)
                    TableColumn("") { entry in
                        Button { model.quickLook(entry) } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless)
                            .disabled(entry.unsupported != nil)
                            .help("Quick Look this file before extracting it")
                            .accessibilityLabel("Quick Look \(entry.name)")
                    }
                    .width(28)
                }
                .quickLookPreview($model.previewURL, in: model.previewURLs)
                .overlay {
                    if model.shown.isEmpty {
                        Text(model.files.isEmpty ? "The archive has no files" : "No file matches “\(model.query)”")
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                }
                footer
            }
        }
        .padding(AOMSpace.x4)
        .onAppear { searchFocused = true }
        .onDisappear { model.close() }
    }

    private var summary: String {
        let files = model.files
        let unsupported = files.filter { $0.unsupported != nil }.count
        let total = ZipArchive.totalSize(files).map(SystemStatus.size) ?? "too large to add up"
        var text = "\(files.count) file\(files.count == 1 ? "" : "s") · \(total) unpacked"
        if unsupported > 0 { text += " · \(unsupported) can't be extracted" }
        return text
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            if let result = model.result {
                HStack {
                    Image(systemName: result.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(result.failed ? AOMColor.warningText : AOMColor.successText)
                    Text(result.message).font(AOMFont.callout).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if !result.files.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.files) }
                    }
                }
            }
            HStack(spacing: AOMSpace.x3) {
                Toggle("Keep the archive's folders", isOn: $model.keepFolders)
                    .help("On: report.pdf in Contracts/2026 comes out in Contracts/2026. Off: every file goes straight into the folder you choose.")
                Spacer()
                if model.extracting {
                    ProgressView(value: Double(model.written), total: Double(max(1, model.pickedSize ?? 1)))
                        .frame(width: 140)
                    Button("Stop") { model.cancel() }
                } else {
                    Text(model.picked.isEmpty ? "Pick files to extract" : "\(model.pickedEntries.count) picked · \(model.pickedSize.map(SystemStatus.size) ?? "too large to add up")")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    Button("Extract To…") { model.chooseFolderAndExtract() }
                        .buttonStyle(AOMPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.pickedEntries.isEmpty)
                }
            }
        }
    }
}
