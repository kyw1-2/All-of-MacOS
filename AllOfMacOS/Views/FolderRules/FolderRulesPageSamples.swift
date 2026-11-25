import Foundation

/// Read-only fixtures for CI. The page displays this configuration without
/// writing it through the engine or opening any actual folder.
enum FolderRulesPageSamples {
    static var enabled: Bool {
        PresetManager.isUIPreview && CommandLine.arguments.contains("--aom-preview-sample-data")
    }

    static let config: FolderRulesConfig = {
        let inbox = FolderRuleFolder(path: "/Sample Files/Inbox")
        let downloads = FolderRuleFolder(path: "/Sample Files/Downloads")
        return FolderRulesConfig(folders: [inbox, downloads], rules: [
            FolderRule(folderID: inbox.id, name: "File invoices",
                       conditions: [FolderRuleCondition(attribute: .name, values: ["invoice"])],
                       actions: [FolderRuleAction(kind: .move, folderPath: "/Sample Files/Invoices")]),
            FolderRule(folderID: inbox.id, name: "Tag reference PDFs",
                       conditions: [FolderRuleCondition(attribute: .fileExtension, values: ["pdf"])],
                       actions: [FolderRuleAction(kind: .addTags, tags: ["Reference"])]),
            FolderRule(folderID: downloads.id, name: "Collect archives",
                       conditions: [FolderRuleCondition(attribute: .fileExtension, values: ["zip"])],
                       actions: [FolderRuleAction(kind: .move, folderPath: "/Sample Files/Archives")])
        ])
    }()

    static func preview(_ rule: FolderRule) -> FolderRulePreview {
        guard let folder = config.folder(rule.folderID) else {
            return FolderRulePreview(ruleID: rule.id, folderState: .missing, items: [], inProgress: 0, scanned: 0)
        }
        let name = rule.folderID == config.folders.last?.id ? "Resources.zip" : "November invoice.pdf"
        let url = folder.url.appendingPathComponent(name)
        let file = FolderRuleFileInfo(url: url, name: name)
        let steps = FolderRulePlanDescriber.describe(rule, info: file, now: Date(), counter: 1)
        let item = FolderRulePreviewItem(id: url.path, info: file, state: .willRun,
                                         steps: steps, conditionResults: rule.conditions.map { _ in true })
        return FolderRulePreview(ruleID: rule.id, folderState: .ok(1), items: [item], inProgress: 0, scanned: 1)
    }
}
