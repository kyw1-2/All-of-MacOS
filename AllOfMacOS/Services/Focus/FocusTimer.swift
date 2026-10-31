import Foundation

/// One part of a focus session.
enum FocusPhase: String, Codable, CaseIterable {
    case focus, shortBreak, longBreak

    var isBreak: Bool { self != .focus }

    /// Title Case, for HUDs, menus and the status header.
    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long Break"
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }
}

/// The lengths and break rules a session runs with. Values are clamped on
/// decode and by `normalized`, so a hand-edited or corrupt setting can never
/// produce a zero-length or day-long phase.
struct FocusPlan: Codable, Equatable {
    var focusMinutes = 25
    var breakMinutes = 5
    var longBreakMinutes = 15
    /// A long break follows every N completed focus phases.
    var sessionsBeforeLongBreak = 4
    var breaksEnabled = true
    var longBreaksEnabled = true
    /// After a break, the next focus phase starts by itself.
    var autoStartsNextSession = false

    static let focusRange = 1...240
    static let breakRange = 1...60
    static let longBreakRange = 1...90
    static let sessionsRange = 2...8

    init() {}

    init(focusMinutes: Int, breakMinutes: Int, longBreakMinutes: Int = 15, sessionsBeforeLongBreak: Int = 4,
         breaksEnabled: Bool = true, longBreaksEnabled: Bool = true, autoStartsNextSession: Bool = false) {
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.sessionsBeforeLongBreak = sessionsBeforeLongBreak
        self.breaksEnabled = breaksEnabled
        self.longBreaksEnabled = longBreaksEnabled
        self.autoStartsNextSession = autoStartsNextSession
        self = normalized
    }

    enum CodingKeys: String, CodingKey {
        case focusMinutes, breakMinutes, longBreakMinutes, sessionsBeforeLongBreak
        case breaksEnabled, longBreaksEnabled, autoStartsNextSession
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FocusPlan()
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? defaults.focusMinutes
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? defaults.breakMinutes
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? defaults.longBreakMinutes
        sessionsBeforeLongBreak = try c.decodeIfPresent(Int.self, forKey: .sessionsBeforeLongBreak) ?? defaults.sessionsBeforeLongBreak
        breaksEnabled = try c.decodeIfPresent(Bool.self, forKey: .breaksEnabled) ?? defaults.breaksEnabled
        longBreaksEnabled = try c.decodeIfPresent(Bool.self, forKey: .longBreaksEnabled) ?? defaults.longBreaksEnabled
        autoStartsNextSession = try c.decodeIfPresent(Bool.self, forKey: .autoStartsNextSession) ?? defaults.autoStartsNextSession
        self = normalized
    }

    var normalized: FocusPlan {
        var plan = self
        plan.focusMinutes = Self.clamp(focusMinutes, Self.focusRange)
        plan.breakMinutes = Self.clamp(breakMinutes, Self.breakRange)
        plan.longBreakMinutes = Self.clamp(longBreakMinutes, Self.longBreakRange)
        plan.sessionsBeforeLongBreak = Self.clamp(sessionsBeforeLongBreak, Self.sessionsRange)
        return plan
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(range.upperBound, max(range.lowerBound, value)) }

    func minutes(of phase: FocusPhase) -> Int {
        switch phase {
        case .focus: return focusMinutes
        case .shortBreak: return breakMinutes
        case .longBreak: return longBreakMinutes
        }
    }

    func length(of phase: FocusPhase) -> TimeInterval { TimeInterval(minutes(of: phase)) * 60 }

    /// The preset these lengths match, if any.
    var preset: FocusLengthPreset? {
        FocusLengthPreset.all.first { $0.focusMinutes == focusMinutes && $0.breakMinutes == breakMinutes }
    }

    func applying(_ preset: FocusLengthPreset) -> FocusPlan {
        var plan = self
        plan.focusMinutes = preset.focusMinutes
        plan.breakMinutes = preset.breakMinutes
        plan.longBreakMinutes = preset.longBreakMinutes
        return plan.normalized
    }
}

/// The quick lengths: 25/5, 50/10 and 90/15 (Pomodoro, Flow's 50/10,
/// a 90-minute deep-work block).
struct FocusLengthPreset: Identifiable, Equatable {
    let focusMinutes: Int
    let breakMinutes: Int
    let longBreakMinutes: Int

    var id: String { "\(focusMinutes)/\(breakMinutes)" }
    var title: String { "\(focusMinutes)/\(breakMinutes)" }
    var accessibilityTitle: String { "\(focusMinutes) minutes focus, \(breakMinutes) minutes break" }

    static let pomodoro = FocusLengthPreset(focusMinutes: 25, breakMinutes: 5, longBreakMinutes: 15)
    static let flow = FocusLengthPreset(focusMinutes: 50, breakMinutes: 10, longBreakMinutes: 30)
    static let deepWork = FocusLengthPreset(focusMinutes: 90, breakMinutes: 15, longBreakMinutes: 30)
    static let all = [pomodoro, flow, deepWork]
}

/// The phase that is running or paused. Time is wall-clock time from the
/// injected clock, so a phase keeps counting while the Mac sleeps and a
/// relaunch continues where it was.
struct FocusRun: Codable, Equatable {
    var phase: FocusPhase
    var length: TimeInterval
    /// When the phase began (the log's start time).
    var startedAt: Date
    /// Time counted before the current running segment (pauses excluded).
    var accumulated: TimeInterval = 0
    /// Start of the running segment; nil while paused.
    var segmentStart: Date?
    var pausedAt: Date?

    var isPaused: Bool { segmentStart == nil }

    func elapsed(at now: Date) -> TimeInterval {
        let running = segmentStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(length, accumulated + running)
    }

    func remaining(at now: Date) -> TimeInterval { max(0, length - elapsed(at: now)) }

    func progress(at now: Date) -> Double { length > 0 ? min(1, elapsed(at: now) / length) : 1 }

    /// When the phase ends if nobody pauses it; nil while paused.
    var endsAt: Date? { segmentStart.map { $0.addingTimeInterval(max(0, length - accumulated)) } }
}

/// One focus phase in the session log: completed ones count as sessions,
/// stopped and skipped ones keep their minutes.
struct FocusLogEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var start: Date
    var end: Date
    var plannedMinutes: Int
    var focusedSeconds: TimeInterval
    var completed: Bool

    init(id: UUID = UUID(), start: Date, end: Date, plannedMinutes: Int, focusedSeconds: TimeInterval, completed: Bool) {
        self.id = id
        self.start = start
        self.end = end
        self.plannedMinutes = plannedMinutes
        self.focusedSeconds = max(0, focusedSeconds)
        self.completed = completed
    }
}

/// What a transition did, in order, for the controller to act on (sounds,
/// HUDs, hiding apps, the log). The timer itself has no side effects.
enum FocusTimerEvent: Equatable {
    case started(FocusPhase, at: Date)
    case paused(FocusPhase, at: Date)
    case resumed(FocusPhase, at: Date)
    /// The phase ran to its end at `at` (possibly while the Mac slept).
    case completed(FocusPhase, at: Date)
    case skipped(FocusPhase, at: Date)
    case stopped(FocusPhase, at: Date)
    case logged(FocusLogEntry)

    var date: Date? {
        switch self {
        case .started(_, let at), .paused(_, let at), .resumed(_, let at),
             .completed(_, let at), .skipped(_, let at), .stopped(_, let at): return at
        case .logged(let entry): return entry.end
        }
    }
}

/// The focus session state machine (Session, Flow, Raycast Focus): idle →
/// focus → break → focus …, a long break after every N completed focus
/// phases, pause/resume/skip/stop. Every call takes `now` from the caller's
/// clock; `advance(to:)` completes every phase that ended before `now`, so a
/// Mac that slept through the end of a phase catches up on wake, but never
/// starts a focus phase retroactively.
struct FocusTimer: Codable, Equatable {
    var plan = FocusPlan()
    var run: FocusRun?
    /// Focus phases completed since the last long break.
    var completedInCycle = 0
    var lastFocusEndedAt: Date?

    /// A cycle (the count toward the long break) starts again after this
    /// long without a focus phase.
    static let cycleResetGap: TimeInterval = 2 * 3600
    /// A break that ended this long before `now` (the Mac slept) does not
    /// auto-start the next focus phase: nobody was there to focus.
    static let catchUpTolerance: TimeInterval = 90
    /// Stopped or skipped focus shorter than this is not logged.
    static let minimumLoggedSeconds: TimeInterval = 60

    init(plan: FocusPlan = FocusPlan()) { self.plan = plan.normalized }

    var isIdle: Bool { run == nil }
    var isRunning: Bool { run.map { !$0.isPaused } ?? false }
    var isPaused: Bool { run?.isPaused ?? false }
    var phase: FocusPhase? { run?.phase }
    var nextDeadline: Date? { run?.endsAt }

    /// The 1-based number of the current (or next) focus phase in the cycle.
    var sessionNumberInCycle: Int {
        if let run, run.phase == .longBreak { return plan.sessionsBeforeLongBreak }
        if let run, run.phase == .shortBreak { return max(1, completedInCycle) }
        return completedInCycle + 1
    }

    // MARK: Transitions

    /// Starts a focus phase from idle with `plan` (or the current plan).
    mutating func start(plan newPlan: FocusPlan? = nil, at now: Date) -> [FocusTimerEvent] {
        guard run == nil else { return [] }
        if let newPlan { plan = newPlan.normalized }
        if let last = lastFocusEndedAt, now.timeIntervalSince(last) > Self.cycleResetGap { completedInCycle = 0 }
        if lastFocusEndedAt == nil { completedInCycle = 0 }
        run = FocusRun(phase: .focus, length: plan.length(of: .focus), startedAt: now, segmentStart: now)
        return [.started(.focus, at: now)]
    }

    mutating func pause(at now: Date) -> [FocusTimerEvent] {
        var events = advance(to: now)
        guard var current = run, let segment = current.segmentStart else { return events }
        current.accumulated = min(current.length, current.accumulated + max(0, now.timeIntervalSince(segment)))
        current.segmentStart = nil
        current.pausedAt = now
        run = current
        events.append(.paused(current.phase, at: now))
        return events
    }

    mutating func resume(at now: Date) -> [FocusTimerEvent] {
        guard var current = run, current.isPaused else { return [] }
        current.segmentStart = now
        current.pausedAt = nil
        run = current
        return [.resumed(current.phase, at: now)]
    }

    /// Focus: ends it early (minutes logged, not a completed session) and
    /// starts the short break. Break: starts the next focus phase now.
    mutating func skip(at now: Date) -> [FocusTimerEvent] {
        var events = advance(to: now)
        guard let current = run else { return events }
        events.append(.skipped(current.phase, at: now))
        switch current.phase {
        case .focus:
            if let entry = partialEntry(current, at: now) { events.append(.logged(entry)) }
            lastFocusEndedAt = now
            if plan.breaksEnabled {
                run = FocusRun(phase: .shortBreak, length: plan.length(of: .shortBreak), startedAt: now, segmentStart: now)
                events.append(.started(.shortBreak, at: now))
            } else {
                run = nil
            }
        case .shortBreak, .longBreak:
            run = FocusRun(phase: .focus, length: plan.length(of: .focus), startedAt: now, segmentStart: now)
            events.append(.started(.focus, at: now))
        }
        return events
    }

    /// Ends the session from any phase; a focus phase keeps its minutes.
    mutating func stop(at now: Date) -> [FocusTimerEvent] {
        var events = advance(to: now)
        guard let current = run else { return events }
        events.append(.stopped(current.phase, at: now))
        if current.phase == .focus {
            if let entry = partialEntry(current, at: now) { events.append(.logged(entry)) }
            lastFocusEndedAt = now
        }
        run = nil
        return events
    }

    /// Completes every phase whose end is at or before `now`, in order.
    mutating func advance(to now: Date) -> [FocusTimerEvent] {
        var events: [FocusTimerEvent] = []
        var guardCount = 0
        while let current = run, let end = current.endsAt, now >= end, guardCount < 16 {
            guardCount += 1
            events.append(.completed(current.phase, at: end))
            switch current.phase {
            case .focus:
                completedInCycle += 1
                lastFocusEndedAt = end
                events.append(.logged(FocusLogEntry(start: current.startedAt, end: end,
                                                    plannedMinutes: plan.minutes(of: .focus),
                                                    focusedSeconds: current.length, completed: true)))
                if plan.breaksEnabled {
                    let long = plan.longBreaksEnabled && completedInCycle >= plan.sessionsBeforeLongBreak
                    let next: FocusPhase = long ? .longBreak : .shortBreak
                    if long { completedInCycle = 0 }
                    run = FocusRun(phase: next, length: plan.length(of: next), startedAt: end, segmentStart: end)
                    events.append(.started(next, at: end))
                } else {
                    run = nil
                }
            case .shortBreak, .longBreak:
                if plan.autoStartsNextSession, now.timeIntervalSince(end) <= Self.catchUpTolerance {
                    run = FocusRun(phase: .focus, length: plan.length(of: .focus), startedAt: end, segmentStart: end)
                    events.append(.started(.focus, at: end))
                } else {
                    run = nil
                }
            }
        }
        return events
    }

    private func partialEntry(_ run: FocusRun, at now: Date) -> FocusLogEntry? {
        let focused = run.elapsed(at: now)
        guard focused >= Self.minimumLoggedSeconds else { return nil }
        return FocusLogEntry(start: run.startedAt, end: now, plannedMinutes: Int((run.length / 60).rounded()),
                             focusedSeconds: focused, completed: false)
    }
}

/// "18:22" / "1:05:09": a countdown in minutes and seconds (hours when needed).
enum FocusDurationFormat {
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "18 min", "1 h 5 min", "45 s" for idle times and summaries.
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 48 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
        return "\(hours / 24) d"
    }

    /// Whole minutes, rounded, for totals ("50 min").
    static func minutes(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) / 60).rounded()) }

    /// For VoiceOver: "18 minutes 22 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = total >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(total)) ?? "\(total) seconds"
    }
}
