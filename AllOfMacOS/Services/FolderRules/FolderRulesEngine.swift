import AppKit
import Combine
import Foundation
import UserNotifications

/// Items one rule wants to change, waiting for the person's OK (grouped per
/// rule, so a first run over 30 old files asks once, not 30 times).
struct FolderRuleApproval: Identifiable, Equatable {
    let id: UUID
    let ruleID: UUID
    var ruleName: String
    var folderName: String
    var requests: [FolderRuleApprovalRequest]
    var created: Date
    /// The approve button ("Move to Trash", "Install", "Optimize").
    var verb: String
    /// "Move “Old.dmg” to the Trash?"
    var question: String
}

/// A message for the Folder Rules page's toast.
struct FolderRulesMessage: Equatable {
    let id = UUID()
    var text: String
    var tone: AOMTone
}

/// Folder Rules' coordinator: the rules, the watcher and sweep, the runs,
/// approvals, the activity log with Undo, and the Workspace status. All
/// file work happens on the runner's queue; this class stays on main.
@MainActor
final class FolderRulesEngine: ObservableObject {
    static let shared = FolderRulesEngine(store: FolderRulesStore(), environment: .live, publishesStatus: true)

    @Published private(set) var config: FolderRulesConfig
    @Published private(set) var activity: [FolderRuleActivity]
    @Published private(set) var approvals: [FolderRuleApproval] = []
    @Published private(set) var folderStates: [UUID: FolderRuleFolderState] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var lastPass: Date?
    /// Rules the loop guard turned off, with why.
    @Published private(set) var stoppedRules: [UUID: String] = [:]
    /// Set when rules.json couldn't be read and was set aside.
    @Published private(set) var setAside: URL?
    /// The disk image a manual install is working on.
    @Published private(set) var installing: String?
    @Published var message: FolderRulesMessage?

    let store: FolderRulesStore
    let runner: FolderRulesRunner
    private let publishesStatus: Bool
    private let watcher = FolderRulesWatcher()
    private let saveQueue = DispatchQueue(label: "com.kyw.allofmacos.folder-rules.save", qos: .utility)
    /// Posts a rule's notification (title, body). Replaced in tests.
    var notify: (String, String) -> Void = { title, body in FolderRulesNotifier.post(title: title, body: body) }
    /// Whether AOM is paused (the master switch or Pause AOM). Replaced in tests.
    var gateIsOpen: () -> Bool = { AutomationGate.isOn && !TriggerSuppression.shared.isPaused }

    private var started = false
    private var sweepTimer: Timer?
    private var scheduledPass: DispatchWorkItem?
    private var scheduledDeadline: Date?
    /// Folders the next pass covers: nil for all, empty for none yet.
    private var scheduledFolders: Set<UUID>? = []
    private var passRunning = false
    private var rerunRequested = false
    private var rerunFolders: Set<UUID>? = []
    private var jobs = 0 { didSet { isRunning = jobs > 0 } }
    private var grants: [String: Date] = [:]
    private var deferredWhilePaused = false
    private var lastGate = true
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var configSave: DispatchWorkItem?

    /// How often the sweep re-checks time-based conditions.
    static let sweepInterval: TimeInterval = 300

    init(store: FolderRulesStore, environment: FolderRulesEnvironment, publishesStatus: Bool) {
        self.store = store
        self.publishesStatus = publishesStatus
        let loaded = store.loadConfig(defaults: FolderRulesLocations.defaultConfig)
        config = loaded.config
        setAside = loaded.setAside
        activity = FolderRulesStore.trimmed(store.loadActivity(), now: environment.now())
        runner = FolderRulesRunner(environment: environment, memory: store.loadMemory())
        if !loaded.existed { saveConfig(immediately: true) }
        refreshStatus()
    }

    // MARK: Start, watching, sweeps

    /// Launch: observe Pause AOM and wake, watch the active folders and
    /// catch up on what changed while AOM wasn't running.
    func start() {
        guard !started else { return }
        started = true
        lastGate = gateIsOpen()
        TriggerSuppression.shared.$pause
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.gateMayHaveChanged() } }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gateMayHaveChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePass(nil, after: 10) }
        })
        watcher.onChange = { [weak self] paths in
            MainActor.assumeIsolated { self?.foldersChanged(paths) }
        }
        updateActivity()
        schedulePass(nil, after: 3)
    }

    /// Active: the master switch is on, AOM isn't paused, and a folder has a rule that can run.
    var isActive: Bool { config.isEnabled && gateIsOpen() && !activeRules.isEmpty }

    var activeRules: [FolderRule] { config.rules.filter { $0.isEnabled && $0.problems.isEmpty } }

    private var watchedFolders: [FolderRuleFolder] {
        let ids = Set(activeRules.map(\.folderID))
        return config.folders.filter { ids.contains($0.id) }
    }

    /// Watches and sweeps only while active: no stream and no timer otherwise.
    private func updateActivity() {
        guard started else { refreshStatus(); return }
        if isActive {
            watcher.watch(watchedFolders.map(\.path))
            if sweepTimer == nil {
                let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedulePass(nil, after: 0) }
                }
                timer.tolerance = 60
                RunLoop.main.add(timer, forMode: .common)
                sweepTimer = timer
            }
        } else {
            watcher.stop()
            sweepTimer?.invalidate()
            sweepTimer = nil
        }
        refreshStatus()
    }

    private func gateMayHaveChanged() {
        let open = gateIsOpen()
        guard open != lastGate else { return }
        lastGate = open
        updateActivity()
        if open, deferredWhilePaused || config.isEnabled {
            deferredWhilePaused = false
            schedulePass(nil, after: 1)
        }
    }

    private func foldersChanged(_ paths: [String]) {
        let ids = Set(config.folders.filter { paths.contains($0.path) }.map(\.id))
        guard !ids.isEmpty else { return }
        schedulePass(ids, after: 1.5)
    }

    /// Nil (all folders) absorbs any set; sets merge.
    static func merge(_ a: Set<UUID>?, _ b: Set<UUID>?) -> Set<UUID>? {
        guard let a, let b else { return nil }
        return a.union(b)
    }

    /// Coalesces requests: folders merge (nil means all) and the earliest
    /// deadline wins, so a long download's steady events never postpone a pass.
    func schedulePass(_ folders: Set<UUID>?, after delay: TimeInterval) {
        scheduledFolders = Self.merge(scheduledFolders, folders)
        let deadline = Date().addingTimeInterval(max(0, delay))
        if scheduledPass != nil, let current = scheduledDeadline, current <= deadline { return }
        scheduledPass?.cancel()
        scheduledDeadline = deadline
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduledPass = nil
                self?.scheduledDeadline = nil
                self?.startPass()
            }
        }
        scheduledPass = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    /// "Run Folder Rules Now".
    func runNow() {
        schedulePass(nil, after: 0)
    }

    private func startPass() {
        let folders = scheduledFolders
        scheduledFolders = []
        guard config.isEnabled, !activeRules.isEmpty else { return }
        guard gateIsOpen() else { deferredWhilePaused = true; refreshStatus(); return }
        guard !passRunning else {
            rerunRequested = true
            rerunFolders = Self.merge(rerunFolders, folders)
            return
        }
        passRunning = true
        jobs += 1
        refreshStatus()
        let now = runner.environment.now()
        grants = grants.filter { now.timeIntervalSince($0.value) < 86_400 }
        let input = FolderRulesRunner.PassInput(config: config, folderIDs: folders,
                                                pending: Set(approvals.flatMap { $0.requests.map(\.key) }),
                                                granted: Set(grants.keys))
        let runner = self.runner
        let store = self.store
        runner.queue.async { [weak self] in
            let output = runner.pass(input)
            try? store.save(memory: runner.memory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishPass(output) }
            }
        }
    }

    private func finishPass(_ output: FolderRulePassOutput, wasPass: Bool = true) {
        jobs = max(0, jobs - 1)
        if wasPass { passRunning = false }
        lastPass = runner.environment.now()
        for (id, state) in output.folderStates { folderStates[id] = state }
        for key in output.consumedGrants { grants.removeValue(forKey: key) }
        absorb(output)
        if let delay = output.recheckAfter { schedulePass(nil, after: delay) }
        if wasPass, rerunRequested {
            rerunRequested = false
            let folders = rerunFolders
            rerunFolders = []
            schedulePass(folders, after: 0.5)
        }
        refreshStatus()
    }

    /// Activity lines, approvals, loop stops and notifications from a pass.
    private func absorb(_ output: FolderRulePassOutput) {
        let now = runner.environment.now()
        if !output.runs.isEmpty {
            activity.insert(contentsOf: output.runs.reversed().map { FolderRuleActivity($0, date: now) }, at: 0)
            activity = FolderRulesStore.trimmed(activity, now: now)
            saveActivity()
        }
        addApprovals(output.approvals, now: now)
        for (ruleID, reason) in output.stoppedRules {
            guard let index = config.rules.firstIndex(where: { $0.id == ruleID }) else { continue }
            config.rules[index].isEnabled = false
            stoppedRules[ruleID] = reason
            activity.insert(FolderRuleActivity(date: now, ruleID: ruleID, ruleName: config.rules[index].name,
                                               folderName: config.folder(config.rules[index].folderID)?.name ?? "",
                                               fileName: "", result: .failed, detail: "Turned off: \(reason)."), at: 0)
            saveActivity()
            saveConfig()
            updateActivity()
        }
        for (ruleID, texts) in output.notifications where !texts.isEmpty {
            let title = config.rules.first { $0.id == ruleID }?.name ?? "Folder Rules"
            let body = texts.count == 1 ? texts[0] : "\(texts[0]) and \(texts.count - 1) more"
            notify(title, body)
        }
    }

    // MARK: Approvals

    private func addApprovals(_ requests: [FolderRuleApprovalRequest], now: Date) {
        guard !requests.isEmpty else { return }
        for (ruleID, group) in Dictionary(grouping: requests, by: \.ruleID) {
            guard let rule = config.rules.first(where: { $0.id == ruleID }) else { continue }
            if let index = approvals.firstIndex(where: { $0.ruleID == ruleID }) {
                let known = Set(approvals[index].requests.map(\.key))
                approvals[index].requests += group.filter { !known.contains($0.key) }
                Self.describe(&approvals[index], rule: rule)
            } else {
                var approval = FolderRuleApproval(id: UUID(), ruleID: ruleID, ruleName: rule.name,
                                                  folderName: config.folder(rule.folderID)?.name ?? "",
                                                  requests: group, created: now, verb: "", question: "")
                Self.describe(&approval, rule: rule)
                approvals.append(approval)
            }
        }
    }

    static func describe(_ approval: inout FolderRuleApproval, rule: FolderRule) {
        let count = approval.requests.count
        let name = approval.requests.first?.info.name ?? "the item"
        let one = count == 1
        switch rule.actionsNeedingApproval.first?.kind ?? .moveToTrash {
        case .installApp:
            approval.verb = "Install"
            approval.question = one ? "Install the app from “\(name)”?" : "Install the apps from \(count) disk images?"
        case .optimizeImage:
            approval.verb = "Optimize"
            approval.question = one ? "Optimize “\(name)”?" : "Optimize \(count) images?"
        case .compress:
            approval.verb = "Compress"
            approval.question = one ? "Compress “\(name)” and move the original to the Trash?"
                                    : "Compress \(count) items and move the originals to the Trash?"
        case .extract:
            approval.verb = "Extract"
            approval.question = one ? "Extract “\(name)” and move the archive to the Trash?"
                                    : "Extract \(count) archives and move them to the Trash?"
        default:
            approval.verb = "Move to Trash"
            approval.question = one ? "Move “\(name)” to the Trash?" : "Move \(count) items to the Trash?"
        }
    }

    /// Runs the approved items; `alwaysAllow` makes the rule run without asking from now on.
    func approve(_ id: UUID, alwaysAllow: Bool = false) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        if alwaysAllow, let ruleIndex = config.rules.firstIndex(where: { $0.id == approval.ruleID }) {
            config.rules[ruleIndex].runWithoutAsking = true
            saveConfig()
        }
        guard gateIsOpen() else {
            message = FolderRulesMessage(text: "AOM is paused; the approved items run when it resumes.", tone: .warning)
            for request in approval.requests { grants[request.key] = runner.environment.now() }
            deferredWhilePaused = true
            refreshStatus()
            return
        }
        let config = self.config
        let runner = self.runner
        let store = self.store
        jobs += 1
        refreshStatus()
        runner.queue.async { [weak self] in
            let output = runner.runApproved(approval.requests, config: config)
            try? store.save(memory: runner.memory)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishPass(output, wasPass: false) } }
        }
    }

    /// Skip: the rule leaves those items alone from now on.
    func skip(_ id: UUID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        let config = self.config
        let runner = self.runner
        let store = self.store
        runner.queue.async {
            runner.markSkipped(approval.requests, config: config)
            try? store.save(memory: runner.memory)
        }
        let now = runner.environment.now()
        let names = approval.requests.map(\.info.name)
        activity.insert(FolderRuleActivity(date: now, ruleID: approval.ruleID, ruleName: approval.ruleName,
                                           folderName: approval.folderName,
                                           fileName: names.count == 1 ? names[0] : "\(names.count) items",
                                           result: .skipped, detail: "Skipped by you"), at: 0)
        saveActivity()
        refreshStatus()
    }

    // MARK: Editing

    func setMasterEnabled(_ on: Bool) {
        guard config.isEnabled != on else { return }
        config.isEnabled = on
        saveConfig()
        updateActivity()
        if on { schedulePass(nil, after: 0.5) }
    }

    func folder(_ id: UUID?) -> FolderRuleFolder? { id.flatMap(config.folder) }

    /// Adds a folder to watch. Refuses the inside of packages and duplicates.
    @discardableResult
    func addFolder(_ url: URL) -> Result<FolderRuleFolder, FolderRuleFailure> {
        let standardized = url.standardizedFileURL
        if let existing = config.folders.first(where: { $0.path == standardized.path }) { return .success(existing) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(FolderRuleFailure("“\(standardized.lastPathComponent)” isn't a folder."))
        }
        if (try? standardized.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            || FolderRuleFileReader.isInsidePackage(standardized) {
            return .failure(FolderRuleFailure("Folder Rules never works inside apps or other packages."))
        }
        if standardized.path == "/" || standardized.path == FolderRulesLocations.home.path {
            return .failure(FolderRuleFailure("Choose a folder inside your home folder, such as Downloads."))
        }
        let folder = FolderRuleFolder(path: standardized.path)
        config.folders.append(folder)
        saveConfig()
        return .success(folder)
    }

    /// Removes a folder with its rules; returns them for Undo.
    func removeFolder(_ id: UUID) -> (folder: FolderRuleFolder, index: Int, rules: [FolderRule])? {
        guard let index = config.folders.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = config.folders.remove(at: index)
        let rules = config.rules.filter { $0.folderID == id }
        config.rules.removeAll { $0.folderID == id }
        approvals.removeAll { approval in rules.contains { $0.id == approval.ruleID } }
        folderStates.removeValue(forKey: id)
        saveConfig()
        updateActivity()
        return (folder, index, rules)
    }

    func restoreFolder(_ folder: FolderRuleFolder, at index: Int, rules: [FolderRule]) {
        guard !config.folders.contains(where: { $0.id == folder.id }) else { return }
        config.folders.insert(folder, at: min(index, config.folders.count))
        config.rules += rules
        saveConfig()
        updateActivity()
    }

    /// A new, empty-ish rule in a folder (off, with one condition and one action to edit).
    func newRule(in folderID: UUID) -> FolderRule {
        let rule = FolderRule(folderID: folderID, name: "New rule",
                              conditions: [FolderRuleCondition(attribute: .kind, kind: .image)],
                              actions: [FolderRuleAction(kind: .move, folderPath: FolderRulesLocations.pictures.path)])
        config.rules.append(rule)
        saveConfig()
        return rule
    }

    /// Adds a template's rule (off) to its folder, adding the folder if needed.
    func add(_ template: FolderRuleTemplate) -> FolderRule? {
        let folder: FolderRuleFolder
        switch addFolder(template.folderURL) {
        case .success(let found): folder = found
        case .failure(let failure):
            message = FolderRulesMessage(text: "Couldn't add “\(template.title)”: \(failure.message)", tone: .danger)
            return nil
        }
        let rule = template.make(folder.id)
        config.rules.append(rule)
        saveConfig()
        return rule
    }

    /// Saves an edited rule. A change to its conditions lets it look at
    /// items it already handled again (Hazel does the same).
    func update(_ rule: FolderRule) {
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }), config.rules[index] != rule else { return }
        let wasActive = config.rules[index].isEnabled
        config.rules[index] = rule
        stoppedRules.removeValue(forKey: rule.id)
        if let approvalIndex = approvals.firstIndex(where: { $0.ruleID == rule.id }) {
            approvals[approvalIndex].ruleName = rule.name
        }
        saveConfig()
        updateActivity()
        if rule.isEnabled || wasActive { schedulePass([rule.folderID], after: 1) }
    }

    func delete(_ id: UUID) -> (rule: FolderRule, index: Int)? {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return nil }
        let rule = config.rules.remove(at: index)
        approvals.removeAll { $0.ruleID == id }
        stoppedRules.removeValue(forKey: id)
        saveConfig()
        updateActivity()
        return (rule, index)
    }

    func restore(_ rule: FolderRule, at index: Int) {
        guard !config.rules.contains(where: { $0.id == rule.id }) else { return }
        config.rules.insert(rule, at: min(index, config.rules.count))
        saveConfig()
        updateActivity()
    }

    func duplicate(_ id: UUID) -> FolderRule? {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = config.rules[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.isEnabled = false
        config.rules.insert(copy, at: index + 1)
        saveConfig()
        return copy
    }

    /// Moves a rule within its folder (rules run top to bottom).
    func move(_ id: UUID, by offset: Int) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        let folderID = config.rules[index].folderID
        let siblings = config.rules.indices.filter { config.rules[$0].folderID == folderID }
        guard let position = siblings.firstIndex(of: index) else { return }
        let target = position + offset
        guard siblings.indices.contains(target) else { return }
        config.rules.swapAt(index, siblings[target])
        saveConfig()
    }

    /// Turns a rule on or off. On comes after the preview: `approving` holds
    /// the items the person saw there, which then run without asking again.
    /// Turning a rule on also turns Folder Rules on.
    func setRule(_ id: UUID, enabled: Bool, approving keys: Set<String> = []) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        config.rules[index].isEnabled = enabled
        if enabled {
            stoppedRules.removeValue(forKey: id)
            let now = runner.environment.now()
            for key in keys { grants[key] = now }
            if !config.isEnabled { config.isEnabled = true }
        } else {
            approvals.removeAll { $0.ruleID == id }
        }
        saveConfig()
        updateActivity()
        if enabled { schedulePass([config.rules[index].folderID], after: 0.3) }
    }

    /// Lets a rule act again on everything that matches (Hazel's "run rules
    /// on all items" after the person asks for it).
    func forgetHandledItems(of id: UUID) {
        let runner = self.runner
        let store = self.store
        runner.queue.async {
            runner.forget(rule: id)
            try? store.save(memory: runner.memory)
        }
    }

    // MARK: Preview, test, undo

    func preview(_ rule: FolderRule) async -> FolderRulePreview {
        let config = self.config
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            runner.queue.async { continuation.resume(returning: runner.preview(rule, config: config)) }
        }
    }

    func test(_ rule: FolderRule, file: URL) async -> FolderRulePreviewItem? {
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            runner.queue.async { continuation.resume(returning: runner.test(rule, file: file)) }
        }
    }

    func undo(_ id: UUID) {
        guard let index = activity.firstIndex(where: { $0.id == id }), activity[index].canUndo else { return }
        let entry = activity[index]
        let runner = self.runner
        runner.queue.async { [weak self] in
            let result = runner.undo(entry.steps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishUndo(id, steps: result.steps, failure: result.failure) }
            }
        }
    }

    private func finishUndo(_ id: UUID, steps: [FolderRuleStepRecord], failure: String?) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        activity[index].steps = steps
        if failure == nil { activity[index].undone = true }
        let name = activity[index].fileName
        message = failure.map { FolderRulesMessage(text: "Couldn't undo “\(name)”: \($0)", tone: .danger) }
            ?? FolderRulesMessage(text: "Put “\(name)” back", tone: .success)
        saveActivity()
        refreshStatus()
    }

    func clearActivity() {
        activity.removeAll()
        saveActivity()
        refreshStatus()
    }

    // MARK: Manual install

    /// "Install Disk Image…": installs the app from a disk image the person
    /// chose. It asks before replacing an installed app.
    func installDiskImage(_ image: URL, trashAfter: Bool) {
        guard installing == nil else {
            message = FolderRulesMessage(text: "Another install is still running.", tone: .warning)
            return
        }
        installing = image.lastPathComponent
        refreshStatus()
        var environment = runner.environment
        environment.chooseApp = { apps in FolderRulesLive.chooseApp(apps) }
        let options = FolderRuleInstallOptions(trashDiskImage: trashAfter, openAfterInstall: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = FolderRulesRunner(environment: environment).installManually(image, options: options)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishInstall(image, outcome: outcome) }
            }
        }
    }

    private func finishInstall(_ image: URL, outcome: FolderRuleRunOutcome) {
        installing = nil
        let record = FolderRuleRunRecord(ruleID: UUID(), ruleName: "Install Disk Image", folderID: UUID(),
                                         folderName: FolderRulesSafety.display(image.deletingLastPathComponent()),
                                         fileName: image.lastPathComponent, originalPath: image.path, outcome: outcome)
        var line = FolderRuleActivity(record, date: runner.environment.now())
        line.ruleID = nil
        activity.insert(line, at: 0)
        saveActivity()
        let summary = outcome.steps.last?.summary ?? ""
        let tone: AOMTone = outcome.failed ? .danger : (line.result == .skipped ? .warning : .success)
        message = FolderRulesMessage(text: outcome.failed ? "Couldn't install: \(summary)" : summary, tone: tone)
        FolderRulesNotifier.hud(title: outcome.failed ? "Install Failed" : (line.result == .skipped ? "Not Installed" : "App Installed"),
                                detail: summary)
        refreshStatus()
    }

    // MARK: Previews

    /// Sample state for isolated UI previews (`FolderRulesPreviewSamples`).
    func replaceForPreview(config: FolderRulesConfig, activity: [FolderRuleActivity]) {
        guard PresetManager.isUIPreview else { return }
        self.config = config
        self.activity = activity
        saveConfig(immediately: true)
        saveActivity()
        refreshStatus()
    }

    func addPreviewApproval(_ request: FolderRuleApprovalRequest) {
        guard PresetManager.isUIPreview else { return }
        addApprovals([request], now: runner.environment.now())
        refreshStatus()
    }

    // MARK: Saving

    private func saveConfig(immediately: Bool = false) {
        configSave?.cancel()
        configSave = nil
        if immediately { writeConfigNow(); return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.writeConfigNow() } }
        configSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func writeConfigNow() {
        configSave = nil
        let snapshot = config
        let store = self.store
        saveQueue.async { [weak self] in
            do {
                try store.save(snapshot)
            } catch {
                let text = "Couldn't save the rules: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.message = FolderRulesMessage(text: text, tone: .danger) }
                }
            }
        }
    }

    private func saveActivity() {
        let snapshot = activity
        let store = self.store
        saveQueue.async { try? store.save(activity: snapshot) }
    }

    /// Writes what is pending now (tests, and before quitting).
    func flushSaves() {
        if configSave != nil {
            configSave?.cancel()
            writeConfigNow()
        }
        saveQueue.sync {}
    }

    // MARK: Status

    /// Successful runs today.
    var filesToday: Int {
        let calendar = Calendar.current
        let now = runner.environment.now()
        return activity.filter { $0.result == .succeeded && calendar.isDate($0.date, inSameDayAs: now) }.count
    }

    /// Activity lines per day, newest day first.
    var activityByDay: [(day: Date, count: Int)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: activity.filter { $0.result == .succeeded }) { calendar.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.day > $1.day }
    }

    var waitingCount: Int { approvals.reduce(0) { $0 + $1.requests.count } }

    /// The one line Workspace shows when something needs the person.
    var attention: String? {
        if let denied = watchedFolders.first(where: { folderStates[$0.id] == .denied }) {
            return "Can't read \(denied.name). Allow All of MacOS in System Settings › Privacy & Security › Files and Folders."
        }
        if let missing = watchedFolders.first(where: { folderStates[$0.id] == .missing }) {
            return "\(missing.name) is missing."
        }
        if waitingCount > 0 { return waitingCount == 1 ? "1 action is waiting for your OK" : "\(waitingCount) actions are waiting for your OK" }
        if let stopped = stoppedRules.first, let rule = config.rules.first(where: { $0.id == stopped.key }) {
            return "Turned off “\(rule.name)”: possible loop"
        }
        if let setAside { return "rules.json couldn't be read and was kept as \(setAside.lastPathComponent)" }
        return nil
    }

    var statusDetail: String {
        if config.rules.isEmpty { return "No rules yet" }
        if !config.isEnabled {
            let ready = config.rules.count
            return "Off · \(ready) \(ready == 1 ? "rule" : "rules") set up"
        }
        if !gateIsOpen() { return "Paused with AOM" }
        if let installing { return "Installing \(installing)…" }
        let watched = watchedFolders.map(\.name)
        guard !watched.isEmpty else { return "No rules turned on" }
        let names = watched.count <= 2 ? watched.joined(separator: ", ") : "\(watched.count) folders"
        let today = filesToday
        return "Watching \(names) · \(today) \(today == 1 ? "file" : "files") today"
    }

    func refreshStatus() {
        guard publishesStatus else { return }
        let status = AOMModuleStatusBoard.folderRules
        if status.setOn == nil {
            status.setOn = { on in FolderRulesEngine.shared.setMasterEnabled(on) }
        }
        let count = activeRules.count
        status.isOn = config.isEnabled
        status.count = config.isEnabled ? count : nil
        status.unit = count == 1 ? "rule" : "rules"
        status.detail = statusDetail
        status.attention = attention
    }
}

/// Folder Rules' notifications: one per rule and pass, a HUD instead while
/// AOM is in front (design-3.4.0 #111, #112). Never in previews or tests.
enum FolderRulesNotifier {
    static var isQuiet: Bool { PresetManager.isRunningTests || PresetManager.isUIPreview }

    static func post(title: String, body: String) {
        guard !isQuiet else { return }
        if NSRunningApplication.current.isActive { hud(title: title, detail: body); return }
        // UNUserNotificationCenter needs a real app bundle; bare executables trap.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            hud(title: title, detail: body)
            return
        }
        let center = UNUserNotificationCenter.current()
        func send() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = "folder-rules"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if error != nil { DispatchQueue.main.async { hud(title: title, detail: body) } }
            }
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: send()
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { send() } else { DispatchQueue.main.async { hud(title: title, detail: body) } }
                }
            default:
                DispatchQueue.main.async { hud(title: title, detail: body) }
            }
        }
    }

    static func hud(title: String, detail: String) {
        guard !isQuiet else { return }
        GestureHUD.shared.show(title: title, detail: detail.isEmpty ? nil : detail)
    }
}
