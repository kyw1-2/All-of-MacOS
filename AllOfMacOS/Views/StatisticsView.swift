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
            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.m) {
                    overviewStrip(figures, columns: geometry.size.width >= 760 ? nil : 2)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 4, elevated: false)
                    switch layout {
                    case .threeColumns, .twoColumns:
                        HStack(alignment: .top, spacing: AOMSpace.m) {
                            mostUsedCard(figures)
                            VStack(alignment: .leading, spacing: AOMSpace.m) {
                                inputsCard
                                configurationCard
                            }
                            .frame(width: layout == .threeColumns ? 320 : 290)
                        }
                    case .stacked:
                        mostUsedCard(figures)
                        inputsCard
                        configurationCard
                    }
                }
                .padding(.horizontal, layout == .stacked ? AOMSpace.m : AOMSpace.l)
                .padding(.top, AOMSpace.m)
                .padding(.bottom, AOMSpace.l)
                .frame(maxWidth: AOMSize.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .suppressScrollerReservation()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMTheme.workspace)
        .navigationTitle("Insights")
        .navigationSubtitle("Counting since \(stats.sessionStart.formatted(date: .abbreviated, time: .omitted))")
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

    private func mostUsedCard(_ figures: Figures) -> some View {
        AOMSectionCard("Most Used", symbol: "chart.bar.fill", tint: AOMMainTab.insights.accentColor,
                       detail: figures.entries.isEmpty ? nil
                       : "\(figures.entries.count) inputs · \(period.rawValue.lowercased())") {
            EmptyView()
        } content: {
            gestureBreakdown(figures)
        }
    }

    private var inputsCard: some View {
        AOMSectionCard("Inputs", symbol: "hand.point.up.left", detail: "Automations on, by input") {
            EmptyView()
        } content: {
            inputsList
        }
    }

    private var configurationCard: some View {
        AOMSectionCard("Configuration", symbol: "slider.horizontal.3") {
            EmptyView()
        } content: {
            configurationList
        }
    }

    // MARK: - Overview Cards

    private func overviewStrip(_ figures: Figures, columns: Int?) -> some View {
        let period = period.rawValue.lowercased()
        return AOMStatStrip(items: [
            AOMStatItem(title: "Automations run", value: figures.fired.formatted(), unit: "runs",
                        detail: period, systemImage: "bolt.fill", tint: AOMTheme.positive),
            AOMStatItem(title: "Inputs recognized", value: figures.detected.formatted(), unit: "inputs",
                        detail: "\(figures.matchRate) ran an automation", systemImage: "hand.raised.fingers.spread", tint: AOMTheme.blue),
            AOMStatItem(title: "Nothing assigned", value: (period == "all time" ? stats.unmatchedCount : figures.unmatched).formatted(),
                        unit: "inputs", detail: "inputs that ran no automation", systemImage: "questionmark.circle", tint: AOMTheme.orange),
            AOMStatItem(title: "Different inputs", value: figures.distinct.formatted(), unit: "gestures",
                        detail: "different inputs \(period)", systemImage: "square.grid.2x2", tint: AOMTheme.purple)
        ], columns: columns)
    }

    // MARK: - Gesture Breakdown

    private func gestureBreakdown(_ figures: Figures) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if figures.entries.isEmpty {
                AOMEmptyState(period == .all ? "No Gestures Recorded Yet" : "Nothing in the \(period.rawValue)", systemImage: "hand.tap",
                              message: "Use a trackpad gesture, shortcut or mouse button. Counts and the most-used list appear here as you work.") {
                    if period != .all { Button("Show All Time") { period = .all } }
                }
                    .frame(minHeight: 240)
            } else {
                let maxCount = max(1, figures.entries.map(\.totalCount).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(figures.entries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { AOMDivider() }
                        GestureStatRow(rank: index + 1, entry: entry, maxCount: maxCount,
                                       accentColor: appState.accentColorChoice.color)
                    }
                }
            }
        }
    }

    // MARK: - Configuration summary

    /// Enabled automations per input device.
    private var inputsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(TriggerCategory.inputCategories.enumerated()), id: \.element) { index, category in
                if index > 0 { AOMDivider() }
                let all = triggers.filter { $0.input.category == category }
                HStack(spacing: 10) {
                    Image(systemName: category.iconName).frame(width: 20).foregroundStyle(GestureVisual.tint(category))
                    Text(category.rawValue).foregroundStyle(AOMTheme.text)
                    Spacer()
                    Text("\(all.filter(\.isEnabled).count) of \(all.count)")
                        .monospacedDigit().foregroundStyle(AOMTheme.textSecondary)
                }
                .font(AOMType.body)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Profiles, groups, zones and the size of the action library.
    private var configurationList: some View {
        VStack(spacing: 0) {
            summaryRow("Application profiles", "\(appState.currentPreset.appTargets.filter { !$0.isGlobal }.count)", "app.badge")
            AOMDivider()
            summaryRow("Activation groups", "\(appState.currentPreset.activationGroups.count)", "square.stack.3d.up")
            AOMDivider()
            summaryRow("Snap zones", "\(appState.effectiveSnapZones.filter(\.isEnabled).count)", "rectangle.split.2x2")
            AOMDivider()
            summaryRow("Total actions", "\(triggers.reduce(0) { $0 + $1.actions.count })", "bolt")
        }
    }

    private func summaryRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(AOMTheme.textTertiary)
            Text(title).foregroundStyle(AOMTheme.text)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(AOMTheme.textSecondary)
        }
        .font(AOMType.body)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gesture Row

private struct GestureStatRow: View {
    let rank: Int
    let entry: GestureStatEntry
    let maxCount: Int
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(AOMTheme.textTertiary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.gesture).font(AOMType.rowTitle).foregroundStyle(AOMTheme.text).lineLimit(1)
                    Spacer()
                    if entry.firedCount > 0 {
                        Text("\(entry.firedCount) fired")
                            .font(AOMType.caption.weight(.medium))
                            .foregroundStyle(AOMTheme.positive)
                    }
                    Text("\(entry.totalCount)")
                        .font(AOMType.bodyEmphasis.monospacedDigit())
                        .foregroundStyle(AOMTheme.text)
                }
                GeometryReader { geo in
                    let fraction = CGFloat(entry.totalCount) / CGFloat(maxCount)
                    ZStack(alignment: .leading) {
                        Capsule().fill(AOMTheme.track)
                        Capsule().fill(accentColor).frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                if let last = entry.lastDetected {
                    Text("Last used \(last, style: .relative) ago")
                        .font(AOMType.caption)
                        .foregroundStyle(AOMTheme.textTertiary)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
