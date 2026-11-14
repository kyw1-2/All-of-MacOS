import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Folder Rules page's state: what is selected, the rule being edited,
/// its preview, and the page's toasts. Edits to a rule that is off save as
/// you type; edits to a rule that is on wait for Apply Changes, so a half
/// typed condition never moves files.
@MainActor
final class FolderRulesPageModel: ObservableObject {
    enum Selection: Hashable {
        case activity
        case folder(UUID)
        case rule(UUID)
    }

    @Published var selection: Selection? { didSet { if selection != oldValue { selectionChanged() } } }
    /// The rule in the editor.
    @Published var draft: FolderRule?
    /// The engine's version of `draft` when it was loaded.
    private(set) var draftBase: FolderRule?
    @Published var preview: FolderRulePreview?
    @Published var previewLoading = false
    /// The preview shown in place before a rule is turned on.
    @Published var turnOnPreview: FolderRulePreview?
    /// The preview in the detail, for windows too narrow for the inspector.
    @Published var showsInlinePreview = false
    @Published var testResult: FolderRulePreviewItem?
    @Published var testFile: URL?
    let toast = AOMToastModel()
    let engine: FolderRulesEngine

    private var cancellables: Set<AnyCancellable> = []
    private var commitWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?

    init(engine: FolderRulesEngine) {
        self.engine = engine
        engine.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.configChanged() } }
            .store(in: &cancellables)
        engine.$message
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in MainActor.assumeIsolated { self?.toast.show(message.text, tone: message.tone) } }
            .store(in: &cancellables)
    }

    // MARK: Lookups

    var config: FolderRulesConfig { engine.config }

    func rules(in folder: UUID) -> [FolderRule] { config.rules(in: folder) }

    var selectedRule: FolderRule? {
        guard case .rule(let id) = selection else { return nil }
        return config.rules.first { $0.id == id }
    }

    var selectedFolder: FolderRuleFolder? {
        switch selection {
        case .folder(let id): return config.folder(id)
        case .rule: return selectedRule.flatMap { config.folder($0.folderID) }
        default: return nil
        }
    }

    /// The folder new rules go into: the selected one, else the first.
    var targetFolder: FolderRuleFolder? { selectedFolder ?? config.folders.first }

    /// The draft differs from the saved rule (only kept for rules that are on).
    var hasUnappliedChanges: Bool { draft != nil && draft != draftBase }

    // MARK: Selection and drafts

    func selectDefault() {
        guard selection == nil else { return }
        if let first = config.rules.first { selection = .rule(first.id) } else if let folder = config.folders.first { selection = .folder(folder.id) }
    }

    private func selectionChanged() {
        flushCommit()
        loadDraft()
        turnOnPreview = nil
        testResult = nil
        testFile = nil
        preview = nil
        refreshPreview()
    }

    private func loadDraft() {
        draft = selectedRule
        draftBase = draft
    }

    private func configChanged() {
        guard case .rule = selection else { return }
        guard let saved = selectedRule else {
            draft = nil
            draftBase = nil
            return
        }
        // Keep the person's unapplied edits; otherwise follow the saved rule
        // (the list's switch, the loop guard, Always Allow).
        if draft == draftBase || draft == nil {
            draft = saved
            draftBase = saved
        } else {
            draftBase = saved
            draft?.isEnabled = saved.isEnabled
            draft?.runWithoutAsking = saved.runWithoutAsking
        }
    }

    /// Changes the draft. A rule that is off saves shortly after; one that is
    /// on waits for Apply Changes.
    func edit(_ change: (inout FolderRule) -> Void) {
        guard var rule = draft else { return }
        change(&rule)
        guard rule != draft else { return }
        draft = rule
        if draftBase?.isEnabled != true { scheduleCommit() }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<FolderRule, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { [weak self] in self?.draft?[keyPath: keyPath] ?? fallback },
                set: { [weak self] value in self?.edit { $0[keyPath: keyPath] = value } })
    }

    private func scheduleCommit() {
        commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.commitDraft() } }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushCommit() {
        guard let work = commitWork else { return }
        work.cancel()
        commitWork = nil
        commitDraft()
    }

    private func commitDraft() {
        commitWork = nil
        guard let rule = draft, rule != draftBase, draftBase?.isEnabled != true else { return }
        draftBase = rule
        engine.update(rule)
        refreshPreview()
    }

    func applyChanges() {
        guard let rule = draft else { return }
        if !rule.problems.isEmpty {
            toast.show("Fix the rule first: \(rule.problems[0])", tone: .danger)
            return
        }
        draftBase = rule
        engine.update(rule)
        toast.show("Changes applied")
        refreshPreview()
    }

    func revertChanges() {
        loadDraft()
        refreshPreview()
    }

    // MARK: On and off

    /// The rule's switch: on shows the preview in place first.
    func setEnabled(_ on: Bool) {
        guard let rule = draft else { return }
        if !on {
            turnOnPreview = nil
            engine.setRule(rule.id, enabled: false)
            return
        }
        if let problem = rule.problems.first {
            toast.show("Can't turn it on yet: \(problem)", tone: .danger)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.preview(rule)
            if draft?.id == rule.id { turnOnPreview = result }
        }
    }

    /// Turn On after the preview: the listed items run without asking again.
    func confirmTurnOn() {
        guard let rule = draft, let shown = turnOnPreview, shown.ruleID == rule.id else { return }
        if rule != draftBase {
            draftBase = rule
            engine.update(rule)
        }
        let keys = Set(shown.willRun.map(\.id))
        engine.setRule(rule.id, enabled: true, approving: keys)
        turnOnPreview = nil
        let count = shown.willRun.count
        toast.show(count == 0 ? "“\(rule.name)” is on" : "“\(rule.name)” is on and handles \(count) \(count == 1 ? "item" : "items") now")
    }

    func cancelTurnOn() { turnOnPreview = nil }

    // MARK: Preview and test

    func refreshPreview() {
        previewTask?.cancel()
        guard let rule = draft else { preview = nil; return }
        previewLoading = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            let result = await engine.preview(rule)
            guard !Task.isCancelled, draft?.id == rule.id else { return }
            preview = result
            previewLoading = false
        }
    }

    func test(_ file: URL) {
        guard let rule = draft else { return }
        testFile = file
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.test(rule, file: file)
            guard draft?.id == rule.id else { return }
            testResult = result
            if result == nil { toast.show("“\(file.lastPathComponent)” can't be tested: rules skip hidden items and links.", tone: .warning) }
        }
    }

    func chooseTestFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Test"
        panel.directoryURL = selectedFolder?.url
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.test(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    // MARK: Adding and removing

    func newRule() {
        guard let folder = targetFolder else { addFolder(); return }
        let rule = engine.newRule(in: folder.id)
        selection = .rule(rule.id)
    }

    func add(_ template: FolderRuleTemplate) {
        guard let rule = engine.add(template) else { return }
        selection = .rule(rule.id)
        toast.show("Added “\(template.title)”. It stays off until you turn it on.")
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        panel.message = "Choose a folder for Folder Rules to watch."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.addFolder(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    func addFolder(_ url: URL) {
        switch engine.addFolder(url) {
        case .success(let folder): selection = .folder(folder.id)
        case .failure(let failure): toast.show("Couldn't add “\(url.lastPathComponent)”: \(failure.message)", tone: .danger)
        }
    }

    /// Clears the activity list; Edit › Undo and the toast's Undo bring it back.
    func clearActivity(undoManager: UndoManager?) {
        var removed: [FolderRuleActivity] = []
        AOMUndo.perform("Clear Activity", undoManager: undoManager, perform: { [weak self] in
            removed = self?.engine.clearActivity() ?? []
        }, revert: { [weak self] in
            self?.engine.restoreActivity(removed)
        })
        toast.show("Activity cleared", tone: .neutral, actionTitle: "Undo") { [weak self] in
            self?.engine.restoreActivity(removed)
        }
    }

    func deleteRule(_ id: UUID, undoManager: UndoManager?) {
        guard let rule = config.rules.first(where: { $0.id == id }) else { return }
        var removed: (rule: FolderRule, index: Int)?
        AOMUndo.perform("Delete Rule", undoManager: undoManager, perform: { [weak self] in
            removed = self?.engine.delete(id)
            if self?.selection == .rule(id) { self?.selection = .folder(rule.folderID) }
        }, revert: { [weak self] in
            if let removed { self?.engine.restore(removed.rule, at: removed.index) }
            self?.selection = .rule(id)
        })
        toast.show("Deleted “\(rule.name)”", actionTitle: "Undo") { [weak self] in
            if let removed { self?.engine.restore(removed.rule, at: removed.index) }
            self?.selection = .rule(id)
        }
    }

    func removeFolder(_ id: UUID, undoManager: UndoManager?) {
        guard let folder = config.folder(id) else { return }
        var removed: (folder: FolderRuleFolder, index: Int, rules: [FolderRule])?
        let restore: () -> Void = { [weak self] in
            if let removed { self?.engine.restoreFolder(removed.folder, at: removed.index, rules: removed.rules) }
            self?.selection = .folder(id)
        }
        AOMUndo.perform("Remove Folder", undoManager: undoManager, perform: { [weak self] in
            removed = self?.engine.removeFolder(id)
            if self?.selectedFolder?.id == id || self?.selection == .folder(id) { self?.selection = nil }
        }, revert: restore)
        let count = removed?.rules.count ?? 0
        toast.show("Stopped watching \(folder.name)" + (count > 0 ? " and removed \(count) \(count == 1 ? "rule" : "rules")" : ""),
                   actionTitle: "Undo", action: restore)
    }

    func removeSelection(undoManager: UndoManager?) {
        switch selection {
        case .rule(let id): deleteRule(id, undoManager: undoManager)
        case .folder(let id): removeFolder(id, undoManager: undoManager)
        default: break
        }
    }

    func duplicateSelectedRule() {
        guard case .rule(let id) = selection, let copy = engine.duplicate(id) else { return }
        selection = .rule(copy.id)
    }

    func moveSelectedRule(by offset: Int) {
        guard case .rule(let id) = selection else { return }
        engine.move(id, by: offset)
    }

    // MARK: Activity

    func undo(_ entry: FolderRuleActivity) {
        engine.undo(entry.id)
    }

    static func logEntry(_ activity: FolderRuleActivity) -> AOMLogEntry {
        let tone: AOMTone
        switch activity.result {
        case .succeeded: tone = activity.undone ? .neutral : .success
        case .skipped: tone = .neutral
        case .failed: tone = .danger
        case .info: tone = .info
        }
        let title = activity.fileName.isEmpty ? activity.ruleName : activity.fileName
        let detail = activity.undone ? "Undone · " + activity.detail : activity.detail
        return AOMLogEntry(id: activity.id, date: activity.date, tone: tone, message: title, detail: detail,
                           source: activity.fileName.isEmpty ? nil : activity.ruleName)
    }
}
