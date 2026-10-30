import SwiftUI

// MARK: - Tile button style

/// The press and hover fills shared by every tile on the page (HIG Buttons:
/// custom buttons need a press state). Tiles are opaque surfaces on the
/// canvas, one level deep, never inside another card.
struct SystemTileButtonStyle: ButtonStyle {
    var radius: CGFloat = AOMRadius.well
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(configuration.isPressed ? AOMColor.surfacePressed : hovering ? AOMColor.surfaceHover : AOMColor.surface, in: shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
    }
}

// MARK: - Tool tile

/// One tool, one row tall (36 pt): glyph in the group's hue, the name in
/// Body, and on the right either a small live state pill or a spinner while
/// it runs. The tooltip carries the one-line description; right-click pins it.
struct SystemToolTile: View {
    let info: SystemToolInfo
    let state: SystemToolState?
    let isRunning: Bool
    let isFavorite: Bool
    let run: () -> Void
    let toggleFavorite: () -> Void

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
                    ProgressView().controlSize(.small)
                } else if let state {
                    SystemToolStatePill(state: state)
                }
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(maxWidth: .infinity, minHeight: AOMSize.rowStandard, alignment: .leading)
        }
        .buttonStyle(SystemTileButtonStyle())
        .disabled(isRunning)
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
            .padding(.horizontal, AOMSpace.x2 - 2)
            .padding(.vertical, 2)
            .background(tint.opacity(scheme == .dark ? 0.22 : 0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Control Center toggle tile

/// A Quick Toggle the way Control Center draws its modules: a round glyph
/// that fills with the accent while the setting is on, the name in Headline
/// and the live state under it. Tools without a readable state (Focus,
/// Bluetooth Device) keep a neutral circle and say what a click does.
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
        case .focus: return "Runs your shortcut"
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
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
        }
        .accessibilityLabel(info.title)
        .accessibilityValue(stateLine)
        .accessibilityHint(info.help)
        .accessibilityAddTraits(state != nil ? .isToggle : [])
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", toggleFavorite)
    }
}

// MARK: - Status panel

/// A continuous capacity bar (HIG Gauges, Disk Utility's volume header):
/// accent fill on a track, orange when the value needs attention.
struct SystemCapacityBar: View {
    let fraction: Double
    var warning = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AOMColor.track)
                Capsule().fill(warning ? AOMColor.warning : AOMColor.accent)
                    .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The live readouts on top of the page, like Activity Monitor's footer and
/// Battery settings: a card per figure with a big value, a capacity bar and
/// one detail line, then a facts card (uptime, thermal state, address).
/// Values show "…" until the first sample.
struct SystemStatusPanel: View {
    @ObservedObject var monitor: SystemStatusMonitor

    private struct Gauge: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let value: String
        let fraction: Double?
        let detail: String
        var warning = false
        var help: String?
    }

    private var gauges: [Gauge] {
        var gauges: [Gauge] = []
        let cpu = monitor.cpuPercent
        gauges.append(Gauge(title: "CPU", symbol: "cpu", value: cpu.map { "\(Int($0.rounded()))%" } ?? "…", fraction: cpu.map { $0 / 100 },
                            detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores in use by all apps", warning: (cpu ?? 0) > 85))
        if let memory = monitor.memory {
            gauges.append(Gauge(title: "Memory", symbol: "memorychip", value: SystemStatus.memorySize(memory.used),
                                fraction: memory.total > 0 ? Double(memory.used) / Double(memory.total) : nil,
                                detail: "of \(SystemStatus.memorySize(memory.total)) · pressure \(memory.pressure.lowercased())",
                                warning: (memory.pressureLevel ?? 1) > 1))
        } else {
            gauges.append(Gauge(title: "Memory", symbol: "memorychip", value: "…", fraction: nil, detail: "Reading…"))
        }
        let volumes = monitor.volumes.prefix(3)
        if volumes.isEmpty, let disk = monitor.disk {
            gauges.append(Gauge(title: "Startup Disk", symbol: "internaldrive", value: "\(SystemStatus.size(disk.available)) free",
                                fraction: DiskTools.usedFraction(total: disk.total, available: disk.available),
                                detail: "of \(SystemStatus.size(disk.total))",
                                warning: disk.total > 0 && Double(disk.available) / Double(disk.total) < 0.1))
        }
        for volume in volumes {
            let low = volume.total > 0 && Double(volume.available) / Double(volume.total) < 0.1
            gauges.append(Gauge(title: volume.url.path == "/" ? "\(volume.name) (startup)" : volume.name,
                                symbol: volume.isInternal ? "internaldrive" : "externaldrive",
                                value: "\(SystemStatus.size(volume.available)) free", fraction: volume.usedFraction,
                                detail: "\(SystemStatus.size(volume.used)) used of \(SystemStatus.size(volume.total))", warning: low,
                                help: volume.url.path))
        }
        if let battery = monitor.battery {
            var detail: [String] = []
            if let health = battery.healthPercent { detail.append("\(health)% health") }
            if let cycles = battery.cycleCount { detail.append("\(cycles) cycles") }
            if detail.isEmpty { detail.append(battery.state) }
            // The power state rides in the title so health and cycles fit.
            let power = battery.isCharging ? "Battery · charging" : battery.onPower ? "Battery · on power" : "Battery"
            gauges.append(Gauge(title: power, symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                                value: "\(battery.percent)%", fraction: Double(battery.percent) / 100,
                                detail: detail.joined(separator: " · "), warning: !battery.onPower && battery.percent <= 15))
        }
        return gauges
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = [("Uptime", SystemStatus.uptimeText(monitor.uptime)),
                                         ("Thermal", SystemStatus.thermalText(monitor.thermal))]
        facts.append((monitor.address.map { "IP (\($0.interface))" } ?? "IP", monitor.address?.address ?? "Offline"))
        facts.append(("macOS", SystemInfo.versionText(ProcessInfo.processInfo.operatingSystemVersion)))
        if monitor.battery == nil && !monitor.hasBattery { facts.append(("Power", "AC, no battery")) }
        return facts
    }

    private let columns = [GridItem(.adaptive(minimum: 196), spacing: AOMSpace.tileGap, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AOMSpace.tileGap) {
            ForEach(gauges) { gauge in
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    Label(gauge.title, systemImage: gauge.symbol)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                    Text(gauge.value)
                        .font(AOMFont.metricLarge)
                        .foregroundStyle(gauge.warning ? AOMColor.warningText : AOMColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    SystemCapacityBar(fraction: gauge.fraction ?? 0, warning: gauge.warning)
                        .padding(.vertical, AOMSpace.x0_5)
                    Text(gauge.detail)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .aomCard(padding: AOMSpace.cardPadding)
                .help(gauge.help ?? "\(gauge.title): \(gauge.value), \(gauge.detail)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(gauge.title), \(gauge.value), \(gauge.detail)")
            }
            VStack(alignment: .leading, spacing: AOMSpace.x1 + 2) {
                ForEach(facts, id: \.0) { fact in
                    HStack(spacing: AOMSpace.x2) {
                        Text(fact.0).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        Spacer(minLength: AOMSpace.x2)
                        Text(fact.1).font(AOMFont.callout.monospacedDigit()).foregroundStyle(AOMColor.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .aomCard(padding: AOMSpace.cardPadding)
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
                        if review.allowsTrash {
                            Toggle("", isOn: Binding(get: { selected.contains(item.id) },
                                                     set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                        }
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
                if review.allowsTrash {
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
                } else {
                    Text("\(review.candidates.count) items").font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
                    Spacer()
                    Button("Done", action: onCancel).keyboardShortcut(.defaultAction)
                }
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
