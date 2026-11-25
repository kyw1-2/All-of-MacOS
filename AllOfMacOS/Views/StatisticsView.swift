import Charts
import SwiftUI

/// Insights: live gesture statistics plus an overview of what is configured,
/// so the page is informative from the first launch, not a blank chart.
struct StatisticsView: View {
    /// Observed through `observation`: GestureStatistics publishes on every
    /// detection, which a hidden Insights page must not render.
    let stats = GestureStatistics.shared
    @StateObject private var observation = AOMPageObservation([GestureStatistics.shared.aomChanges])
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false
    @AppStorage("AOMInsightsPeriod") private var period: Period = .week
    /// The bar under the pointer (or clicked): its exact value is shown on
    /// the chart (design-3.4.0 #169).
    @State private var selectedBucket: Date?
    /// D30: the event log shows runs only, or every input.
    @AppStorage("AOMInsightsLogRunsOnly") private var logRunsOnly = true
    @StateObject private var toast = AOMToastModel()

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

    private func figures(now: Date) -> Figures {
        guard let interval = period.interval else {
            return Figures(detected: stats.totalGestures, fired: stats.totalFired,
                           distinct: stats.uniqueGesturesCount, entries: stats.sortedEntries)
        }
        let since = now.addingTimeInterval(-interval)
        var byGesture: [String: GestureStatEntry] = [:]
        var detected = 0, fired = 0
        for event in stats.events where (since...now).contains(event.timestamp) {
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
    private func periodIsTruncated(now: Date) -> Bool {
        guard let interval = period.interval, stats.events.count >= GestureStatistics.recentEventLimit,
              let oldest = stats.events.first?.timestamp else { return false }
        return oldest > now.addingTimeInterval(-interval)
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
            let now = Date()
            let figures = figures(now: now)
            let series = Self.activitySeries(events: stats.events, period: period, now: now)
            AOMPage {
                header(figures)
                AOMSection(help: periodIsTruncated(now: now)
                           ? "The log kept only the latest \(GestureStatistics.recentEventLimit.formatted()) events. All Time uses the full totals."
                           : nil,
                           padding: AOMSpace.x1) {
                    overviewStrip(figures, columns: geometry.size.width >= Self.stripSingleRowWidth ? nil : 2)
                }
                switch layout {
                case .threeColumns, .twoColumns:
                    HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                        // Its own height, top-aligned: an empty list must not
                        // stretch to the taller column beside it.
                        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                            activitySection(series)
                            mostUsedSection(figures)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                            inputsSection
                            configurationSection
                        }
                        .frame(width: layout == .threeColumns ? AOMSize.tileMax : AOMSize.drawerWidth.lowerBound)
                    }
                case .stacked:
                    activitySection(series)
                    mostUsedSection(figures)
                    inputsSection
                    configurationSection
                }
                // D30: the events themselves, apart from the figures above,
                // under the same period (and the chart's selected bar).
                eventLogSection(series, now: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aomPage("Insights")
        .aomObserving(observation)
        .onChange(of: period) { _, _ in selectedBucket = nil }
        .aomPageToolbar {
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
            Button("Reset Statistics", role: .destructive) {
                stats.reset()
                toast.show("Statistics reset; counting starts again now")
            }
        } message: {
            Text("Counts start again from zero. Your gestures and actions are not changed.")
        }
        .aomToast(toast)
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
        return AOMPageHeader(title, subtitle: context.joined(separator: " · "),
                             help: "Insights counts the inputs AOM recognizes on this Mac and the automations they run. The last 24 hours and last 7 days come from the most recent \(GestureStatistics.recentEventLimit.formatted()) inputs; All Time uses running totals. Nothing leaves your Mac.")
    }

    /// Below this width the four figures wrap onto two rows.
    static let stripSingleRowWidth: CGFloat = 760

    // MARK: - Activity chart (design-336 #26–28, #70, #84)

    struct ActivityBucket: Identifiable, Equatable {
        let start: Date
        let runs: Int
        var id: Date { start }
    }

    struct ActivitySeries {
        let buckets: [ActivityBucket]
        let unit: Calendar.Component
        var total: Int { buckets.reduce(0) { $0 + $1.runs } }

        func label(for date: Date) -> String {
            switch unit {
            case .hour: date.formatted(date: .omitted, time: .shortened)
            case .month: date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
            case .year: date.formatted(.dateTime.year())
            default: date.formatted(.dateTime.month(.abbreviated).day())
            }
        }
    }

    /// Calendar-aligned bars include both partial edge bins, but count only
    /// events within the exact rolling period used by the figures and log.
    /// All Time uses the available event history, not a mislabeled 7-day chart.
    static func activitySeries(events: [GestureEvent], period: Period, now: Date,
                               calendar: Calendar = .current) -> ActivitySeries {
        let earliestLogged = events.first(where: { $0.timestamp <= now })?.timestamp ?? now
        let since = period.interval.map { now.addingTimeInterval(-$0) } ?? earliestLogged
        let days = now.timeIntervalSince(since) / 86_400
        let unit: Calendar.Component = switch period {
        case .day: .hour
        case .week: .day
        case .all: days <= 1 ? .hour : (days <= 31 ? .day : (days <= 730 ? .month : .year))
        }
        var counts: [Date: Int] = [:]
        for event in events where event.fired && (since...now).contains(event.timestamp) {
            if let bin = calendar.dateInterval(of: unit, for: event.timestamp) { counts[bin.start, default: 0] += 1 }
        }
        guard !counts.isEmpty, var bin = calendar.dateInterval(of: unit, for: since) else {
            return ActivitySeries(buckets: [], unit: unit)
        }
        var buckets: [ActivityBucket] = []
        while bin.start <= now {
            buckets.append(ActivityBucket(start: bin.start, runs: counts[bin.start, default: 0]))
            guard let next = calendar.dateInterval(of: unit, for: bin.end), next.start > bin.start else { break }
            bin = next
        }
        return ActivitySeries(buckets: buckets, unit: unit)
    }

    private func activitySection(_ series: ActivitySeries) -> some View {
        let total = series.total
        let unit = String(describing: series.unit)
        return AOMSection("Automation runs", detail: period == .all ? "Recorded events" : period.rawValue,
                          help: "One bar per \(unit), from the retained event log. Select a bar to filter the log. All Time figures use running totals.",
                          padding: total == 0 ? 0 : AOMSpace.cardPadding) {
            if total == 0 {
                AOMInlineEmpty(symbol: "chart.bar", message: "No runs recorded in this period.")
            } else {
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    activityChart(series)
                    DisclosureGroup("View run counts") {
                        ForEach(series.buckets) { bucket in
                            Button {
                                selectedBucket = bucket.start
                            } label: {
                                HStack {
                                    Text(series.label(for: bucket.start))
                                    Spacer()
                                    Text("\(bucket.runs.formatted()) \(bucket.runs == 1 ? "run" : "runs")").monospacedDigit()
                                }
                            }
                            .buttonStyle(AOMRowButtonStyle())
                        }
                    }
                    .font(AOMFont.callout)
                }
            }
        }
    }

    // MARK: Event log (D30)

    private func eventLogSection(_ series: ActivitySeries, now: Date) -> some View {
        let bucketStart = bucket(at: selectedBucket, in: series)?.start
        let shown = AOMActivityLog.events(stats.events, now: now, within: period.interval,
                                          bucketStart: bucketStart, hourly: series.unit == .hour, runsOnly: logRunsOnly,
                                          bucketUnit: series.unit)
        let scope = bucketStart.map(series.label(for:)) ?? period.rawValue
        return AOMSection("Event log", detail: shown.isEmpty ? scope : "\(shown.count.formatted()) · \(scope)",
                          help: "The latest \(AOMActivityLog.limit) recorded events in the selected period or bar.") {
            HStack(spacing: AOMSpace.x2) {
                Toggle("Runs only", isOn: $logRunsOnly).toggleStyle(.checkbox).font(AOMFont.callout)
                if bucketStart != nil {
                    Button("Show the whole period") { selectedBucket = nil }.buttonStyle(.link).font(AOMFont.callout)
                }
            }
        } content: {
            if shown.isEmpty {
                AOMInlineEmpty(symbol: "list.bullet.rectangle",
                               message: logRunsOnly ? "No runs recorded in this period." : "No inputs recorded in this period.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, event in
                        HStack(spacing: AOMSpace.x3) {
                            Text(event.timestamp.formatted(date: period == .day ? .omitted : .abbreviated, time: .standard))
                                .font(AOMFont.callout.monospacedDigit())
                                .foregroundStyle(AOMColor.textSecondary)
                                .frame(minWidth: 96, alignment: .leading)
                            Text(event.gesture).font(AOMFont.body).lineLimit(1)
                            Spacer(minLength: AOMSpace.x2)
                            Text(event.fired ? "Ran" : "No automation")
                                .font(AOMFont.callout)
                                .foregroundStyle(event.fired ? AOMColor.success : AOMColor.textTertiary)
                        }
                        .frame(minHeight: AOMSize.rowSingle + AOMSpace.x2)
                        .padding(.horizontal, AOMSpace.rowInset)
                        .overlay(alignment: .top) { if index > 0 { AOMRowDivider(inset: AOMSpace.rowInset) } }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// The bucket a chart selection falls in (the selection is a date inside it).
    private func bucket(at date: Date?, in series: ActivitySeries) -> ActivityBucket? {
        guard let date, let start = Calendar.current.dateInterval(of: series.unit, for: date)?.start else { return nil }
        return series.buckets.first { $0.start == start }
    }

    private func activityChart(_ series: ActivitySeries) -> some View {
        let selected = bucket(at: selectedBucket, in: series)
        let unit = String(describing: series.unit).capitalized
        let peak = series.buckets.map(\.runs).max() ?? 0
        let tickStep = max(1, Int(ceil(Double(peak) / 3)))
        let top = max(1, (peak + tickStep - 1) / tickStep) * tickStep
        let ticks = Array(stride(from: 0, through: top, by: tickStep))
        let labelStep = max(1, (series.buckets.count + 5) / 6)
        let dates = stride(from: 0, to: series.buckets.count, by: labelStep).map { series.buckets[$0].start }
        return Chart {
            ForEach(series.buckets) { bucket in
                BarMark(x: .value(unit, bucket.start, unit: series.unit),
                        y: .value("Runs", bucket.runs), width: .ratio(0.65))
                    .foregroundStyle(bucket.id == selected?.id ? AOMColor.accent : AOMColor.textTertiary)
                    .cornerRadius(AOMRadius.keycap)
                    .accessibilityLabel(series.label(for: bucket.start))
                    .accessibilityValue("\(bucket.runs) run\(bucket.runs == 1 ? "" : "s")")
            }
            if let selected {
                RuleMark(x: .value(unit, selected.start, unit: series.unit))
                    .foregroundStyle(AOMColor.hairline)
                    .annotation(position: .top, spacing: AOMSpace.x1,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(series.label(for: selected.start)) · \(selected.runs.formatted()) \(selected.runs == 1 ? "run" : "runs")")
                            .font(AOMFont.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(AOMColor.text)
                            .padding(.horizontal, AOMSpace.x2)
                            .padding(.vertical, AOMSpace.x0_5)
                            .background(AOMColor.raised, in: Capsule())
                            .overlay(Capsule().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                    }
            }
        }
        .chartXSelection(value: $selectedBucket)
        .chartYScale(domain: 0...top)
        .chartYAxisLabel("Runs", position: .leading)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { _ in
                AxisGridLine()
                AxisValueLabel().font(AOMFont.caption.monospacedDigit())
            }
        }
        .chartXAxis {
            AxisMarks(values: dates) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        Text(series.label(for: date)).font(AOMFont.caption.monospacedDigit())
                    }
                }
            }
        }
        .frame(height: StatisticsMetrics.chartHeight)
        // Room above the top grid line for its label.
        .padding(.top, AOMSpace.x2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automation runs per \(unit.lowercased())")
        .accessibilityValue("\(series.total) recorded runs · \(period.rawValue)")
    }

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
        // Two lines per figure: the header and the toolbar already name the
        // period and the match rate.
        return AOMStatStrip(items: [
            AOMStatItem(title: "Automations run", value: figures.fired.formatted(), unit: "runs",
                        systemImage: "bolt.fill", tint: AOMTheme.positive),
            // The match rate is in the header line, so no figure carries a
            // third line and the four values stay on one baseline.
            AOMStatItem(title: "Inputs recognized", value: figures.detected.formatted(), unit: "inputs",
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
                // design-336 b.9: one row in the card, one button.
                AOMInlineEmpty(symbol: "hand.tap", message: "No inputs recorded in this period.")
            } else {
                let maxCount = max(1, figures.entries.map(\.totalCount).max() ?? 1)
                ForEach(Array(figures.entries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                    GestureStatRow(rank: index + 1, entry: entry, maxCount: maxCount)
                        .contentShape(Rectangle())
                        .contextMenu { mostUsedMenu(entry) }
                        .overlay(alignment: .top) {
                            if index > 0 { AOMRowDivider(inset: AOMSpace.rowInset + StatisticsMetrics.rankColumn + AOMSpace.x3) }
                        }
                }
            }
        }
    }

    /// Flat, unavailable items hidden (b.4).
    @ViewBuilder private func mostUsedMenu(_ entry: GestureStatEntry) -> some View {
        if let trigger = triggers.first(where: { $0.input.displayName == entry.gesture }) {
            Button("Show in Automation") { show(trigger) }
        }
        Button("Copy Input Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.gesture, forType: .string)
            toast.show("Copied “\(entry.gesture)”")
        }
    }

    /// Opens the Automation page on this automation, in its own scope.
    private func show(_ trigger: Trigger) {
        if let group = trigger.activationGroupID {
            appState.selectedActivationGroupID = group
        } else {
            appState.selectedActivationGroupID = nil
            appState.selectedAppTarget = trigger.appBundleID.flatMap { id in
                appState.currentPreset.appTargets.first { $0.bundleID == id }
            } ?? .allApps
        }
        appState.selectedTrigger = trigger
        appState.selectedMainTab = .gestures
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x3) {
            Text("\(rank)")
                .font(AOMFont.headline.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: StatisticsMetrics.rankColumn, alignment: .trailing)
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                    Text(entry.gesture).font(AOMFont.body).foregroundStyle(AOMColor.text).lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: AOMSpace.x2)
                    if let last = entry.lastDetected {
                        // "Last used 3 min. ago", not the long "3 min, 12 sec ago";
                        // mid-sentence, so "Just now" starts lower case.
                        let when = AOMRelativeTime.string(last)
                        Text("Last used \(when.prefix(1).lowercased() + when.dropFirst())")
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .lineLimit(1)
                    }
                    if entry.firedCount > 0 {
                        Text("\(entry.firedCount) fired")
                            .font(AOMFont.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(AOMColor.textSecondary)
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
                        Capsule().fill(AOMColor.textTertiary).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: AOMFeatureSize.meter)
            }
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .accessibilityElement(children: .combine)
    }
}

/// Insights sizes the shared scale does not name.
private enum StatisticsMetrics {
    /// The activity chart: tall enough for three grid lines over 13 pt labels.
    static let chartHeight: CGFloat = 150
    /// The rank column in Most used (two digits of Headline).
    static let rankColumn: CGFloat = 24
}

/// D30: which logged inputs the event log lists — inside the page's period,
/// inside the chart's selected hour or day when one is selected, runs only
/// if asked — newest first, at most `limit`.
enum AOMActivityLog {
    static let limit = 50

    static func events(_ events: [GestureEvent], now: Date, within interval: TimeInterval?, bucketStart: Date?,
                       hourly: Bool, runsOnly: Bool, calendar: Calendar = .current,
                       bucketUnit: Calendar.Component? = nil) -> [GestureEvent] {
        let earliest = interval.map { now.addingTimeInterval(-$0) }
        let unit = bucketUnit ?? (hourly ? .hour : .day)
        let bin = bucketStart.flatMap { calendar.dateInterval(of: unit, for: $0) }
        var result: [GestureEvent] = []
        for event in events.reversed() {
            if let earliest, event.timestamp < earliest { break }
            guard event.timestamp <= now else { continue }
            if runsOnly && !event.fired { continue }
            if let bin, !(bin.start..<bin.end).contains(event.timestamp) { continue }
            result.append(event)
            if result.count == limit { break }
        }
        return result
    }
}
