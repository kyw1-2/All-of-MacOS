import AppKit
import SwiftUI

/// Clipboard library: the full, searchable history and pinboards in the main
/// window (the ⇧⌘V shelf is the quick-paste surface). Native search field,
/// segmented type filter, pinboard chips and an adaptive card grid whose
/// image thumbnails decode off the main thread.
struct ClipboardStudioView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @StateObject private var search = ClipboardPanelState()
    @AppStorage("AOMClipboardGridLayout") private var gridLayout = false
    @State private var selectedEntryID: UUID?
    @State private var boardCounts: [UUID: Int] = [:]
    @State private var hoveredCardID: UUID? = nil
    @State private var showingSettings = false
    @State private var showingNewBoardSheet = false
    @State private var showingEraseConfirmation = false
    @State private var newBoardName = ""
    @State private var newBoardColor = "blue"
    @StateObject private var toast = AOMToastModel()

    private let boardColors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    private var filteredEntries: [ClipboardEntry] {
        search.displayedResults(in: store)
    }

    private var subtitle: String {
        let count = store.entries.count
        var parts = ["\(count) item\(count == 1 ? "" : "s")", "\(store.boards.count) pinboard\(store.boards.count == 1 ? "" : "s")"]
        if store.paused { parts.append("recording paused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let entries = filteredEntries
        VStack(spacing: 0) {
            libraryHeading
            filterBar
            AOMDivider()
            Group {
                if search.isSearchPending {
                    ProgressView("Searching clipboard…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    if store.isLoading && store.entries.isEmpty {
                        AOMEmptyState("Unlocking Clipboard History", systemImage: "lock",
                                      message: "If macOS asks for your login keychain password, choose Always Allow.")
                    } else if store.entries.isEmpty {
                        AOMEmptyState("Your Clipboard Is Empty", systemImage: "doc.on.clipboard",
                                      message: store.paused ? "Recording is paused. Resume to keep what you copy."
                                      : "Copy text, links, colors, images or files and they appear here — searchable, pinnable and encrypted on this Mac.") {
                            if store.paused { Button("Resume Recording") { store.resume() }.buttonStyle(.borderedProminent) }
                        }
                    } else if !search.query.isEmpty {
                        ContentUnavailableView.search(text: search.query)
                    } else {
                        AOMEmptyState(search.board == nil ? "No Matching Items" : "Pinboard Is Empty",
                                      systemImage: search.board == nil ? "line.3.horizontal.decrease.circle" : "pin",
                                      message: search.board == nil ? "No items of this type yet." : "Pin items from their menu to keep them here.") {
                            Button("Show All Items") { search.kind = nil; search.board = nil }
                        }
                    }
                } else {
                    library(entries)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aomPane()
        .navigationTitle("Clipboard")
        .navigationSubtitle(subtitle)
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search text, links and files")
        .toolbar { toolbarContent }
        .task(id: store.revision) {
            let entries = store.entries
            let counts = await Task.detached(priority: .userInitiated) {
                var counts: [UUID: Int] = [:]
                for entry in entries { for id in entry.pinboardIDs { counts[id, default: 0] += 1 } }
                return counts
            }.value
            guard !Task.isCancelled else { return }
            boardCounts = counts
        }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                ClipboardSettingsView()
                Divider()
                HStack { Spacer(); Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction) }
                    .padding(12)
            }
            .frame(minWidth: 600, idealWidth: 660, minHeight: 520, idealHeight: 600)
        }
        .sheet(isPresented: $showingNewBoardSheet) { newBoardSheet }
        .confirmationDialog("Erase clipboard history?", isPresented: $showingEraseConfirmation) {
            Button("Erase History", role: .destructive) {
                store.eraseHistory()
                showToast("History erased · pinned items kept")
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(ClipboardEraseCopy.message(unpinned: store.entries.filter { $0.pinboardIDs.isEmpty }.count)) }
        .aomToast(toast.message)
    }

    // MARK: - Library (Bear's list + preview; Paste's cards for the gallery)

    private func library(_ entries: [ClipboardEntry]) -> some View {
        GeometryReader { geometry in
            if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
                        ForEach(entries) { entry in libraryCard(entry) }
                    }
                    .padding(24)
                }
                .background(AOMTheme.workspace)
            } else {
                let showsPreview = geometry.size.width >= 640
                HStack(spacing: 0) {
                    List(selection: $selectedEntryID) {
                        ForEach(entries) { entry in libraryRow(entry) }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity)
                    .onKeyPress(.return) {
                        guard let entry = entries.first(where: { $0.id == selectedEntryID }) else { return .ignored }
                        copy(entry)
                        return .handled
                    }
                    if showsPreview, let entry = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first {
                        AOMDivider(axis: .vertical)
                        previewPane(entry)
                            .frame(width: min(420, max(300, geometry.size.width * 0.42)))
                    }
                }
            }
        }
    }

    private func libraryRow(_ entry: ClipboardEntry) -> some View {
        AOMListRow(entry.title,
                   detail: [entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · ")) {
            Image(systemName: entry.kind.symbol).font(.system(size: 13, weight: .medium))
        } trailing: {
            if !entry.pinboardIDs.isEmpty {
                Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(AOMTheme.textTertiary)
                    .accessibilityLabel("Pinned")
            }
        }
        .tag(entry.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { copy(entry) })
        .contextMenu { entryMenu(entry) }
    }

    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry) -> some View {
        Button("Copy") { copy(entry) }
        if entry.kind == .text || entry.kind == .link {
            Button("Copy as Plain Text") { copy(entry, plainText: true) }
        }
        if !store.boards.isEmpty {
            Menu("Pinboards") {
                ForEach(store.boards) { board in
                    Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") { togglePin(entry, board) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(entryID: entry.id); showToast("Deleted item") }
    }

    /// The selected item, readable: a preview made for its kind, the source
    /// and time beneath, and the actions next to it.
    private func previewPane(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.xs) {
                if let icon = AppMetadataCache.shared.icon(for: entry.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text([entry.sourceName ?? entry.kind.displayName, AOMRelativeTime.string(entry.lastCopiedAt)].joined(separator: " · "))
                    .font(AOMType.caption)
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, AOMSpace.m)
            .frame(height: 38)
            AOMDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    ClipboardStudioCard.Preview(entry: entry, large: true)
                        .frame(maxWidth: .infinity, minHeight: entry.kind == .text ? nil : 160, alignment: .topLeading)
                }
                .padding(AOMSpace.m)
            }
            AOMDivider()
            HStack(spacing: AOMSpace.xs) {
                Button { copy(entry) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(AOMFilledButtonStyle())
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy (⇧⌘C, or press Return in the list)")
                Menu {
                    entryMenu(entry)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.m)
            .frame(height: 48)
        }
        .id(entry.id)
    }

    private func libraryCard(_ entry: ClipboardEntry) -> some View {
        ClipboardStudioCard(entry: entry, isHovered: hoveredCardID == entry.id, boards: store.boards,
            onCopy: { copy(entry) }, onTogglePin: { board in togglePin(entry, board) },
            onDelete: { store.delete(entryID: entry.id); showToast("Deleted item") })
            .onHover { hovering in
                if hovering { hoveredCardID = entry.id } else if hoveredCardID == entry.id { hoveredCardID = nil }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Picker("Layout", selection: $gridLayout) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Gallery", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .help("List with preview, or a gallery of cards")
            if store.paused {
                Button {
                    store.resume()
                    showToast("Clipboard recording resumed")
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .help("Resume recording copied items")
            } else {
                Menu {
                    Button("For 5 Minutes") { store.pause(for: 300) }
                    Button("For 15 Minutes") { store.pause(for: 900) }
                    Button("For 1 Hour") { store.pause(for: 3600) }
                    Divider()
                    Button("Until Resumed") { store.pause() }
                } label: {
                    Label("Pause", systemImage: "pause")
                }
                .help("Temporarily stop recording copied items")
            }
            Menu {
                // Erase never touches pinned items (the old "Clear All History"
                // deleted pinboard items too, without asking).
                Button("Erase History…", role: .destructive) { showingEraseConfirmation = true }
                    .disabled(!store.entries.contains { $0.pinboardIDs.isEmpty })
                Divider()
                Button("Clipboard Settings…") { showingSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Clear history and clipboard settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                ClipboardPanelController.shared.show()
            } label: {
                Label("Open Shelf", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Open the quick-paste shelf\(ClipboardShortcuts.shared.shortcut(for: .history).map { " (\($0.displayString))" } ?? "")")
        }
    }

    // MARK: - Filter bar (pinboards and kinds — this page's own navigation)

    private var libraryHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(search.board.flatMap { id in store.boards.first { $0.id == id }?.name } ?? "Your clipboard")
                .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                .lineLimit(1).accessibilityAddTraits(.isHeader)
            Text("\(filteredEntries.count) items")
                .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            Spacer(minLength: 0)
            if store.paused {
                Label("Paused", systemImage: "pause.circle")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.warning)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
    }

    private var filterBar: some View {
        HStack(spacing: AOMSpace.s) {
            pinboardsBar
            Picker("Type", selection: $search.kind) {
                Text("All").tag(ClipboardEntry.Kind?.none)
                ForEach(ClipboardEntry.Kind.allCases) { kind in
                    Image(systemName: kind.symbol)
                        .help(kind.displayName)
                        .accessibilityLabel(kind.displayName)
                        .tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(minHeight: 40)
    }

    private var pinboardsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                chip(title: "All Items", count: store.entries.count, color: nil, symbol: "tray.full",
                     selected: search.board == nil) { search.board = nil }
                ForEach(store.boards) { board in
                    let count = boardCounts[board.id] ?? 0
                    chip(title: board.name, count: count, color: colorForBoard(board.color), symbol: nil,
                         selected: search.board == board.id) {
                        search.board = search.board == board.id ? nil : board.id
                    }
                    .contextMenu {
                        Button("Delete Pinboard…", role: .destructive) {
                            if search.board == board.id { search.board = nil }
                            store.deleteBoard(id: board.id)
                        }
                    }
                }
                Button {
                    newBoardName = ""
                    newBoardColor = "blue"
                    showingNewBoardSheet = true
                } label: {
                    Label("New Pinboard", systemImage: "plus")
                        .font(AOMType.body)
                        .padding(.horizontal, 8).frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AOMTheme.textSecondary)
                .help("Create a pinboard")
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(title: String, count: Int, color: Color?, symbol: String?, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        let accent = Color.accentColor
        return Button {
            withAnimation(AOMMotion.quick) { action() }
        } label: {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                Text(title).font(AOMType.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text("\(count)").font(AOMType.caption.monospacedDigit())
                    .foregroundStyle(selected ? AOMTheme.onAccent(accent).opacity(0.75) : AOMTheme.textTertiary)
            }
            .foregroundStyle(selected ? AOMTheme.onAccent(accent) : AOMTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - New Board Sheet

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Pinboard").font(.headline)
            TextField("Name (e.g. Snippets, Colors, Work)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(boardColors, id: \.self) { colorName in
                        Button { newBoardColor = colorName } label: {
                            Circle()
                                .fill(colorForBoard(colorName))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: newBoardColor == colorName ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName.capitalized)
                        .accessibilityAddTraits(newBoardColor == colorName ? .isSelected : [])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingNewBoardSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = store.createBoard(name: trimmed, color: newBoardColor)
                    showingNewBoardSheet = false
                    showToast("Created pinboard “\(trimmed)”")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newBoardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Helpers

    private func copy(_ entry: ClipboardEntry, plainText: Bool = false) {
        Task {
            do {
                _ = try await store.writeAsync(entryIDs: [entry.id], plainText: plainText, playSound: true)
                showToast("Copied “\(entry.title.prefix(40))”")
            } catch { showToast("Could not copy: \(error.localizedDescription)") }
        }
    }

    private func togglePin(_ entry: ClipboardEntry, _ board: ClipboardPinboard) {
        if entry.pinboardIDs.contains(board.id) {
            store.unpin(entryID: entry.id, boardID: board.id)
            showToast("Unpinned from \(board.name)")
        } else {
            store.pin(entryID: entry.id, boardID: board.id)
            showToast("Pinned to \(board.name)")
        }
    }

    private func showToast(_ message: String) { toast.show(message) }

    private func colorForBoard(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        default: return .gray
        }
    }
}

// MARK: - Clipboard Studio Card

private struct ClipboardStudioCard: View {
    let entry: ClipboardEntry
    let isHovered: Bool
    let boards: [ClipboardPinboard]
    let onCopy: () -> Void
    let onTogglePin: (ClipboardPinboard) -> Void
    let onDelete: () -> Void
    private var appIcon: NSImage? { AppMetadataCache.shared.icon(for: entry.sourceBundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: entry.kind.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.sourceName ?? entry.kind.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.pinboardIDs.isEmpty {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: 4)
                Text(AOMRelativeTime.string(entry.lastCopiedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Preview(entry: entry)
                .frame(height: 144)
                .frame(maxWidth: .infinity)
                .background(AOMTheme.cardAlt.opacity(0.55))

            HStack(spacing: 8) {
                Label(entry.kind.displayName, systemImage: entry.kind.symbol)
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                Spacer(minLength: 4)
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AOMTheme.textSecondary)
                    .help("Copy").accessibilityLabel("Copy item")
                Menu {
                    Button("Copy", action: onCopy)
                    if !boards.isEmpty {
                        Menu("Pinboards") {
                            ForEach(boards) { board in
                                Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                                    onTogglePin(board)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Item actions").accessibilityLabel("Item actions")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .aomSurface(radius: AOMDesign.tileRadius, padding: nil, highlighted: isHovered)
        .clipShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
        .onTapGesture(count: 2, perform: onCopy)
        .contextMenu {
            Button("Copy", action: onCopy)
            if !boards.isEmpty {
                Menu("Pinboards") {
                    ForEach(boards) { board in
                        Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                            onTogglePin(board)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.kind.displayName): \(entry.title)")
    }

    fileprivate static func isLikelyCode(_ text: String) -> Bool {
        ["func ", "struct ", "class ", "import ", "const ", "var ", "let ", "def ", "return ", "{", "}"].contains { text.contains($0) }
    }
}


extension ClipboardStudioCard {
    /// The content of one item, made for its kind. `large` is the library's
    /// preview pane: full text, a bigger image and the whole link.
    struct Preview: View {
        let entry: ClipboardEntry
        var large = false
        @State private var thumbnail: ClipboardThumbnailCache.Preview?

        var body: some View {
            content
                .task(id: entry.id) {
                    guard entry.kind == .image, let data = entry.imageData else { return }
                    thumbnail = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
                }
        }

        @ViewBuilder private var content: some View {
            switch entry.kind {
            case .color:
                let hex = entry.text ?? "#000000"
                Rectangle().fill(Color(hex: hex))
                    .overlay {
                        Text(hex.uppercased())
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                    }
            case .image:
                if let image = thumbnail?.image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(6)
                        .overlay(alignment: .bottomTrailing) {
                            if let size = thumbnail?.dimensions {
                                Text(size).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    .padding(6)
                            }
                        }
                } else {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                }
            case .link:
                VStack(alignment: .leading, spacing: 6) {
                    Label(URL(string: entry.text ?? "")?.host ?? "Link", systemImage: "safari")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    Text(entry.text ?? "")
                        .font(large ? AOMType.body : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(large ? nil : 4)
                        .textSelection(.enabled)
                    if large, let url = URL(string: entry.text ?? ""), url.scheme?.hasPrefix("http") == true {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(large ? 0 : 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .file:
                VStack(spacing: 6) {
                    if let url = entry.fileURLs.first {
                        Image(nsImage: AppMetadataCache.shared.fileIcon(for: url)).resizable().scaledToFit()
                            .frame(width: large ? 64 : 48, height: large ? 64 : 48)
                    } else {
                        Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                    Text(entry.fileURLs.count > 1 ? "\(entry.fileURLs.first?.lastPathComponent ?? "") +\(entry.fileURLs.count - 1)"
                         : entry.fileURLs.first?.lastPathComponent ?? "File")
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                let full = large ? (entry.text ?? entry.previewText) : entry.previewText
                let text = String(full.prefix(large ? 16000 : 600))
                VStack(alignment: .leading, spacing: AOMSpace.xs) {
                    Text(text)
                        .font(.system(size: large ? 13 : 12, design: ClipboardStudioCard.isLikelyCode(text) ? .monospaced : .default))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(large ? nil : 5)
                        .textSelection(.enabled)
                    if large, full.count > 16000 {
                        Text("Preview shortened. Copy includes the full text.")
                            .font(AOMType.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(large ? 0 : 10)
                .frame(maxWidth: .infinity, maxHeight: large ? nil : .infinity, alignment: .topLeading)
            }
        }

    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
