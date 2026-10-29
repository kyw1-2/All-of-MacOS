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
    // 44 pt rows and a guided empty state.
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Paste Stack").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                HStack {
                    Button { controller.stopStack() } label: {
                        Image(systemName: "xmark.circle.fill").font(AOMFont.section.weight(.regular))
                            .foregroundStyle(AOMColor.textSecondary)
                            .frame(width: AOMIcon.row, height: AOMIcon.row)
                    }
                    .help("Close Paste Stack").accessibilityLabel("Close Paste Stack")
                    Spacer()
                    Button { state.stackReversed.toggle() } label: {
                        Image(systemName: state.stackReversed ? "arrow.up.square" : "arrow.down.square")
                            .font(AOMFont.section.weight(.regular)).foregroundStyle(AOMColor.textSecondary)
                            .frame(width: AOMIcon.row, height: AOMIcon.row)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help(state.stackReversed ? "Pasting newest first — click for oldest first"
                                              : "Pasting oldest first — click for newest first")
                    .accessibilityLabel("Paste Order")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowStandard)
            if orderedRows.isEmpty {
                AOMEmptyState("Stack Is Empty", systemImage: "doc.on.clipboard",
                              message: "Copy items to add them. ⌘V pastes them in order.") {
                    Button("Open Clipboard Library") {
                        // The stack panel floats outside the main window's
                        // environment, so reuse the menu bar's switch path.
                        let delegate = NSApp.delegate as? AppDelegate
                        delegate?.appState?.selectedMainTab = .clipboard
                        delegate?.showMainWindow()
                    }
                }
                .padding(.horizontal, AOMSpace.x4)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(orderedRows.enumerated()), id: \.element.position) { ordinal, row in
                            stackRow(row.entry, position: row.position, ordinal: ordinal)
                            if ordinal < orderedRows.count - 1 {
                                AOMRowDivider(inset: AOMSpace.x2 + AOMIcon.headerBadge + AOMSpace.x2, trailingInset: AOMSpace.x2)
                            }
                        }
                    }.padding(.horizontal, AOMSpace.x1)
                }
            }
            if !state.status.isEmpty {
                Text(state.status).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AOMSpace.x3).padding(.vertical, AOMSpace.x1)
            }
            AOMDivider()
            HStack(spacing: AOMSpace.x2) {
                Button { state.stackMode.toggle() } label: {
                    AOMStatusPill(state.stackMode ? "Collecting" : "Paused", tone: state.stackMode ? .success : .neutral)
                }
                .buttonStyle(.plain)
                .help(state.stackMode ? "New copies are added to the stack" : "New copies are not added")
                Spacer()
                Button("Paste Next") { controller.pasteNext() }
                    .controlSize(.small).disabled(orderedRows.isEmpty)
                    .aomGlassButton(prominent: !orderedRows.isEmpty)
                    .help("Paste the next item (⌘V in the destination does the same)")
            }.padding(.horizontal, AOMSpace.x3).frame(height: AOMSize.rowStandard + AOMSpace.x1)
        }
        .onChange(of: state.stack.count) { _, _ in controller.fitStackPanel() }
        .frame(width: AOMFeatureSize.stackPanelWidth)
        .aomFloatingSurface(.panel, radius: AOMRadius.panel)
    }

    private func stackRow(_ entry: ClipboardEntry, position index: Int, ordinal: Int) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Group {
                if let data = entry.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let url = entry.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                } else if let icon = AppMetadataCache.shared.icon(for: entry.sourceBundleID) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.kind == .link ? "link" : "doc.text").foregroundStyle(AOMColor.textSecondary)
                }
            }
            .frame(width: AOMIcon.headerBadge, height: AOMIcon.headerBadge)
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .overlay(alignment: .topLeading) {
                if ordinal == 0 {
                    Circle().fill(AOMColor.accent).frame(width: AOMSpace.x2, height: AOMSpace.x2)
                        .offset(x: -AOMSpace.x0_5 - 1, y: -AOMSpace.x0_5 - 1)
                        .accessibilityLabel("Next")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.previewText.isEmpty ? entry.title : entry.previewText)
                    .font(ordinal == 0 ? AOMFont.callout.weight(.semibold) : AOMFont.callout)
                    .foregroundStyle(AOMColor.text).lineLimit(1)
                Text(entry.sourceName ?? entry.kind.displayName).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { if state.stack.indices.contains(index) { state.stack.remove(at: index) } } label: {
                Image(systemName: "minus.circle").foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row + AOMSpace.x0_5, height: AOMIcon.row + AOMSpace.x0_5).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Remove from Stack").accessibilityLabel("Remove from Stack")
        }
        .padding(.horizontal, AOMSpace.x2).frame(height: AOMSize.rowDouble)
        .contentShape(Rectangle())
        .onDrag {
            let provider = NSItemProvider()
            let snapshot = ClipboardStackDragPayload(index: index, queue: state.stack)
            provider.registerDataRepresentation(forTypeIdentifier: ClipboardStackDragPayload.type, visibility: .ownProcess) { done in
                done(try? JSONEncoder().encode(snapshot), nil); return nil
            }
            return provider
        }
        .onDrop(of: [ClipboardStackDragPayload.type], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: ClipboardStackDragPayload.type) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(ClipboardStackDragPayload.self, from: data) else { return }
                Task { @MainActor in state.reorderStack(from: payload.index, before: index, expected: payload.queue) }
            }
            return true
        }
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

private struct ClipboardStackDragPayload: Codable {
    static let type = "com.kyw.allofmacos.clipboard-stack-order"
    let index: Int
    let queue: [UUID]
}
