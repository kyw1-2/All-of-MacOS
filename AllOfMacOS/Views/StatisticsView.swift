import SwiftUI

/// Insights: live gesture statistics plus an overview of what is configured,
/// so the page is informative from the first launch, not a blank chart.
struct StatisticsView: View {
    @ObservedObject var stats = GestureStatistics.shared
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false

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

    /// Page padding and spacing around the sheet (the header is measured);
    /// the sheet takes the rest of the window height so the page reads as one
    /// surface.
    static let chromeHeight: CGFloat = AOMDesign.pagePadding + 18 + 24
    @State private var headerHeight: CGFloat = 59

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(width: geometry.size.width)
            let sheetMinHeight = layout == .stacked ? 0 : max(0, geometry.size.height - Self.chromeHeight - headerHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AOMPageHeader("Insights",
                                  subtitle: "Tracking since \(stats.sessionStart.formatted(date: .abbreviated, time: .omitted))",
                                  systemImage: "chart.xyaxis.line", tint: AOMTheme.positive) {
                        Button { confirmingReset = true } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(stats.totalGestures == 0)
                    }
                    .aomReadHeight($headerHeight)
                    VStack(spacing: 0) {
                        overviewStrip(columns: geometry.size.width >= 760 ? nil : 2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        AOMDivider()
                        switch layout {
                        case .threeColumns:
                            HStack(alignment: .top, spacing: 0) {
                                gestureBreakdown
                                    .padding(20)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                AOMDivider(axis: .vertical)
                                VStack(alignment: .leading, spacing: 12) {
                                    AOMSectionHeader("Inputs", systemImage: "hand.point.up.left")
                                    inputsList
                                }
                                .padding(20)
                                .frame(width: 280)
                                .frame(maxHeight: .infinity, alignment: .top)
                                AOMDivider(axis: .vertical)
                                VStack(alignment: .leading, spacing: 12) {
                                    AOMSectionHeader("Configuration", systemImage: "slider.horizontal.3")
                                    configurationList
                                }
                                .padding(20)
                                .frame(width: 280)
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                            .frame(maxHeight: .infinity)
                        case .twoColumns:
                            HStack(alignment: .top, spacing: 0) {
                                gestureBreakdown
                                    .padding(20)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                AOMDivider(axis: .vertical)
                                configurationSummary
                                    .padding(20)
                                    .frame(width: min(360, geometry.size.width * 0.36))
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                            .frame(maxHeight: .infinity)
                        case .stacked:
                            gestureBreakdown.padding(20)
                            AOMDivider()
                            configurationSummary.padding(20)
                        }
                    }
                    .frame(minHeight: sheetMinHeight, alignment: .top)
                    .aomCardStyle(.paper, radius: 22, padding: 0)
                }
                .padding(.horizontal, AOMDesign.pagePadding)
                .padding(.top, AOMDesign.pagePadding)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .suppressScrollerReservation()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMWorkspaceBackground())
        .confirmationDialog("Reset gesture statistics?", isPresented: $confirmingReset) {
            Button("Reset Statistics", role: .destructive) { stats.reset() }
        } message: {
            Text("Counts start again from zero. Your gestures and actions are not changed.")
        }
    }

    // MARK: - Overview Cards

    private var matchRate: String {
        guard stats.totalGestures > 0 else { return "—" }
        return (Double(stats.totalFired) / Double(stats.totalGestures)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func overviewStrip(columns: Int?) -> some View {
        AOMStatStrip(items: [
            AOMStatItem(title: "Gestures Detected", value: stats.totalGestures.formatted(),
                        detail: "Every recognized input", systemImage: "hand.raised.fingers.spread.fill", tint: AOMTheme.blue),
            AOMStatItem(title: "Actions Triggered", value: stats.totalFired.formatted(),
                        detail: "Match rate \(matchRate)", systemImage: "bolt.fill", tint: AOMTheme.positive),
            AOMStatItem(title: "Unmatched", value: stats.unmatchedCount.formatted(),
                        detail: "Detected with no gesture assigned", systemImage: "questionmark", tint: AOMTheme.orange),
            AOMStatItem(title: "Distinct Gestures", value: stats.uniqueGesturesCount.formatted(),
                        detail: "Different gestures used", systemImage: "hand.draw.fill", tint: AOMTheme.purple)
        ], columns: columns)
    }

    // MARK: - Gesture Breakdown

    private var gestureBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Most Used", systemImage: "list.number",
                             caption: stats.sortedEntries.isEmpty ? nil : "\(stats.sortedEntries.count) gestures seen")
            if stats.sortedEntries.isEmpty {
                AOMEmptyState("No Gestures Recorded Yet", systemImage: "hand.tap",
                              message: "Use a trackpad gesture, shortcut or mouse button. Counts and the most-used list appear here as you work.")
                    .frame(minHeight: 240)
            } else {
                let maxCount = max(1, stats.sortedEntries.first?.totalCount ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(stats.sortedEntries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { AOMDivider() }
                        GestureStatRow(rank: index + 1, entry: entry, maxCount: maxCount,
                                       accentColor: appState.accentColorChoice.color)
                    }
                }
            }
        }
    }

    // MARK: - Configuration summary

    /// "Your Setup": inputs then configuration, for the narrower layouts.
    private var configurationSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Your Setup", systemImage: "slider.horizontal.3")
            Text("Inputs").aomSectionCaps().padding(.top, 2)
            inputsList
            Text("Configuration").aomSectionCaps().padding(.top, 10)
            configurationList
        }
    }

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
                .font(.system(size: 14))
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
        .font(.system(size: 14))
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
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(AOMTheme.positive)
                    }
                    Text("\(entry.totalCount)")
                        .font(.system(size: 14.5, weight: .bold).monospacedDigit())
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
                        .font(.system(size: 12))
                        .foregroundStyle(AOMTheme.textTertiary)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
