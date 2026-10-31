import AppKit
import SwiftUI

/// Folder Rules (3.4.0, design-3.4.0 b.2 list + detail + inspector): the
/// watched folders on the left with each folder's rules under it, the rule
/// editor in the middle, and the preview, a test file and the rule's history
/// in the inspector. The module's master switch sits in the page header.
struct FolderRulesPage: View {
    @StateObject private var model = FolderRulesPageModel(engine: FolderRulesEngine.shared)
    @ObservedObject private var engine = FolderRulesEngine.shared
    @AppStorage("AOMFolderRulesListWidth") private var listWidth = AOMSize.moduleListIdeal
    @AppStorage("AOMFolderRulesInspector") private var showsInspector = true
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                FolderRulesHeader(engine: engine)
                FolderRulesNotices(model: model, engine: engine)
            }
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.vertical, AOMSpace.x3)
            AOMDivider()
            AOMListDetail(listWidth: $listWidth, showsInspector: $showsInspector) {
                FolderRulesListColumn(model: model, engine: engine)
            } detail: {
                FolderRulesDetail(model: model, engine: engine)
            } inspector: {
                FolderRulesInspector(model: model, engine: engine)
            }
        }
        .background(AOMColor.canvas)
        .aomPage("Folder Rules")
        .aomToolbarSubtitle(engine.statusDetail)
        .toolbar { toolbarContent }
        .aomToast(model.toast)
        .onDeleteCommand { model.removeSelection(undoManager: undoManager) }
        .task {
            FolderRulesPreviewSamples.prepare(engine: engine, model: model)
            model.selectDefault()
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Blank Rule") { model.newRule() }
                Section("Templates") {
                    ForEach(FolderRuleTemplates.all) { template in
                        Button(template.title) { model.add(template) }
                    }
                }
                Divider()
                Button("Add Folder…") { model.addFolder() }
                Button("Install Disk Image…") { FolderRulesModule.installDiskImage() }
            } label: {
                Label("New Rule", systemImage: "plus")
            } primaryAction: {
                model.newRule()
            }
            .help("New Rule in the selected folder; the menu adds a template or a folder")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                withAnimation(AOMMotion.panel) { showsInspector.toggle() }
            } label: {
                Label(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(showsInspector ? "Hide the preview and history (⌥⌘I)" : "Show the preview and history (⌥⌘I)")
        }
    }
}

/// "Folder Rules is on", the status line, Run Now and the master switch.
struct FolderRulesHeader: View {
    @ObservedObject var engine: FolderRulesEngine

    var body: some View {
        let on = engine.config.isEnabled
        AOMPageHeader(on ? "Folder Rules is on" : "Folder Rules is off", module: .folderRules,
                      subtitle: engine.statusDetail, status: status,
                      help: "Folder Rules watches the folders on the left. Each new or changed item goes to the first rule that matches it, and that rule's actions run in order. Moves, renames and the Trash can be undone from the activity.",
                      active: on) {
            Button("Run Now") { engine.runNow() }
                .disabled(!engine.isActive)
                .help("Checks the watched folders now")
            Toggle("Folder Rules", isOn: Binding(get: { engine.config.isEnabled }, set: { engine.setMasterEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(on ? "Turns Folder Rules off" : "Turns Folder Rules on")
                .accessibilityLabel("Folder Rules")
        }
    }

    private var status: AOMStatus? {
        if engine.isRunning { return AOMStatus("Working", tone: .info, symbol: "arrow.triangle.2.circlepath") }
        if engine.config.isEnabled, !engine.gateIsOpen() { return AOMStatus("Paused with AOM", tone: .neutral, symbol: "pause.circle") }
        if engine.waitingCount > 0 { return AOMStatus("\(engine.waitingCount) waiting", tone: .warning) }
        return nil
    }
}

/// What needs the person: approvals, folder access, a rule turned off by the
/// loop guard, an unreadable rules file.
struct FolderRulesNotices: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine

    var body: some View {
        ForEach(engine.approvals) { approval in
            AOMNotice(.info, approval.question, detail: approvalDetail(approval)) {
                Button("Skip") { engine.skip(approval.id) }
                    .help("Leaves these items alone; the rule won't ask about them again")
                Button(approval.verb) { engine.approve(approval.id) }
                    .aomPrimaryButton()
                    .help("Runs the rule on these items now")
            }
            .contextMenu {
                Button("Always Allow for This Rule") { engine.approve(approval.id, alwaysAllow: true) }
                Button("Show Rule") { model.selection = .rule(approval.ruleID) }
            }
        }
        ForEach(deniedFolders) { folder in
            AOMNotice(.warning, "macOS doesn't let All of MacOS read \(folder.name)",
                      detail: "Allow it in System Settings › Privacy & Security › Files and Folders, then choose Run Now.") {
                Button("Open Privacy Settings") { FolderRulesPrivacy.openFilesAndFolders() }
            }
        }
        if let setAside = engine.setAside {
            AOMNotice(.warning, "The rules file couldn't be read",
                      detail: "It was kept as \(setAside.lastPathComponent) in \(FolderRulesSafety.display(setAside.deletingLastPathComponent())), and Folder Rules started fresh.") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([setAside]) }
            }
        }
    }

    private var deniedFolders: [FolderRuleFolder] {
        engine.config.folders.filter { engine.folderStates[$0.id] == .denied }
    }

    private func approvalDetail(_ approval: FolderRuleApproval) -> String {
        let names = approval.requests.map(\.info.name)
        let listed = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        return "“\(approval.ruleName)” in \(approval.folderName)" + (names.count > 1 ? ": \(listed)" : "")
    }
}

enum FolderRulesPrivacy {
    static func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - List column

/// Activity, then each folder with its rules indented under it (Hazel's
/// folders and rules in one list), and the + − ⋯ bar.
struct FolderRulesListColumn: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        AOMListColumn(rows: {
            List(selection: $model.selection) {
                AOMListRow("Activity", detail: activityDetail) {
                    Image(systemName: "clock.arrow.circlepath").imageScale(.medium)
                }
                .tag(FolderRulesPageModel.Selection.activity)
                Section("Folders") {
                    ForEach(engine.config.folders) { folder in
                        folderRow(folder)
                            .tag(FolderRulesPageModel.Selection.folder(folder.id))
                        ForEach(engine.config.rules(in: folder.id)) { rule in
                            ruleRow(rule)
                                .tag(FolderRulesPageModel.Selection.rule(rule.id))
                        }
                    }
                    Button {
                        model.addFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                            .font(AOMFont.body)
                            .foregroundStyle(AOMColor.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, AOMSpace.x1)
                    .help("Choose another folder to watch")
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                for folder in folders { model.addFolder(folder) }
                return !folders.isEmpty
            }
        }, footer: {
            AOMAddRemoveBar(addLabel: "New Rule", add: { model.newRule() }, removeLabel: removeLabel,
                            remove: canRemove ? { model.removeSelection(undoManager: undoManager) } : nil) {
                Button("Add Folder…") { model.addFolder() }
                Menu("Add Template") {
                    ForEach(FolderRuleTemplates.all) { template in
                        Button(template.title) { model.add(template) }
                    }
                }
                Divider()
                Button("Duplicate Rule") { model.duplicateSelectedRule() }.disabled(!isRuleSelected)
                Button("Move Rule Up") { model.moveSelectedRule(by: -1) }.disabled(!isRuleSelected)
                Button("Move Rule Down") { model.moveSelectedRule(by: 1) }.disabled(!isRuleSelected)
            }
        })
    }

    private var isRuleSelected: Bool {
        if case .rule = model.selection { return true }
        return false
    }

    private var canRemove: Bool {
        switch model.selection {
        case .rule, .folder: return true
        default: return false
        }
    }

    private var removeLabel: String {
        if case .folder = model.selection { return "Stop Watching Folder" }
        return "Delete Rule"
    }

    private var activityDetail: String {
        let today = engine.filesToday
        return today == 0 ? "Nothing today" : "\(today) \(today == 1 ? "file" : "files") today"
    }

    private func folderRow(_ folder: FolderRuleFolder) -> some View {
        let rules = engine.config.rules(in: folder.id)
        let on = rules.filter(\.isEnabled).count
        let problem = engine.folderStates[folder.id]?.problem
        let detail = problem ?? (rules.isEmpty ? "No rules" : "\(rules.count) \(rules.count == 1 ? "rule" : "rules") · \(on) on")
        return AOMListRow(folder.name, detail: detail) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } trailing: {
            if problem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AOMColor.warning)
                    .help(problem ?? "")
                    .accessibilityLabel("Needs attention")
            }
        }
        .help(FolderRulesSafety.display(folder.url))
        .contextMenu {
            Button("New Rule") {
                let rule = engine.newRule(in: folder.id)
                model.selection = .rule(rule.id)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.path, forType: .string)
            }
            Divider()
            Button("Stop Watching Folder", role: .destructive) { model.removeFolder(folder.id, undoManager: undoManager) }
        }
    }

    private func ruleRow(_ rule: FolderRule) -> some View {
        AOMListRow(rule.name.isEmpty ? "Untitled rule" : rule.name, detail: FolderRulesText.summary(rule), dimmed: !rule.isEnabled) {
            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(rule.isEnabled ? AOMColor.success : AOMColor.textTertiary)
        } trailing: {
            if !rule.problems.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AOMColor.warning)
                    .help(rule.problems.joined(separator: " "))
                    .accessibilityLabel("Incomplete")
            }
        }
        .padding(.leading, AOMSpace.x4)
        .accessibilityValue(rule.isEnabled ? "On" : "Off")
        .contextMenu {
            if rule.isEnabled {
                Button("Turn Off") { engine.setRule(rule.id, enabled: false) }
            } else {
                Button("Turn On…") {
                    model.selection = .rule(rule.id)
                    model.setEnabled(true)
                }
            }
            Button("Duplicate") {
                if let copy = engine.duplicate(rule.id) { model.selection = .rule(copy.id) }
            }
            Button("Move Up") { engine.move(rule.id, by: -1) }
            Button("Move Down") { engine.move(rule.id, by: 1) }
            Divider()
            Button("Delete Rule", role: .destructive) { model.deleteRule(rule.id, undoManager: undoManager) }
        }
    }
}

// MARK: - Detail

struct FolderRulesDetail: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine

    var body: some View {
        switch model.selection {
        case .activity:
            FolderRulesActivityView(model: model, engine: engine)
        case .folder(let id):
            if let folder = engine.config.folder(id) {
                FolderRulesFolderView(model: model, engine: engine, folder: folder)
            } else {
                empty
            }
        case .rule:
            if model.draft != nil { FolderRulesRuleEditor(model: model, engine: engine) } else { empty }
        case nil:
            empty
        }
    }

    @ViewBuilder private var empty: some View {
        if engine.config.folders.isEmpty {
            AOMEmptyState("No folders", systemImage: "folder.badge.plus",
                          message: "Add a folder for Folder Rules to watch, such as Downloads.") {
                Button("Add Folder…") { model.addFolder() }.aomPrimaryButton()
            }
        } else {
            AOMEmptyState("No rule selected", systemImage: "folder.badge.gearshape",
                          message: "Choose a folder or a rule on the left, or start with a template.") {
                Button("New Rule") { model.newRule() }.aomPrimaryButton()
            }
        }
    }
}

/// Short sentences for rules, conditions and actions.
enum FolderRulesText {
    static func summary(_ rule: FolderRule) -> String {
        let condition = rule.conditions.first.map(sentence) ?? "No conditions"
        let more = rule.conditions.count > 1 ? " +\(rule.conditions.count - 1)" : ""
        let action = rule.actions.first.map { $0.kind.title } ?? "No actions"
        return "\(condition)\(more) → \(action)"
    }

    static func sentence(_ condition: FolderRuleCondition) -> String {
        let subject = condition.attribute.title
        let verb = condition.comparison.title
        switch condition.attribute {
        case .kind:
            return "\(subject) \(verb) \(condition.kind.title)"
        case .dateAdded, .dateCreated, .dateModified, .dateLastOpened:
            let amount = condition.amount.formatted()
            let unit = condition.timeUnit.title(condition.amount)
            return condition.comparison == .olderThan ? "\(subject) \(verb) \(amount) \(unit) ago" : "\(subject) \(verb) \(amount) \(unit)"
        case .size:
            return "\(subject) \(verb) \(condition.amount.formatted()) \(condition.sizeUnit.rawValue)"
        case .name where condition.comparison == .matchesRegex:
            return "\(subject) \(verb) \(condition.pattern)"
        default:
            let values = condition.cleanValues
            let list = values.isEmpty ? "…" : values.map { "“\($0)”" }.joined(separator: values.count > 2 ? ", " : " or ")
            return "\(subject) \(verb) \(list)"
        }
    }
}
