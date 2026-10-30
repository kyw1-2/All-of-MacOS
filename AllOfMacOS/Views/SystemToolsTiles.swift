import SwiftUI

// MARK: - Tool tile

/// One tool, one row tall: glyph in the group's hue, the name, and on the
/// right either a small live state pill or a spinner while it runs. The
/// tooltip carries the one-line description; right-click pins it.
struct SystemToolTile: View {
    let info: SystemToolInfo
    let state: SystemToolState?
    let isRunning: Bool
    let isFavorite: Bool
    let run: () -> Void
    let toggleFavorite: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: info.symbol)
                    .font(AOMFont.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(info.group.tint)
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .accessibilityHidden(true)
                Text(info.title)
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: AOMSpace.x1)
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else if let state {
                    SystemToolStatePill(state: state)
                }
            }
            .padding(.horizontal, AOMSpace.x2 + 2)
            .frame(maxWidth: .infinity, minHeight: AOMSize.rowStandard, alignment: .leading)
            .background(hovering ? AOMColor.track : AOMColor.sunken.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .help(info.help)
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
        }
        .accessibilityLabel(info.title)
        .accessibilityValue(isRunning ? "Running" : (state?.text ?? ""))
        .accessibilityHint(info.help)
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", toggleFavorite)
    }
}

/// A compact state capsule for tiles: on in the success colour, off and
/// values in secondary text.
struct SystemToolStatePill: View {
    let state: SystemToolState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = state.tone == .success ? AOMColor.success : AOMColor.paused
        Text(state.text)
            .font(AOMFont.badge)
            .foregroundStyle(state.tone == .success ? AOMColor.successText : AOMColor.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, AOMSpace.x1 + 2)
            .padding(.vertical, 1)
            .background(tint.opacity(scheme == .dark ? 0.22 : 0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Status strip

/// The live readouts on top of the page (Stats / iStat Menus style), as a
/// grid of small cells that wraps in narrow windows.
struct SystemStatusStrip: View {
    @ObservedObject var monitor: SystemStatusMonitor

    private struct Cell: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let value: String
        let detail: String
        var tone: AOMTone?
    }

    private var cells: [Cell] {
        var cells: [Cell] = []
        cells.append(Cell(title: "CPU", symbol: "cpu", value: monitor.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "…",
                          detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                          tone: (monitor.cpuPercent ?? 0) > 85 ? .warning : nil))
        if let memory = monitor.memory {
            cells.append(Cell(title: "Memory", symbol: "memorychip", value: SystemStatus.memorySize(memory.used),
                              detail: "of \(SystemStatus.memorySize(memory.total)) · \(memory.pressure)",
                              tone: (memory.pressureLevel ?? 1) > 1 ? .warning : nil))
        }
        if let disk = monitor.disk {
            cells.append(Cell(title: "Disk Free", symbol: "internaldrive", value: SystemStatus.size(disk.available),
                              detail: "of \(SystemStatus.size(disk.total))",
                              tone: disk.total > 0 && Double(disk.available) / Double(disk.total) < 0.1 ? .warning : nil))
        }
        if let battery = monitor.battery {
            // The power state rides with the charge so health and cycles fit
            // the detail line.
            var detail: [String] = []
            if let health = battery.healthPercent { detail.append("\(health)% health") }
            if let cycles = battery.cycleCount { detail.append("\(cycles) cycles") }
            let power = battery.isCharging ? " · Charging" : (battery.onPower ? " · AC" : "")
            cells.append(Cell(title: "Battery", symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                              value: "\(battery.percent)%\(power)", detail: detail.isEmpty ? battery.state : detail.joined(separator: " · "),
                              tone: !battery.onPower && battery.percent <= 15 ? .warning : nil))
        } else if !monitor.hasBattery {
            cells.append(Cell(title: "Power", symbol: "powerplug", value: "AC", detail: "No battery"))
        }
        cells.append(Cell(title: "Uptime", symbol: "clock", value: SystemStatus.uptimeText(monitor.uptime), detail: "since restart"))
        cells.append(Cell(title: "Thermal", symbol: "thermometer.medium", value: SystemStatus.thermalText(monitor.thermal),
                          detail: "macOS thermal state",
                          tone: monitor.thermal == .serious || monitor.thermal == .critical ? .warning : nil))
        cells.append(Cell(title: "Local IP", symbol: "network", value: monitor.address?.address ?? "Offline",
                          detail: monitor.address?.interface ?? "no IPv4 address"))
        return cells
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: AOMSpace.tileGap)], alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(cells) { cell in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: AOMSpace.x1) {
                        Image(systemName: cell.symbol).imageScale(.small).foregroundStyle(AOMColor.textSecondary)
                        Text(cell.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                    }
                    Text(cell.value)
                        .font(AOMFont.metric)
                        .foregroundStyle(cell.tone?.textColor ?? AOMColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(cell.detail).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                        .minimumScaleFactor(0.85).truncationMode(.tail)
                }
                .padding(.horizontal, AOMSpace.x2 + 2)
                .padding(.vertical, AOMSpace.x1 + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AOMColor.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                .help("\(cell.title): \(cell.value), \(cell.detail)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(cell.title), \(cell.value), \(cell.detail)")
            }
        }
    }
}

// MARK: - Cleanup review

/// The preview list every new cleanup tool shows before anything moves:
/// checkboxes, sizes, Reveal in Finder, and one Move to Trash button.
struct CleanupReviewSheet: View {
    let review: SystemToolsModel.CleanupReview
    let onTrash: (SystemToolsModel.CleanupReview) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>

    init(review: SystemToolsModel.CleanupReview, onTrash: @escaping (SystemToolsModel.CleanupReview) -> Void, onCancel: @escaping () -> Void) {
        self.review = review
        self.onTrash = onTrash
        self.onCancel = onCancel
        _selected = State(initialValue: review.selected)
    }

    private var selectedSize: Int64 {
        review.candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Text(review.title).font(AOMFont.title).lineLimit(1)
                Text(review.detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(review.candidates) { item in
                    HStack(spacing: AOMSpace.x2) {
                        Toggle("", isOn: Binding(get: { selected.contains(item.id) },
                                                 set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.url.lastPathComponent).font(AOMFont.body).lineLimit(1).truncationMode(.middle)
                            Text(item.note).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: AOMSpace.x2)
                        Text(SystemStatus.size(item.size)).font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                            .accessibilityLabel("Show \(item.url.lastPathComponent) in Finder")
                    }
                    .help(item.url.path)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 240)
            HStack(spacing: AOMSpace.x2) {
                Button("Select All") { selected = Set(review.candidates.map(\.id)) }
                Button("Select None") { selected = [] }
                Text("\(selected.count) of \(review.candidates.count) · \(SystemStatus.size(selectedSize))")
                    .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move \(selected.count) to Trash") {
                    var chosen = review
                    chosen.selected = selected
                    onTrash(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(AOMSpace.x4)
        .frame(width: 640, height: 480)
    }
}

// MARK: - Process review

/// Processes holding a port or a file, each with Quit (asks first).
struct ProcessReviewSheet: View {
    let review: SystemToolsModel.ProcessReview
    let onQuit: (SystemToolsModel.ProcessReview.Row) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text(review.title).font(AOMFont.title)
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
        .frame(width: 560, height: 360)
    }
}
