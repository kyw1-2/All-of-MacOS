import AppKit
import SwiftUI

/// Paste 7.0-style Visual Clipboard Studio.
/// Displays an interactive visual card grid of rich clipboard entries with search,
/// pinboard collections, smart previews (code, colors, links, images, files),
/// and pause/privacy controls.
struct ClipboardStudioView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @State private var searchQuery = ""
    @State private var selectedKind: ClipboardEntry.Kind? = nil
    @State private var selectedBoardID: UUID? = nil
    @State private var hoveredCardID: UUID? = nil
    @State private var showingSettings = false
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""
    @State private var newBoardColor = "blue"
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    private let boardColors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    private var filteredEntries: [ClipboardEntry] {
        let results = store.filtered(
            query: searchQuery,
            kind: selectedKind,
            source: nil,
            board: selectedBoardID,
            since: nil
        )

        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            VStack(spacing: 12) {
                pinboardsBar
                searchAndFilterBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.background.opacity(0.25))

            Divider()

            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 290), spacing: 14)], spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            ClipboardStudioCard(
                                entry: entry,
                                isHovered: hoveredCardID == entry.id,
                                boards: store.boards,
                                onPaste: {
                                    copyAndPaste(entry)
                                },
                                onTogglePin: { board in
                                    if entry.pinboardIDs.contains(board.id) {
                                        store.unpin(entryID: entry.id, boardID: board.id)
                                        showToast("Unpinned from \(board.name)")
                                    } else {
                                        store.pin(entryID: entry.id, boardID: board.id)
                                        showToast("Pinned to \(board.name)")
                                    }
                                },
                                onDelete: {
                                    withAnimation {
                                        store.delete(entryID: entry.id)
                                        showToast("Deleted item")
                                    }
                                }
                            )
                            .onHover { isHovering in
                                hoveredCardID = isHovering ? entry.id : nil
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.18))
        .sheet(isPresented: $showingSettings) {
            ClipboardSettingsView()
                .frame(width: 560, height: 480)
        }
        .sheet(isPresented: $showingNewBoardSheet) {
            newBoardSheet
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.indigo)
                    Text("Clipboard Memory")
                        .font(.headline.weight(.bold))

                    if store.paused {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text(store.pauseRemainingSeconds > 0
                                 ? "Paused (\(store.pauseRemainingSeconds)s)"
                                 : "Paused")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }
                Text("Searchable history, collections, smart format previews & on-device OCR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                // Pause Controls
                if store.paused {
                    Button {
                        store.resume()
                        showToast("Clipboard monitoring resumed")
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Menu {
                        Button("Pause for 5 Minutes") { store.pause(for: 300) }
                        Button("Pause for 15 Minutes") { store.pause(for: 900) }
                        Button("Pause for 1 Hour") { store.pause(for: 3600) }
                        Button("Pause Indefinitely") { store.pause() }
                    } label: {
                        Label("Pause…", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Temporarily stop recording copied items")
                }

                // Clean Menu
                Menu {
                    Button("Clear Unpinned Items") {
                        store.clearUnpinned()
                        showToast("Cleared unpinned clipboard items")
                    }
                    Button("Clear All History", role: .destructive) {
                        store.delete(entryIDs: store.entries.map(\.id))
                        showToast("Cleared all clipboard history")
                    }
                } label: {
                    Label("Clear…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showingSettings = true
                } label: {
                    Label("Options", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background.opacity(0.4))
    }

    // MARK: - Pinboards Bar

    private var pinboardsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All items chip
                let isAll = selectedBoardID == nil
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        selectedBoardID = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 11))
                        Text("All Items")
                            .font(.system(size: 12, weight: isAll ? .bold : .medium))
                        Text("\(store.entries.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isAll ? Color.white : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(isAll ? Color.indigo.opacity(0.8) : Color.primary.opacity(0.08)))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isAll ? Color.indigo.opacity(0.18) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        Capsule().stroke(isAll ? Color.indigo.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // User Pinboards
                ForEach(store.boards) { board in
                    let isSelected = selectedBoardID == board.id
                    let count = store.entries.filter { $0.pinboardIDs.contains(board.id) }.count

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            selectedBoardID = isSelected ? nil : board.id
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForBoard(board.color))
                                .frame(width: 8, height: 8)

                            Text(board.name)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))

                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? colorForBoard(board.color).opacity(0.18) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            Capsule().stroke(isSelected ? colorForBoard(board.color).opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Board", role: .destructive) {
                            store.deleteBoard(id: board.id)
                        }
                    }
                }

                // New Pinboard Button
                Button {
                    newBoardName = ""
                    newBoardColor = "blue"
                    showingNewBoardSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("New Board")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.secondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Search & Filters

    private var searchAndFilterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search text, code, colors (#HEX), URLs…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // Kind filter chips
            HStack(spacing: 3) {
                filterPill(title: "All", kind: nil)
                filterPill(title: "Text", kind: .text)
                filterPill(title: "Links", kind: .link)
                filterPill(title: "Images", kind: .image)
                filterPill(title: "Colors", kind: .color)
                filterPill(title: "Files", kind: .file)
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
        }
    }

    private func filterPill(title: String, kind: ClipboardEntry.Kind?) -> some View {
        let isSelected = selectedKind == kind
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                selectedKind = kind
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected ? Color.indigo.opacity(0.2) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No Clipboard Items Found")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(searchQuery.isEmpty
                 ? "Copy any text, link, color or image to start building your clipboard memory."
                 : "No items match your search query “\(searchQuery)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - New Board Sheet

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Pinboard")
                .font(.headline)

            TextField("Pinboard Name (e.g. Code Snippets, Colors, Work)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Board Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(boardColors, id: \.self) { colorName in
                        Circle()
                            .fill(colorForBoard(colorName))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().stroke(Color.primary, lineWidth: newBoardColor == colorName ? 2 : 0)
                            )
                            .onTapGesture {
                                newBoardColor = colorName
                            }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { showingNewBoardSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create Board") {
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
        .frame(width: 360)
    }

    // MARK: - Helpers

    private func copyAndPaste(_ entry: ClipboardEntry) {
        do {
            _ = try store.write(entryIDs: [entry.id], plainText: false, playSound: true)
            showToast("Copied “\(entry.title)” to clipboard")
        } catch {
            showToast("Failed to copy item: \(error.localizedDescription)")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }

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
    let onPaste: () -> Void
    let onTogglePin: (ClipboardPinboard) -> Void
    let onDelete: () -> Void

    private var appIcon: NSImage? {
        AppMetadataCache.shared.icon(for: entry.sourceBundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header
            HStack(spacing: 6) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: entry.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.indigo)
                }

                Text(entry.sourceName ?? entry.kind.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(timeAgo(entry.lastCopiedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // Card Content Preview
            Group {
                switch entry.kind {
                case .color:
                    colorPreview
                case .image:
                    imagePreview
                case .link:
                    linkPreview
                case .file:
                    filePreview
                case .text:
                    textPreview
                }
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.3))

            Divider()

            // Card Footer & Action Strip
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer()

                if isHovered {
                    HStack(spacing: 4) {
                        Button(action: onPaste) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")

                        Menu {
                            ForEach(boards) { board in
                                Button {
                                    onTogglePin(board)
                                } label: {
                                    HStack {
                                        Text(board.name)
                                        if entry.pinboardIDs.contains(board.id) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: entry.pinboardIDs.isEmpty ? "pin" : "pin.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.pinboardIDs.isEmpty ? Color.secondary : Color.orange)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Pin to board")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete item")
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.05), radius: isHovered ? 4 : 2, y: isHovered ? 2 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isHovered ? Color.indigo.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onTapGesture(count: 2) {
            onPaste()
        }
    }

    // MARK: - Preview Subviews

    private var textPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.previewText)
                .font(.system(size: 11, design: isLikelyCode(entry.previewText) ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var colorPreview: some View {
        let hex = entry.text ?? "#000000"
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: hex))
                .frame(width: 60, height: 60)
                .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(hex.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text("Color Swatch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    private var imagePreview: some View {
        ZStack {
            if let data = entry.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.blue)
                Text(URL(string: entry.text ?? "")?.host ?? "Web Link")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }

            Text(entry.text ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
    }

    private var filePreview: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(entry.fileURLs.first?.lastPathComponent ?? "File")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
    }

    private func isLikelyCode(_ text: String) -> Bool {
        let codeSymbols = ["func ", "struct ", "class ", "import ", "const ", "var ", "let ", "def ", "return ", "{", "}"]
        return codeSymbols.contains { text.contains($0) }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
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
