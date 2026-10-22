import SwiftUI

/// Insights: live gesture statistics plus an overview of what is configured,
/// so the page is informative from the first launch, not a blank chart.
struct StatisticsView: View {
    @ObservedObject var stats = GestureStatistics.shared
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false

    private var triggers: [Trigger] { appState.currentPreset.triggers }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AOMDesign.sectionSpacing) {
                    AOMPageHeader("쌓여가는 나의 흐름",
                                  subtitle: "Tracking since \(stats.sessionStart.formatted(date: .abbreviated, time: .omitted))",
                                  systemImage: "chart.xyaxis.line", tint: .green) {
                        Button { confirmingReset = true } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(stats.totalGestures == 0)
                    }
                    overviewCards(columns: geometry.size.width >= 820 ? 4 : 2)
                    let wide = geometry.size.width >= 900
                    if wide {
                        HStack(alignment: .top, spacing: AOMDesign.sectionSpacing) {
                            gestureBreakdown.frame(maxWidth: .infinity)
                            configurationSummary.frame(width: min(340, geometry.size.width * 0.34))
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        gestureBreakdown
                        configurationSummary
                    }
                }
                .padding(AOMDesign.pagePadding)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
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

    private func overviewCards(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AOMDesign.gridSpacing), count: columns),
                  spacing: AOMDesign.gridSpacing) {
            AOMMetricTile(title: "Gestures Detected", value: stats.totalGestures.formatted(),
                          systemImage: "hand.raised.fingers.spread.fill", tint: .blue, detail: "Every recognized input")
            AOMMetricTile(title: "Actions Triggered", value: stats.totalFired.formatted(),
                          systemImage: "bolt.fill", tint: .green, detail: "Match rate \(matchRate)")
            AOMMetricTile(title: "Unmatched", value: stats.unmatchedCount.formatted(),
                          systemImage: "questionmark.circle", tint: .orange, detail: "Detected with no gesture assigned")
            AOMMetricTile(title: "Distinct Gestures", value: stats.uniqueGesturesCount.formatted(),
                          systemImage: "hand.draw.fill", tint: .purple, detail: "Different gestures used")
        }
    }

    // MARK: - Gesture Breakdown

    private var gestureBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Most Used", systemImage: "list.number",
                             caption: stats.sortedEntries.isEmpty ? nil : "\(stats.sortedEntries.count) gestures seen")
            if stats.sortedEntries.isEmpty {
                AOMEmptyState("No Gestures Recorded Yet", systemImage: "hand.tap",
                              message: "Use a trackpad gesture, shortcut or mouse button. Counts and the most-used list appear here as you work.")
                    .frame(minHeight: 260)
                    .aomSurface(padding: nil)
            } else {
                let maxCount = max(1, stats.sortedEntries.first?.totalCount ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(stats.sortedEntries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        GestureStatRow(rank: index + 1, entry: entry, maxCount: maxCount,
                                       accentColor: appState.accentColorChoice.color)
                    }
                }
                .aomSurface(padding: 12)
            }
        }
    }

    // MARK: - Configuration summary

    private var configurationSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            AOMSectionHeader("Your Setup", systemImage: "slider.horizontal.3")
            VStack(spacing: 0) {
                ForEach(Array(TriggerCategory.inputCategories.enumerated()), id: \.element) { index, category in
                    if index > 0 { Divider() }
                    let all = triggers.filter { $0.input.category == category }
                    HStack(spacing: 10) {
                        Image(systemName: category.iconName).frame(width: 20).foregroundStyle(.secondary)
                        Text(category.rawValue)
                        Spacer()
                        Text("\(all.filter(\.isEnabled).count) of \(all.count)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            .aomSurface(padding: 12)
            VStack(spacing: 0) {
                summaryRow("Application profiles", "\(appState.currentPreset.appTargets.filter { !$0.isGlobal }.count)", "app.badge")
                Divider()
                summaryRow("Activation groups", "\(appState.currentPreset.activationGroups.count)", "square.stack.3d.up")
                Divider()
                summaryRow("Snap zones", "\(appState.effectiveSnapZones.filter(\.isEnabled).count)", "rectangle.split.2x2")
                Divider()
                summaryRow("Total actions", "\(triggers.reduce(0) { $0 + $1.actions.count })", "bolt")
            }
            .aomSurface(padding: 12)
        }
    }

    private func summaryRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 8)
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
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.gesture).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    if entry.firedCount > 0 {
                        Text("\(entry.firedCount) fired")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    Text("\(entry.totalCount)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                GeometryReader { geo in
                    let fraction = CGFloat(entry.totalCount) / CGFloat(maxCount)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(accentColor.gradient).frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                if let last = entry.lastDetected {
                    Text("Last used \(last, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
