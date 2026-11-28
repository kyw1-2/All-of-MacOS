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
    /// 7.22: rings (DaisyDisk) instead of the rectangle map; remembered.
    @Published var showsRings = UserDefaults.standard.bool(forKey: "AOMStorageMapRings") {
        didSet { UserDefaults.standard.set(showsRings, forKey: "AOMStorageMapRings") }
    }
    /// 7.23 (the 7.22 open item, DaisyDisk/GrandPerspective overlays): colour by folder, kind or age.
    @Published var coloring = StorageColoring(rawValue: UserDefaults.standard.string(forKey: "AOMStorageMapColoring") ?? "") ?? .folders {
        didSet { UserDefaults.standard.set(coloring.rawValue, forKey: "AOMStorageMapColoring") }
    }
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
                    Group {
                        if model.showsRings {
                            StorageSunburst(node: current, selection: model.selection, tapped: { node in
                                if node.canOpen { model.open(node) } else { model.selection = node.id }
                            }, coloring: model.coloring)
                        } else {
                            StorageTreemap(node: current, selection: model.selection, tapped: { node in
                                if node.canOpen { model.open(node) } else { model.selection = node.id }
                            }, coloring: model.coloring)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if model.coloring != .folders { StorageColoringLegend(coloring: model.coloring).padding(AOMSpace.x2) }
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
            Picker("Colour", selection: $model.coloring) {
                ForEach(StorageColoring.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .help("Colour the map by folder, by kind of file, or by when files last changed")
            Picker("View", selection: $model.showsRings) {
                Image(systemName: "square.grid.2x2").help("Map").tag(false)
                Image(systemName: "circle.circle").help("Rings").tag(true)
            }
            .labelsHidden().aomSegmented().fixedSize()
            .accessibilityLabel("Map or rings")
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
            }
        }
        .listStyle(.inset)
        // Double-click opens; the menu has the Finder actions (DaisyDisk).
        .contextMenu(forSelectionType: StorageNode.ID.self) { ids in
            if let node = current.children.first(where: { ids.contains($0.id) }) {
                if node.canOpen { Button("Open") { model.open(node) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let node = current.children.first(where: { ids.contains($0.id) }) { model.open(node) }
        }
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
        if current.unreadableItems > 0 { parts.append("\(current.unreadableItems) item\(current.unreadableItems == 1 ? "" : "s") without a readable size (not counted)") }
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
    var coloring: StorageColoring = .folders

    var body: some View {
        GeometryReader { proxy in
            let children = node.children.filter { $0.size > 0 }
            let rects = StorageMap.squarify(children.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    if rect.width > 1, rect.height > 1 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.color(child, index: index, coloring: coloring))
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

    static func color(_ node: StorageNode, index: Int, coloring: StorageColoring) -> Color {
        switch coloring {
        case .folders: return color(node, index: index)
        case .kind:
            guard node.kind == .file else { return node.kind == .folder ? Color(white: 0.6) : Color(white: 0.5) }
            return StorageColoring.kindColor(StorageColoring.kind(of: node.name))
        case .age:
            guard node.kind == .file else { return Color(white: 0.6) }
            return StorageColoring.ageColor(StorageColoring.age(of: node.url))
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

// MARK: - 7.22 rings (DaisyDisk's sunburst)

/// 7.22 (DeepSeek 7.21 report §3.2, DaisyDisk's `TASunburst`): the same
/// folder as rings — the folder in the middle, its items in the first ring,
/// their items in the next, three rings deep. A segment's angle is its share
/// of the folder; click a folder to make it the middle.
enum StorageSunburstLayout {
    struct Segment: Identifiable {
        let node: StorageNode
        let depth: Int
        /// Fractions of a turn, 0 at 12 o'clock, clockwise.
        let start: Double
        let end: Double
        let index: Int
        var id: StorageNode.ID { node.id }
        var span: Double { end - start }
    }

    /// Segments under `root` to `depth` rings, skipping slivers under a
    /// quarter of a degree (they'd be invisible and unclickable).
    static func segments(_ root: StorageNode, depth: Int = 3, minimumSpan: Double = 0.25 / 360) -> [Segment] {
        var out: [Segment] = []
        func walk(_ node: StorageNode, level: Int, start: Double, span: Double) {
            guard level <= depth, node.size > 0 else { return }
            var cursor = start
            for (index, child) in node.children.enumerated() where child.size > 0 {
                let share = span * Double(child.size) / Double(node.size)
                guard share >= minimumSpan else { cursor += share; continue }
                out.append(Segment(node: child, depth: level, start: cursor, end: cursor + share, index: index))
                if child.canOpen { walk(child, level: level + 1, start: cursor, span: share) }
                cursor += share
            }
        }
        walk(root, level: 1, start: 0, span: 1)
        return out
    }

    /// The segment under `point` (view coordinates, centre `center`), given
    /// the hole radius and ring width.
    static func hit(_ point: CGPoint, center: CGPoint, hole: CGFloat, ring: CGFloat, in segments: [Segment]) -> Segment? {
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= hole, ring > 0 else { return nil }
        let depth = Int((radius - hole) / ring) + 1
        var angle = atan2(Double(dx), Double(-dy)) / (2 * .pi)
        if angle < 0 { angle += 1 }
        return segments.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}

struct StorageSunburst: View {
    let node: StorageNode
    let selection: StorageNode.ID?
    let tapped: (StorageNode) -> Void
    var coloring: StorageColoring = .folders
    @State private var hovered: StorageNode.ID?

    var body: some View {
        GeometryReader { proxy in
            let segments = StorageSunburstLayout.segments(node)
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let hole = side * 0.16
            let ring = (side / 2 - hole - 4) / 3
            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let inner = hole + ring * CGFloat(segment.depth - 1) + 1
                        let outer = inner + ring - 2
                        let a0 = Angle.degrees(segment.start * 360 - 90), a1 = Angle.degrees(segment.end * 360 - 90)
                        var path = Path()
                        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
                        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
                        path.closeSubpath()
                        // Deeper rings fade, so the first ring reads first.
                        let base = StorageTreemap.color(segment.node, index: segment.index, coloring: coloring)
                        let dimmed = segment.depth == 1 ? 1.0 : (segment.depth == 2 ? 0.78 : 0.58)
                        context.fill(path, with: .color(base.opacity(hovered == segment.id ? 1 : dimmed)))
                        if segment.id == selection || segment.id == hovered {
                            context.stroke(path, with: .color(AOMColor.focusRing), lineWidth: 2)
                        }
                    }
                }
                VStack(spacing: 2) {
                    let shown = segments.first { $0.id == hovered }?.node ?? node
                    Text(shown.name).font(AOMFont.headline).lineLimit(1).truncationMode(.middle)
                    Text(StorageTreemap.sizeText(shown)).font(AOMFont.callout).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                }
                .frame(width: hole * 1.7)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    hovered = StorageSunburstLayout.hit(point, center: center, hole: hole, ring: ring, in: segments)?.id
                } else { hovered = nil }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let segment = StorageSunburstLayout.hit(value.location, center: center, hole: hole, ring: ring, in: segments) {
                    tapped(segment.node)
                }
            })
            .animation(AOMMotion.quick, value: node.id)
            .overlay {
                if segments.isEmpty {
                    Text(node.unreadable ? "Couldn't be read" : "Nothing here takes space").foregroundStyle(AOMColor.textSecondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 7.23: how the map is coloured. Kind is read from the name; age from the
/// file's modification date, read once per file and kept for the session.
enum StorageColoring: String, CaseIterable, Identifiable {
    case folders, kind, age
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folders: "By Folder"
        case .kind: "By Kind"
        case .age: "By Age"
        }
    }

    enum FileKind: String, CaseIterable { case image, video, audio, document, archive, code, app, other }
    enum Age: Int, CaseIterable { case week, month, year, older, unknown }

    /// Pure: a file's kind from its extension.
    static func kind(of name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "raw", "cr2", "nef", "dng", "psd", "svg", "bmp": return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts": return .video
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ogg", "logicx": return .audio
        case "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "epub", "hwp", "hwpx": return .document
        case "zip", "dmg", "pkg", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso", "xip": return .archive
        case "swift", "py", "js", "ts", "c", "h", "m", "cpp", "rs", "go", "java", "kt", "rb", "sh", "json", "yml", "yaml", "html", "css": return .code
        case "app": return .app
        default: return .other
        }
    }

    /// Pure: a modification date's bucket.
    static func age(of date: Date?, now: Date = Date()) -> Age {
        guard let date else { return .unknown }
        let days = now.timeIntervalSince(date) / 86_400
        if days < 7 { return .week }
        if days < 31 { return .month }
        if days < 365 { return .year }
        return .older
    }

    private static let lock = NSLock()
    private static var ages: [URL: Date] = [:]

    static func age(of url: URL) -> Age {
        lock.lock()
        if let cached = ages[url] { lock.unlock(); return age(of: cached) }
        lock.unlock()
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date { lock.lock(); if ages.count > 50_000 { ages.removeAll() }; ages[url] = date; lock.unlock() }
        return age(of: date)
    }

    static func kindColor(_ kind: FileKind) -> Color {
        switch kind {
        case .image: Color(hue: 0.92, saturation: 0.5, brightness: 0.8)
        case .video: Color(hue: 0.0, saturation: 0.55, brightness: 0.78)
        case .audio: Color(hue: 0.08, saturation: 0.6, brightness: 0.85)
        case .document: Color(hue: 0.58, saturation: 0.55, brightness: 0.78)
        case .archive: Color(hue: 0.13, saturation: 0.55, brightness: 0.75)
        case .code: Color(hue: 0.38, saturation: 0.5, brightness: 0.7)
        case .app: Color(hue: 0.75, saturation: 0.45, brightness: 0.78)
        case .other: Color(white: 0.62)
        }
    }

    static func ageColor(_ age: Age) -> Color {
        switch age {
        case .week: Color(hue: 0.38, saturation: 0.6, brightness: 0.72)
        case .month: Color(hue: 0.2, saturation: 0.55, brightness: 0.78)
        case .year: Color(hue: 0.1, saturation: 0.55, brightness: 0.82)
        case .older: Color(hue: 0.02, saturation: 0.55, brightness: 0.75)
        case .unknown: Color(white: 0.6)
        }
    }

    static func title(_ kind: FileKind) -> String { kind.rawValue.capitalized }
    static func title(_ age: Age) -> String {
        switch age {
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        case .older: "Older"
        case .unknown: "Unknown"
        }
    }
}

struct StorageColoringLegend: View {
    let coloring: StorageColoring

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            if coloring == .kind {
                ForEach(StorageColoring.FileKind.allCases, id: \.self) { item(StorageColoring.title($0), StorageColoring.kindColor($0)) }
            } else {
                ForEach(StorageColoring.Age.allCases.filter { $0 != .unknown }, id: \.self) { item(StorageColoring.title($0), StorageColoring.ageColor($0)) }
            }
        }
        .padding(.horizontal, AOMSpace.x2).padding(.vertical, AOMSpace.x1)
        .background(.regularMaterial, in: Capsule())
    }

    private func item(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(AOMFont.caption)
        }
    }
}
