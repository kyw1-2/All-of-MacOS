import AppKit
import IOKit.pwr_mgt

/// Isolated UI previews only (`--aom-ui-preview <tmp> --aom-preview-focus-sample`):
/// a system seam with sample apps, memory and audio so the Focus page can be
/// reviewed with realistic content. It never touches a real app.
@MainActor
final class FocusPreviewSystem: FocusSystem {
    static var isRequested: Bool {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-focus-sample")
    }

    /// `--aom-preview-focus-scroll <section>`: the page opens scrolled there.
    static var requestedSection: String? {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-focus-scroll"),
              args.indices.contains(index + 1) else { return nil }
        let section = args[index + 1]
        return ["during", "idle", "memory"].contains(section) ? section : nil
    }

    private let apps: [FocusRunningApp]
    private let footprints: [pid_t: UInt64]

    init() {
        let now = Date()
        apps = [
            FocusRunningApp(pid: 90_001, bundleID: "com.apple.Safari", name: "Safari", isActive: true, launchDate: now.addingTimeInterval(-9000)),
            FocusRunningApp(pid: 90_002, bundleID: "com.apple.mail", name: "Mail", launchDate: now.addingTimeInterval(-9000)),
            FocusRunningApp(pid: 90_003, bundleID: "com.apple.Music", name: "Music", launchDate: now.addingTimeInterval(-9000)),
            FocusRunningApp(pid: 90_004, bundleID: "com.apple.Notes", name: "Notes", isHidden: true, launchDate: now.addingTimeInterval(-9000)),
            FocusRunningApp(pid: 90_005, bundleID: "com.apple.MobileSMS", name: "Messages", launchDate: now.addingTimeInterval(-9000))
        ]
        footprints = [90_002: 286 << 20, 90_003: 198 << 20, 90_004: 141 << 20, 90_005: 512 << 20, 90_001: 1_350 << 20]
    }

    func runningApps() -> [FocusRunningApp] { apps }
    var frontmostBundleID: String? { "com.apple.Safari" }
    func hide(pid: pid_t) -> Bool { false }
    func terminate(pid: pid_t) -> Bool { false }
    func isRunning(pid: pid_t) -> Bool { apps.contains { $0.pid == pid } }
    func audioActivity() -> FocusAudioActivity? { FocusAudioActivity(playing: [90_003], recording: []) }
    var isOutputMuted: Bool { false }
    var outputDeviceUID: String? { nil }
    func toggleOutputMute(completion: @escaping (Bool) -> Void) { completion(false) }
    func appFootprints(for pids: [pid_t], completion: @escaping ([pid_t: UInt64]) -> Void) {
        completion(footprints.filter { pids.contains($0.key) })
    }
    func memoryPressure() -> FocusMemoryPressure { .warning }
    func beginKeepAwake(minutes: Int) -> IOPMAssertionID? { nil }
    func endKeepAwake(_ id: IOPMAssertionID) {}
    var isKeepAwakeActive: Bool { false }
    func playSound(_ name: String) {}
    func showHUD(symbol: String, title: String, detail: String?, seconds: TimeInterval) {}
    func runShortcut(_ shortcut: FocusShortcutRef, completion: @escaping @MainActor (Result<Void, FocusShortcutError>) -> Void) {}
    var isAOMPaused: Bool { false }
    func isPaused(forApp bundleID: String) -> Bool { false }
    var pausedApps: Set<String> { [] }
    var secondsSinceLastInput: TimeInterval { 1 }
    var isSecureInputOn: Bool { false }

    /// Fills the preview's own Focus data: a week of sessions, the lists,
    /// the activity log and a focus phase seven minutes in.
    static func seed(_ env: FocusEnvironment) {
        guard isRequested else { return }
        let now = Date()
        let calendar = Calendar.current
        var entries: [FocusLogEntry] = []
        let perDay = [3, 2, 4, 1, 3, 2, 2]
        for (offset, count) in perDay.enumerated() {
            let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset - 6, to: now) ?? now)
            for index in 0..<count {
                let start = dayStart.addingTimeInterval(TimeInterval(9 * 3600 + index * 4200))
                let minutes = index % 3 == 2 ? 50 : 25
                guard start.addingTimeInterval(TimeInterval(minutes * 60)) < now.addingTimeInterval(-600) else { continue }
                entries.append(FocusLogEntry(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                             plannedMinutes: minutes, focusedSeconds: TimeInterval(minutes * 60), completed: true))
            }
        }
        env.log.replace(with: entries)
        var lists = FocusLists()
        lists.distractingApps = [FocusAppRef(bundleID: "com.apple.MobileSMS", name: "Messages"),
                                 FocusAppRef(bundleID: "com.apple.Music", name: "Music"),
                                 FocusAppRef(bundleID: "com.apple.news", name: "News")]
        lists.idleRules = [
            FocusIdleRule(bundleID: "com.apple.MobileSMS", name: "Messages", hideAfterMinutes: 15, quitAfterMinutes: 60),
            FocusIdleRule(bundleID: "com.apple.mail", name: "Mail", hideAfterMinutes: 10, quitAfterMinutes: 120),
            FocusIdleRule(bundleID: "com.apple.Music", name: "Music", hideAfterMinutes: nil, quitAfterMinutes: 30),
            FocusIdleRule(bundleID: "com.apple.Notes", name: "Notes", hideAfterMinutes: 5, quitAfterMinutes: nil,
                          quitsUnderMemoryPressure: false),
            FocusIdleRule(bundleID: "com.apple.iCal", name: "Calendar", hideAfterMinutes: 15, quitAfterMinutes: 60)
        ]
        env.lists.lists = lists
        var settings = FocusSettings()
        settings.hidesDistractions = true
        settings.keepsAwake = true
        settings.startShortcut = FocusShortcutsCLI.previewSamples[0]
        settings.endShortcut = FocusShortcutsCLI.previewSamples[1]
        settings.idleAppsEnabled = true
        settings.memoryPressureEnabled = true
        settings.eyeBreaksEnabled = true
        env.settings.settings = settings
        env.activity.replace(with: [
            FocusActivity(date: now.addingTimeInterval(-300), kind: .quitUnderPressure, appName: "Pages", idleSeconds: 3 * 3600,
                          memoryBytes: 402 << 20),
            FocusActivity(date: now.addingTimeInterval(-1500), kind: .hid, appName: "Mail", idleSeconds: 11 * 60),
            FocusActivity(date: now.addingTimeInterval(-2900), kind: .shortcut, appName: "“Do Not Disturb On”"),
            FocusActivity(date: now.addingTimeInterval(-5400), kind: .quit, appName: "Keynote", idleSeconds: 64 * 60,
                          memoryBytes: 655 << 20)
        ])
        env.idleApps.setPreviewState(
            memory: [90_002: 286 << 20, 90_003: 198 << 20, 90_004: 141 << 20, 90_005: 512 << 20],
            pressure: .warning, swap: 4_254 << 20,
            idleSince: ["com.apple.mail": now.addingTimeInterval(-42 * 60), "com.apple.Music": now.addingTimeInterval(-26 * 60),
                        "com.apple.Notes": now.addingTimeInterval(-18 * 60), "com.apple.MobileSMS": now.addingTimeInterval(-72 * 60)])
        if !ProcessInfo.processInfo.arguments.contains("--aom-preview-focus-idle") {
            env.session.startForPreview(elapsed: 7 * 60 + 12)
        }
    }
}
