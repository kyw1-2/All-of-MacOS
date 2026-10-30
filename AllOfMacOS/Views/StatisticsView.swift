import SwiftUI

/// Insights: live gesture statistics plus an overview of what is configured,
/// so the page is informative from the first launch, not a blank chart.
struct StatisticsView: View {
    @ObservedObject var stats = GestureStatistics.shared
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false
    @AppStorage("AOMInsightsPeriod") private var period: Period = .week

    /// The question each figure answers is scoped to one period.
    enum Period: String, CaseIterable, Identifiable {
        case day = "Last 24 Hours", week = "Last 7 Days", all = "All Time"
        var id: String { rawValue }
        var interval: TimeInterval? {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .all: return nil
            }
        }
    }

    /// Figures for the chosen period. Day and week come from the recent
    /// event log (the latest \(GestureStatistics.recentEventLimit) events);
    /// all time uses the running totals.
    private struct Figures {
        var detected: Int
        var fired: Int
        var distinct: Int
        var entries: [GestureStatEntry]
        var matchRate: String {
            guard detected > 0 else { return "—" }
            return min(1, Double(fired) / Double(detected)).formatted(.percent.precision(.fractionLength(0)))
        }
        var unmatched: Int { max(0, detected - fired) }
    }

    private var figures: Figures {
        guard let interval = period.interval else {
            return Figures(detected: stats.totalGestures, fired: stats.totalFired,
                           distinct: stats.uniqueGesturesCount, entries: stats.sortedEntries)
        }
        let since = Date().addingTimeInterval(-interval)
        var byGesture: [String: GestureStatEntry] = [:]
        var detected = 0, fired = 0
        for event in stats.events where event.timestamp >= since {
            var entry = byGesture[event.gesture] ?? GestureStatEntry(gesture: event.gesture, totalCount: 0, firedCount: 0)
            if event.fired { fired += 1; entry.firedCount += 1 } else { detected += 1; entry.totalCount += 1 }
            entry.lastDetected = max(entry.lastDetected ?? .distantPast, event.timestamp)
            byGesture[event.gesture] = entry
        }
        let entries = byGesture.values.sorted { ($0.totalCount, $0.firedCount) > ($1.totalCount, $1.firedCount) }
        return Figures(detected: detected, fired: fired, distinct: byGesture.count, entries: entries)
    }

    private var triggers: [Trigger] { appState.currentPreset.triggers }

    /// True when the bounded event log starts after the chosen period began,
    /// so day or week figures miss the period's earliest inputs.
    private var periodIsTruncated: Bool {
        guard let interval = period.interval, stats.events.count >= GestureStatistics.recentEventLimit,
              let oldest = stats.events.first?.timestamp else { return false }
        return oldest > Date().addingTimeInterval(-interval)
    }

    /// How the area under the figures is divided at a given page width.
    enum Layout: Equatable {
        /// Most used, inputs and configuration side by side.
        case threeColumns
        /// Most used beside one "Your Setup" column.
        case twoColumns
        /// Everything in one column; the page scrolls.
        case stacked

        init(width: CGFloat) {
            if width >= 1060 { self = .threeColumns } else if width >= 900 { self = .twoColumns } else { self = .stacked }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(width: geometry.size.width)
            let figures = figures
            AOMPage {
                header(figures)
                // Day and week figures come from a bounded event log; the
                // footer says so only when it actually cuts the period short.
                AOMSection(footer: periodIsTruncated
                           ? "These figures cover the latest \(GestureStatistics.recentEventLimit.formatted()) inputs, so earlier activity in this period isn't counted. All Time uses the full totals."
                           : nil,
                           padding: AOMSpace.x1) {
                    overviewStrip(figures, columns: geometry.size.width >= Self.stripSingleRowWidth ? nil : 2)
                }
                switch layout {
                case .threeColumns, .twoColumns:
                    HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                        // Its own height, top-aligned: an empty list must not
                        // stretch to the taller column beside it.
                        mostUsedSection(figures)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                            inputsSection
                            configurationSection
                        }
                        .frame(width: layout == .threeColumns ? AOMSize.tileMax : AOMSize.drawerWidth.lowerBound)
                    }
                case .stacked:
                    mostUsedSection(figures)
                    inputsSection
                    configurationSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aomPage("Insights")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("The period every figure on this page covers")
                Button { confirmingReset = true } label: {
                    Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                }
                .disabled(stats.totalGestures == 0)
                .help("Start counting again from zero")
            }
        }
        .confirmationDialog("Reset gesture statistics?", isPresented: $confirmingReset) {
            Button("Reset Statistics", role: .destructive) { stats.reset() }
        } message: {
            Text("Counts start again from zero. Your gestures and actions are not changed.")
        }
    }

    // MARK: - Header (d.9)

    /// The page's one status: how many automations ran in the period, with
    /// the counting start and the match rate as context. Insights has no
    /// module hue and no master switch; the period lives in the toolbar.
    private func header(_ figures: Figures) -> some View {
        let scope = period == .all ? "so far" : "in the \(period.rawValue.lowercased())"
        let title: String
        if figures.fired == 0 && figures.detected == 0 {
            title = period == .all ? "No activity yet" : "No activity \(scope)"
        } else {
            title = "\(figures.fired.formatted()) automation\(figures.fired == 1 ? "" : "s") ran \(scope)"
        }
        var context = ["Counting since \(stats.sessionStart.formatted(date: .abbreviated, time: .omitted))"]
        if figures.detected > 0 { context.append("\(figures.matchRate) of inputs ran an automation") }
        return AOMPageHeader(title, symbol: "chart.bar.xaxis", subtitle: context.joined(separator: " · "),
                             help: "Insights counts the inputs AOM recognizes on this Mac and the automations they run. The last 24 hours and last 7 days come from the most recent \(GestureStatistics.recentEventLimit.formatted()) inputs; All Time uses running totals. Nothing leaves your Mac.")
    }

    /// Below this width the four figures wrap onto two rows.
    static let stripSingleRowWidth: CGFloat = 760

    private func mostUsedSection(_ figures: Figures) -> some View {
        AOMSection("Most used",
                   detail: figures.entries.isEmpty ? nil
                   : "\(figures.entries.count) input\(figures.entries.count == 1 ? "" : "s") · \(period.rawValue.lowercased())") {
            gestureBreakdown(figures)
        }
    }

    private var inputsSection: some View {
        AOMSection("Inputs", detail: "Automations on, by input") {
            inputsList
        }
    }

    private var configurationSection: some View {
        AOMSection("Configuration") {
            configurationList
        }
    }

    // MARK: - Overview Cards

    private func overviewStrip(_ figures: Figures, columns: Int?) -> some View {
        // Two lines per figure (3.3.5): the header and the toolbar already
        // name the period, so a figure's third line only adds a fact (the
        // match rate), never the period again.
        return AOMStatStrip(items: [
            AOMStatItem(title: "Automations run", value: figures.fired.formatted(), unit: "runs",
                        systemImage: "bolt.fill", tint: AOMTheme.positive),
            AOMStatItem(title: "Inputs recognized", value: figures.detected.formatted(), unit: "inputs",
                        detail: figures.detected > 0 ? "\(figures.matchRate) ran an automation" : nil,
                        systemImage: "hand.raised.fingers.spread", tint: AOMTheme.blue),
            AOMStatItem(title: "Nothing assigned", value: (period == .all ? stats.unmatchedCount : figures.unmatched).formatted(),
                        unit: "inputs", systemImage: "questionmark.circle", tint: AOMTheme.orange),
            AOMStatItem(title: "Different inputs", value: figures.distinct.formatted(), unit: "inputs",
                        systemImage: "square.grid.2x2", tint: AOMTheme.purple)
        ], columns: columns)
    }

    // MARK: - Gesture Breakdown

    private func gestureBreakdown(_ figures: Figures) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if figures.entries.isEmpty {
                AOMCompactEmptyState(period == .all ? "No Gestures Recorded Yet" : "Nothing in the \(period.rawValue)", systemImage: "hand.tap",
                                     message: "Use a trackpad gesture, shortcut or mouse button. Counts and the most-used list appear here as you work.",
                                     centered: true) {
                    if period != .all { Button("Show All Time") { period = .all } }
                }
                .padding(.vertical, AOMSpace.x2)
            } else {
                let maxCount = max(1, figures.entries.map(\.totalCount).max() ?? 1)
                ForEach(Array(figures.entries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                    GestureStatRow(rank: index + 1, entry: entry, maxCount: maxCount,
                                   accentColor: appState.accentColorChoice.color)
                        .overlay(alignment: .top) {
                            if index > 0 { AOMRowDivider(inset: AOMSpace.rowInset + AOMIcon.row + AOMSpace.x2) }
                        }
                }
            }
        }
    }

    // MARK: - Configuration summary

    /// Enabled automations per input device.
    private var inputsList: some View {
        ForEach(TriggerCategory.inputCategories, id: \.self) { category in
            let all = triggers.filter { $0.input.category == category }
            AOMSettingRow(category.insightsTitle, symbol: category.iconName) {
                Text("\(all.filter(\.isEnabled).count) of \(all.count)")
                    .font(AOMFont.body)
                    .monospacedDigit()
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Profiles, groups, zones and the size of the action library.
    @ViewBuilder private var configurationList: some View {
        summaryRow("Application profiles", "\(appState.currentPreset.appTargets.filter { !$0.isGlobal }.count)", "app.badge")
        summaryRow("Activation groups", "\(appState.currentPreset.activationGroups.count)", "square.stack.3d.up")
        summaryRow("Snap zones", "\(appState.effectiveSnapZones.filter(\.isEnabled).count)", "rectangle.split.2x2")
        summaryRow("Total actions", "\(triggers.reduce(0) { $0 + $1.actions.count })", "bolt")
    }

    private func summaryRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        AOMSettingRow(title, symbol: symbol) {
            Text(value)
                .font(AOMFont.body)
                .monospacedDigit()
                .foregroundStyle(AOMColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Input names

private extension TriggerCategory {
    /// The input kinds in the words of Automation's "Start with" list, in
    /// sentence case. `rawValue` is persisted, so it stays as it is.
    var insightsTitle: String {
        switch self {
        case .all: return "All inputs"
        case .trackpad: return "Trackpad gesture"
        case .keyboard: return "Keyboard shortcut"
        case .normalMouse: return "Mouse button"
        case .drawings: return "Drawing"
        case .otherTriggers: return "Other trigger"
        }
    }
}

// MARK: - Gesture Row

/// One input in Most used: rank, name, when it was last used, how often it
/// ran an automation and its count on one line, the usage bar under it.
private struct GestureStatRow: View {
    let rank: Int
    let entry: GestureStatEntry
    let maxCount: Int
    let accentColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Text("\(rank)")
                .font(AOMFont.caption.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AOMIcon.row, alignment: .trailing)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                    Text(entry.gesture).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: AOMSpace.x2)
                    if let last = entry.lastDetected {
                        Text("Last used \(last, style: .relative) ago")
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(1)
                    }
                    if entry.firedCount > 0 {
                        Text("\(entry.firedCount) fired")
                            .font(AOMFont.caption.weight(.medium))
                            .foregroundStyle(AOMColor.successText)
                            .lineLimit(1)
                    }
                    Text("\(entry.totalCount)")
                        .font(AOMFont.bodyEmphasis.monospacedDigit())
                        .foregroundStyle(AOMColor.text)
                }
                GeometryReader { geo in
                    let fraction = CGFloat(entry.totalCount) / CGFloat(maxCount)
                    ZStack(alignment: .leading) {
                        Capsule().fill(AOMColor.track)
                        Capsule().fill(accentColor).frame(width: max(AOMSpace.x1, geo.size.width * fraction))
                    }
                }
                .frame(height: AOMFeatureSize.meter)
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .accessibilityElement(children: .combine)
    }
}
