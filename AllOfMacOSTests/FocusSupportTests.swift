import AppKit
import IOKit.pwr_mgt
import XCTest
@testable import AllOfMacOS

/// A clock the tests move by hand ("the Mac slept for an hour").
final class FocusManualClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// The Focus system seam with no real effects: records every call.
@MainActor
final class FocusFakeSystem: FocusSystem {
    var apps: [FocusRunningApp] = []
    var hidden: [pid_t] = []
    var terminated: [pid_t] = []
    var hideSucceeds = true
    var terminateSucceeds = true
    var audio: FocusAudioActivity? = FocusAudioActivity()
    var muted = false
    var deviceUID: String? = "BuiltInSpeakerDevice"
    var muteToggles = 0
    var footprints: [pid_t: UInt64] = [:]
    /// Returned one per call; the last one repeats.
    var pressureLevels: [FocusMemoryPressure] = [.normal]
    var keepAwakeBegun: [Int] = []
    var keepAwakeEnded: [IOPMAssertionID] = []
    private var nextAssertion: IOPMAssertionID = 100
    var sounds: [String] = []
    var huds: [String] = []
    var shortcutRuns: [String] = []
    var shortcutResult: Result<Void, FocusShortcutError> = .success(())
    var paused = false
    var pausedAppIDs: Set<String> = []
    var idleInput: TimeInterval = 1
    var secureInput = false

    func runningApps() -> [FocusRunningApp] { apps }
    var frontmostBundleID: String? { apps.first(where: \.isActive)?.bundleID }

    func hide(pid: pid_t) -> Bool {
        hidden.append(pid)
        guard hideSucceeds else { return false }
        if let index = apps.firstIndex(where: { $0.pid == pid }) { apps[index].isHidden = true }
        return true
    }

    func terminate(pid: pid_t) -> Bool {
        terminated.append(pid)
        return terminateSucceeds
    }

    /// The app finished quitting.
    func finishQuitting(pid: pid_t) { apps.removeAll { $0.pid == pid } }

    func isRunning(pid: pid_t) -> Bool { apps.contains { $0.pid == pid } }
    func audioActivity() -> FocusAudioActivity? { audio }
    var isOutputMuted: Bool { muted }
    var outputDeviceUID: String? { deviceUID }
    func toggleOutputMute(completion: @escaping (Bool) -> Void) {
        muteToggles += 1
        muted.toggle()
        completion(true)
    }
    func appFootprints(for pids: [pid_t], completion: @escaping ([pid_t: UInt64]) -> Void) {
        completion(footprints.filter { pids.contains($0.key) })
    }
    func memoryPressure() -> FocusMemoryPressure {
        if pressureLevels.count > 1 { return pressureLevels.removeFirst() }
        return pressureLevels.first ?? .normal
    }
    func beginKeepAwake(minutes: Int) -> IOPMAssertionID? {
        keepAwakeBegun.append(minutes)
        nextAssertion += 1
        return nextAssertion
    }
    func endKeepAwake(_ id: IOPMAssertionID) { keepAwakeEnded.append(id) }
    var isKeepAwakeActive: Bool { keepAwakeBegun.count > keepAwakeEnded.count }
    func playSound(_ name: String) { sounds.append(name) }
    func showHUD(symbol: String, title: String, detail: String?, seconds: TimeInterval) { huds.append(title) }
    func runShortcut(_ shortcut: FocusShortcutRef, completion: @escaping @MainActor (Result<Void, FocusShortcutError>) -> Void) {
        shortcutRuns.append(shortcut.name)
        completion(shortcutResult)
    }
    var isAOMPaused: Bool { paused }
    func isPaused(forApp bundleID: String) -> Bool { pausedAppIDs.contains(bundleID) }
    var pausedApps: Set<String> { pausedAppIDs }
    var secondsSinceLastInput: TimeInterval { idleInput }
    var isSecureInputOn: Bool { secureInput }
}

/// A throwaway folder and settings suite per test.
@MainActor
final class FocusTestWorld {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let clock = FocusManualClock()
    let system = FocusFakeSystem()
    let settings: FocusSettingsStore
    let lists: FocusListsStore
    let log: FocusLogStore
    let activity: FocusActivityStore
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 2
        return calendar
    }()

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOMFocusTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "AOMFocusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = FocusSettingsStore(defaults: defaults)
        lists = FocusListsStore(directory: directory)
        log = FocusLogStore(directory: directory)
        activity = FocusActivityStore(directory: directory)
    }

    func makeSession() -> FocusSessionController {
        let clock = self.clock
        return FocusSessionController(system: system, settings: settings, lists: lists, log: log, activity: activity,
                                      directory: directory, clock: { clock.now }, calendar: calendar, schedules: false)
    }

    func makeIdleApps() -> FocusIdleAppsController {
        let clock = self.clock
        return FocusIdleAppsController(system: system, settings: settings, lists: lists, activity: activity,
                                       clock: { clock.now }, schedules: false)
    }

    func cleanUp() {
        FocusStorage.flush()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// The fakes behave like the system they stand in for.
@MainActor
final class FocusSupportTests: XCTestCase {
    func testTheFakeSystemRecordsWithoutTouchingTheMac() {
        let system = FocusFakeSystem()
        system.apps = [FocusRunningApp(pid: 10, bundleID: "com.example.chat", name: "Chat")]
        XCTAssertTrue(system.hide(pid: 10))
        XCTAssertTrue(system.apps[0].isHidden)
        XCTAssertTrue(system.terminate(pid: 10))
        XCTAssertTrue(system.isRunning(pid: 10), "terminate asks; the app quits when it is ready")
        system.finishQuitting(pid: 10)
        XCTAssertFalse(system.isRunning(pid: 10))
        system.pressureLevels = [.critical, .warning, .normal]
        XCTAssertEqual([system.memoryPressure(), system.memoryPressure(), system.memoryPressure(), system.memoryPressure()],
                       [.critical, .warning, .normal, .normal])
    }

    func testIsolatedEnvironmentNeverActs() {
        let env = FocusEnvironment.shared
        XCTAssertTrue(env.isolated, "tests get the isolated environment")
        XCTAssertTrue(env.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path), env.directory.path)
        XCTAssertFalse(env.system.hide(pid: getpid()), "the isolated system never hides an app")
        XCTAssertFalse(env.system.terminate(pid: getpid()), "the isolated system never quits an app")
        XCTAssertNil(env.system.beginKeepAwake(minutes: 5), "no power assertion in tests")
        XCTAssertFalse(env.statusItem.isShowing)
    }
}
