import AppKit
import SwiftUI

// MARK: - Home

/// The Workspace: everything AOM is doing, on one screen.
///
/// A greeting with the master switch, then a single sheet — summary figures
/// across the top, the automations you use on the left, this Mac's switches
/// and health on the right. The sheet fills the window, so nothing hides below
/// the fold at the default size; only very short windows scroll.
struct AOMHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool

    static let headerHeight: CGFloat = 58
    static let topPadding: CGFloat = 20
    static let headerSpacing: CGFloat = 18
    static let bottomPadding: CGFloat = 24
    /// Below this the sheet keeps its size and the page scrolls instead.
    static let minimumSheetHeight: CGFloat = 400
    static let maximumContentWidth: CGFloat = 1320

    static func sheetHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        max(minimumSheetHeight, height - topPadding - headerHeight - headerSpacing - bottomPadding)
    }

    /// Below this width (the diagnostics drawer is open) the two columns stack
    /// and the page scrolls.
    static let compactWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Self.compactWidth
            let fits = geometry.size.height - Self.topPadding - Self.headerHeight - Self.headerSpacing - Self.bottomPadding
                >= Self.minimumSheetHeight
            ScrollView {
                VStack(alignment: .leading, spacing: Self.headerSpacing) {
                    HomeHeader(compact: compact).frame(height: Self.headerHeight)
                    HomeSheet(height: compact ? nil : Self.sheetHeight(forAvailableHeight: geometry.size.height),
                              showingCommandPalette: $showingCommandPalette)
                }
                .frame(maxWidth: Self.maximumContentWidth)
                .padding(.horizontal, compact ? 20 : AOMDesign.pagePadding)
                .padding(.top, Self.topPadding)
                .padding(.bottom, Self.bottomPadding)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(fits && !compact)
            .suppressScrollerReservation()
        }
        .background(AOMWorkspaceBackground())
    }
}

// MARK: - Header

/// Greeting and one-line status on the canvas; the master switch and the
/// primary action on the trailing edge.
private struct HomeHeader: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var stats = GestureStatistics.shared
    var compact = false

    private var activeCount: Int { appState.currentPreset.triggers.filter(\.isEnabled).count }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Working late"
        }
    }

    private var summary: String {
        let date = Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard appState.globalEnabled else { return "\(date) · Automation is paused — gestures and shortcuts pass through" }
        let ready = "\(activeCount) automation\(activeCount == 1 ? "" : "s") ready"
        if let last = stats.events.last(where: \.fired) {
            return "\(date) · \(ready) · \(last.gesture) ran \(AOMRelativeTime.string(last.timestamp).lowercased())"
        }
        return "\(date) · \(ready)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(AOMType.heroTitle).tracking(AOMType.heroTracking)
                    .foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(summary)
                    .font(.system(size: 14.5))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HomeMasterSwitch()
            Button {
                appState.selectedMainTab = .gestures
                appState.showingAddTrigger = true
            } label: {
                if compact {
                    Image(systemName: "plus").accessibilityLabel("New Automation")
                } else {
                    Label("New Automation", systemImage: "plus")
                }
            }
            .buttonStyle(AOMFilledButtonStyle(height: 38))
            .fixedSize()
            .help("Create an automation")
        }
    }
}

/// The global on/off as a labelled switch in a capsule.
private struct HomeMasterSwitch: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let on = appState.globalEnabled
        HStack(spacing: 10) {
            Circle()
                .fill(on ? AOMTheme.positive : AOMTheme.warning)
                .frame(width: 8, height: 8)
            Text(on ? "Automation on" : "Automation paused")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AOMTheme.text)
                .fixedSize()
            Toggle("Automation", isOn: Binding(get: { appState.globalEnabled },
                                               set: { if $0 != appState.globalEnabled { appState.toggleGlobalEnabled() } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(AOMTheme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(AOMTheme.hairline, lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .help(on ? "Pause every gesture and shortcut" : "Resume automation")
    }
}

// MARK: - The sheet

private struct HomeSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared
    /// A fixed height fills the window; `nil` is the stacked, scrolling layout.
    let height: CGFloat?
    @Binding var showingCommandPalette: Bool

    static let sideColumnWidth: CGFloat = 372

    var body: some View {
        Group {
            if let height {
                VStack(spacing: 0) {
                    HomeSummaryStrip()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    AOMDivider()
                    HStack(spacing: 0) {
                        HomeAutomationsColumn()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        AOMDivider(axis: .vertical)
                        HomeMacColumn(showingCommandPalette: $showingCommandPalette)
                            .frame(width: Self.sideColumnWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: height)
            } else {
                // Stacked: each column gets the height its rows need.
                let automations = appState.currentPreset.triggers.count
                let shownRows = CGFloat(min(max(automations, 2), 6))
                VStack(spacing: 0) {
                    HomeSummaryStrip(columns: 3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    AOMDivider()
                    HomeAutomationsColumn()
                        .frame(height: 66 + shownRows * HomeAutomationsColumn.rowHeight
                               + (automations > 6 ? HomeAutomationsColumn.footerHeight : 0))
                    AOMDivider()
                    HomeMacColumn(showingCommandPalette: $showingCommandPalette)
                        .frame(height: 66 + 5 * HomeMacColumn.rowHeight + HomeMacColumn.quickActionsHeight
                               + (history.entries.isEmpty ? 0 : HomeMacColumn.capturesHeight))
                }
            }
        }
        .aomCardStyle(.paper, radius: 22, padding: 0)
    }
}

// MARK: - Summary strip

private struct HomeSummaryStrip: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var stats = GestureStatistics.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var clipboardShortcuts = ClipboardShortcuts.shared
    @ObservedObject private var captureShortcuts = CaptureShortcuts.shared
    var columns: Int?

    var body: some View {
        AOMStatStrip(items: [automations, tiling, clipboardItem, captures, insights], columns: columns)
    }

    private var automations: AOMStatItem {
        let enabled = appState.currentPreset.triggers.filter(\.isEnabled)
        let parts = TriggerCategory.inputCategories.compactMap { category -> String? in
            let count = enabled.filter { $0.input.category == category }.count
            return count == 0 ? nil : "\(count) \(Self.shortName(category))"
        }
        return AOMStatItem(title: "Automations", value: enabled.count.formatted(), unit: "active",
                           detail: parts.isEmpty ? "Nothing set up yet" : parts.prefix(2).joined(separator: " · "),
                           systemImage: "bolt.fill", tint: AOMTheme.blue) {
            appState.selectedMainTab = .gestures
        }
    }

    private var tiling: AOMStatItem {
        let zones = appState.effectiveSnapZones.filter(\.isEnabled).count
        let on = appState.currentPreset.snappingEnabled
        return AOMStatItem(title: "Window Tiling", value: zones.formatted(), unit: zones == 1 ? "zone" : "zones",
                           detail: on ? "Drag to Snap is on" : "Drag to Snap is off",
                           systemImage: "rectangle.split.2x2.fill", tint: AOMTheme.indigo) {
            appState.selectedMainTab = .snapping
        }
    }

    private var clipboardItem: AOMStatItem {
        let boards = "\(clipboard.boards.count) pinboard\(clipboard.boards.count == 1 ? "" : "s")"
        let detail: String
        if clipboard.paused {
            detail = "History is paused"
        } else if let keys = clipboardShortcuts.shortcut(for: .history)?.displayString {
            detail = "\(boards) · \(keys)"
        } else {
            detail = boards
        }
        return AOMStatItem(title: "Clipboard", value: clipboard.entries.count.formatted(),
                           unit: clipboard.entries.count == 1 ? "item" : "items", detail: detail,
                           systemImage: "doc.on.clipboard.fill", tint: AOMTheme.purple) {
            appState.selectedMainTab = .clipboard
        }
    }

    private var captures: AOMStatItem {
        let count = history.entries.count
        let detail: String
        if let latest = history.entries.first {
            detail = "Latest \(AOMRelativeTime.string(latest.capturedAt).lowercased())"
        } else if let keys = captureShortcuts.shortcut(for: .captureArea)?.displayString {
            detail = "\(keys) to capture an area"
        } else {
            detail = "Nothing captured yet"
        }
        return AOMStatItem(title: "Captures", value: count.formatted(), unit: count == 1 ? "capture" : "captures",
                           detail: detail, systemImage: "camera.viewfinder", tint: AOMTheme.orange) {
            appState.selectedMainTab = .capture
        }
    }

    private var insights: AOMStatItem {
        let rate: String = stats.totalGestures > 0
            ? (Double(stats.totalFired) / Double(stats.totalGestures)).formatted(.percent.precision(.fractionLength(0)))
            : "—"
        return AOMStatItem(title: "Insights", value: stats.totalFired.formatted(), unit: stats.totalFired == 1 ? "run" : "runs",
                           detail: "\(stats.totalGestures.formatted()) detected · \(rate) matched",
                           systemImage: "chart.bar.fill", tint: AOMTheme.positive) {
            appState.selectedMainTab = .insights
        }
    }

    static func shortName(_ category: TriggerCategory) -> String {
        switch category {
        case .trackpad: return "trackpad"
        case .keyboard: return "keyboard"
        case .normalMouse: return "mouse"
        case .drawings: return "drawing"
        case .otherTriggers, .all: return "other"
        }
    }
}

// MARK: - Column header

private struct HomeColumnHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            // Title and count share a baseline; the accessory is centred, so
            // both columns' titles sit on the same line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(AOMTheme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

private struct HomeLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(AOMTheme.blue)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(AOMRowButtonStyle(radius: 8))
    }
}

// MARK: - Automations column

private struct HomeAutomationsColumn: View {
    @EnvironmentObject var appState: AppState

    static let rowHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40

    var body: some View {
        let triggers = appState.currentPreset.triggers
        let ordered = triggers.filter(\.isFavorite) + triggers.filter { !$0.isFavorite }
        VStack(alignment: .leading, spacing: 4) {
            HomeColumnHeader("Automations",
                             detail: triggers.isEmpty ? nil : "\(triggers.filter(\.isEnabled).count) of \(triggers.count) on") {
                if !triggers.isEmpty {
                    HomeLinkButton(title: "View all") { appState.selectedMainTab = .gestures }
                }
            }
            if ordered.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let capacity = max(1, Int(geometry.size.height / Self.rowHeight))
                    let overflow = ordered.count > capacity
                    let fitting = overflow ? max(1, Int((geometry.size.height - Self.footerHeight) / Self.rowHeight)) : ordered.count
                    let shown = Array(ordered.prefix(fitting))
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, trigger in
                            HomeAutomationRow(trigger: trigger, showsDivider: index < shown.count - 1 || overflow)
                        }
                        if overflow {
                            AOMLinkRow(title: "\(ordered.count - shown.count) more in Automation") {
                                appState.selectedMainTab = .gestures
                            }
                            .frame(height: Self.footerHeight)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            AOMIconBadge(systemImage: "bolt.fill", tint: AOMTheme.blue, size: 40, filled: true)
            Text("One shortcut. A whole workflow.").font(.system(size: 16, weight: .semibold)).foregroundStyle(AOMTheme.text)
            Text("Connect a trackpad gesture, a key or a mouse button to the actions you repeat.")
                .font(.system(size: 13.5)).foregroundStyle(AOMTheme.textSecondary)
            Button("Create an Automation") {
                appState.selectedMainTab = .gestures
                appState.showingAddTrigger = true
            }
            .buttonStyle(AOMTintedButtonStyle(height: 34))
            .fixedSize()
            .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }
}

private struct HomeAutomationRow: View {
    @EnvironmentObject var appState: AppState
    let trigger: Trigger
    let showsDivider: Bool
    @State private var hovering = false

    var body: some View {
        let tint = GestureVisual.tint(trigger.input.category)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    appState.selectedTrigger = trigger
                    appState.selectedMainTab = .gestures
                } label: {
                    HStack(spacing: 12) {
                        AOMIconBadge(systemImage: trigger.input.category.iconName,
                                     tint: trigger.isEnabled ? tint : AOMTheme.textTertiary, size: 32, filled: trigger.isEnabled)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(trigger.displayName).font(AOMType.rowTitle).lineLimit(1)
                                    .foregroundStyle(trigger.isEnabled ? AOMTheme.text : AOMTheme.textTertiary)
                                if trigger.isFavorite {
                                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(AOMTheme.orange)
                                        .accessibilityLabel("Pinned")
                                }
                            }
                            Text(detail).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if case .keyboardShortcut(let shortcut) = trigger.input {
                            AOMKeycap(text: shortcut.displayString)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit \(trigger.displayName)")
                Toggle(trigger.displayName, isOn: Binding(get: { trigger.isEnabled },
                                                          set: { appState.setTriggerEnabled($0, triggerID: trigger.id) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 8)
            .frame(height: HomeAutomationsColumn.rowHeight - 1)
            .background(hovering ? AOMTheme.cardAlt : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovering = $0 }
            Rectangle().fill(showsDivider ? AOMTheme.divider : .clear).frame(height: 1).padding(.leading, 52)
        }
    }

    private var detail: String {
        let input = trigger.input.displayName
        let actions = trigger.actions.filter(\.isEnabled).map(\.displayName)
        let summary = actions.isEmpty ? "No actions" : actions.prefix(2).joined(separator: " → ") + (actions.count > 2 ? " +\(actions.count - 2)" : "")
        if case .keyboardShortcut = trigger.input { return summary }
        return input == trigger.displayName ? summary : "\(input) · \(summary)"
    }
}

// MARK: - This Mac column

/// Switches and health for the whole Mac, then one-click launchers and recent
/// captures when the window is tall enough to show them without crowding.
private struct HomeMacColumn: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @Binding var showingCommandPalette: Bool
    @State private var permissions: [(AOMPermission, AOMPermissionStatus)] = []
    @State private var shortcutConflict: ShortcutConflicts.Conflict?

    static let rowHeight: CGFloat = 54
    static let capturesHeight: CGFloat = 132
    static let quickActionsHeight: CGFloat = HomeQuickActions.height + 12

    private var missingPermissions: [AOMPermission] {
        permissions.filter { $0.1 != .granted && $0.1 != .manualReview }.map(\.0)
    }

    /// The Type Text automations whose shortcut needs a stand-in inside
    /// password fields, with that stand-in.
    private var secureAliases: [(name: String, alias: KeyboardShortcut)] {
        appState.currentPreset.triggers.compactMap { trigger in
            guard trigger.isEnabled, trigger.actions.contains(where: { $0.actionType == .typeText && $0.isEnabled }),
                  case .keyboardShortcut(let shortcut) = trigger.input,
                  let alias = SecureInputHotKeys.secureAlias(for: shortcut) else { return nil }
            return (trigger.displayName, alias)
        }
    }

    private var attentionCount: Int { (missingPermissions.isEmpty ? 0 : 1) + (shortcutConflict == nil ? 0 : 1) }

    var body: some View {
        GeometryReader { geometry in
            let rows = rowCount
            let used = 40 + 4 + CGFloat(rows) * Self.rowHeight + 22
            let free = geometry.size.height - used
            // Launchers first (always useful), then captures if there is room.
            let showsQuickActions = free >= Self.quickActionsHeight
            let showsCaptures = !history.entries.isEmpty
                && free - (showsQuickActions ? Self.quickActionsHeight : 0) >= Self.capturesHeight
            VStack(alignment: .leading, spacing: 4) {
                HomeColumnHeader("This Mac",
                                 detail: permissions.isEmpty ? nil : (attentionCount == 0 ? "All good" : "\(attentionCount) to review"))
                VStack(spacing: 0) {
                    permissionsRow
                    if let conflict = shortcutConflict { conflictRow(conflict) }
                    HomeStatusRow(symbol: "rectangle.split.2x2.fill", tint: AOMTheme.indigo, title: "Drag to Snap",
                                  detail: "Snap windows to screen edges and zones") {
                        Toggle("Drag to Snap", isOn: Binding(get: { appState.currentPreset.snappingEnabled },
                                                             set: { appState.setSnappingEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    HomeStatusRow(symbol: "doc.on.clipboard.fill", tint: AOMTheme.purple, title: "Clipboard History",
                                  detail: clipboard.paused ? "Paused — new copies are not saved" : "Saving copies on this Mac, encrypted") {
                        Toggle("Clipboard History", isOn: Binding(get: { !clipboard.paused },
                                                                  set: { $0 ? clipboard.resume() : clipboard.pause() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    passwordRow
                }
                if showsCaptures || showsQuickActions {
                    Spacer(minLength: 0)
                }
                if showsCaptures {
                    HomeRecentCaptures()
                }
                if showsQuickActions {
                    HomeQuickActions(showingCommandPalette: $showingCommandPalette)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .task {
            while !Task.isCancelled {
                let current = AOMPermission.required.map { ($0, $0.status) }
                if current.map(\.1) != permissions.map(\.1) { permissions = current }
                let conflict = ShortcutConflicts.clipboardHistoryConflict()
                if conflict != shortcutConflict { shortcutConflict = conflict }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var rowCount: Int { 4 + (shortcutConflict == nil ? 0 : 1) }

    private var permissionsRow: some View {
        HomeStatusRow(symbol: "checkmark.shield.fill",
                      tint: missingPermissions.isEmpty ? AOMTheme.positive : AOMTheme.warning,
                      title: "Permissions",
                      detail: permissions.isEmpty ? "Checking…" : missingPermissions.isEmpty
                          ? "Everything AOM needs is allowed" : missingPermissions.map(\.title).joined(separator: ", ")) {
            if let first = missingPermissions.first {
                Button("Allow…") { _ = first.openSettings() }
                    .buttonStyle(AOMTintedButtonStyle(height: 30))
                    .fixedSize()
                    .help("Open System Settings to allow \(first.title)")
            } else if !permissions.isEmpty {
                AOMChip(text: "Allowed", tint: AOMTheme.positive, symbol: "checkmark")
            }
        }
    }

    private func conflictRow(_ conflict: ShortcutConflicts.Conflict) -> some View {
        HomeStatusRow(symbol: "exclamationmark.triangle.fill", tint: AOMTheme.warning,
                      title: "\(conflict.shortcut.displayString) is taken",
                      detail: "\(conflict.appName) uses it too") {
            Button("Use \(ShortcutConflicts.alternativeHistoryShortcut.displayString)") {
                ClipboardShortcuts.shared.setShortcut(ShortcutConflicts.alternativeHistoryShortcut, for: .history)
                shortcutConflict = nil
            }
            .buttonStyle(AOMTintedButtonStyle(height: 30))
            .fixedSize()
        }
    }

    private var passwordRow: some View {
        let aliases = secureAliases
        let detail: String
        if let first = aliases.first {
            detail = aliases.count == 1 ? "In password dialogs, press this for \(first.name)" : "In password dialogs, add ⌃ to Type Text shortcuts"
        } else {
            detail = "Type Text works in password fields and macOS dialogs"
        }
        return HomeStatusRow(symbol: "lock.fill", tint: AOMTheme.blue, title: "Password Fields", detail: detail,
                             showsDivider: false) {
            if let first = aliases.first {
                AOMKeycap(text: first.alias.displayString)
                    .help("macOS keeps ⌥ shortcuts for typing inside password fields, so AOM listens for this one there.")
            }
        }
    }
}

/// One status row in the This Mac column.
private struct HomeStatusRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    init(symbol: String, tint: Color, title: String, detail: String, showsDivider: Bool = true,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: symbol, tint: tint, size: 32, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AOMType.rowTitle).foregroundStyle(AOMTheme.text).lineLimit(1)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 8)
            .frame(height: HomeMacColumn.rowHeight - 1)
            .accessibilityElement(children: .combine)
            Rectangle().fill(showsDivider ? AOMTheme.divider : .clear).frame(height: 1).padding(.leading, 52)
        }
    }
}

// MARK: - Recent captures

private struct HomeRecentCaptures: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = CaptureHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Captures").font(.system(size: 14, weight: .semibold)).foregroundStyle(AOMTheme.textSecondary)
                Spacer()
                HomeLinkButton(title: "Library") { appState.selectedMainTab = .capture }
            }
            .padding(.leading, 8)
            HStack(spacing: 8) {
                ForEach(history.entries.prefix(3)) { entry in
                    HomeCaptureThumb(entry: entry)
                }
                ForEach(0..<max(0, 3 - history.entries.prefix(3).count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 6)
    }
}

private struct HomeCaptureThumb: View {
    let entry: CaptureHistoryEntry
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AOMTheme.cardAlt)
            Image(nsImage: entry.thumbnail)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .padding(4)
            if entry.kind == .videoRecording {
                Image(systemName: "play.circle.fill").font(.system(size: 20)).foregroundStyle(.white, .black.opacity(0.45))
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(hovering ? AOMTheme.blue.opacity(0.8) : AOMTheme.hairline, lineWidth: hovering ? 1.5 : 0.75))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }
        .help("\(entry.displayName) · \(AOMRelativeTime.string(entry.capturedAt)) — double-click to annotate")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.displayName), \(AOMRelativeTime.string(entry.capturedAt))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Annotate") { AnnotationEditorController.shared.open(capture: entry, url: entry.fileURL) }
    }
}

// MARK: - Quick actions

/// Three one-click launchers with their shortcuts, in the manner of Toss's
/// quick menu: grey wells on the sheet, glyph and key cap on top, label below.
private struct HomeQuickActions: View {
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var clipboardShortcuts = ClipboardShortcuts.shared
    @ObservedObject private var captureShortcuts = CaptureShortcuts.shared

    static let height: CGFloat = 70

    var body: some View {
        HStack(spacing: 8) {
            HomeQuickTile(title: "Capture", help: "Capture an area of the screen",
                          symbol: "viewfinder", tint: AOMTheme.orange,
                          keys: captureShortcuts.shortcut(for: .captureArea)?.displayString) {
                CaptureCoordinator.shared.captureArea()
            }
            HomeQuickTile(title: "Clipboard", help: "Open the clipboard shelf",
                          symbol: "doc.on.clipboard.fill", tint: AOMTheme.purple,
                          keys: clipboardShortcuts.shortcut(for: .history)?.displayString) {
                ClipboardPanelController.shared.show()
            }
            HomeQuickTile(title: "Search", help: "Search commands, automations and settings",
                          symbol: "magnifyingglass", tint: AOMTheme.blue, keys: "⌘K") {
                showingCommandPalette = true
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

private struct HomeQuickTile: View {
    let title: String
    let help: String
    let symbol: String
    let tint: Color
    let keys: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                    Spacer(minLength: 6)
                    if let keys { AOMKeycap(text: keys) }
                }
                Spacer(minLength: 4)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(hovering ? AOMTheme.track : AOMTheme.cardAlt,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { hovering = $0 }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: hovering)
        .help(keys.map { "\(help) (\($0))" } ?? help)
        .accessibilityLabel(keys.map { "\(title), \($0)" } ?? title)
    }
}

// MARK: - Shared row components

/// Underlined filter tab used by the Automation page.
struct AOMUnderlineTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected || hovering ? AOMTheme.text : AOMTheme.textSecondary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(AOMTheme.blue).frame(height: 2.5) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A launcher row used by the Capture page's tool column.
struct AOMToolButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
                Text(title).font(.system(size: 14, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .foregroundStyle(prominent ? Color.white : AOMTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                if prominent {
                    shape.fill(AOMTheme.blue.aomDarker(hovering ? 0.06 : 0))
                } else if hovering {
                    shape.fill(AOMTheme.cardAlt)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { hovering = $0 }
    }
}

/// Category colours shared by gesture rows and icons.
enum GestureVisual {
    static func tint(_ category: TriggerCategory) -> Color {
        switch category {
        case .trackpad: return AOMTheme.cyan
        case .keyboard: return AOMTheme.orange
        case .normalMouse: return AOMTheme.indigo
        case .drawings: return .pink
        case .otherTriggers: return .gray
        case .all: return AOMTheme.blue
        }
    }
}

/// A titled inset group on a sheet: the grouped `Form` look for custom
/// layouts.
struct AOMGroup<Content: View>: View {
    let title: String?
    let trailing: String?
    @ViewBuilder var content: Content

    init(_ title: String?, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).aomSectionCaps() }
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(AOMTheme.textTertiary) }
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .aomCardStyle(.paper, radius: AOMTheme.cardRadius, padding: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One settings-style row: squircle symbol, title, secondary detail and a
/// trailing control. Optional single/double-click actions, hover highlight.
struct AOMRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var dimmed = false
    var showsDivider = true
    var onSelect: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    init(symbol: String, tint: Color, title: String, detail: String? = nil, dimmed: Bool = false,
         showsDivider: Bool = true, onSelect: (() -> Void)? = nil, onDoubleClick: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.dimmed = dimmed
        self.showsDivider = showsDivider
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.trailing = trailing()
    }

    private var interactive: Bool { onSelect != nil || onDoubleClick != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: symbol, tint: dimmed ? AOMTheme.textTertiary : tint, size: 32, filled: !dimmed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AOMType.rowTitle).lineLimit(1)
                        .foregroundStyle(dimmed ? AOMTheme.textTertiary : AOMTheme.text)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if onSelect != nil {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(hovering && interactive ? AOMTheme.cardAlt : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick?() }, including: onDoubleClick == nil ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded { onSelect?() }, including: onSelect == nil ? .subviews : .all)
            if showsDivider {
                Rectangle().fill(AOMTheme.divider).frame(height: 1).padding(.leading, 54)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect != nil ? .isButton : [])
    }
}

/// Footer link inside a group ("Show All …").
struct AOMLinkRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AOMTheme.blue)
                Spacer()
                if let shortcut { AOMKeycap(text: shortcut) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(hovering ? AOMTheme.cardAlt : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
