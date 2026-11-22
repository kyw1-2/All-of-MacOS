import AppKit
import SwiftUI

/// 7.5 (Codex F08): Compare Folders — two folders by relative path, then
/// copy only what one side is missing, in the direction you pick.
@MainActor
final class FolderCompareModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case differences, missing, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .differences: return "Differences"
            case .missing: return "Missing"
            case .all: return "Everything"
            }
        }
    }

    @Published var left: URL?
    @Published var right: URL?
    @Published private(set) var comparison: FolderCompare.Comparison?
    @Published private(set) var comparing = false
    @Published private(set) var progress = ""
    @Published private(set) var problem: String?
    @Published var filter: Filter = .differences
    @Published var direction: FolderCompare.Direction = .leftToRight { didSet { picked = [] } }
    @Published var picked: Set<String> = []
    @Published private(set) var copying = false
    @Published private(set) var copyProgress = 0
    /// Item id → what happened when it was copied (or why it wasn't).
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var message: String?
    private var stop: AOMCancelFlag?

    var shown: [FolderCompare.Item] {
        guard let items = comparison?.items else { return [] }
        switch filter {
        case .all: return items
        case .missing: return items.filter { $0.status == direction.copies }
        case .differences: return items.filter { $0.status != .same }
        }
    }

    var copyable: [FolderCompare.Item] { (comparison?.items ?? []).filter { $0.canCopy && $0.status == direction.copies } }
    var pickedItems: [FolderCompare.Item] { copyable.filter { picked.contains($0.id) } }

    func choose(_ isLeft: Bool) {
        guard let url = AOMFileToolsLauncher.pick("Choose the \(isLeft ? "left" : "right") folder.", types: [], directories: true)?.first else { return }
        if isLeft { left = url } else { right = url }
        comparison = nil
        if left != nil, right != nil { compare() }
    }

    func swapSides() {
        (left, right) = (right, left)
        comparison = nil
        if left != nil, right != nil { compare() }
    }

    func compare() {
        guard let left, let right, !comparing else { return }
        comparing = true
        problem = nil
        message = nil
        notes = [:]
        picked = []
        let flag = AOMCancelFlag()
        stop = flag
        Task.detached(priority: .userInitiated) {
            var last = Date.distantPast
            let outcome = Result {
                try FolderCompare.compare(left, right, isCancelled: { flag.isSet }) { path in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    Task { @MainActor in self.progress = path }
                }
            }
            await MainActor.run {
                self.comparing = false
                self.stop = nil
                switch outcome {
                case .success(let comparison?):
                    self.comparison = comparison
                    // Missing items start picked: that is what the window is for.
                    self.picked = Set(self.copyable.map(\.id))
                case .success(nil): self.message = "Stopped before the comparison finished"
                case .failure(let error): self.problem = error.localizedDescription
                }
            }
        }
    }

    func copy() {
        let items = pickedItems
        guard !items.isEmpty, !copying else { return }
        copying = true
        copyProgress = 0
        let flag = AOMCancelFlag()
        stop = flag
        let direction = direction
        Task.detached(priority: .userInitiated) {
            let result = FolderCompare.copyMissing(items, direction: direction, isCancelled: { flag.isSet }) { number in
                Task { @MainActor in self.copyProgress = number }
            }
            await MainActor.run {
                self.copying = false
                self.stop = nil
                for id in result.copied { self.notes[id] = "Copied" }
                for (id, why) in result.skipped { self.notes[id] = why }
                // Copied items are on both sides now: never copied twice.
                if var comparison = self.comparison {
                    for index in comparison.items.indices where result.copied.contains(comparison.items[index].id) {
                        comparison.items[index].status = .same
                        comparison.items[index].note = "Copied \(direction.title)"
                        // The copy is the other side now.
                        if let source = direction == .leftToRight ? comparison.items[index].left : comparison.items[index].right,
                           let parent = comparison.items[index].otherParent,
                           let copy = FolderCompare.side(parent.appendingPathComponent(source.url.lastPathComponent)) {
                            let filled = copy.isFolder ? FolderCompare.Side(url: copy.url, size: source.size, modified: copy.modified, isFolder: true,
                                                                            isLink: false, files: source.files, fingerprint: copy.fingerprint) : copy
                            if direction == .leftToRight { comparison.items[index].right = filled } else { comparison.items[index].left = filled }
                        }
                    }
                    self.comparison = comparison
                }
                self.picked.subtract(result.copied)
                var text = "Copied \(result.copied.count) of \(items.count) \(direction.title)"
                if result.cancelled { text = "Stopped: " + text }
                if !result.skipped.isEmpty { text += " · \(result.skipped.count) left as they were (see the rows)" }
                self.message = text
                FilesActivityLog.shared.record(text, tool: "Compare Folders", files: result.written,
                                               failures: result.skipped.compactMap { id, why in
                                                   items.first { $0.id == id }.map { FilesTransfer.Failure(url: ($0.left ?? $0.right)!.url, reason: why) }
                                               })
            }
        }
    }

    func cancel() { stop?.set() }
}

struct FolderCompareView: View {
    @ObservedObject var model: FolderCompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                Group {
                    folderButton(model.left, title: "Left", isLeft: true)
                    Button { model.swapSides() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .help("Swap the two folders")
                        .disabled(model.left == nil && model.right == nil)
                    folderButton(model.right, title: "Right", isLeft: false)
                }
                .disabled(model.comparing || model.copying)
                Button(model.comparison == nil ? "Compare" : "Compare Again") { model.compare() }
                    .disabled(model.left == nil || model.right == nil || model.comparing || model.copying)
            }
            if let problem = model.problem {
                AOMNotice(.error, "Can't Compare These", detail: problem)
            }
            if model.comparing {
                HStack(spacing: AOMSpace.x2) {
                    ProgressView().controlSize(.small)
                    Text("Comparing \(model.progress)").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Stop") { model.cancel() }
                }
            }
            if let comparison = model.comparison {
                HStack(spacing: AOMSpace.x3) {
                    Picker("Show", selection: $model.filter) {
                        ForEach(FolderCompareModel.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text(counts(comparison)).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                    Spacer()
                }
                Table(model.shown) {
                    TableColumn("") { item in
                        if item.canCopy && item.status == model.direction.copies {
                            Toggle("", isOn: Binding(get: { model.picked.contains(item.id) },
                                                     set: { on in if on { model.picked.insert(item.id) } else { model.picked.remove(item.id) } }))
                                .labelsHidden()
                                .accessibilityLabel("Copy \(item.path)")
                        }
                    }
                    .width(24)
                    TableColumn("Status") { item in
                        Label(item.status.title, systemImage: symbol(item.status))
                            .foregroundStyle(color(item.status))
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Path") { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.path).lineLimit(1).truncationMode(.middle).help(item.path)
                            if let note = model.notes[item.id] ?? item.note {
                                Text(note).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                            }
                        }
                    }
                    TableColumn("Left") { item in Text(describe(item.left)).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary) }
                        .width(min: 110, ideal: 150)
                    TableColumn("Right") { item in Text(describe(item.right)).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary) }
                        .width(min: 110, ideal: 150)
                }
                // Gemini 7.5 idea (ForkLift): a row that differs opens in the tool that shows how.
                .contextMenu(forSelectionType: FolderCompare.Item.ID.self) { ids in
                    if let item = comparison.items.first(where: { ids.contains($0.id) }) {
                        let urls = [item.left?.url, item.right?.url].compactMap { $0 }
                        if urls.count == 2, urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
                            Button("Compare the Two PDFs") { AOMFileToolsLauncher.comparePDFs(urls) }
                        }
                        Button(urls.count == 2 ? "Show Both in Finder" : "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                        }
                    }
                } primaryAction: { ids in
                    guard let item = comparison.items.first(where: { ids.contains($0.id) }) else { return }
                    let urls = [item.left?.url, item.right?.url].compactMap { $0 }
                    if urls.count == 2, urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) { AOMFileToolsLauncher.comparePDFs(urls) }
                    else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                }
                .overlay {
                    if model.shown.isEmpty {
                        Text(comparison.items.isEmpty ? "Both folders are empty" : "Nothing differs: every file is on both sides with the same contents")
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                }
                footer(comparison)
            } else if !model.comparing {
                VStack(spacing: AOMSpace.x3) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 30, weight: .light)).foregroundStyle(AOMColor.textSecondary)
                    Text("Pick two folders, such as a work folder and its copy on an external drive.").foregroundStyle(AOMColor.textSecondary)
                    Text("Files of the same size are compared byte by byte. Only what's missing is copied; nothing is replaced.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(AOMSpace.x4)
        .onDisappear { model.cancel() }
    }

    private func folderButton(_ url: URL?, title: String, isLeft: Bool) -> some View {
        Button { model.choose(isLeft) } label: {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    Text(url.map { FolderRulesSafety.display($0) } ?? "Choose…").lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(url?.path ?? "Choose the \(title.lowercased()) folder")
    }

    private func footer(_ comparison: FolderCompare.Comparison) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            if let message = model.message {
                Text(message).font(AOMFont.callout).textSelection(.enabled)
            }
            HStack(spacing: AOMSpace.x3) {
                Picker("Copy", selection: $model.direction) {
                    ForEach(FolderCompare.Direction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.copying)
                Text(comparison.ignoresCase ? "Names matched without case" : "Names matched with case")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                Spacer()
                if model.copying {
                    ProgressView(value: Double(model.copyProgress), total: Double(max(1, model.pickedItems.count))).frame(width: 140)
                    Button("Stop") { model.cancel() }
                } else {
                    Text("\(model.pickedItems.count) of \(model.copyable.count) missing picked")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    Button("Copy Missing") { model.copy() }
                        .buttonStyle(AOMPrimaryButtonStyle())
                        .disabled(model.pickedItems.isEmpty || model.comparing)
                }
            }
        }
    }

    private func counts(_ comparison: FolderCompare.Comparison) -> String {
        FolderCompare.Status.allCases.compactMap { status in
            let count = comparison.count(status)
            return count == 0 ? nil : "\(count) \(status.title.lowercased())"
        }.joined(separator: " · ")
    }

    private func describe(_ side: FolderCompare.Side?) -> String {
        guard let side else { return "—" }
        if side.isLink { return "Link" }
        let size = SystemStatus.size(side.size)
        if side.isFolder { return "Folder · \(side.files) file\(side.files == 1 ? "" : "s") · \(size)" }
        guard let date = side.modified else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func symbol(_ status: FolderCompare.Status) -> String {
        switch status {
        case .leftOnly: return "arrow.left.circle"
        case .rightOnly: return "arrow.right.circle"
        case .differs: return "notequal.circle"
        case .same: return "equal.circle"
        case .problem: return "exclamationmark.triangle"
        }
    }

    private func color(_ status: FolderCompare.Status) -> Color {
        switch status {
        case .leftOnly, .rightOnly: return AOMColor.accent
        case .differs: return AOMColor.warningText
        case .same: return AOMColor.textSecondary
        case .problem: return AOMColor.dangerText
        }
    }
}
