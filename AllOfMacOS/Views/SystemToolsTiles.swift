import SwiftUI

// MARK: - Tile button style

/// The press and hover fills shared by every tile on the page (HIG Buttons:
/// custom buttons need a press state). Tiles are opaque surfaces on the
/// canvas, one level deep, never inside another card.
struct SystemTileButtonStyle: ButtonStyle {
    var radius: CGFloat = AOMRadius.well
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(configuration.isPressed ? AOMColor.surfacePressed : hovering ? AOMColor.surfaceHover : AOMColor.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased
                        ? AOMColor.strongLine
                        : (hovering ? Color.accentColor.opacity(scheme == .dark ? 0.5 : 0.38) : AOMColor.hairline),
                    lineWidth: contrast == .increased || hovering ? 1 : 0.75
                )
            }
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.22 : 0.035), radius: hovering ? 5 : 2.5, x: 0, y: 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
    }
}

// MARK: - Tool tiles

/// A compact command: glyph in the section's hue, the name, the value when
/// there is one, and a chevron for tools that open a sheet. One row tall.
struct SystemToolTile: View {
    let info: SystemToolInfo
    let state: SystemToolState?
    let isRunning: Bool
    let isFavorite: Bool
    let run: () -> Void
    let toggleFavorite: () -> Void
    /// Tools that take a dropped app (Uninstall App…): the tile is a drop
    /// target with the accent ring while an app hovers over it.
    var dropApp: ((URL) -> Void)?
    @State private var dropTargeted = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: AOMSpace.x2) {
                AOMModuleBadge(symbol: info.symbol, hue: info.group.tint, size: 24, active: true)
                    .accessibilityHidden(true)
                Text(info.title)
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: AOMSpace.x1)
                if isRunning {
                    ProgressView().controlSize(.small)
                } else if let state {
                    SystemToolValue(state: state)
                }
                if info.kind == .sheet {
                    Image(systemName: "ellipsis")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(maxWidth: .infinity, minHeight: AOMSize.rowStandard, alignment: .leading)
        }
        .buttonStyle(SystemTileButtonStyle())
        .disabled(isRunning)
        .help(info.help)
        .contextMenu {
            Button("Run") { run() }.disabled(isRunning)
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
        }
        .aomDropTarget(dropTargeted, radius: AOMRadius.well)
        .modifier(SystemToolDropModifier(dropApp: dropApp, targeted: $dropTargeted))
        .accessibilityLabel(info.title)
        .accessibilityValue(isRunning ? "Running" : (state?.text ?? ""))
        .accessibilityHint(info.help)
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", toggleFavorite)
    }
}

/// A compact switch tile: the round glyph fills with the accent while the
/// setting is on, and the live value sits beside the name.
struct SystemToggleTile: View {
    let info: SystemToolInfo
    let state: SystemToolState?
    let isRunning: Bool
    let isFavorite: Bool
    let run: () -> Void
    let toggleFavorite: () -> Void

    static let height: CGFloat = 56
    private static let glyph: CGFloat = 32

    private var isOn: Bool { state?.tone == .success }

    private var stateLine: String {
        if isRunning { return "Working…" }
        if let state { return state.text }
        switch info.id {
        case .bluetooth: return "Choose a device"
        default: return "Click to run"
        }
    }

    var body: some View {
        Button(action: run) {
            HStack(spacing: AOMSpace.x3) {
                ZStack {
                    Circle().fill(isOn ? AnyShapeStyle(AOMColor.accent) : AnyShapeStyle(AOMColor.track))
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: info.symbol)
                            .font(AOMFont.bodyEmphasis)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(isOn ? Color.white : AOMColor.text)
                    }
                }
                .frame(width: Self.glyph, height: Self.glyph)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title)
                        .font(AOMFont.headline)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                    Text(stateLine)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        }
        .buttonStyle(SystemTileButtonStyle(radius: AOMRadius.card))
        .disabled(isRunning)
        .help(info.help)
        .contextMenu {
            Button("Run") { run() }.disabled(isRunning)
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
        }
        .accessibilityLabel(info.title)
        .accessibilityValue(stateLine)
        .accessibilityHint(info.help)
        .accessibilityAddTraits(state != nil ? .isToggle : [])
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", toggleFavorite)
    }
}

/// Accepts one dropped app bundle when the tile takes one.
private struct SystemToolDropModifier: ViewModifier {
    let dropApp: ((URL) -> Void)?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let dropApp {
            content.dropDestination(for: URL.self) { urls, _ in
                guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
                dropApp(app)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// A tool's value beside its name: plain secondary text, in the success
/// colour only when it means "on".
struct SystemToolValue: View {
    let state: SystemToolState

    var body: some View {
        Text(state.text)
            .font(AOMFont.caption.monospacedDigit())
            .foregroundStyle(state.tone == .success ? AOMColor.successText : AOMColor.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - This Mac strip

/// The live strip on top of the page, one line of figures (Activity Monitor's
/// toolbar and Battery settings): model and macOS, battery percentage and
/// health, startup disk free space, memory pressure, network and uptime.
/// Battery, disk and network open their detail sheet.
struct SystemStatusStrip: View {
    @ObservedObject var monitor: SystemStatusMonitor
    let openBattery: () -> Void
    let openFreeUpSpace: () -> Void
    let openNetworkInfo: () -> Void

    private struct Figure: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        var action: (() -> Void)?
    }

    private var figures: [Figure] {
        var figures: [Figure] = []
        let os = SystemInfo.versionText(ProcessInfo.processInfo.operatingSystemVersion)
        figures.append(Figure(id: "mac", title: "This Mac", value: "macOS \(os)", symbol: "laptopcomputer"))
        if let battery = monitor.battery {
            let health = battery.healthPercent.map { ", \($0)% health" } ?? ""
            figures.append(Figure(id: "battery", title: "Battery", value: "\(battery.percent)%\(health)", symbol: "battery.75percent",
                                  action: openBattery))
        }
        if let disk = monitor.disk {
            figures.append(Figure(id: "disk", title: "Startup Disk", value: "\(SystemStatus.size(disk.available)) free",
                                  symbol: "internaldrive", action: openFreeUpSpace))
        }
        if let memory = monitor.memory {
            figures.append(Figure(id: "memory", title: "Memory", value: memory.pressure, symbol: "memorychip"))
        }
        figures.append(Figure(id: "network", title: "Network", value: networkText, symbol: "network", action: openNetworkInfo))
        figures.append(Figure(id: "uptime", title: "Uptime", value: SystemStatus.uptimeText(monitor.uptime), symbol: "clock"))
        return figures
    }

    private var networkText: String {
        if VPNModel.shared.lastServices?.contains(where: { $0.state == .connected }) == true { return "VPN" }
        if monitor.address == nil { return "Offline" }
        if let ssid = monitor.wifiSSID { return ssid }
        return monitor.address?.interface == "en0" ? "Wi-Fi" : (monitor.address?.interface ?? "Online")
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: AOMSpace.tileGap)], alignment: .leading,
                  spacing: AOMSpace.tileGap) {
            ForEach(figures) { figure in
                let content = HStack(spacing: AOMSpace.x2) {
                    Image(systemName: figure.symbol)
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.row)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(figure.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                        Text(figure.value).font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.text)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AOMSpace.x2)
                .frame(minHeight: AOMSize.rowDetail)
                if let action = figure.action {
                    Button(action: action) { content }
                        .buttonStyle(SystemTileButtonStyle())
                        .help(figure.title)
                        .accessibilityLabel("\(figure.title), \(figure.value)")
                } else {
                    content.aomCard(padding: 0)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(figure.title), \(figure.value)")
                }
            }
        }
    }
}

// MARK: - Review sheets

/// The preview every scan (and the uninstaller) shows before anything moves:
/// checkboxes, sizes, Show in Finder, and one Move to Trash button.
struct CleanupReviewSheet: View {
    let review: CleanupReview
    let onTrash: (CleanupReview) -> Void
    let onCancel: () -> Void

    var body: some View {
        CleanupReviewContent(review: review, onTrash: onTrash, onCancel: onCancel)
            .padding(AOMSpace.x4)
            .frame(width: 640, height: review.groupsByNote ? 540 : 480)
    }
}

/// The review list itself, so the Free Up Space sheet can show it in place.
struct CleanupReviewContent: View {
    let review: CleanupReview
    let onTrash: (CleanupReview) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>

    init(review: CleanupReview, onTrash: @escaping (CleanupReview) -> Void, onCancel: @escaping () -> Void) {
        self.review = review
        self.onTrash = onTrash
        self.onCancel = onCancel
        _selected = State(initialValue: review.selected)
    }

    private var selectedSize: Int64 {
        review.candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Sections in first-seen order of their note (the uninstaller lists the
    /// app, then Application Support, Caches, Preferences …).
    private var sections: [(title: String, items: [CleanupCandidate])] {
        var order: [String] = []
        var grouped: [String: [CleanupCandidate]] = [:]
        for item in review.candidates {
            if grouped[item.note] == nil { order.append(item.note) }
            grouped[item.note, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    @ViewBuilder
    private func row(_ item: CleanupCandidate) -> some View {
        HStack(spacing: AOMSpace.x2) {
            if review.allowsTrash {
                Toggle(item.url.lastPathComponent, isOn: Binding(get: { selected.contains(item.id) },
                                                                 set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: AOMIcon.row - 4, height: AOMIcon.row - 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.url.lastPathComponent).font(AOMFont.body).lineLimit(1).truncationMode(.middle)
                let second = review.hints[item.id] ?? (review.groupsByNote ? item.url.deletingLastPathComponent().path
                    .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") : item.note)
                Text(second)
                    .font(AOMFont.caption)
                    .foregroundStyle(review.hints[item.id] == nil ? AOMColor.textSecondary : AOMColor.warningText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: AOMSpace.x2)
            Text(SystemStatus.size(item.size)).font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
            AOMIconButton("magnifyingglass", label: "Show \(item.url.lastPathComponent) in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .help(item.url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Text(review.title).font(AOMFont.title).lineLimit(1)
                Text(review.detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                if review.groupsByNote {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { row($0) }
                        }
                    }
                } else {
                    ForEach(review.candidates) { row($0) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: !review.groupsByNote))
            .frame(minHeight: 240)
            HStack(spacing: AOMSpace.x2) {
                if review.allowsTrash {
                    Button("Select All") { selected = Set(review.candidates.map(\.id)) }
                    Button("Select None") { selected = [] }
                    Text("\(selected.count) of \(review.candidates.count) · \(SystemStatus.size(selectedSize))")
                        .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                        .contentTransition(.numericText())
                    Spacer()
                    if review.safeDefault {
                        Button("Move \(selected.count) to Trash", role: .destructive) { trash() }
                            .disabled(selected.isEmpty)
                        Button("Cancel", role: .cancel, action: onCancel)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                        Button("Move \(selected.count) to Trash") { trash() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(selected.isEmpty)
                    }
                } else {
                    Text("\(review.candidates.count) items").font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                    Spacer()
                    Button("Done", action: onCancel).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular)
        }
        .onExitCommand(perform: onCancel)
    }

    private func trash() {
        var chosen = review
        chosen.selected = selected
        onTrash(chosen)
    }
}

/// Processes in a sheet, each with Quit (asks first); Activity adds the
/// CPU/Memory sort.
struct ProcessReviewSheet: View {
    let review: ProcessReview
    let onQuit: (ProcessReview.Row) -> Void
    let onSort: (ProcessTools.Order) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x3) {
                Text(review.title).font(AOMFont.title)
                Spacer()
                if let sort = review.sort {
                    Picker("Sort", selection: Binding(get: { sort }, set: onSort)) {
                        Text("CPU").tag(ProcessTools.Order.cpu)
                        Text("Memory").tag(ProcessTools.Order.memory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            List(review.rows) { row in
                HStack(spacing: AOMSpace.x2) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.command).font(AOMFont.bodyEmphasis).lineLimit(1)
                        Text(row.detail).font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: AOMSpace.x2)
                    Button("Quit…") { onQuit(row) }
                }
                .help(row.detail)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)
            HStack {
                Text("Quit asks the process to stop (SIGTERM). Processes of other users can't be stopped from here.")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(AOMSpace.x4)
        .frame(width: 560, height: 380)
    }
}
