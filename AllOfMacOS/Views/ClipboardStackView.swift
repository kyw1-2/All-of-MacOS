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

    private var entries: [ClipboardEntry] {
        let byID = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0) })
        return state.stack.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                Text("Paste Stack").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { state.stack.reverse() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("Reverse Order").disabled(entries.count < 2)
                Button { controller.stopStack() } label: { Image(systemName: "xmark") }
                    .help("Close Paste Stack")
            }.buttonStyle(.plain).padding(15)
            Divider().opacity(0.4)
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.on.square.dashed").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("Copy items to build a stack").font(.system(size: 13, weight: .medium))
                    Text("Press ⌘V in your destination to paste in order.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            HStack(spacing: 9) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary).frame(width: 19)
                                if let data = entry.imageData, let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
                                } else {
                                    Image(systemName: entry.kind == .link ? "link" : "doc.text")
                                        .foregroundStyle(Color.accentColor).frame(width: 28)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(entry.previewText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Button { if state.stack.indices.contains(index) { state.stack.remove(at: index) } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }.buttonStyle(.plain).help("Remove from Stack")
                            }
                            .padding(9).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .background(Color.primary.opacity(index == 0 ? 0.08 : 0.035),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu {
                                Button("Move to Top") {
                                    guard state.stack.indices.contains(index) else { return }
                                    let moved = state.stack.remove(at: index)
                                    state.stack.insert(moved, at: 0)
                                }
                                Button("Remove from Stack") { if state.stack.indices.contains(index) { state.stack.remove(at: index) } }
                            }
                        }
                    }.padding(10)
                }
            }
            if !state.status.isEmpty {
                Text(state.status).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
            }
            Text("⌘V Paste Next · ⇧⌘V Plain Text").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 7)
            Divider().opacity(0.4)
            HStack(spacing: 7) {
                Circle().fill(state.stackMode ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Button(state.stackMode ? "Collecting" : "Paused") { state.stackMode.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Paste Next") { controller.pasteNext() }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(entries.isEmpty)
            }.padding(12)
        }
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow, state: .active))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
