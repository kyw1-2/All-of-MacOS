import AppKit
import SwiftUI

// MARK: - Inspector

/// The trailing inspector: the dry run for the selected rule, a test file
/// with ✓ and ✗ per condition, and the rule's history with Undo.
struct FolderRulesInspector: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine
    @State private var testTargeted = false

    var body: some View {
        AOMInspector {
            if let rule = model.draft {
                AOMInspectorSection("Preview", showsDivider: false) { preview(rule) }
                AOMInspectorSection("Test a File") { test(rule) }
                AOMInspectorSection("History") { history(rule) }
            } else {
                AOMInspectorSection("Preview", showsDivider: false) {
                    Text("Select a rule to see which items it would act on.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func preview(_ rule: FolderRule) -> some View {
        HStack {
            if model.previewLoading, model.preview == nil {
                Text("…").font(AOMFont.body).foregroundStyle(AOMColor.textSecondary)
            } else if let preview = model.preview {
                Text(previewSummary(preview))
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AOMSpace.x1)
            AOMIconButton("arrow.clockwise", label: "Refresh Preview") { model.refreshPreview() }
        }
        if let preview = model.preview {
            if let problem = preview.folderState.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.warningText)
            }
            ForEach(preview.items.prefix(20)) { item in
                FolderRulesPreviewRow(item: item, showsDivider: true)
                    .padding(.horizontal, -AOMSpace.rowInset)
            }
            if preview.items.count > 20 {
                Text("and \(preview.items.count - 20) more")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
            }
        }
    }

    private func previewSummary(_ preview: FolderRulePreview) -> String {
        FolderRulesText.previewSummary(preview)
    }

    @ViewBuilder private func test(_ rule: FolderRule) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Text(model.testFile?.lastPathComponent ?? "Drop a file here")
                    .font(AOMFont.callout)
                    .foregroundStyle(model.testFile == nil ? AOMColor.textSecondary : AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AOMSpace.x1)
                Button("Choose…") { model.chooseTestFile() }
            }
            .padding(AOMSpace.x2)
            .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .aomDropTarget(testTargeted, radius: AOMRadius.well)
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.first else { return false }
                model.test(file)
                return true
            } isTargeted: { testTargeted = $0 }
            if let result = model.testResult {
                ForEach(Array(rule.conditions.enumerated()), id: \.element.id) { index, condition in
                    let passed = result.conditionResults.indices.contains(index) && result.conditionResults[index]
                    Label {
                        Text(FolderRulesText.sentence(condition)).font(AOMFont.callout)
                    } icon: {
                        Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(passed ? AOMColor.success : AOMColor.danger)
                    }
                    .accessibilityLabel("\(FolderRulesText.sentence(condition)): \(passed ? "matches" : "doesn't match")")
                }
                Text(result.state == .noMatch ? "The rule wouldn't act on this item." : "The rule would:")
                    .font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMColor.text)
                ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                    Text(step).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func history(_ rule: FolderRule) -> some View {
        let entries = Array(engine.activity.filter { $0.ruleID == rule.id }.prefix(8))
        if entries.isEmpty {
            Text("This rule hasn't acted on anything yet.")
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    FolderRulesActivityRow(model: model, activity: entry, showsDivider: index > 0, compact: true)
                        .padding(.horizontal, -AOMSpace.rowInset)
                }
            }
        }
    }
}

// MARK: - Activity

/// Every rule's activity, grouped by day with a count per day.
struct FolderRulesActivityView: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader("Activity", subtitle: "\(engine.filesToday) \(engine.filesToday == 1 ? "file" : "files") handled today",
                          active: engine.config.isEnabled) {
                if !engine.activity.isEmpty {
                    Button("Clear") { model.clearActivity(undoManager: undoManager) }
                        .help("Clears the activity list; files stay where they are, and Undo brings the list back")
                }
            }
            if engine.activity.isEmpty {
                AOMSection {
                    AOMInlineEmpty(symbol: "clock.arrow.circlepath", message: "Nothing has happened yet. Turn on a rule to start.")
                }
            }
            ForEach(days, id: \.day) { group in
                FolderRulesActivitySection(model: model, title: title(for: group.day),
                                           detail: FolderRulesText.dayCount(group.entries), entries: group.entries, limit: 12)
            }
        }
    }

    private var days: [(day: Date, entries: [FolderRuleActivity])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: engine.activity) { calendar.startOfDay(for: $0.date) }
        return grouped.map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }.sorted { $0.day > $1.day }
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A titled card of activity rows, newest first, with Show All.
struct FolderRulesActivitySection: View {
    @ObservedObject var model: FolderRulesPageModel
    let title: String
    var detail: String?
    let entries: [FolderRuleActivity]
    var limit = 6
    var emptyMessage = "Nothing has happened yet."
    @State private var showsAll = false

    var body: some View {
        let visible = showsAll ? entries : Array(entries.prefix(limit))
        AOMSection(title, detail: detail) {
            if entries.count > limit {
                AOMCardLink(showsAll ? "Show Less" : "Show All", symbol: showsAll ? "chevron.up" : "chevron.down") {
                    withAnimation(AOMMotion.standard) { showsAll.toggle() }
                }
            }
        } content: {
            if entries.isEmpty {
                AOMInlineEmpty(symbol: "clock.arrow.circlepath", message: emptyMessage)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                    FolderRulesActivityRow(model: model, activity: entry, showsDivider: index > 0)
                }
            }
        }
    }
}

/// One activity line: the result glyph, the file, the rule and what it did,
/// the time and Undo. The time and buttons keep their size; the text wraps.
struct FolderRulesActivityRow: View {
    @ObservedObject var model: FolderRulesPageModel
    let activity: FolderRuleActivity
    var showsDivider = true
    /// The inspector's narrower rows: no rule name, shorter text.
    var compact = false

    var body: some View {
        let entry = FolderRulesPageModel.logEntry(activity)
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Image(systemName: entry.tone.symbol)
                .imageScale(.small)
                .foregroundStyle(entry.tone.color)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(compact ? AOMFont.callout : AOMFont.body)
                    .foregroundStyle(activity.undone ? AOMColor.textSecondary : AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(compact || activity.ruleName.isEmpty ? detail : "\(activity.ruleName) · \(detail)")
                        .font(compact ? AOMFont.caption : AOMFont.callout)
                        .foregroundStyle(entry.tone == .danger ? AOMColor.dangerText : AOMColor.textSecondary)
                        .lineLimit(compact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AOMRelativeTime.string(activity.date, now: context.date))
                    .font(AOMFont.timestamp)
                    .foregroundStyle(AOMColor.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(activity.date.formatted(date: .abbreviated, time: .standard))
            }
            FolderRulesActivityActions(model: model, activity: activity)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
        .frame(minHeight: AOMSize.logRow)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) } }
        .contextMenu {
            if activity.canUndo { Button("Undo") { model.undo(activity) } }
            if let path = activity.finalPath, FolderRulesSafety.exists(path) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString([activity.fileName, activity.ruleName, activity.detail].filter { !$0.isEmpty }
                    .joined(separator: " — "), forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Undo and Show in Finder for one activity line.
struct FolderRulesActivityActions: View {
    @ObservedObject var model: FolderRulesPageModel
    let activity: FolderRuleActivity

    var body: some View {
        HStack(spacing: AOMSpace.x1) {
            if activity.canUndo {
                Button("Undo") { model.undo(activity) }
                    .help("Puts “\(activity.fileName)” back where it was")
            }
            if let path = activity.finalPath, FolderRulesSafety.exists(path) {
                AOMIconButton("magnifyingglass", label: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }
}

// MARK: - Folder

/// A watched folder: where it is, whether AOM can read it, its rules, the
/// templates, and its activity.
struct FolderRulesFolderView: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine
    let folder: FolderRuleFolder
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let rules = engine.config.rules(in: folder.id)
        AOMPage(maxWidth: AOMSize.readableWidth) {
            AOMPageHeader(folder.name, subtitle: FolderRulesSafety.display(folder.url),
                          status: state, active: engine.config.isEnabled && rules.contains(where: \.isEnabled)) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
            }
            AOMSection("Rules", detail: rules.isEmpty ? nil : "\(rules.filter(\.isEnabled).count) of \(rules.count) on",
                       footer: "Each item goes to the first rule that matches it, top to bottom.") {
                if rules.isEmpty {
                    AOMInlineEmpty(symbol: "folder.badge.gearshape", message: "No rules for \(folder.name) yet.",
                                   actionTitle: "New Rule") {
                        let rule = engine.newRule(in: folder.id)
                        model.selection = .rule(rule.id)
                    }
                } else {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        AOMSettingRow(rule.name.isEmpty ? "Untitled rule" : rule.name, detail: FolderRulesText.summary(rule),
                                      showsDivider: index > 0) {
                            HStack(spacing: AOMSpace.x2) {
                                Button("Edit") { model.selection = .rule(rule.id) }
                                Toggle(rule.name, isOn: Binding(get: { rule.isEnabled }, set: { on in
                                    if on {
                                        model.selection = .rule(rule.id)
                                        model.setEnabled(true)
                                    } else {
                                        engine.setRule(rule.id, enabled: false)
                                    }
                                }))
                                .help(rule.isEnabled ? "Turns the rule off" : "Shows its preview, then turns it on")
                            }
                        }
                    }
                }
            }
            AOMSection("Templates", footer: "A template is added off. Check its preview, then turn it on.") {
                ForEach(Array(FolderRuleTemplates.all.enumerated()), id: \.element.id) { index, template in
                    AOMSettingRow(template.title, detail: template.detail, symbol: template.symbol, showsDivider: index > 0) {
                        Button("Add") { model.add(template) }
                            .help("Adds “\(template.title)” for \(FolderRulesSafety.display(template.folderURL)), switched off")
                    }
                }
            }
            FolderRulesActivitySection(model: model, title: "Activity",
                                       detail: FolderRulesText.dayCount(engine.activity.filter { $0.folderName == folder.name }),
                                       entries: engine.activity.filter { $0.folderName == folder.name },
                                       emptyMessage: "Nothing has happened in \(folder.name) yet.")
            AOMSection {
                AOMSettingRow("Stop watching \(folder.name)", detail: "Removes the folder and its rules from Folder Rules. Its files stay as they are.",
                              showsDivider: false) {
                    Button("Stop Watching…", role: .destructive) { model.removeFolder(folder.id, undoManager: undoManager) }
                }
            }
        }
    }

    private var state: AOMStatus? {
        switch engine.folderStates[folder.id] {
        case .denied: return AOMStatus("No access", tone: .warning)
        case .missing: return AOMStatus("Missing", tone: .warning)
        case .unreadable: return AOMStatus("Can't read", tone: .warning)
        case .ok(let items): return AOMStatus("\(items) \(items == 1 ? "item" : "items")", tone: .neutral)
        case nil: return nil
        }
    }
}
