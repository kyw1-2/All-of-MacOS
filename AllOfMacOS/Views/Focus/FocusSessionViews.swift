import Charts
import SwiftUI

// MARK: - Status header

/// The big session control (Clock's timers, Flighty's live status): the
/// ring with the time left, the phase, and Start / Pause / Resume / Skip /
/// Stop. Only this view observes the 1 Hz ticker.
struct FocusSessionHeader: View {
    @ObservedObject var session: FocusSessionController
    @ObservedObject var ticker: FocusTicker
    @ObservedObject var settings: FocusSettingsStore

    var body: some View {
        let now = ticker.now
        let timer = session.timer
        let plan = settings.settings.plan
        if let run = timer.run {
            AOMStatusHeader(.focus, active: !run.isPaused, title: run.phase.title,
                            figure: FocusDurationFormat.countdown(run.remaining(at: now)), unit: "left",
                            detail: Self.runningDetail(run: run, timer: timer, now: now),
                            status: run.isPaused ? AOMStatus("Paused", tone: .neutral, symbol: "pause.fill") : nil,
                            progress: run.progress(at: now)) {
                if run.isPaused {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                        .aomPrimaryButton()
                        .help("Continues the \(run.phase.title.lowercased())")
                } else {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .help("Pauses the countdown")
                }
                Button { session.skip() } label: {
                    Label(Self.skipTitle(run: run, plan: timer.plan), systemImage: "forward.end.fill")
                }
                .help(run.phase == .focus ? "Ends this focus early and starts the break" : "Ends the break and starts the next focus")
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Ends the session; focused minutes stay in the log")
            }
            .accessibilityValue("\(FocusDurationFormat.spoken(run.remaining(at: now))) left")
        } else {
            AOMStatusHeader(.focus, active: false, title: "Focus",
                            figure: FocusDurationFormat.countdown(plan.length(of: .focus)), unit: nil,
                            detail: Self.idleDetail(timer: timer, plan: plan, now: now)) {
                Button { session.start() } label: { Label("Start Focus", systemImage: "play.fill") }
                    .aomPrimaryButton()
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Starts a \(plan.focusMinutes) min focus (⌘↩)")
            }
        }
    }

    static func skipTitle(run: FocusRun, plan: FocusPlan) -> String {
        if run.phase == .focus { return plan.breaksEnabled ? "Skip to Break" : "Finish Now" }
        return "Skip Break"
    }

    static func runningDetail(run: FocusRun, timer: FocusTimer, now: Date) -> String {
        var parts: [String] = []
        if run.isPaused {
            parts.append("Paused at \((run.pausedAt ?? now).formatted(date: .omitted, time: .shortened))")
        } else if let end = run.endsAt {
            parts.append("Ends at \(end.formatted(date: .omitted, time: .shortened))")
        }
        let plan = timer.plan
        switch run.phase {
        case .focus:
            if plan.breaksEnabled && plan.longBreaksEnabled {
                parts.append("Session \(timer.sessionNumberInCycle) of \(plan.sessionsBeforeLongBreak)")
            }
        case .shortBreak, .longBreak:
            parts.append("Then \(plan.focusMinutes) min focus\(plan.autoStartsNextSession ? "" : " when you start it")")
        }
        return parts.joined(separator: " · ")
    }

    static func idleDetail(timer: FocusTimer, plan: FocusPlan, now: Date) -> String {
        guard plan.breaksEnabled else { return "\(plan.focusMinutes) min focus, no breaks" }
        var text = "\(plan.focusMinutes) min focus, \(plan.breakMinutes) min break"
        if plan.longBreaksEnabled {
            text += " · \(plan.longBreakMinutes) min break after \(plan.sessionsBeforeLongBreak) sessions"
        }
        return text
    }
}

// MARK: - Quick lengths

/// 25/5, 50/10, 90/15 or Custom… (the popover sets each length).
struct FocusLengthPicker: View {
    @ObservedObject var session: FocusSessionController
    @ObservedObject var settings: FocusSettingsStore
    @State private var showsCustom = false

    init(session: FocusSessionController, settings: FocusSettingsStore) {
        self.session = session
        self.settings = settings
    }

    var body: some View {
        let plan = settings.settings.plan
        HStack(spacing: AOMSpace.x3) {
            Text("Length")
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.textSecondary)
            Picker("Length", selection: Binding(
                get: { plan.preset?.id ?? "custom" },
                set: { id in
                    if let preset = FocusLengthPreset.all.first(where: { $0.id == id }) {
                        session.setPlan(plan.applying(preset))
                    } else {
                        showsCustom = true
                    }
                })) {
                ForEach(FocusLengthPreset.all) { preset in
                    Text(preset.title).tag(preset.id).accessibilityLabel(preset.accessibilityTitle)
                }
                Text(plan.preset == nil ? "Custom · \(plan.focusMinutes)/\(plan.breakMinutes)" : "Custom…").tag("custom")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Focus and break lengths in minutes")
            .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
                FocusCustomLengths(session: session, settings: settings)
            }
            if plan.preset == nil {
                Button("Edit…") { showsCustom = true }
                    .buttonStyle(.link)
                    .help("Changes the custom lengths")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.x0_5)
    }
}

/// The Custom… popover: focus, break and long-break minutes.
struct FocusCustomLengths: View {
    @ObservedObject var session: FocusSessionController
    @ObservedObject var settings: FocusSettingsStore

    var body: some View {
        let plan = settings.settings.plan
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text("Custom Lengths").font(AOMFont.headline)
            stepper("Focus", value: plan.focusMinutes, range: 5...240, step: 5) { var p = plan; p.focusMinutes = $0; return p }
            stepper("Break", value: plan.breakMinutes, range: FocusPlan.breakRange, step: 1) { var p = plan; p.breakMinutes = $0; return p }
            stepper("Long break", value: plan.longBreakMinutes, range: 5...90, step: 5) { var p = plan; p.longBreakMinutes = $0; return p }
            Text("A running focus keeps its length; the next ones use these.")
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AOMSpace.x4)
        .frame(width: 280)
    }

    private func stepper(_ title: String, value: Int, range: ClosedRange<Int>, step: Int,
                         change: @escaping (Int) -> FocusPlan) -> some View {
        Stepper(value: Binding(get: { value }, set: { session.setPlan(change($0)) }), in: range, step: step) {
            HStack {
                Text(title).font(AOMFont.body)
                Spacer()
                Text("\(value) min").font(AOMFont.body.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue("\(value) minutes")
    }
}

// MARK: - Today

/// Today's and this week's sessions and minutes, and the last seven days.
struct FocusTodaySection: View {
    let stats: FocusStats

    var body: some View {
        AOMSection("Today", help: "A session counts when a focus runs to its end. Stopped or skipped focus keeps its minutes.") {
            AOMStatStrip(items: [
                AOMStatItem(title: "Sessions", value: "\(stats.todaySessions)", unit: nil, detail: "today",
                            systemImage: "checkmark.circle", tint: AOMModule.focus.hue),
                AOMStatItem(title: "Focused", value: "\(stats.todayMinutes)", unit: "min", detail: "today",
                            systemImage: "timer", tint: AOMModule.focus.hue),
                AOMStatItem(title: "This week", value: "\(stats.weekSessions)",
                            unit: stats.weekSessions == 1 ? "session" : "sessions",
                            detail: FocusTodaySection.hours(stats.weekMinutes), systemImage: "calendar", tint: AOMModule.focus.hue)
            ])
            AOMRowDivider()
            FocusWeekChart(days: stats.lastSevenDays)
                .frame(height: 112)
                .padding(.horizontal, AOMSpace.cardPadding)
                .padding(.vertical, AOMSpace.x3)
        }
    }

    static func hours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }
}

/// Seven bars of focused minutes in the Focus hue; today in full colour,
/// earlier days lighter, weekday labels, three grid lines at most.
struct FocusWeekChart: View {
    let days: [FocusDayTotal]

    var body: some View {
        let peak = days.map(\.minutes).max() ?? 0
        let today = days.last?.day
        Chart(days) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.minutes), width: .ratio(0.55))
                .foregroundStyle(day.day == today ? AOMModule.focus.hue : AOMModule.focus.hue.opacity(0.45))
                .cornerRadius(3)
        }
        .chartYScale(domain: 0...max(30, peak))
        .chartXAxis {
            AxisMarks(values: days.map(\.day)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(AOMFont.caption.weight(date == today ? .bold : .regular))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel().font(AOMFont.caption)
            }
        }
        .overlay {
            if peak == 0 {
                Text("No focus this week yet")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .padding(.horizontal, AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x1)
                    .background(AOMColor.overlaySurface, in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focused minutes, last 7 days")
        .accessibilityValue(days.map { day in
            "\(day.day.formatted(.dateTime.weekday(.wide))): \(day.minutes) minutes, \(day.sessions) sessions"
        }.joined(separator: "; "))
    }
}

// MARK: - During focus

/// Loads the Shortcuts list once per page visit (and on Refresh).
@MainActor
final class FocusShortcutsModel: ObservableObject {
    @Published private(set) var shortcuts: [FocusShortcutRef] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    private var loaded = false

    func loadIfNeeded() { if !loaded { reload() } }

    func reload() {
        guard !loading else { return }
        loading = true
        FocusShortcutsCLI.list { [weak self] result in
            guard let self else { return }
            self.loading = false
            self.loaded = true
            switch result {
            case .success(let list):
                self.shortcuts = list
                self.problem = list.isEmpty ? "No shortcuts yet. Make one in the Shortcuts app." : nil
            case .failure(let error):
                self.problem = "Couldn't list shortcuts because \(error.errorDescription ?? "Shortcuts failed")."
            }
        }
    }
}

/// What a focus phase does: hide distracting apps, mute, keep awake, run
/// shortcuts, the menu bar countdown and the end sound.
struct FocusDuringSection: View {
    @ObservedObject var settings: FocusSettingsStore
    @ObservedObject var lists: FocusListsStore
    @ObservedObject var session: FocusSessionController
    @StateObject private var shortcuts = FocusShortcutsModel()
    let removeDistraction: (FocusAppRef) -> Void

    init(settings: FocusSettingsStore, lists: FocusListsStore, session: FocusSessionController,
         removeDistraction: @escaping (FocusAppRef) -> Void) {
        self.settings = settings
        self.lists = lists
        self.session = session
        self.removeDistraction = removeDistraction
    }

    static let shortcutsHelp = "macOS gives apps no way to turn a Focus such as Do Not Disturb on or off. Make a shortcut with the Shortcuts app's Set Focus action and choose it here; Focus runs it when a focus starts or ends."

    var body: some View {
        let options = settings.settings
        AOMSection("During focus", footer: "macOS gives apps no direct way to turn on a Focus such as Do Not Disturb, so choose a shortcut that uses Set Focus. Changes apply from the next focus.") {
            if let problem = session.shortcutProblem {
                AOMNotice(.warning, problem) {
                    Button("Refresh") { shortcuts.reload() }
                }
                .padding(AOMSpace.x2)
            }
            AOMToggleRow("Hide distracting apps", detail: "At the start, and again if one comes forward",
                         symbol: "eye.slash", isOn: $settings.settings.hidesDistractions)
            FocusDistractionsRow(lists: lists, remove: removeDistraction)
                .disabled(!options.hidesDistractions)
                .opacity(options.hidesDistractions ? 1 : AOMRowControlMetrics.dependentOpacity)
            AOMToggleRow("Remind me when one is hidden", detail: "A short note with the time left", indent: true,
                         isOn: $settings.settings.showsDistractionHUD)
                .disabled(!options.hidesDistractions)
            AOMToggleRow("Mute sound", detail: "Sound comes back on when the focus ends", symbol: "speaker.slash",
                         isOn: $settings.settings.mutesSound)
            AOMToggleRow("Keep the Mac awake", detail: "The display stays on until the focus ends", symbol: "flask",
                         isOn: $settings.settings.keepsAwake)
            shortcutRow("At the start, run", symbol: "play.circle", selection: $settings.settings.startShortcut)
            shortcutRow("At the end, run", symbol: "stop.circle", selection: $settings.settings.endShortcut)
            AOMToggleRow("Countdown in the menu bar", detail: "Its own item, shown only while a session runs",
                         symbol: "menubar.rectangle", isOn: $settings.settings.showsMenuBarCountdown)
            AOMSettingRow("Sound at the end", symbol: "bell") {
                Picker("Sound at the end", selection: $settings.settings.endSound) {
                    Text("None").tag("")
                    ForEach(FocusSettings.endSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: options.endSound) { _, name in
                    if !name.isEmpty, !PresetManager.isUIPreview { AOMSystemSound.play(name) }
                }
            }
        }
        .onAppear { shortcuts.loadIfNeeded() }
    }

    private func shortcutRow(_ title: String, symbol: String, selection: Binding<FocusShortcutRef?>) -> some View {
        AOMSettingRow(title, detail: shortcuts.problem, symbol: symbol, help: Self.shortcutsHelp) {
            HStack(spacing: AOMSpace.x1) {
                Picker(title, selection: selection) {
                    Text("Nothing").tag(FocusShortcutRef?.none)
                    if let current = selection.wrappedValue, !shortcuts.shortcuts.contains(current) {
                        Text(current.name).tag(FocusShortcutRef?.some(current))
                    }
                    ForEach(shortcuts.shortcuts) { shortcut in
                        Text(shortcut.name).tag(FocusShortcutRef?.some(shortcut))
                    }
                }
                .frame(maxWidth: 220)
                AOMIconButton("arrow.clockwise", label: "Refresh Shortcuts") { shortcuts.reload() }
                    .disabled(shortcuts.loading)
            }
        }
    }
}

/// The distracting apps as chips with Add App.
struct FocusDistractionsRow: View {
    @ObservedObject var lists: FocusListsStore
    let remove: (FocusAppRef) -> Void

    var body: some View {
        let apps = lists.lists.distractingApps
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            if apps.isEmpty {
                Text("No distracting apps yet.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
            } else {
                AOMFlowLayout(spacing: AOMSpace.x1 + AOMSpace.x0_5, lineSpacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    ForEach(apps) { app in FocusAppChip(app: app) { remove(app) } }
                }
            }
            FocusAddAppMenu(excluded: Set(apps.map(\.bundleID))) { lists.addDistraction($0) }
                .controlSize(.small)
        }
        .padding(.leading, AOMSpace.rowSymbolInset + AOMSpace.x5)
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Distracting apps")
    }
}

// MARK: - Breaks and reminders

struct FocusBreaksSection: View {
    @ObservedObject var settings: FocusSettingsStore

    var body: some View {
        let plan = settings.settings.plan
        AOMSection("Breaks") {
            AOMToggleRow("Breaks", detail: "A \(plan.breakMinutes) min break follows each focus", symbol: "cup.and.saucer",
                         isOn: $settings.settings.plan.breaksEnabled)
            AOMToggleRow("Long breaks", detail: "\(plan.longBreakMinutes) min after every \(plan.sessionsBeforeLongBreak) sessions",
                         indent: true, isOn: $settings.settings.plan.longBreaksEnabled)
                .disabled(!plan.breaksEnabled)
            AOMSettingRow("Sessions before a long break", indent: true) {
                Stepper("\(plan.sessionsBeforeLongBreak)", value: $settings.settings.plan.sessionsBeforeLongBreak,
                        in: FocusPlan.sessionsRange)
                    .labelsHidden()
                Text("\(plan.sessionsBeforeLongBreak)").font(AOMFont.body.monospacedDigit()).frame(minWidth: 20, alignment: .trailing)
            }
            .disabled(!plan.breaksEnabled || !plan.longBreaksEnabled)
            AOMToggleRow("Start the next focus by itself", detail: "Otherwise Focus waits after a break",
                         symbol: "arrow.triangle.2.circlepath", isOn: $settings.settings.plan.autoStartsNextSession)
                .disabled(!plan.breaksEnabled)
        }
    }
}

struct FocusRemindersSection: View {
    @ObservedObject var settings: FocusSettingsStore
    static let standChoices = [30, 45, 50, 60, 90]

    var body: some View {
        let options = settings.settings
        AOMSection("Break reminders", help: "Reminders wait during a focus break and while AOM is paused. Time away from the Mac (five minutes without input, sleep or a locked screen) counts as a break.") {
            AOMToggleRow("Eye breaks", detail: "Every 20 minutes, look 20 feet away for 20 seconds", symbol: "eye",
                         isOn: $settings.settings.eyeBreaksEnabled)
            AOMToggleRow("Stand-up reminders", detail: "After \(options.standMinutes) min at the screen", symbol: "figure.stand",
                         isOn: $settings.settings.standBreaksEnabled)
            AOMSettingRow("Remind after", indent: true) {
                Picker("Remind after", selection: $settings.settings.standMinutes) {
                    ForEach(Self.standChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            .disabled(!options.standBreaksEnabled)
        }
    }
}
