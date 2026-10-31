import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The rule editor: rows that read like sentences ("If all of the following
/// are true · Kind is Screenshot", then "Move to Folder ~/Pictures ·
/// Screenshots/{year}-{month}"), the rule's switch in its header, and the
/// preview in place before it turns on.
struct FolderRulesRuleEditor: View {
    @ObservedObject var model: FolderRulesPageModel
    @ObservedObject var engine: FolderRulesEngine

    var body: some View {
        if let rule = model.draft {
            AOMPage(maxWidth: AOMSize.readableWidth) {
                AOMPageHeader(rule.name.isEmpty ? "Untitled rule" : rule.name, module: .folderRules,
                              subtitle: subtitle(rule), status: status(rule), active: savedEnabled(rule)) {
                    Toggle("Rule", isOn: Binding(get: { savedEnabled(rule) }, set: { model.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(savedEnabled(rule) ? "Turns this rule off" : "Shows what the rule would do, then turns it on")
                        .accessibilityLabel("Rule on")
                }
                if let preview = model.turnOnPreview, preview.ruleID == rule.id {
                    FolderRulesTurnOnPreview(model: model, preview: preview)
                }
                if model.hasUnappliedChanges {
                    AOMNotice(.info, "Changes take effect when you apply them",
                              detail: "The rule is on, so edits wait until you're done.") {
                        Button("Revert") { model.revertChanges() }
                        Button("Apply Changes") { model.applyChanges() }.aomPrimaryButton()
                    }
                }
                if let stopped = engine.stoppedRules[rule.id] {
                    AOMNotice(.warning, "Turned off to stop a loop", detail: "It \(stopped). Check its actions, then turn it on again.")
                }
                if !rule.problems.isEmpty {
                    AOMNotice(.warning, "This rule can't run yet", detail: rule.problems.joined(separator: " "))
                }
                conditions(rule)
                actions(rule)
                options(rule)
            }
        }
    }

    private func savedEnabled(_ rule: FolderRule) -> Bool { model.draftBase?.isEnabled ?? rule.isEnabled }

    private func subtitle(_ rule: FolderRule) -> String {
        let folder = engine.config.folder(rule.folderID)?.name ?? "No folder"
        return "In \(folder) · " + (rule.includeSubfolders ? "includes subfolders" : "top level only")
    }

    private func status(_ rule: FolderRule) -> AOMStatus? {
        if !rule.problems.isEmpty { return AOMStatus("Incomplete", tone: .warning) }
        if savedEnabled(rule) { return AOMStatus("On", tone: .success) }
        return nil
    }

    // MARK: Conditions

    private func conditions(_ rule: FolderRule) -> some View {
        AOMSection("Conditions", help: "Each item in the folder is tested against these. Names ignore upper and lower case; dates count back from now.") {
            AOMConditionGroupHeader(match: Binding(get: { AOMConditionMatch(rawValue: rule.match.rawValue) ?? .all },
                                                   set: { value in model.edit { $0.match = FolderRuleMatch(rawValue: value.rawValue) ?? .all } }))
            ForEach(rule.conditions) { condition in
                AOMConditionRow(canRemove: rule.conditions.count > 1,
                                add: { addCondition(after: condition.id) },
                                remove: { model.edit { $0.conditions.removeAll { $0.id == condition.id } } }) {
                    FolderRuleConditionSubject(condition: conditionBinding(condition.id, fallback: condition))
                } value: {
                    FolderRuleConditionValue(condition: conditionBinding(condition.id, fallback: condition))
                }
            }
            if rule.conditions.isEmpty {
                AOMInlineEmpty(symbol: "line.3.horizontal.decrease", message: "No conditions yet.",
                               actionTitle: "Add Condition") { addCondition(after: nil) }
            }
        }
    }

    private func conditionBinding(_ id: UUID, fallback: FolderRuleCondition) -> Binding<FolderRuleCondition> {
        Binding(get: { model.draft?.conditions.first { $0.id == id } ?? fallback },
                set: { value in
                    model.edit { rule in
                        if let index = rule.conditions.firstIndex(where: { $0.id == id }) { rule.conditions[index] = value }
                    }
                })
    }

    private func addCondition(after id: UUID?) {
        model.edit { rule in
            let condition = FolderRuleCondition(attribute: .name, values: [])
            if let id, let index = rule.conditions.firstIndex(where: { $0.id == id }) {
                rule.conditions.insert(condition, at: index + 1)
            } else {
                rule.conditions.append(condition)
            }
        }
    }

    // MARK: Actions

    private func actions(_ rule: FolderRule) -> some View {
        AOMSection("Actions", footer: "Actions run in order on the matching item. If one fails, the rest wait for the next check.") {
            Text("Do the following to the matching file or folder:")
                .font(AOMFont.body)
                .foregroundStyle(AOMColor.text)
                .padding(.horizontal, AOMSpace.rowInset)
                .frame(minHeight: AOMSize.rowStandard)
            ForEach(rule.actions) { action in
                AOMConditionRow(canRemove: rule.actions.count > 1, addLabel: "Add Action", removeLabel: "Remove Action",
                                add: { addAction(after: action.id) },
                                remove: { model.edit { $0.actions.removeAll { $0.id == action.id } } }) {
                    FolderRuleActionSubject(action: actionBinding(action.id, fallback: action))
                } value: {
                    FolderRuleActionValue(action: actionBinding(action.id, fallback: action))
                }
                .contextMenu {
                    Button("Move Up") { moveAction(action.id, by: -1) }
                    Button("Move Down") { moveAction(action.id, by: 1) }
                }
            }
            if rule.actions.isEmpty {
                AOMInlineEmpty(symbol: "bolt", message: "No actions yet.", actionTitle: "Add Action") { addAction(after: nil) }
            }
        }
    }

    private func actionBinding(_ id: UUID, fallback: FolderRuleAction) -> Binding<FolderRuleAction> {
        Binding(get: { model.draft?.actions.first { $0.id == id } ?? fallback },
                set: { value in
                    model.edit { rule in
                        if let index = rule.actions.firstIndex(where: { $0.id == id }) { rule.actions[index] = value }
                    }
                })
    }

    private func addAction(after id: UUID?) {
        model.edit { rule in
            let action = FolderRuleAction(kind: .addTags, tags: [])
            if let id, let index = rule.actions.firstIndex(where: { $0.id == id }) {
                rule.actions.insert(action, at: index + 1)
            } else {
                rule.actions.append(action)
            }
        }
    }

    private func moveAction(_ id: UUID, by offset: Int) {
        model.edit { rule in
            guard let index = rule.actions.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard rule.actions.indices.contains(target) else { return }
            rule.actions.swapAt(index, target)
        }
    }

    // MARK: Options

    private func options(_ rule: FolderRule) -> some View {
        AOMSection("Options") {
            AOMSettingRow("Name", showsDivider: false) {
                TextField("Rule name", text: model.binding(\.name, fallback: rule.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .accessibilityLabel("Rule name")
            }
            AOMToggleRow("Look inside subfolders", detail: "Also checks items in folders inside \(engine.config.folder(rule.folderID)?.name ?? "the folder"), never inside apps or other packages",
                         isOn: model.binding(\.includeSubfolders, fallback: rule.includeSubfolders))
            AOMToggleRow("Run without asking",
                         detail: "Moving to the Trash, optimizing, compressing and installing won't ask first. Replacing an installed app always asks.",
                         isOn: Binding(get: { model.draft?.runWithoutAsking ?? false },
                                       set: { value in
                                           model.edit { $0.runWithoutAsking = value }
                                           if model.draftBase?.isEnabled == true, var saved = model.draftBase {
                                               saved.runWithoutAsking = value
                                               engine.update(saved)
                                           }
                                       }))
            AOMSettingRow("Handled items", detail: "The rule leaves items it already handled alone, like Hazel. This lets it look at them again.") {
                Button("Check Them Again") {
                    engine.forgetHandledItems(of: rule.id)
                    model.toast.show("“\(rule.name)” will check every matching item again")
                    model.refreshPreview()
                }
            }
        }
    }
}

// MARK: - Turn on

/// The dry run shown in place before a rule turns on (design-3.4.0 #198).
struct FolderRulesTurnOnPreview: View {
    @ObservedObject var model: FolderRulesPageModel
    let preview: FolderRulePreview

    var body: some View {
        let ready = preview.willRun
        AOMSection("Before turning on", detail: ready.isEmpty ? nil : "\(ready.count) now",
                   footer: footer) {
            if let problem = preview.folderState.problem {
                AOMInlineEmpty(symbol: "exclamationmark.triangle", message: problem)
            } else if ready.isEmpty {
                AOMInlineEmpty(symbol: "checkmark.circle", message: "Nothing in the folder matches right now. New items are handled as they arrive.")
            } else {
                ForEach(ready.prefix(8)) { item in
                    FolderRulesPreviewRow(item: item)
                }
                if ready.count > 8 {
                    Text("and \(ready.count - 8) more")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .padding(.horizontal, AOMSpace.rowInset)
                        .padding(.vertical, AOMSpace.x2)
                }
            }
            HStack(spacing: AOMSpace.x2) {
                Spacer()
                Button("Cancel") { model.cancelTurnOn() }
                    .keyboardShortcut(.cancelAction)
                Button(ready.isEmpty ? "Turn On" : "Turn On and Run") { model.confirmTurnOn() }
                    .aomPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.folderState.problem != nil)
            }
            .padding(AOMSpace.rowInset)
            .overlay(alignment: .top) { AOMRowDivider() }
        }
    }

    private var footer: String {
        var parts: [String] = []
        if preview.inProgress > 0 {
            parts.append("\(preview.inProgress) unfinished \(preview.inProgress == 1 ? "download is" : "downloads are") left alone.")
        }
        let waiting = preview.items.filter { $0.state == .waiting }.count
        if waiting > 0 { parts.append("\(waiting) still changing, handled once \(waiting == 1 ? "it settles" : "they settle").") }
        let earlier = preview.items.filter { if case .earlierRule = $0.state { return true } else { return false } }.count
        if earlier > 0 { parts.append("\(earlier) go to an earlier rule.") }
        return parts.isEmpty ? "Turning it on approves these items; later ones that change or remove files still ask first." : parts.joined(separator: " ")
    }
}

/// One item of a preview: its icon and name, then what would happen.
struct FolderRulesPreviewRow: View {
    let item: FolderRulePreviewItem
    var showsDivider = true

    var body: some View {
        HStack(alignment: .top, spacing: AOMSpace.x2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.info.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: AOMIcon.row, height: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(spacing: AOMSpace.x1) {
                    Text(item.info.name)
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let state = stateText {
                        AOMStatusPill(state.text, tone: state.tone)
                    }
                }
                ForEach(Array(item.steps.enumerated()), id: \.offset) { _, step in
                    Text(step)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .overlay(alignment: .top) { if showsDivider { AOMRowDivider(inset: AOMSpace.rowSymbolInset) } }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.info.url]) }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateText: (text: String, tone: AOMTone)? {
        switch item.state {
        case .willRun: return nil
        case .waiting: return ("Still changing", .neutral)
        case .handled: return ("Already handled", .neutral)
        case .earlierRule(let name): return ("Goes to “\(name)”", .neutral)
        case .noMatch: return ("Doesn't match", .neutral)
        }
    }
}

// MARK: - Condition rows

struct FolderRuleConditionSubject: View {
    @Binding var condition: FolderRuleCondition

    var body: some View {
        HStack(spacing: AOMSpace.x1) {
            Picker("Attribute", selection: Binding(get: { condition.attribute }, set: { attribute in
                guard attribute != condition.attribute else { return }
                condition = FolderRuleCondition(id: condition.id, attribute: attribute,
                                                values: attribute == condition.attribute ? condition.values : [],
                                                kind: condition.kind, amount: condition.amount,
                                                timeUnit: condition.timeUnit, sizeUnit: condition.sizeUnit)
            })) {
                ForEach(FolderRuleAttribute.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("Attribute")
            Picker("Comparison", selection: $condition.comparison) {
                ForEach(condition.attribute.comparisons) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("Comparison")
        }
    }
}

struct FolderRuleConditionValue: View {
    @Binding var condition: FolderRuleCondition

    var body: some View {
        switch condition.attribute {
        case .name:
            if condition.comparison == .matchesRegex {
                TextField("Regular expression, such as invoice|receipt", text: $condition.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(AOMFont.mono)
                    .accessibilityLabel("Pattern")
            } else {
                AOMTokenField(tokens: $condition.values, placeholder: "Add a word")
            }
        case .fileExtension:
            AOMTokenField(tokens: $condition.values, placeholder: "Add an extension",
                          suggestions: ["dmg", "pkg", "zip", "pdf", "png", "jpg", "heic", "mov", "mp4", "docx", "hwp"],
                          normalize: { raw in
                              var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
                              while value.hasPrefix(".") { value.removeFirst() }
                              return value.isEmpty || value.contains("/") ? nil : value
                          })
        case .kind:
            Picker("Kind", selection: $condition.kind) {
                ForEach(FolderRuleKind.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .accessibilityLabel("Kind")
        case .dateAdded, .dateCreated, .dateModified, .dateLastOpened:
            HStack(spacing: AOMSpace.x1) {
                TextField("Amount", value: $condition.amount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("Amount")
                Picker("Unit", selection: $condition.timeUnit) {
                    ForEach(FolderRuleTimeUnit.allCases) { Text($0.title(condition.amount)).tag($0) }
                }
                .fixedSize()
                .accessibilityLabel("Unit")
                if condition.comparison == .olderThan {
                    Text("ago").font(AOMFont.body).foregroundStyle(AOMColor.text)
                }
            }
        case .size:
            HStack(spacing: AOMSpace.x1) {
                TextField("Size", value: $condition.amount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .accessibilityLabel("Size")
                Picker("Unit", selection: $condition.sizeUnit) {
                    ForEach(FolderRuleSizeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .accessibilityLabel("Unit")
            }
        case .downloadedFrom:
            AOMTokenField(tokens: $condition.values, placeholder: "Add a site, such as github.com",
                          normalize: { raw in
                              let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
                              if value.contains("://"), let host = URLComponents(string: value)?.host { return host }
                              return value.isEmpty ? nil : value
                          })
        case .tags:
            AOMTokenField(tokens: $condition.values, placeholder: "Add a tag")
        }
    }
}

// MARK: - Action rows

struct FolderRuleActionSubject: View {
    @Binding var action: FolderRuleAction

    var body: some View {
        Picker("Action", selection: Binding(get: { action.kind }, set: { kind in
            guard kind != action.kind else { return }
            action.kind = kind
            if (kind == .move || kind == .copy), action.folderPath.isEmpty {
                action.folderPath = FolderRulesLocations.documents.path
            }
            if kind == .rename, action.pattern.isEmpty { action.pattern = "{name}" }
        })) {
            ForEach(FolderRuleActionKind.allCases) { kind in
                Label(kind.title, systemImage: kind.symbol).tag(kind)
            }
        }
        .accessibilityLabel("Action")
    }
}

struct FolderRuleActionValue: View {
    @Binding var action: FolderRuleAction
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch action.kind {
        case .move, .copy:
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                FolderRulesChooseButton(path: action.folderPath, placeholder: "Choose Folder…", choosesApps: false) { url in
                    action.folderPath = url.path
                }
                HStack(spacing: AOMSpace.x1) {
                    TextField("Subfolders, such as {year}-{month}", text: $action.subfolderPattern)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Subfolders")
                    FolderRulesTokenMenu(tokens: ["{year}", "{month}", "{day}", "{kind}", "{ext}", "/"]) { action.subfolderPattern += $0 }
                }
            }
            .padding(.vertical, AOMSpace.x1)
        case .rename:
            HStack(spacing: AOMSpace.x1) {
                TextField("New name, such as {name} {date:yyyy-MM-dd}", text: $action.pattern)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name pattern")
                FolderRulesTokenMenu(tokens: ["{name}", "{ext}", "{date:yyyy-MM-dd}", "{counter}", "{counter:3}", "{kind}"]) {
                    action.pattern += $0
                }
            }
            .help("Without {ext} the file keeps its extension. {counter} counts up each time the rule renames a file.")
        case .addTags:
            AOMTokenField(tokens: $action.tags, placeholder: "Add a tag")
        case .setColorLabel:
            Picker("Color", selection: $action.colorLabel) {
                ForEach(FolderRuleColorLabel.allCases) { label in
                    Text(label.title).tag(label)
                }
            }
            .fixedSize()
            .accessibilityLabel("Color label")
        case .moveToTrash:
            note("The item goes to the Trash; Undo in the activity puts it back.")
        case .compress:
            Toggle("Then move the original to the Trash", isOn: $action.trashOriginal)
                .toggleStyle(.checkbox)
        case .extract:
            Toggle("Then move the archive to the Trash", isOn: $action.trashOriginal)
                .toggleStyle(.checkbox)
        case .optimizeImage:
            FolderRulesImageOptionsEditor(options: $action.image)
        case .installApp:
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Toggle("Then move the disk image to the Trash", isOn: $action.install.trashDiskImage)
                    .toggleStyle(.checkbox)
                Toggle("Open the app after installing", isOn: $action.install.openAfterInstall)
                    .toggleStyle(.checkbox)
                note("Asks before replacing an app that is already installed; the old copy goes to the Trash.")
            }
            .padding(.vertical, AOMSpace.x1)
        case .openWith:
            FolderRulesChooseButton(path: action.appPath, placeholder: "Default App", choosesApps: true,
                                    clear: { action.appPath = "" }) { url in action.appPath = url.path }
        case .notify:
            TextField("Text, such as {name} is ready", text: $action.message)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Notification text")
        case .runAutomation:
            automationPicker
        case .runShortcut:
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                TextField("Shortcut name", text: $action.shortcutName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Shortcut name")
                note("The Shortcuts app gets the file as its input.")
            }
            .padding(.vertical, AOMSpace.x1)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AOMFont.callout)
            .foregroundStyle(AOMColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var automations: [Trigger] {
        TriggerListQuery.sorted(appState.currentPreset.triggers, mode: .manual)
    }

    @ViewBuilder private var automationPicker: some View {
        let options = automations
        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
            Picker("Automation", selection: Binding(get: { action.automationID }, set: { id in
                action.automationID = id
                action.automationName = options.first { $0.id == id }?.displayName ?? ""
            })) {
                Text("Choose…").tag(UUID?.none)
                ForEach(options) { trigger in
                    Text(trigger.displayName).tag(UUID?.some(trigger.id))
                }
            }
            .fixedSize()
            .accessibilityLabel("Automation")
            note("It can read the file as {{var:\(FolderRulesLive.fileVariable)}} and {{var:\(FolderRulesLive.fileNameVariable)}}.")
        }
        .padding(.vertical, AOMSpace.x1)
    }
}

/// Optimize Image's settings.
struct FolderRulesImageOptionsEditor: View {
    @Binding var options: FolderRuleImageOptions

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: AOMSpace.x2, verticalSpacing: AOMSpace.x1) {
            GridRow {
                Text("Longest side").font(AOMFont.body)
                HStack(spacing: AOMSpace.x1) {
                    TextField("Pixels", value: $options.maxDimension, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .accessibilityLabel("Longest side in pixels")
                    Text("px (0 keeps the size)").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                }
            }
            GridRow {
                Text("Quality").font(AOMFont.body)
                HStack(spacing: AOMSpace.x1) {
                    Slider(value: $options.quality, in: 0.1...1, step: 0.05)
                        .frame(maxWidth: 180)
                        .accessibilityLabel("JPEG and HEIC quality")
                        .accessibilityValue("\(Int((options.clampedQuality * 100).rounded())) percent")
                    Text("\(Int((options.clampedQuality * 100).rounded()))%")
                        .font(AOMFont.body)
                        .monospacedDigit()
                }
            }
            GridRow {
                Text("PNG screenshots").font(AOMFont.body)
                Picker("PNG screenshots", selection: $options.screenshotOutput) {
                    ForEach(FolderRuleImageOptions.Output.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Original").font(AOMFont.body)
                Picker("Original", selection: $options.original) {
                    ForEach(FolderRuleImageOptions.Original.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Remove location", isOn: $options.stripLocation)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, AOMSpace.x1)
    }
}

/// A button that shows the chosen folder or app and opens a panel.
struct FolderRulesChooseButton: View {
    let path: String
    let placeholder: String
    let choosesApps: Bool
    var clear: (() -> Void)?
    let choose: (URL) -> Void

    var body: some View {
        HStack(spacing: AOMSpace.x1) {
            Button(action: openPanel) {
                HStack(spacing: AOMSpace.x1) {
                    if !path.isEmpty {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: AOMIcon.tileGlyph, height: AOMIcon.tileGlyph)
                            .accessibilityHidden(true)
                    }
                    Text(path.isEmpty ? placeholder : label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(path.isEmpty ? (choosesApps ? "Opens with the app macOS uses for it" : "Choose a folder") : path)
            .accessibilityLabel(choosesApps ? "App" : "Folder")
            .accessibilityValue(path.isEmpty ? placeholder : label)
            if let clear, !path.isEmpty {
                AOMIconButton("xmark.circle", label: "Use the Default App", action: clear)
            }
        }
    }

    private var label: String {
        let url = URL(fileURLWithPath: path)
        return choosesApps ? url.deletingPathExtension().lastPathComponent : FolderRulesSafety.display(url)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !choosesApps
        panel.canChooseFiles = choosesApps
        panel.canCreateDirectories = !choosesApps
        panel.allowsMultipleSelection = false
        if choosesApps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.prompt = "Choose App"
        } else {
            panel.prompt = "Choose Folder"
            if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            choose(url)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// A pull-down that inserts a pattern token.
struct FolderRulesTokenMenu: View {
    let tokens: [String]
    let insert: (String) -> Void

    var body: some View {
        Menu {
            ForEach(tokens, id: \.self) { token in
                Button(token == "/" ? "/ (a deeper folder)" : token) { insert(token) }
            }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a token")
        .accessibilityLabel("Insert a token")
    }
}
