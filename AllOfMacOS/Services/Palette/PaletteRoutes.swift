import AppKit
import CoreAudio
import Combine
import Darwin

// AOM 6.7: the launcher's screens (Raycast's navigation stack).
//
// 6.6 could only act on an app after its name was typed, and Uninstall…
// left the launcher for System Tools. A command now opens a screen of its
// own in the same panel — Kill Apps lists the running apps, Uninstall App
// the installed ones, then a review, a confirmation and the result — and
// esc steps back one screen with the search and the selected row the
// screen below had (docs/design-6.7-launcher.md, the Codex spec of
// 2026-11-20). Destructive steps ask inside the panel with Cancel selected.

/// One screen the launcher pushes over the root search.
enum PaletteRoute: Hashable {
    case killApps
    case uninstallApps
    case uninstallReview(URL)
    case soundDevices
    case clipboard
    case windowLayouts
    case keepAwake
    case system
    /// 6.10: AlDente's controls.
    case battery
    /// 6.11: every app's menu bar item (Ice's search).
    case menuBarItems
    /// 6.9: Quick AI on Claude Code or Codex; 7.0 every model.
    case ai
    /// 7.0: the model picker (⌘P on Ask AI).
    case aiModels
    /// The pending in-panel confirmation (one at a time).
    case confirm

    var title: String {
        switch self {
        case .killApps: return "Kill Apps"
        case .uninstallApps: return "Uninstall App"
        case .uninstallReview(let url): return "Uninstall \(url.deletingPathExtension().lastPathComponent)"
        case .soundDevices: return "Sound Devices"
        case .clipboard: return "Clipboard History"
        case .windowLayouts: return "Window Management"
        case .keepAwake: return "Keep Awake"
        case .system: return "System Commands"
        case .battery: return "Battery"
        case .menuBarItems: return "Menu Bar Items"
        case .ai: return "Ask AI"
        case .aiModels: return "Choose Model"
        case .confirm: return "Confirm"
        }
    }

    var placeholder: String {
        switch self {
        case .killApps: return "Search running apps…"
        case .uninstallApps: return "Search installed apps…"
        case .uninstallReview: return "Filter the items to remove…"
        case .soundDevices: return "Search outputs, inputs and volume…"
        case .clipboard: return "Search clipboard history…"
        case .windowLayouts: return "Search layouts…"
        case .keepAwake: return "Search durations…"
        case .system: return "Search system commands…"
        case .battery: return "Search battery controls…"
        case .menuBarItems: return "Search menu bar items, even those behind the notch…"
        case .ai: return "Ask anything…"
        case .aiModels: return "Search models…"
        case .confirm: return "↑↓ to choose, ↩ to confirm, esc to go back"
        }
    }

    var symbol: String {
        switch self {
        case .killApps: return "xmark.octagon"
        case .uninstallApps, .uninstallReview: return "trash"
        case .soundDevices: return "hifispeaker.2"
        case .clipboard: return "doc.on.clipboard"
        case .windowLayouts: return "rectangle.split.3x1"
        case .keepAwake: return "cup.and.saucer"
        case .system: return "gearshape.2"
        case .battery: return "battery.75percent"
        case .menuBarItems: return "menubar.rectangle"
        case .ai: return "sparkles"
        case .aiModels: return "cpu"
        case .confirm: return "exclamationmark.triangle"
        }
    }

    /// Typing filters this screen's rows (a confirmation has two fixed rows).
    var isSearchable: Bool { self != .confirm }
}

/// A screen on the stack and what the screen below it showed.
struct PaletteFrame: Equatable {
    let route: PaletteRoute
    let returnQuery: String
    let returnSelection: String?
}

/// The launcher's stack, pure for tests: push keeps the query and the
/// selected row of the screen it covers; pop gives them back.
struct PaletteNavigation: Equatable {
    private(set) var frames: [PaletteFrame] = []

    var current: PaletteRoute? { frames.last?.route }
    var depth: Int { frames.count }
    var isRoot: Bool { frames.isEmpty }

    mutating func push(_ route: PaletteRoute, query: String, selection: String?) {
        // A confirmation never stacks on another one.
        if route == .confirm, current == .confirm { frames.removeLast() }
        frames.append(PaletteFrame(route: route, returnQuery: query, returnSelection: selection))
    }

    /// The frame that was on top, whose return values the caller restores.
    @discardableResult
    mutating func pop() -> PaletteFrame? { frames.popLast() }

    mutating func popToRoot() { frames.removeAll() }

    /// Titles for the search field's breadcrumb, root first.
    var breadcrumb: [String] { frames.filter { $0.route != .confirm }.map(\.route.title) }
}

/// A question asked inside the panel before something that cannot be
/// undone (Raycast's confirmAlert): Cancel is the selected row, ↩ on a held
/// key does not repeat into it, and esc goes back to the screen below.
struct PaletteConfirmation {
    enum After: Equatable {
        /// Back to the screen that asked (Kill Apps, the uninstall review).
        case pop
        /// Close the launcher first; `restoresFocus` gives the front app its focus back.
        case close(restoresFocus: Bool)
    }

    let title: String
    let message: String
    let confirmTitle: String
    var symbol = "exclamationmark.triangle.fill"
    var destructive = true
    var after: After = .pop
    let run: () -> Void
}

// MARK: - Kill Apps

/// The running apps Kill Apps lists: regular (Dock) apps, the ones that can
/// be quit first by memory footprint (Activity Monitor's order, so the
/// heavy app is on top), then the ones AOM never quits from here.
enum PaletteKillApps {
    struct Entry: Equatable, Identifiable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        /// The running copy's path; an action quits this copy only.
        let path: String?
        let memory: UInt64?
        let isHidden: Bool
        let isProtected: Bool

        var id: String { "kill.\(pid)" }
    }

    static func entries(from running: [NSRunningApplication] = NSWorkspace.shared.runningApplications,
                        footprint: (pid_t) -> UInt64? = memoryFootprint) -> [Entry] {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = running.filter { !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != own }
        return ordered(apps.map { app in
            Entry(pid: app.processIdentifier,
                  name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "PID \(app.processIdentifier)",
                  bundleID: app.bundleIdentifier, path: app.bundleURL?.standardizedFileURL.path,
                  memory: footprint(app.processIdentifier), isHidden: app.isHidden,
                  isProtected: PaletteAppControl.isProtected(app.bundleIdentifier))
        })
    }

    /// Pure: quittable apps by memory (largest first, then by name), then
    /// the protected ones by name.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        let byName: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let quittable = entries.filter { !$0.isProtected }.sorted { lhs, rhs in
            let left = lhs.memory ?? 0, right = rhs.memory ?? 0
            return left != right ? left > right : byName(lhs, rhs)
        }
        return quittable + entries.filter(\.isProtected).sorted(by: byName)
    }

    /// The process's physical footprint (Activity Monitor's Memory column);
    /// readable for the user's own processes without any permission.
    static func memoryFootprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    static func memoryDescription(_ bytes: UInt64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = bytes >= 1 << 30 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// The instance the row named, again: same PID and the same copy. A
    /// relaunch, or another copy now at that PID, is not the target.
    static func resolve(_ entry: Entry) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated,
              app.bundleURL?.standardizedFileURL.path == entry.path,
              app.bundleIdentifier == entry.bundleID else { return nil }
        return app
    }

    /// After this long a quit that has not finished reads "Still running".
    static let quitPatience: TimeInterval = 10

    enum QuitState: Equatable { case quitting, stillRunning }

    /// Pure: the row's state after a normal quit was asked at `asked`.
    static func quitState(askedAt asked: Date?, now: Date) -> QuitState? {
        guard let asked else { return nil }
        return now.timeIntervalSince(asked) >= quitPatience ? .stillRunning : .quitting
    }
}

// MARK: - Uninstall App

/// Uninstall App's review inside the launcher: the same checks, scan and
/// default ticks as System Tools (`CleanupTools`), drawn in the panel.
@MainActor
final class PaletteUninstallFlow: ObservableObject {
    enum Phase: Equatable {
        case checking
        /// This copy is open; AOM asks it to quit the normal way first.
        case needsQuit(String)
        case quitting(String)
        case scanning
        case review
        case moving
        case done(CleanupTools.TrashOutcome)
        case failed(title: String, detail: String)
    }

    let app: URL
    let name: String
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var review: CleanupTools.UninstallReview?
    @Published private(set) var selected: Set<String> = []
    /// ~/Library folders that exist but could not be read (6.8, Codex
    /// review): reported as "not checked", never as "nothing there".
    @Published private(set) var unreadable: [String] = []

    /// 6.8 (Codex review U2): the last result, kept outside the screen so a
    /// move that finishes after the panel closed is still shown — on the
    /// Uninstall App screen and in a HUD.
    struct Recent: Equatable {
        let app: URL
        let name: String
        let outcome: CleanupTools.TrashOutcome
        let date: Date
    }
    static private(set) var recent: Recent? {
        didSet { recentDidChange.send() }
    }
    /// The Uninstall App screen redraws when a result lands while it is open.
    static let recentDidChange = PassthroughSubject<Void, Never>()
    private var bundleID: String?
    private var generation = 0
    private let library: URL

    init(app: URL, library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) {
        self.app = app
        self.name = app.deletingPathExtension().lastPathComponent
        self.library = library
    }

    var candidates: [CleanupCandidate] { review?.items ?? [] }
    var chosen: [CleanupCandidate] { candidates.filter { selected.contains($0.id) } }
    var selectedSize: Int64 { chosen.reduce(0) { $0 + $1.size } }

    func isNameOnly(_ candidate: CleanupCandidate) -> Bool { review?.nameOnly.contains(candidate.id) == true }

    /// Ends whatever is in flight: a late scan or quit check is dropped.
    func cancel() { generation &+= 1 }

    func start() {
        generation &+= 1
        phase = .checking
        let identity: (id: String, name: String)
        do { identity = try CleanupTools.uninstallIdentity(for: app) } catch {
            phase = .failed(title: "Can't Uninstall \(name)", detail: error.localizedDescription)
            return
        }
        bundleID = identity.id
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identity.id).filter { !$0.isTerminated }
        guard !running.isEmpty else { scan(); return }
        let target = PaletteAppControl.installedKey(app)
        if let other = running.first(where: { $0.bundleURL.map(PaletteAppControl.installedKey) != target }) {
            let place = other.bundleURL.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? "another folder"
            phase = .failed(title: "Another Copy Is Running",
                            detail: "\(identity.name) from \(place) is open and shares this app's data. Quit that copy first. Nothing was moved.")
            return
        }
        phase = .needsQuit(running.first?.localizedName ?? identity.name)
    }

    /// The normal quit (the app can still ask to save), then the scan.
    func quitAndReview() {
        guard case .needsQuit(let shown) = phase, let bundleID else { return }
        let target = PaletteAppControl.installedKey(app)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.bundleURL.map(PaletteAppControl.installedKey) == target }
        running.forEach { $0.terminate() }
        phase = .quitting(shown)
        let ticket = generation
        waitForQuit(running, name: shown, ticket: ticket, triesLeft: 20)
    }

    private func waitForQuit(_ apps: [NSRunningApplication], name: String, ticket: Int, triesLeft: Int) {
        guard ticket == generation else { return }
        if apps.allSatisfy(\.isTerminated) { scan(); return }
        guard triesLeft > 0 else {
            phase = .failed(title: "\(name) Didn't Quit",
                            detail: "\(name) is still open, probably asking about unsaved work. Nothing was moved.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForQuit(apps, name: name, ticket: ticket, triesLeft: triesLeft - 1)
        }
    }

    private func scan() {
        phase = .scanning
        let ticket = generation
        let app = self.app, library = self.library
        Task.detached(priority: .userInitiated) {
            let result = Result { try CleanupTools.uninstallReview(for: app, library: library) }
            await MainActor.run { [weak self] in
                guard let self, ticket == self.generation else { return }
                switch result {
                case .success(let review):
                    self.unreadable = review.unreadable
                    self.review = review
                    self.selected = review.preselected
                    self.phase = .review
                case .failure(let error):
                    self.phase = .failed(title: "Can't Review \(self.name)", detail: error.localizedDescription)
                }
            }
        }
    }

    func toggle(_ id: String) {
        guard phase == .review else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAll() { if phase == .review { selected = Set(candidates.map(\.id)) } }
    func selectNone() { if phase == .review { selected = [] } }

    /// Moves the ticked items to the Trash once: the app is checked again
    /// (same bundle ID, not running) right before anything moves.
    func trash() {
        guard phase == .review, let review else { return }
        let chosen = self.chosen
        guard !chosen.isEmpty else { return }
        phase = .moving
        let ticket = generation
        let app = self.app, name = self.name
        let includesApp = chosen.contains { $0.url == app }
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> CleanupTools.TrashOutcome in
                let isRunning: (String) -> Bool = {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { !$0.isTerminated }.isEmpty
                }
                if includesApp || FileManager.default.fileExists(atPath: app.path) {
                    _ = try CleanupTools.checkUninstallTarget(app, expectedID: review.bundleID, isRunning: isRunning)
                } else if isRunning(review.bundleID) {
                    // A retry after the app itself already went: its data
                    // still must not move while a copy of it runs.
                    throw CleanupTools.UninstallRefusal.running(name)
                }
                return CleanupTools.moveToTrash(chosen)
            }
            await MainActor.run { [weak self] in
                PaletteApplications.invalidate()
                switch result {
                case .success(let outcome):
                    PaletteUninstallFlow.recent = Recent(app: app, name: name, outcome: outcome, date: Date())
                    GestureLog.shared.logFromAnyThread("Uninstall \(name) from the launcher: \(outcome.summary)", level: .action)
                    guard let self, ticket == self.generation else {
                        // The screen closed meanwhile: the result still shows.
                        GestureHUD.shared.show(title: Self.title(for: outcome, app: app, name: name), detail: outcome.summary)
                        return
                    }
                    self.phase = .done(outcome)
                case .failure(let error):
                    guard let self, ticket == self.generation else {
                        GestureHUD.shared.show(title: "Nothing Was Moved", detail: error.localizedDescription)
                        return
                    }
                    self.phase = .failed(title: "Nothing Was Moved", detail: error.localizedDescription)
                }
            }
        }
    }

    /// Pure (Codex review U1): the result names the app only when the app
    /// itself was moved; leftovers alone keep the app installed.
    nonisolated static func title(for outcome: CleanupTools.TrashOutcome, app: URL, name: String) -> String {
        let appMoved = outcome.moved.contains { $0.standardizedFileURL == app.standardizedFileURL }
        let count = outcome.moved.count
        if outcome.moved.isEmpty { return "Nothing Was Moved" }
        if !outcome.failures.isEmpty { return "\(count) Moved, \(outcome.failures.count) Stayed" }
        if appMoved { return "\(name) Is in the Trash" }
        return "\(count) Leftover\(count == 1 ? "" : "s") in the Trash · \(name) Stays Installed"
    }

    /// The items that did not move and still exist, ticked for another try
    /// (Codex review U3). Items already moved are never moved twice.
    func retryFailed() {
        guard case .done(let outcome) = phase, let review else { return }
        let moved = Set(outcome.moved.map(\.standardizedFileURL))
        let remaining = chosen.filter { !moved.contains($0.url.standardizedFileURL) && FileManager.default.fileExists(atPath: $0.url.path) }
        guard !remaining.isEmpty else { return }
        // The list itself shrinks to what is left: nothing already in the
        // Trash stays listed (unticked) as if it were still here.
        let ids = Set(remaining.map(\.id))
        self.review = CleanupTools.UninstallReview(bundleID: review.bundleID, items: remaining, preselected: ids,
                                                   nameOnly: review.nameOnly.intersection(ids), unreadable: review.unreadable)
        selected = ids
        phase = .review
    }

    var canRetry: Bool {
        guard case .done(let outcome) = phase else { return false }
        return !outcome.failures.isEmpty
    }
}

// MARK: - Sound devices

/// Outputs and inputs read off the main thread (HAL reads can block while
/// an AirPlay receiver wakes).
struct PaletteSoundDevices: Equatable {
    var outputs: [AudioOutputDevice] = []
    var inputs: [AudioOutputDevice] = []
    var currentOutput: AudioDeviceID?
    var currentInput: AudioDeviceID?
    var isMuted = false

    static func load() async -> PaletteSoundDevices {
        await Task.detached(priority: .userInitiated) {
            AudioOutputService.invalidateDeviceCache()
            let output = AudioOutputService.currentDeviceID()
            return PaletteSoundDevices(outputs: AudioOutputService.devices(), inputs: AudioOutputService.inputDevices(),
                                       currentOutput: output, currentInput: AudioOutputService.currentInputDeviceID(),
                                       isMuted: AudioOutputService.isOutputMuted())
        }.value
    }
}

// MARK: - System commands

/// Raycast's System Commands (manual.raycast.com/system-commands) that AOM
/// already performs as actions, plus Restart and Shut Down through macOS's
/// own dialogs. Each runs on the app that was in front.
struct PaletteSystemCommand: Identifiable {
    enum Kind: Equatable {
        case action(ActionType)
        /// loginwindow's "show restart / shut down dialog" events: macOS asks.
        case restartDialog, shutDownDialog
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let group: String
    let kind: Kind
    var aliases: [String] = []
    /// Asked in the panel first (the action's own alert is then skipped).
    var confirmation: (title: String, message: String, button: String)?

    static let all: [PaletteSystemCommand] = [
        .init(id: "system.lock", title: "Lock Screen", subtitle: "Lock the Mac · 화면 잠금", symbol: "lock",
              group: "Power & session", kind: .action(.lockScreen), aliases: ["lock", "잠금", "화면 잠금"]),
        .init(id: "system.sleep", title: "Sleep", subtitle: "Put the Mac to sleep · 잠자기", symbol: "moon",
              group: "Power & session", kind: .action(.sleepComputer), aliases: ["sleep", "잠자기", "절전"]),
        .init(id: "system.sleepDisplays", title: "Sleep Displays", subtitle: "Turn the displays off · 화면 끄기",
              symbol: "display", group: "Power & session", kind: .action(.sleepDisplay), aliases: ["화면 끄기", "display off"]),
        .init(id: "system.screenSaver", title: "Start Screen Saver", subtitle: "화면 보호기", symbol: "sparkles.tv",
              group: "Power & session", kind: .action(.startScreenSaver), aliases: ["screen saver", "화면 보호기"]),
        .init(id: "system.restart", title: "Restart…", subtitle: "macOS asks before anything quits · 재시동",
              symbol: "arrow.clockwise.circle", group: "Power & session", kind: .restartDialog,
              aliases: ["restart", "reboot", "재시동", "재부팅", "다시 시작"]),
        .init(id: "system.shutDown", title: "Shut Down…", subtitle: "macOS asks before anything quits · 시스템 종료",
              symbol: "power", group: "Power & session", kind: .shutDownDialog,
              aliases: ["shut down", "shutdown", "power off", "시스템 종료", "전원 끄기"]),
        .init(id: "system.logOut", title: "Log Out…", subtitle: "Apps are asked to quit · 로그아웃", symbol: "rectangle.portrait.and.arrow.right",
              group: "Power & session", kind: .action(.logOut), aliases: ["log out", "logout", "로그아웃"],
              confirmation: ("Log Out Now?", "Apps are asked to quit, then you are logged out.", "Log Out")),
        .init(id: "system.emptyTrash", title: "Empty Trash…", subtitle: "Delete everything in the Trash · 휴지통 비우기",
              symbol: "trash.slash", group: "Files", kind: .action(.emptyTrash), aliases: ["empty trash", "휴지통 비우기", "휴지통"],
              confirmation: ("Empty the Trash?", "Everything in the Trash is deleted for good. This can't be undone.", "Empty Trash")),
        .init(id: "system.eject", title: "Eject All Disks", subtitle: "External and disk images · 디스크 추출", symbol: "eject",
              group: "Files", kind: .action(.ejectAllDisks), aliases: ["eject", "추출", "디스크 꺼내기"]),
        .init(id: "system.hiddenFiles", title: "Toggle Hidden Files", subtitle: "Show or hide them in Finder · 숨김 파일",
              symbol: "eye", group: "Files", kind: .action(.toggleHiddenFiles), aliases: ["hidden files", "숨김 파일"]),
        .init(id: "system.appearance", title: "Toggle System Appearance", subtitle: "Light or dark mode · 다크 모드",
              symbol: "circle.lefthalf.filled", group: "Appearance", kind: .action(.toggleDarkMode),
              aliases: ["dark mode", "light mode", "appearance", "다크 모드", "라이트 모드", "다크모드"]),
        .init(id: "system.dnd", title: "Toggle Do Not Disturb", subtitle: "Focus › Do Not Disturb · 방해 금지",
              symbol: "moon.circle", group: "Appearance", kind: .action(.toggleDoNotDisturb),
              aliases: ["do not disturb", "dnd", "방해 금지", "집중 모드"]),
        .init(id: "system.showDesktop", title: "Show Desktop", subtitle: "Move every window aside · 데스크탑 보기",
              symbol: "menubar.dock.rectangle", group: "Apps & windows", kind: .action(.showDesktop),
              aliases: ["desktop", "데스크탑", "바탕화면"]),
        .init(id: "system.hideOthers", title: "Hide All Apps Except Frontmost", subtitle: "다른 앱 가리기",
              symbol: "eye.slash", group: "Apps & windows", kind: .action(.hideOtherApps),
              aliases: ["hide others", "hide all", "다른 앱 가리기", "가리기"]),
        .init(id: "system.missionControl", title: "Mission Control", subtitle: "Every window and Space · 미션 컨트롤",
              symbol: "rectangle.3.group", group: "Apps & windows", kind: .action(.missionControl), aliases: ["미션 컨트롤"]),
        .init(id: "system.notificationCenter", title: "Open Notification Center", subtitle: "알림 센터", symbol: "bell",
              group: "Apps & windows", kind: .action(.openNotificationCenter), aliases: ["notifications", "알림"]),
        .init(id: "system.controlCenter", title: "Open Control Center", subtitle: "제어 센터", symbol: "switch.2",
              group: "Apps & windows", kind: .action(.openControlCenter), aliases: ["control center", "제어 센터"]),
        .init(id: "system.mute", title: "Toggle Mute", subtitle: "The sound output · 음소거", symbol: "speaker.slash",
              group: "Sound", kind: .action(.muteVolume), aliases: ["mute", "음소거", "소리 끄기"]),
        .init(id: "system.micMute", title: "Toggle Microphone Mute", subtitle: "The default microphone · 마이크 음소거",
              symbol: "mic.slash", group: "Sound", kind: .action(.toggleMuteMicrophone),
              aliases: ["mic", "microphone", "마이크", "마이크 끄기"]),
    ]

    /// The macOS dialog events loginwindow answers (kAEShowRestartDialog,
    /// kAEShowShutdownDialog): nothing quits until the user confirms there.
    var appleEventSource: String? {
        switch kind {
        case .restartDialog: return "tell application \"loginwindow\" to «event aevtrrst»"
        case .shutDownDialog: return "tell application \"loginwindow\" to «event aevtrsdn»"
        case .action: return nil
        }
    }

    @MainActor
    func run() {
        switch kind {
        case .action(let type):
            var action = TriggerAction(actionType: type)
            // The launcher already asked (or the command needs no question).
            if confirmation != nil { action.parameters.requiresConfirmation = false }
            ActionExecutor.executeAction(action)
        case .restartDialog, .shutDownDialog:
            guard let source = appleEventSource else { return }
            AppleEventScripts.run(source, action: title, timeout: 15) { _ in }
        }
    }
}

// MARK: - Durations

enum PaletteKeepAwakeChoices {
    struct Choice: Equatable {
        let id: String
        let title: String
        let minutes: Int?
        let keepDisplay: Bool
        let aliases: [String]
    }

    static let all: [Choice] = [
        .init(id: "awake.15", title: "For 15 Minutes", minutes: 15, keepDisplay: false, aliases: ["15", "15m", "15분"]),
        .init(id: "awake.30", title: "For 30 Minutes", minutes: 30, keepDisplay: false, aliases: ["30", "30m", "30분"]),
        .init(id: "awake.60", title: "For 1 Hour", minutes: 60, keepDisplay: false, aliases: ["1h", "60", "1시간"]),
        .init(id: "awake.120", title: "For 2 Hours", minutes: 120, keepDisplay: false, aliases: ["2h", "120", "2시간"]),
        .init(id: "awake.240", title: "For 4 Hours", minutes: 240, keepDisplay: false, aliases: ["4h", "240", "4시간"]),
        .init(id: "awake.480", title: "For 8 Hours", minutes: 480, keepDisplay: false, aliases: ["8h", "480", "8시간"]),
        .init(id: "awake.forever", title: "Until Turned Off", minutes: nil, keepDisplay: false,
              aliases: ["indefinitely", "forever", "무기한", "계속"]),
        .init(id: "awake.display", title: "Keep the Display On Too", minutes: nil, keepDisplay: true,
              aliases: ["display", "screen", "화면 켜기", "화면 유지"]),
    ]
}

// MARK: - Screen state

/// What the launcher's screens load or watch while they are open, outside
/// the view so the results cache can be rebuilt when it changes.
@MainActor
final class PaletteRouteModels: ObservableObject {
    @Published private(set) var uninstall: PaletteUninstallFlow?
    @Published private(set) var sound: PaletteSoundDevices?
    @Published private(set) var menuBarItems: [PaletteMenuBarItems.Item]?
    /// Kill Apps rows a normal quit was asked for, and when.
    @Published private(set) var quitting: [pid_t: Date] = [:]
    /// One line under the search after an action that keeps the screen
    /// ("Quitting Safari…", "Sound output: AirPods").
    @Published var notice: String?

    private var forwarding: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var noticeTicket = 0
    /// Row IDs of the last two builds, so a row that disappears (an app
    /// that quit) hands the selection to its neighbour.
    private(set) var previousIDs: [String] = []
    private var currentIDs: [String] = []

    func remember(_ ids: [String]) {
        guard ids != currentIDs else { return }
        previousIDs = currentIDs
        currentIDs = ids
    }

    /// Pure: the row after `id` in the previous list that is still listed.
    nonisolated static func neighbor(of id: String?, previous: [String], current: [String]) -> String? {
        guard let id, let index = previous.firstIndex(of: id) else { return nil }
        let live = Set(current)
        if let next = previous[(index + 1)...].first(where: live.contains) { return next }
        return previous[..<index].last(where: live.contains)
    }

    func neighbor(of id: String?) -> String? {
        Self.neighbor(of: id, previous: previousIDs, current: currentIDs)
    }

    func show(_ text: String) {
        notice = text
        noticeTicket &+= 1
        let ticket = noticeTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.noticeTicket == ticket else { return }
            self.notice = nil
        }
    }

    // Uninstall

    func beginUninstall(_ app: URL) {
        uninstall?.cancel()
        let flow = PaletteUninstallFlow(app: app)
        forwarding = flow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        uninstall = flow
        flow.start()
    }

    func endUninstall() {
        uninstall?.cancel()
        forwarding = nil
        uninstall = nil
    }

    // Kill Apps

    func watchApps(_ on: Bool) {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        guard on else { quitting = [:]; return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification, let pid {
                        self.quitting.removeValue(forKey: pid)
                    }
                    self.objectWillChange.send()
                }
            })
        }
    }

    func markQuitting(_ pid: pid_t) {
        quitting[pid] = Date()
        // Flip the row to "Still running" once the patience runs out.
        DispatchQueue.main.asyncAfter(deadline: .now() + PaletteKillApps.quitPatience + 0.1) { [weak self] in
            guard let self, self.quitting[pid] != nil else { return }
            self.objectWillChange.send()
        }
    }

    // Sound

    private var soundTicket = 0

    /// 6.8 (Codex review): only the latest read may land, so an older read
    /// finishing late never puts the previous device back.
    func loadSound() {
        soundTicket &+= 1
        let ticket = soundTicket
        Task { [weak self] in
            let devices = await PaletteSoundDevices.load()
            guard let self, ticket == self.soundTicket else { return }
            self.sound = devices
        }
    }

    func clearSound() { soundTicket &+= 1; sound = nil }

    func loadMenuBarItems() {
        Task { [weak self] in
            let items = await PaletteMenuBarItems.scan()
            self?.menuBarItems = items
        }
    }

    func end() {
        watchApps(false)
        endUninstall()
        sound = nil
        notice = nil
    }
}

// MARK: - Menu bar items (Ice's search, from the Oracle REA report 2026-11-14 §3, §7.4)

/// Every app's menu bar extra through Accessibility — including those the
/// notch hides — so the launcher can find one by name and open its menu.
enum PaletteMenuBarItems {
    struct Item: Equatable, Identifiable {
        let pid: pid_t
        let appName: String
        let bundleID: String?
        let title: String
        /// Its index among the app's extras, to find it again when pressed.
        let index: Int
        let x: CGFloat
        var id: String { "menubar.\(pid).\(index)" }
    }

    /// Reads off the main thread; each app answers within a short timeout.
    static func scan() async -> [Item] {
        await Task.detached(priority: .userInitiated) { () -> [Item] in
            guard AXIsProcessTrusted() else { return [] }
            let own = ProcessInfo.processInfo.processIdentifier
            var items: [Item] = []
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier != own {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.15)
                for (index, child) in extras(of: element).enumerated() {
                    let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                        .lazy.compactMap { string(child, $0) }.first { !$0.isEmpty }
                    var position: CFTypeRef?
                    var point = CGPoint.zero
                    if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                       let value = position, CFGetTypeID(value) == AXValueGetTypeID() {
                        AXValueGetValue(value as! AXValue, .cgPoint, &point)
                    }
                    let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                    items.append(Item(pid: app.processIdentifier, appName: name, bundleID: app.bundleIdentifier,
                                      title: title ?? name, index: index, x: point.x))
                }
            }
            // Right to left, as they sit in the menu bar.
            return items.sorted { $0.x > $1.x }
        }.value
    }

    private static func extras(of app: AXUIElement) -> [AXUIElement] {
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success else { return [] }
        return children as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Opens the item's menu, found again by app and position in its list.
    @discardableResult
    static func press(_ item: Item) -> Bool {
        let element = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let list = extras(of: element)
        guard list.indices.contains(item.index) else { return false }
        return AXUIElementPerformAction(list[item.index], kAXPressAction as CFString) == .success
    }
}
