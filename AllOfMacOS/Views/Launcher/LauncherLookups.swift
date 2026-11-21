import AppKit
import SwiftUI

@MainActor
private final class LauncherSpotlightResults: ObservableObject {
    @Published var urls: [URL] = []
    @Published var status = ""
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query?.stop()
        query = nil
    }

    func search(_ text: String) {
        stop()
        urls = []
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { status = "Type a filename"; return }
        status = "Searching…"
        let search = NSMetadataQuery()
        search.searchScopes = [NSMetadataQueryUserHomeScope]
        search.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, term)
        search.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query = search
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                          object: search, queue: .main) { [weak self, weak search] _ in
            MainActor.assumeIsolated {
                guard let self, let search, self.query === search else { return }
                search.disableUpdates()
                self.urls = (0..<min(search.resultCount, 100)).compactMap { index in
                    let item = search.result(at: index) as? NSMetadataItem
                    return item?.value(forAttribute: NSMetadataItemURLKey) as? URL
                }
                self.status = self.urls.isEmpty ? "No indexed files match" : "Showing \\(self.urls.count) of \\(search.resultCount)"
                self.stop()
            }
        }
        if !search.start() { status = "Spotlight could not start"; stop() }
    }
}

struct LauncherFileSearch: View {
    let initial: String
    let back: () -> Void
    @State private var text = ""
    @State private var selection: URL?
    @StateObject private var results = LauncherSpotlightResults()
    @FocusState private var focused: Bool

    private var chosen: URL? { selection ?? results.urls.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Back", action: back)
                TextField("Search filenames with Spotlight", text: $text)
                    .focused($focused).onSubmit { if let chosen { NSWorkspace.shared.open(chosen) } }
                ProgressView().controlSize(.small).opacity(results.status == "Searching…" ? 1 : 0)
            }
            Text(results.status).font(.caption).foregroundStyle(.secondary)
            List(results.urls, id: \.self, selection: $selection) { url in
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent).lineLimit(1)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(url)
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            }
            HStack {
                Button("Open") { if let chosen { NSWorkspace.shared.open(chosen) } }
                Button("Show in Finder") { if let chosen { NSWorkspace.shared.activateFileViewerSelecting([chosen]) } }
                Button("Copy Path") {
                    if let chosen { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chosen.path, forType: .string) }
                }
            }.disabled(chosen == nil)
        }
        .padding()
        .onAppear { text = initial; focused = true }
        .task(id: text) {
            selection = nil
            results.stop()
            results.urls = []
            results.status = text.isEmpty ? "Type a filename" : "Searching…"
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            results.search(text)
        }
        .onDisappear { results.stop() }
        .onExitCommand(perform: back)
    }
}

struct LauncherRulePreview: View {
    let back: () -> Void
    @ObservedObject private var engine = FolderRulesEngine.shared
    @State private var selected: UUID?
    @State private var preview: FolderRulePreview?
    @State private var generation = 0
    private var rule: FolderRule? { engine.config.rules.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back", action: back)
                Picker("Rule", selection: $selected) {
                    Text("Choose a rule").tag(nil as UUID?)
                    ForEach(engine.config.rules) { rule in
                        Text(rule.name).tag(Optional(rule.id))
                    }
                }
                Button("Refresh") { generation += 1 }.disabled(rule == nil)
            }
            if let preview {
                Text(FolderRulesText.previewSummary(preview)).font(.headline)
                if let problem = preview.folderState.problem { Text(problem).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(preview.items) { FolderRulesPreviewRow(item: $0, showsDivider: true) }
                    }
                }
            } else if rule != nil {
                ProgressView("Reading folder…")
            } else {
                Text(engine.config.rules.isEmpty ? "No folder rules configured." : "Choose a rule to preview its actions.")
            }
            Spacer(minLength: 0)
        }
        .padding()
        .task(id: PreviewRequest(rule: rule, generation: generation)) {
            preview = nil
            if let rule {
                let result = await engine.preview(rule)
                if !Task.isCancelled { preview = result }
            }
        }
        .onExitCommand(perform: back)
    }

    private struct PreviewRequest: Equatable {
        let rule: FolderRule?
        let generation: Int
    }
}


struct LauncherStackContents: View {
    let back: () -> Void
    @ObservedObject private var state = ClipboardPanelController.shared.state
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        let entries = Dictionary(store.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let queue = (state.stackReversed ? Array(state.stack.reversed()) : state.stack).compactMap { entries[$0] }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back", action: back)
                Text("Paste Stack").font(.headline)
                Spacer()
                Text("\(queue.count) queued").foregroundStyle(.secondary)
            }
            if queue.isEmpty {
                Text("Open Clipboard History and choose Add to Paste Stack from Actions.")
                Spacer()
            } else {
                List(Array(queue.enumerated()), id: \.offset) { index, entry in
                    HStack {
                        Text("\(index + 1)").monospacedDigit()
                        Image(systemName: entry.kind.symbol)
                        Text(entry.title).lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .onExitCommand(perform: back)
    }
}
