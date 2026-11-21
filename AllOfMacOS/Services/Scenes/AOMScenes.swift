import AppKit
import CoreAudio
import Foundation

// AOM 7.3: work scenes (DeepSeek design v2 §6.3, Codex 7.2.3 report p. 7;
// Bunch's launch/quit/audio/dark mode/dnd lines, its
// +[BunchAudio setAudioDeviceForType:to:]).
//
// A scene sets up the Mac for one kind of work in one step, in this order:
// open its apps and wait (8 s at most) for the first window of those that
// have one → put the windows where a saved Window Tiling layout says, after
// that finishes → the sound output, the appearance, Keep Awake → a Focus
// session → last, ask the apps to quit that the scene closes (their own
// Save dialogs are left to answer). Each step reports done, already so,
// skipped or failed and why; a missing device or display changes nothing;
// Cancel stops before the next step; Run Failed Steps runs only those.

struct SceneApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    /// Wait for its first window before the layout (off for apps without windows).
    var waitsForWindow = true
    var id: String { bundleID }
}

/// The output kept by its CoreAudio UID, with its name and kind to find it
/// again when the UID changes (a re-paired Bluetooth device).
struct SceneAudioTarget: Codable, Hashable {
    var uid: String
    var name: String
    var transport: UInt32 = 0
}

enum SceneAppearance: String, Codable, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : "Light" }
}

struct SceneProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var launchApps: [SceneApp] = []
    /// A layout saved in Window Tiling.
    var layoutName: String?
    var audio: SceneAudioTarget?
    var appearance: SceneAppearance?
    /// Keep Awake for this many minutes; 0 until turned off; nil leaves it.
    var keepAwakeMinutes: Int?
    var startsFocus = false
    var quitApps: [SceneApp] = []

    /// Pure: what to fix before it can be saved.
    var problems: [String] {
        var list: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { list.append("Give the scene a name") }
        let both = Set(launchApps.map(\.bundleID)).intersection(quitApps.map(\.bundleID))
        for id in both.sorted() {
            let name = launchApps.first { $0.bundleID == id }?.name ?? id
            list.append("\(name) is set to open and to quit")
        }
        if launchApps.isEmpty, layoutName == nil, audio == nil, appearance == nil, keepAwakeMinutes == nil, !startsFocus, quitApps.isEmpty {
            list.append("Add at least one step")
        }
        return list
    }
}

/// One step of a scene, in running order.
enum SceneStep: Hashable, Identifiable {
    case launch(SceneApp)
    case layout(String)
    case audio(SceneAudioTarget)
    case appearance(SceneAppearance)
    case keepAwake(Int)
    case focus
    case quit(SceneApp)

    var id: String {
        switch self {
        case .launch(let app): return "launch.\(app.bundleID)"
        case .layout(let name): return "layout.\(name)"
        case .audio(let target): return "audio.\(target.uid)"
        case .appearance(let mode): return "appearance.\(mode.rawValue)"
        case .keepAwake(let minutes): return "keepAwake.\(minutes)"
        case .focus: return "focus"
        case .quit(let app): return "quit.\(app.bundleID)"
        }
    }

    var title: String {
        switch self {
        case .launch(let app): return "Open \(app.name)"
        case .layout(let name): return "Arrange windows: \(name)"
        case .audio(let target): return "Sound output: \(target.name)"
        case .appearance(let mode): return "Appearance: \(mode.title)"
        case .keepAwake(let minutes): return minutes == 0 ? "Keep Awake until turned off" : "Keep Awake for \(minutes) min"
        case .focus: return "Start a Focus session"
        case .quit(let app): return "Quit \(app.name)"
        }
    }

    var symbol: String {
        switch self {
        case .launch: return "arrow.up.forward.app"
        case .layout: return "rectangle.split.3x1"
        case .audio: return "hifispeaker"
        case .appearance: return "circle.lefthalf.filled"
        case .keepAwake: return "cup.and.saucer"
        case .focus: return "timer"
        case .quit: return "xmark.app"
        }
    }

    var stage: String {
        switch self {
        case .launch: return "Apps"
        case .layout: return "Windows"
        case .audio, .appearance, .keepAwake: return "System"
        case .focus: return "Focus"
        case .quit: return "Quit"
        }
    }
}

struct SceneStepResult: Equatable, Identifiable {
    enum Outcome: Equatable {
        case done(String?)
        case already
        case skipped(String)
        case failed(String)
        case cancelled
    }
    var step: SceneStep
    var outcome: Outcome
    var id: String { step.id }

    var isFailure: Bool { if case .failed = outcome { return true }; return false }

    var line: String {
        switch outcome {
        case .done(let note): return note.map { "\(step.title) — \($0)" } ?? step.title
        case .already: return "\(step.title) — already so"
        case .skipped(let why): return "\(step.title) — skipped: \(why)"
        case .failed(let why): return "\(step.title) — failed: \(why)"
        case .cancelled: return "\(step.title) — not run (cancelled)"
        }
    }
}

/// What the Mac looks like now, for the preview (a seam for tests).
struct SceneState {
    var runningBundleIDs: Set<String>
    var layoutNames: Set<String>
    var outputs: [(uid: String, name: String, transport: UInt32)]
    var currentOutputUID: String?
    var isDark: Bool
    var keepAwakeActive: Bool
    var focusActive: Bool

    @MainActor static func live() -> SceneState {
        SceneState(runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
                   layoutNames: Set(WindowManager.shared.layouts.map(\.name)),
                   outputs: AudioOutputService.devices().map { ($0.uid, $0.name, SceneAudio.transport(of: $0.id)) },
                   currentOutputUID: AudioOutputRestore.defaultOutputUID(),
                   isDark: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark",
                   keepAwakeActive: KeepAwakeService.shared.isActive,
                   focusActive: FocusModule.isSessionActive)
    }
}

enum SceneAudio {
    static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr ? type : 0
    }

    /// Pure: the output for `target` — by UID, else the one output of its
    /// kind with its name, else the one with its name. Two candidates that
    /// can't be told apart: none (the scene asks instead of guessing).
    static func resolve(_ target: SceneAudioTarget, in outputs: [(uid: String, name: String, transport: UInt32)]) -> (uid: String, ambiguous: Bool)? {
        if let exact = outputs.first(where: { $0.uid == target.uid }) { return (exact.uid, false) }
        let sameKind = outputs.filter { $0.transport == target.transport && target.transport != 0 && $0.name == target.name }
        if sameKind.count == 1 { return (sameKind[0].uid, false) }
        let sameName = outputs.filter { $0.name == target.name }
        if sameName.count == 1 { return (sameName[0].uid, false) }
        if sameName.count > 1 || sameKind.count > 1 { return ("", true) }
        return nil
    }
}

enum ScenePlanner {
    /// Pure: the steps in running order.
    static func steps(_ scene: SceneProfile) -> [SceneStep] {
        var steps: [SceneStep] = scene.launchApps.map { .launch($0) }
        if let layout = scene.layoutName { steps.append(.layout(layout)) }
        if let audio = scene.audio { steps.append(.audio(audio)) }
        if let appearance = scene.appearance { steps.append(.appearance(appearance)) }
        if let minutes = scene.keepAwakeMinutes { steps.append(.keepAwake(minutes)) }
        if scene.startsFocus { steps.append(.focus) }
        steps += scene.quitApps.map { .quit($0) }
        return steps
    }

    /// Pure (Codex recommended feature 6, the preview): each step and
    /// whether it is already so, can't run here, or will run.
    static func preview(_ scene: SceneProfile, state: SceneState) -> [SceneStepResult] {
        steps(scene).map { step in
            switch step {
            case .launch(let app):
                return .init(step: step, outcome: state.runningBundleIDs.contains(app.bundleID) ? .already : .done(nil))
            case .layout(let name):
                return .init(step: step, outcome: state.layoutNames.contains(name) ? .done(nil) : .skipped("no layout named “\(name)” in Window Tiling"))
            case .audio(let target):
                guard let found = SceneAudio.resolve(target, in: state.outputs) else {
                    return .init(step: step, outcome: .skipped("\(target.name) isn't connected"))
                }
                if found.ambiguous { return .init(step: step, outcome: .skipped("more than one output is named \(target.name); choose it again")) }
                return .init(step: step, outcome: found.uid == state.currentOutputUID ? .already : .done(nil))
            case .appearance(let mode):
                return .init(step: step, outcome: (mode == .dark) == state.isDark ? .already : .done(nil))
            case .keepAwake:
                return .init(step: step, outcome: state.keepAwakeActive ? .already : .done(nil))
            case .focus:
                return .init(step: step, outcome: state.focusActive ? .already : .done(nil))
            case .quit(let app):
                return .init(step: step, outcome: state.runningBundleIDs.contains(app.bundleID) ? .done(nil) : .already)
            }
        }
    }
}

/// The scenes, in Application Support/AllOfMacOS/Scenes/scenes.json
/// (an unreadable file is kept aside, never saved over).
@MainActor
final class SceneStore: ObservableObject {
    static let shared = SceneStore(url: SceneStore.defaultURL)

    @Published private(set) var scenes: [SceneProfile] = []
    @Published private(set) var problem: FocusDataProblem?
    let url: URL?
    private var blocksSaving = false

    static var defaultURL: URL? {
        if PresetManager.isRunningTests { return nil }
        if let preview = PresetManager.previewDirectory { return preview.appendingPathComponent("Scenes/scenes.json") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/Scenes/scenes.json")
    }

    init(url: URL?) {
        self.url = url
        guard let url else { return }
        let loaded = AOMCheckedFile.load(url, owner: "Scenes") { try JSONDecoder().decode([SceneProfile].self, from: $0) }
        scenes = loaded.value ?? []
        if PresetManager.isUIPreview, scenes.isEmpty {
            var coding = SceneProfile(name: "Coding")
            coding.launchApps = [SceneApp(bundleID: "com.apple.Terminal", name: "Terminal"), SceneApp(bundleID: "com.apple.Safari", name: "Safari")]
            coding.layoutName = "Two up"
            coding.appearance = .dark
            coding.keepAwakeMinutes = 120
            coding.startsFocus = true
            coding.quitApps = [SceneApp(bundleID: "com.apple.Music", name: "Music")]
            scenes = [coding]
        }
        problem = loaded.problem("Your scenes")
        blocksSaving = problem?.blocksSaving == true
    }

    func save(_ scene: SceneProfile) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) { scenes[index] = scene } else { scenes.append(scene) }
        write()
    }

    func delete(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        write()
    }

    private func write() {
        guard let url, !blocksSaving else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scenes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FilesAtomicWriter.write(data, to: url)
    }
}

/// Runs scenes one at a time.
@MainActor
final class SceneRunner: ObservableObject {
    static let shared = SceneRunner()

    @Published private(set) var runningID: UUID?
    @Published private(set) var current: SceneStep?
    /// The last run of each scene.
    @Published private(set) var results: [UUID: [SceneStepResult]] = [:]
    private var task: Task<Void, Never>?

    var isRunning: Bool { runningID != nil }

    /// Runs every step, or (`only`) the ones named — Run Failed Steps.
    func run(_ scene: SceneProfile, only: Set<String>? = nil, done: (([SceneStepResult]) -> Void)? = nil) {
        guard runningID == nil else { GestureHUD.shared.show(title: "A Scene Is Running", detail: "Wait for it, or cancel it first."); return }
        runningID = scene.id
        let steps = ScenePlanner.steps(scene).filter { only?.contains($0.id) ?? true }
        task = Task { [weak self] in
            var out: [SceneStepResult] = []
            for step in steps {
                guard let self else { return }
                if Task.isCancelled {
                    out.append(.init(step: step, outcome: .cancelled))
                    continue
                }
                self.current = step
                out.append(.init(step: step, outcome: await self.perform(step, scene: scene)))
            }
            guard let self else { return }
            var merged = self.results[scene.id] ?? []
            if only != nil {
                for result in out {
                    if let index = merged.firstIndex(where: { $0.id == result.id }) { merged[index] = result } else { merged.append(result) }
                }
            } else {
                merged = out
            }
            self.results[scene.id] = merged
            self.current = nil
            self.runningID = nil
            self.task = nil
            let failed = out.filter(\.isFailure).count
            let skipped = out.filter { if case .skipped = $0.outcome { return true }; return false }.count
            GestureHUD.shared.show(title: scene.name,
                                   detail: failed == 0 && skipped == 0 ? "Ready — \(out.count) step\(out.count == 1 ? "" : "s")"
                                       : "\(out.count - failed - skipped) done · \(skipped) skipped · \(failed) failed")
            GestureLog.shared.logFromAnyThread("Scene \(scene.name): " + out.map(\.line).joined(separator: "; "), level: .action)
            done?(out)
        }
    }

    func cancel() { task?.cancel() }

    private func perform(_ step: SceneStep, scene: SceneProfile) async -> SceneStepResult.Outcome {
        switch step {
        case .launch(let app): return await launch(app)
        case .layout(let name): return await arrange(name)
        case .audio(let target):
            // Read afresh: AirPods connected a moment ago aren't in the 0.5 s cache yet.
            AudioOutputService.invalidateDeviceCache()
            let state = SceneState.live()
            guard let found = SceneAudio.resolve(target, in: state.outputs) else { return .skipped("\(target.name) isn't connected") }
            if found.ambiguous { return .skipped("more than one output is named \(target.name)") }
            if found.uid == state.currentOutputUID { return .already }
            return await withCheckedContinuation { continuation in
                AudioOutputService.shared.select(name: target.name, uid: found.uid) { ok in
                    continuation.resume(returning: ok ? .done(nil) : .failed("macOS didn't switch the output"))
                }
            }
        case .appearance(let mode):
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            if (mode == .dark) == dark { return .already }
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(mode == .dark ? "true" : "false")"
            return await withCheckedContinuation { continuation in
                AppleEventScripts.run(script, action: "Scene Appearance", timeout: 5) { ok in
                    continuation.resume(returning: ok ? .done(nil) : .failed("System Events didn't answer (Automation permission)"))
                }
            }
        case .keepAwake(let minutes):
            // One assertion: a Keep Awake already running (yours or Focus's) is kept.
            if KeepAwakeService.shared.isActive { return .already }
            return KeepAwakeService.shared.start(minutes: minutes == 0 ? nil : minutes, keepDisplay: false) ? .done(nil) : .failed("macOS refused")
        case .focus:
            if FocusModule.isSessionActive { return .already }
            guard AOMModuleSwitches.shared.isOn(.focus) else { return .skipped("Focus is turned off in Settings › Modules") }
            FocusModule.environment.session.start(userInitiated: true)
            return FocusModule.isSessionActive ? .done(nil) : .failed("the session didn't start")
        case .quit(let app): return await quit(app)
        }
    }

    private func launch(_ app: SceneApp) async -> SceneStepResult.Outcome {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
        // Open with a window already: nothing to do. Open without one
        // (Safari or Terminal with every window closed): opening it again
        // sends the reopen event, which makes a new window, and the scene
        // waits for it like a launch (7.3 review; activate() alone didn't).
        if let running, !app.waitsForWindow || Self.hasWindow(running.processIdentifier) { return .already }
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            return .failed("\(app.name) isn't installed")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = running != nil
        let opened: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, _ in
                continuation.resume(returning: running)
            }
        }
        guard let opened else { return .failed("macOS didn't open it") }
        guard app.waitsForWindow else { return .done(nil) }
        let start = Date()
        while Date().timeIntervalSince(start) < 8 {
            if Task.isCancelled { return .done("opened; stopped waiting (cancelled)") }
            if Self.hasWindow(opened.processIdentifier) {
                return .done(String(format: "window after %.1f s", Date().timeIntervalSince(start)))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return .done("opened; no window within 8 s, so its windows may not be arranged")
    }

    private func arrange(_ name: String) async -> SceneStepResult.Outcome {
        guard WindowManager.shared.layouts.contains(where: { $0.name == name }) else {
            return .skipped("no layout named “\(name)” in Window Tiling")
        }
        let ok: Bool = await withCheckedContinuation { continuation in
            WindowManager.shared.restoreLayout(name: name) { continuation.resume(returning: $0) }
        }
        let result = WindowManager.shared.lastLayoutResult
        return ok ? .done(result) : (result.hasPrefix("Restored 0") || result.isEmpty ? .failed(result.isEmpty ? "the windows couldn't be moved" : result) : .done(result))
    }

    private func quit(_ app: SceneApp) async -> SceneStepResult.Outcome {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        guard !running.isEmpty else { return .already }
        // A polite quit: the app may ask to save, and that is left to the person.
        running.forEach { _ = $0.terminate() }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if running.allSatisfy(\.isTerminated) { return .done(nil) }
        }
        return .done("asked to quit; it's still open (it may be asking to save)")
    }

    /// A normal on-screen window of the process.
    static func hasWindow(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 60
        }
    }

}
