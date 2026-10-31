import Foundation

/// An app chosen by bundle identifier (distracting apps, rules).
struct FocusAppRef: Codable, Equatable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// One idle-app rule (Quitter): hide the app after N minutes without being
/// the front app, quit it after M minutes. Quitting is a normal quit, so
/// the app can ask to save first; AOM never force quits.
struct FocusIdleRule: Codable, Equatable, Identifiable {
    var id: UUID
    var bundleID: String
    var name: String
    /// nil: never hide.
    var hideAfterMinutes: Int?
    /// nil: never quit on a timer.
    var quitAfterMinutes: Int?
    /// May be quit early, idlest first, while memory pressure is high.
    var quitsUnderMemoryPressure: Bool
    var isEnabled: Bool

    static let minuteRange = 1...720
    static let hideChoices = [5, 10, 15, 30, 60]
    static let quitChoices = [15, 30, 60, 120, 240, 480]

    init(id: UUID = UUID(), bundleID: String, name: String, hideAfterMinutes: Int? = 15,
         quitAfterMinutes: Int? = 60, quitsUnderMemoryPressure: Bool = true, isEnabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.hideAfterMinutes = hideAfterMinutes.map { FocusPlan.clamp($0, Self.minuteRange) }
        self.quitAfterMinutes = quitAfterMinutes.map { FocusPlan.clamp($0, Self.minuteRange) }
        self.quitsUnderMemoryPressure = quitsUnderMemoryPressure
        self.isEnabled = isEnabled
    }

    /// The rule allows quitting at all (on its timer or under pressure).
    var mayQuit: Bool { quitAfterMinutes != nil || quitsUnderMemoryPressure }
    var hidesOrQuits: Bool { hideAfterMinutes != nil || mayQuit }
}

/// A running regular app as seen at one moment.
struct FocusRunningApp: Equatable, Identifiable {
    var pid: pid_t
    var bundleID: String
    var name: String
    var isHidden = false
    var isActive = false
    var launchDate: Date?
    var id: pid_t { pid }
}

/// Idle time per app from activation events: an app is idle from the
/// moment it stops being the front app. An app that has not been in front
/// since tracking began (or since it launched, if later) counts from then,
/// so turning the feature on, or relaunching AOM, never makes an app look
/// idle for longer than AOM could see.
struct FocusIdleTracker: Equatable {
    private(set) var startedAt: Date
    private(set) var frontmost: String?
    private(set) var lastActive: [String: Date] = [:]

    init(startedAt: Date, frontmost: String? = nil) {
        self.startedAt = startedAt
        self.frontmost = frontmost
        if let frontmost { lastActive[frontmost] = startedAt }
    }

    /// `bundleID` became the front app at `date`.
    mutating func activated(_ bundleID: String?, at date: Date) {
        if let previous = frontmost { lastActive[previous] = date }
        frontmost = bundleID
        if let bundleID { lastActive[bundleID] = date }
    }

    /// A launch counts as use (the person just opened it).
    mutating func launched(_ bundleID: String, at date: Date) {
        if lastActive[bundleID].map({ $0 < date }) ?? true { lastActive[bundleID] = date }
    }

    mutating func terminated(_ bundleID: String) {
        lastActive[bundleID] = nil
        if frontmost == bundleID { frontmost = nil }
    }

    /// Time away from the front since tracking began; 0 for the front app.
    func idleSeconds(for bundleID: String, launchedAt: Date? = nil, at now: Date) -> TimeInterval {
        if bundleID == frontmost { return 0 }
        var since = lastActive[bundleID] ?? startedAt
        if let launchedAt, launchedAt > since { since = launchedAt }
        if since < startedAt { since = startedAt }
        return max(0, now.timeIntervalSince(since))
    }
}

/// Why an app is left alone right now.
enum FocusIdleExclusion: String, Equatable {
    case finder, aom, frontmost, playingAudio, recording, audioUnknown, pausedForApp, aomPaused, ruleOff, waitingToQuit

    var description: String {
        switch self {
        case .finder: return "Finder is never hidden or quit"
        case .aom: return "All of MacOS is never hidden or quit"
        case .frontmost: return "In front"
        case .playingAudio: return "Playing audio"
        case .recording: return "Recording"
        case .audioUnknown: return "Needs macOS 14.2 to check audio"
        case .pausedForApp: return "AOM is paused for this app"
        case .aomPaused: return "AOM is paused"
        case .ruleOff: return "Rule off"
        case .waitingToQuit: return "Asked to quit"
        }
    }

    /// The state can change by itself (audio stops, the app goes to the
    /// back), so a waiting rule needs a later look.
    var isTransient: Bool {
        switch self {
        case .frontmost, .playingAudio, .recording, .aomPaused, .pausedForApp, .waitingToQuit: return true
        case .finder, .aom, .audioUnknown, .ruleOff: return false
        }
    }
}

enum FocusIdleAction: String, Equatable { case hide, quit }

/// What the policy decided for one running app with a rule.
struct FocusIdleDecision: Equatable {
    var app: FocusRunningApp
    var rule: FocusIdleRule
    var idleSeconds: TimeInterval
    var action: FocusIdleAction?
    var exclusion: FocusIdleExclusion?
    /// A threshold has passed (the action is due unless an exclusion holds it).
    var isDue = false
    /// When this app reaches its next threshold, if it stays idle.
    var nextThreshold: Date?
}

/// Everything outside the rule that decides whether an app may be touched.
struct FocusIdleContext {
    var now: Date
    /// nil: this Mac can't tell which apps play or record audio.
    var audio: FocusAudioActivity?
    var aomPaused = false
    var pausedApps: Set<String> = []
    var ownBundleIDs: Set<String> = FocusIdlePolicy.aomBundleIDs
    /// Apps asked to quit that are still running (maybe asking to save).
    var waitingToQuit: Set<pid_t> = []
}

/// Pure hide/quit decisions (tested without real apps).
enum FocusIdlePolicy {
    static let finderBundleID = "com.apple.finder"
    static let aomBundleIDs: Set<String> = {
        var ids: Set<String> = ["com.kyw.allofmacos", "com.kyw.allofmacos.preview"]
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }()

    /// Apps a rule may never be made for.
    static func isProtected(_ bundleID: String, own: Set<String> = aomBundleIDs) -> Bool {
        bundleID == finderBundleID || own.contains(bundleID)
    }

    /// The first reason to leave `app` alone, in a fixed order.
    static func exclusion(for app: FocusRunningApp, rule: FocusIdleRule?, context: FocusIdleContext,
                          ignoresGlobalPause: Bool = false) -> FocusIdleExclusion? {
        if app.bundleID == finderBundleID { return .finder }
        if context.ownBundleIDs.contains(app.bundleID) { return .aom }
        if context.aomPaused && !ignoresGlobalPause { return .aomPaused }
        if context.pausedApps.contains(app.bundleID) { return .pausedForApp }
        if app.isActive { return .frontmost }
        if let rule, !rule.isEnabled { return .ruleOff }
        if context.waitingToQuit.contains(app.pid) { return .waitingToQuit }
        guard let audio = context.audio else { return .audioUnknown }
        if audio.recording.contains(app.pid) { return .recording }
        if audio.playing.contains(app.pid) { return .playingAudio }
        return nil
    }

    /// Timer rules: quit at the quit threshold, hide at the hide threshold
    /// (once; a hidden app stays hidden until it is used again).
    static func decide(app: FocusRunningApp, rule: FocusIdleRule, idleSeconds: TimeInterval,
                       context: FocusIdleContext) -> FocusIdleDecision {
        var decision = FocusIdleDecision(app: app, rule: rule, idleSeconds: idleSeconds)
        let idleSince = context.now.addingTimeInterval(-idleSeconds)
        let hideAt = rule.hideAfterMinutes.map { idleSince.addingTimeInterval(TimeInterval($0) * 60) }
        let quitAt = rule.quitAfterMinutes.map { idleSince.addingTimeInterval(TimeInterval($0) * 60) }
        let quitDue = quitAt.map { $0 <= context.now } ?? false
        let hideDue = !app.isHidden && (hideAt.map { $0 <= context.now } ?? false)
        decision.nextThreshold = [hideAt.flatMap { app.isHidden ? nil : $0 }, quitAt]
            .compactMap { $0 }.filter { $0 > context.now }.min()
        decision.isDue = quitDue || hideDue
        if let exclusion = exclusion(for: app, rule: rule, context: context) {
            decision.exclusion = exclusion
            return decision
        }
        if quitDue { decision.action = .quit }
        else if hideDue { decision.action = .hide }
        return decision
    }

    /// Memory-pressure order: apps whose rule allows quitting under
    /// pressure, idle at least `minimumIdle`, not excluded; idlest first,
    /// the larger footprint first on a tie.
    static func pressureCandidates(apps: [FocusRunningApp], rules: [FocusIdleRule], idle: (FocusRunningApp) -> TimeInterval,
                                   footprints: [pid_t: UInt64], minimumIdle: TimeInterval,
                                   context: FocusIdleContext) -> [FocusIdleDecision] {
        candidates(apps: apps, rules: rules, idle: idle, context: context, ignoresGlobalPause: false) { rule, seconds in
            rule.quitsUnderMemoryPressure && seconds >= minimumIdle
        }
        .sorted { lhs, rhs in
            if lhs.idleSeconds != rhs.idleSeconds { return lhs.idleSeconds > rhs.idleSeconds }
            let left = footprints[lhs.app.pid] ?? 0, right = footprints[rhs.app.pid] ?? 0
            if left != right { return left > right }
            return lhs.app.pid < rhs.app.pid
        }
    }

    /// Quit Idle Apps Now: every listed app whose rule allows quitting and
    /// that nothing protects, idlest first. A person asked for it, so AOM's
    /// global pause does not block it; everything else still does.
    static func quitNowCandidates(apps: [FocusRunningApp], rules: [FocusIdleRule], idle: (FocusRunningApp) -> TimeInterval,
                                  context: FocusIdleContext) -> [FocusIdleDecision] {
        candidates(apps: apps, rules: rules, idle: idle, context: context, ignoresGlobalPause: true) { rule, _ in rule.mayQuit }
            .sorted { $0.idleSeconds != $1.idleSeconds ? $0.idleSeconds > $1.idleSeconds : $0.app.pid < $1.app.pid }
    }

    private static func candidates(apps: [FocusRunningApp], rules: [FocusIdleRule], idle: (FocusRunningApp) -> TimeInterval,
                                   context: FocusIdleContext, ignoresGlobalPause: Bool,
                                   allows: (FocusIdleRule, TimeInterval) -> Bool) -> [FocusIdleDecision] {
        var result: [FocusIdleDecision] = []
        var seen = Set<pid_t>()
        for app in apps where !seen.contains(app.pid) {
            seen.insert(app.pid)
            guard let rule = rules.first(where: { $0.bundleID == app.bundleID }) else { continue }
            let seconds = idle(app)
            guard allows(rule, seconds),
                  exclusion(for: app, rule: rule, context: context, ignoresGlobalPause: ignoresGlobalPause) == nil else { continue }
            result.append(FocusIdleDecision(app: app, rule: rule, idleSeconds: seconds, action: .quit))
        }
        return result
    }
}
