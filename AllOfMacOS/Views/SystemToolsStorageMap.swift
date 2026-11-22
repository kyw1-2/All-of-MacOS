import AppKit
import SwiftUI

/// 7.5 (Codex F06): Folder Sizes as a map you walk down — the list and
/// the map show the same items with the same sizes; click a folder (or ↩
/// in the list) to go in, the path bar or ⌘↑ to come back out.
@MainActor
final class StorageMapModel: ObservableObject, Identifiable {
    let id = UUID()
    let root: URL
    @Published private(set) var scan: StorageMap.Scan?
    @Published private(set) var current: StorageNode?
    @Published var selection: StorageNode.ID?
    @Published private(set) var progress = StorageMap.Progress()
    @Published private(set) var scanning = false
    @Published private(set) var stopped = false
    private var stop: AOMCancelFlag?

    init(root: URL) { self.root = root }

    func start() {
        guard !scanning else { return }
        scanning = true
        stopped = false
        scan = nil
        current = nil
        let flag = AOMCancelFlag()
        stop = flag
        let root = root
        Task.detached(priority: .userInitiated) {
            let scan = StorageMap.scan(root, isCancelled: { flag.isSet }) { progress in
                Task { @MainActor in self.progress = progress }
            }
            await MainActor.run {
                self.scanning = false
                self.stop = nil
                guard let scan else { self.stopped = true; return }
                self.scan = scan
                self.current = scan.root
                self.selection = scan.root.children.first?.id
            }
        }
    }

    func cancel() { stop?.set() }

    var selected: StorageNode? { current?.children.first { $0.id == selection } }

    func open(_ node: StorageNode) {
        guard node.canOpen else { selection = node.id; return }
        current = node
        selection = node.children.first?.id
    }

    func go(to node: StorageNode) {
        let from = current
        current = node
        // Coming back out selects the folder you were in.
        selection = from?.path.first { $0.parent === node }?.id ?? node.children.first?.id
    }

    func up() {
        guard let parent = current?.parent else { return }
        go(to: parent)
    }
}

struct StorageMapView: View {
    @ObservedObject var model: StorageMapModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            if model.scanning {
                VStack(spacing: AOMSpace.x3) {
                    ProgressView()
                    Text("Measuring \(model.root.lastPathComponent)… \(model.progress.items.formatted()) items · \(SystemStatus.size(model.progress.bytes))")
                        .font(AOMFont.callout).monospacedDigit()
                    Text(model.progress.folder).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Stop") { model.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let current = model.current, let scan = model.scan {
                pathBar(current)
                HStack(alignment: .top, spacing: AOMSpace.x3) {
                    list(current).frame(width: 280)
                    StorageTreemap(node: current, selection: model.selection) { node in
                        if node.canOpen { model.open(node) } else { model.selection = node.id }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(current, scan)
            } else {
                VStack(spacing: AOMSpace.x3) {
                    Text(model.stopped ? "Stopped before the end" : "Nothing measured").foregroundStyle(AOMColor.textSecondary)
                    HStack {
                        Button("Measure Again") { model.start() }
                        Button("Close", action: onClose)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func pathBar(_ current: StorageNode) -> some View {
        HStack(spacing: AOMSpace.x1) {
            Button { model.up() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(current.parent == nil)
                .help("Up one folder (⌘↑)")
            ForEach(current.path) { node in
                if node.parent != nil { Image(systemName: "chevron.compact.right").foregroundStyle(AOMColor.textTertiary) }
                Button(node.name) { model.go(to: node) }
                    .buttonStyle(.borderless)
                    .font(node === current ? AOMFont.bodyEmphasis : AOMFont.body)
                    .lineLimit(1)
            }
            Spacer()
            Text(SystemStatus.size(current.size)).font(AOMFont.bodyEmphasis).monospacedDigit()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.selected?.url ?? current.url])
            }
            Button("Done", action: onClose)
        }
    }

    private func list(_ current: StorageNode) -> some View {
        List(selection: $model.selection) {
            ForEach(current.children) { node in
                StorageRow(node: node, total: current.size)
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(node) }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            if let node = model.selected { model.open(node) }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if let node = model.selected, node.canOpen { model.open(node); return .handled }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            guard current.parent != nil else { return .ignored }
            model.up()
            return .handled
        }
        .overlay {
            if current.children.isEmpty {
                Text(current.unreadable ? "This folder couldn't be read" : "Empty folder").foregroundStyle(AOMColor.textSecondary)
            }
        }
    }

    private func footer(_ current: StorageNode, _ scan: StorageMap.Scan) -> some View {
        var parts = ["\(current.fileCount.formatted()) file\(current.fileCount == 1 ? "" : "s")",
                     "allocated space, packages included",
                     scan.hardLinksSkipped > 0 ? "\(scan.hardLinksSkipped) hard link\(scan.hardLinksSkipped == 1 ? "" : "s") counted once" : "hard links count once"]
        if current.unreadableBelow > 0 { parts.append("\(current.unreadableBelow) folder\(current.unreadableBelow == 1 ? "" : "s") couldn't be read") }
        parts.append("links and other volumes aren't entered")
        return Text(parts.joined(separator: " · ")).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(2)
    }
}

private struct StorageRow: View {
    let node: StorageNode
    let total: Int64

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: StorageTreemap.symbol(node)).foregroundStyle(StorageTreemap.color(node, index: 0)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                GeometryReader { proxy in
                    Capsule().fill(AOMColor.track)
                        .overlay(alignment: .leading) {
                            Capsule().fill(AOMColor.accent.opacity(0.7))
                                .frame(width: proxy.size.width * CGFloat(total > 0 ? Double(node.size) / Double(total) : 0))
                        }
                }
                .frame(height: 3)
            }
            Spacer(minLength: AOMSpace.x2)
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageTreemap.sizeText(node)).font(AOMFont.callout).monospacedDigit()
                if node.isFolder, node.fileCount > 0 {
                    Text("\(node.fileCount.formatted()) files").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                }
            }
            if node.canOpen { Image(systemName: "chevron.right").font(.caption).foregroundStyle(AOMColor.textTertiary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(node.canOpen ? "Press Return to open the folder" : "")
    }
}

/// The map: one rectangle per item, area by size, laid out squarified.
struct StorageTreemap: View {
    let node: StorageNode
    let selection: StorageNode.ID?
    let tapped: (StorageNode) -> Void

    var body: some View {
        GeometryReader { proxy in
            let children = node.children.filter { $0.size > 0 }
            let rects = StorageMap.squarify(children.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    if rect.width > 1, rect.height > 1 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.color(child, index: index))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(child.id == selection ? AOMColor.focusRing : Color.clear, lineWidth: 2))
                            .overlay(alignment: .topLeading) {
                                if rect.width > 64, rect.height > 30 {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(child.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(Self.sizeText(child)).font(.system(size: 10)).monospacedDigit().opacity(0.8)
                                    }
                                    .foregroundStyle(.white)
                                    .padding(4)
                                }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { tapped(child) }
                            .help("\(child.name) · \(Self.sizeText(child))\(child.canOpen ? " · click to open" : "")")
                    }
                }
            }
            .overlay {
                if children.isEmpty {
                    Text(node.unreadable ? "Couldn't be read" : "Nothing here takes space").foregroundStyle(AOMColor.textSecondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func sizeText(_ node: StorageNode) -> String {
        switch node.kind {
        case .otherVolume: return "Another volume"
        case .link: return "Link"
        default: return node.unreadable ? "Couldn't be read" : SystemStatus.size(node.size)
        }
    }

    static func symbol(_ node: StorageNode) -> String {
        switch node.kind {
        case .folder: return node.unreadable ? "lock" : "folder"
        case .file: return "doc"
        case .link: return "arrowshape.turn.up.right"
        case .otherVolume: return "externaldrive"
        case .smallerItems: return "square.grid.3x3"
        }
    }

    static func color(_ node: StorageNode, index: Int) -> Color {
        switch node.kind {
        case .folder: return Color(hue: (0.58 + Double(index % 7) * 0.045).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.72)
        case .file: return Color(hue: 0.47, saturation: 0.35, brightness: 0.62)
        case .smallerItems, .link, .otherVolume: return Color(white: 0.55)
        }
    }
}
