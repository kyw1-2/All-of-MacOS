import SwiftUI

/// The idle-app rules (Quitter): one row per app with its live idle time,
/// memory and what happens next, the Hide and Quit thresholds, the rule's
/// switch and a ⋯ menu; then Add App and Quit Idle Apps Now.
struct FocusIdleAppsSection: View {
    @ObservedObject var idle: FocusIdleAppsController
    @ObservedObject var lists: FocusListsStore
    @ObservedObject var settings: FocusSettingsStore
    let remove: (FocusIdleRule) -> Void

    static let help = "Never touched: Finder, All of MacOS, the app in front, and apps playing or recording audio. Quitting asks the app to quit the normal way, so it can ask to save changes; nothing is force quit."

    var body: some View {
        let options = settings.settings
        let rules = lists.lists.idleRules
        AOMSection("Idle apps", detail: rules.isEmpty ? nil : "\(rules.count)", help: Self.help,
                   footer: "An app is idle while it isn't the app in front. Times count from when Focus began watching.") {
            AOMToggleRow("Hide or quit idle apps", detail: "Only the apps listed here, after the time you set",
                         symbol: "moon.zzz", isOn: $settings.settings.idleAppsEnabled)
            if FocusSystemProbes.isAudioCheckUnsupported {
                AOMNotice(.info, "Needs macOS 14.2 or later",
                          detail: "Focus can't tell which apps play or record audio on this version, so it leaves every app alone.")
                    .padding(AOMSpace.x2)
            }
            if rules.isEmpty {
                AOMInlineEmpty(symbol: "moon.zzz", message: "No apps yet. Add chat, mail or other apps you leave open.")
                    .overlay(alignment: .top) { AOMRowDivider() }
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let rows = idle.rows(now: context.date)
                    ForEach(rows) { row in
                        FocusIdleRuleRow(row: row, now: context.date, enabled: options.idleAppsEnabled,
                                         update: { lists.updateIdleRule($0) }, remove: { remove(row.rule) })
                    }
                }
            }
            HStack(spacing: AOMSpace.x2) {
                FocusAddAppMenu(excluded: Set(rules.map(\.bundleID))) { app in
                    lists.addIdleRule(for: app)
                }
                Spacer(minLength: AOMSpace.x2)
                Button {
                    FocusModule.quitIdleAppsNow()
                } label: {
                    Label("Quit Idle Apps Now", systemImage: "memorychip")
                }
                .disabled(rules.isEmpty)
                .help("Quits the listed apps that aren't in use, after asking")
            }
            .controlSize(.small)
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .overlay(alignment: .top) { AOMRowDivider() }
        }
        .task {
            // Memory is read only while this section is on screen.
            while !Task.isCancelled {
                idle.refreshMemory()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

/// One idle-app rule.
struct FocusIdleRuleRow: View {
    let row: FocusIdleRow
    let now: Date
    let enabled: Bool
    let update: (FocusIdleRule) -> Void
    let remove: () -> Void

    var body: some View {
        let rule = row.rule
        HStack(spacing: AOMSpace.x2) {
            FocusAppIconView(bundleID: rule.bundleID)
                .opacity(row.app == nil ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .font(AOMFont.body)
                    .foregroundStyle(rule.isEnabled ? AOMColor.text : AOMColor.textSecondary)
                    .lineLimit(1)
                Text(row.statusLine(now: now))
                    .font(AOMFont.callout.monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x2)
            Picker("Hide", selection: Binding(get: { rule.hideAfterMinutes }, set: { var r = rule; r.hideAfterMinutes = $0; update(r) })) {
                Text("Never Hide").tag(Int?.none)
                ForEach(FocusIdleRule.hideChoices, id: \.self) { Text("Hide After \($0) min").tag(Int?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Hides \(rule.name) after it has been idle this long")
            Picker("Quit", selection: Binding(get: { rule.quitAfterMinutes }, set: { var r = rule; r.quitAfterMinutes = $0; update(r) })) {
                Text("Never Quit").tag(Int?.none)
                ForEach(FocusIdleRule.quitChoices, id: \.self) { minutes in
                    Text("Quit After \(FocusDurationFormat.short(TimeInterval(minutes * 60)))").tag(Int?.some(minutes))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Quits \(rule.name) after it has been idle this long")
            Toggle("Rule for \(rule.name)", isOn: Binding(get: { rule.isEnabled }, set: { var r = rule; r.isEnabled = $0; update(r) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(rule.isEnabled ? "Turns this rule off" : "Turns this rule on")
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(AOMColor.textSecondary)
            .fixedSize()
            .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
            .help("More for \(rule.name)")
            .accessibilityLabel("More for \(rule.name)")
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.rowDetail)
        .overlay(alignment: .top) { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.name), \(row.statusLine(now: now))")
    }

    @ViewBuilder private var menuItems: some View {
        let rule = row.rule
        Toggle("Quit Early When Memory Runs Low", isOn: Binding(get: { rule.quitsUnderMemoryPressure },
                                                              set: { var r = rule; r.quitsUnderMemoryPressure = $0; update(r) }))
        Divider()
        Button("Remove \(rule.name)", action: remove)
    }

    private var statusColor: Color {
        switch row.exclusion {
        case .playingAudio?, .recording?, .frontmost?: return AOMColor.textSecondary
        case .aomPaused?, .pausedForApp?, .audioUnknown?: return AOMColor.warningText
        default: return AOMColor.textSecondary
        }
    }
}

/// Memory pressure, swap and what Focus freed, and the memory-saver switch.
struct FocusMemorySection: View {
    @ObservedObject var idle: FocusIdleAppsController
    @ObservedObject var settings: FocusSettingsStore
    @ObservedObject var activity: FocusActivityStore
    static let minimumIdleChoices = [1, 5, 10, 15, 30, 60]

    var body: some View {
        let options = settings.settings
        AOMSection("Memory", help: "On an 8 GB Mac, apps left open in the background compete for memory and macOS starts swapping to the disk. When pressure turns yellow or red, Focus quits the idlest listed app first, waits for memory to come back, and stops when pressure is normal.") {
            AOMSettingRow("Memory pressure", detail: pressureDetail, symbol: "gauge.with.dots.needle.33percent") {
                AOMStatusPill(idle.pressure.title, tone: idle.pressure.tone, symbol: idle.pressure.tone.symbol)
            }
            AOMRowDivider()
            AOMStatStrip(items: [
                AOMStatItem(title: "Swap used", value: idle.swapUsedBytes.map(FocusByteFormat.string) ?? "…", unit: nil,
                            detail: "of \(FocusByteFormat.string(FocusSystemProbes.physicalMemory)) memory",
                            systemImage: "arrow.left.arrow.right", tint: AOMColor.info),
                AOMStatItem(title: "Freed today", value: FocusByteFormat.string(activity.freedToday()), unit: nil,
                            detail: "by quitting idle apps", systemImage: "memorychip", tint: AOMModule.focus.hue)
            ])
            AOMRowDivider()
            AOMToggleRow("When memory runs low, quit idle apps first",
                         detail: "The idlest listed app first, until pressure is normal", symbol: "memorychip",
                         isOn: $settings.settings.memoryPressureEnabled)
                .disabled(!options.idleAppsEnabled)
            AOMSettingRow("Only apps idle for at least", indent: true) {
                Picker("Only apps idle for at least", selection: $settings.settings.memoryPressureMinimumIdleMinutes) {
                    ForEach(Self.minimumIdleChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            .disabled(!options.idleAppsEnabled || !options.memoryPressureEnabled)
        }
        .onAppear { idle.refreshPressure() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                idle.refreshPressure()
            }
        }
    }

    private var pressureDetail: String {
        switch idle.pressure {
        case .normal: return "Memory is fine"
        case .warning: return "Apps compete for memory"
        case .critical: return "The Mac is short of memory"
        case .unknown: return "Not available"
        }
    }
}
