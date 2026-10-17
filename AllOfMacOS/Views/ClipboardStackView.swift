import AppKit
import SwiftUI

/// The queue stays alongside the destination without taking its keyboard focus.
final class ClipboardStackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct ClipboardStackView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardPanelState
    let controller: ClipboardPanelController

    private var rows: [(position: Int, entry: ClipboardEntry)] {
        let byID = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0) })
        // Preserve queue positions when a deleted history item has not yet
        // been pruned. Compacting first makes Remove target the wrong item.
        return state.stack.enumerated().compactMap { index, id in
            byID[id].map { (index, $0) }
        }
    }

    /// Rows in paste order, so the first row is always what ⌘V delivers next.
    private var orderedRows: [(position: Int, entry: ClipboardEntry)] {
        state.stackReversed ? rows.reversed() : rows
    }

    // Paste Stack (PasteStack.storyboard): 264 pt column, close button on the
    // leading edge, centred bold title, direction toggle on the trailing edge,
    // 44 pt rows and a centred "Empty" label.
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Paste Stack").font(.system(size: 13, weight: .bold))
                HStack {
                    Button { controller.stopStack() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .help("Close Paste Stack").accessibilityLabel("Close Paste Stack")
                    Spacer()
                    Button { state.stackReversed.toggle() } label: {
                        Image(systemName: state.stackReversed ? "arrow.up.square" : "arrow.down.square")
                            .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 16, height: 16)
                    }
                    .help(state.stackReversed ? "Pasting newest first — click for oldest first"
                                              : "Pasting oldest first — click for newest first")
                    .accessibilityLabel("Paste Order")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 32)
            if orderedRows.isEmpty {
                VStack(spacing: 6) {
                    Text("Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
                    Text("Copy items to add them. ⌘V pastes them in order.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(orderedRows.enumerated()), id: \.element.position) { ordinal, row in
                            stackRow(row.entry, position: row.position, ordinal: ordinal)
                            if ordinal < orderedRows.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }.padding(.horizontal, 6)
                }
            }
            if !state.status.isEmpty {
                Text(state.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            }
            Divider().opacity(0.5)
            HStack(spacing: 7) {
                Button { state.stackMode.toggle() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(state.stackMode ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(state.stackMode ? "Collecting" : "Paused")
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .help(state.stackMode ? "New copies are added to the stack" : "New copies are not added")
                Spacer()
                Button("Paste Next") { controller.pasteNext() }
                    .controlSize(.small).disabled(orderedRows.isEmpty)
                    .help("Paste the next item (⌘V in the destination does the same)")
            }.padding(.horizontal, 10).frame(height: 36)
        }
        .frame(width: 264)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false))
    }

    private func stackRow(_ entry: ClipboardEntry, position index: Int, ordinal: Int) -> some View {
        HStack(spacing: 8) {
            Group {
                if let data = entry.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let url = entry.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                } else if let icon = AppMetadataCache.shared.icon(for: entry.sourceBundleID) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.kind == .link ? "link" : "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topLeading) {
                if ordinal == 0 {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -3, y: -3)
                        .accessibilityLabel("Next")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.previewText.isEmpty ? entry.title : entry.previewText)
                    .font(.system(size: 12, weight: ordinal == 0 ? .semibold : .regular)).lineLimit(1)
                Text(entry.sourceName ?? entry.kind.displayName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { if state.stack.indices.contains(index) { state.stack.remove(at: index) } } label: {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }.buttonStyle(.plain).help("Remove from Stack").accessibilityLabel("Remove from Stack")
        }
        .padding(.horizontal, 6).frame(height: 44)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Paste Next First") {
                guard state.stack.indices.contains(index) else { return }
                let moved = state.stack.remove(at: index)
                if state.stackReversed { state.stack.append(moved) } else { state.stack.insert(moved, at: 0) }
            }
            Button("Remove from Stack") { if state.stack.indices.contains(index) { state.stack.remove(at: index) } }
        }
    }
}
