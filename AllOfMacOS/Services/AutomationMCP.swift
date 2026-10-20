import AppKit
import Foundation

/// Shares the authenticated local transport, but is exposed only to clients
/// with the independently granted automation scope. Legacy tokens have none.
@MainActor
enum AutomationMCP {
    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: Any] = [:], required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        ["name": "automation_" + name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly]]
    }
    private static let string: [String: Any] = ["type": "string"]
    static let tools: [[String: Any]] = [
        tool("catalog", "List native AOM action names and categories. These are AOM identifiers, not BTT action IDs.", readOnly: true),
        tool("list_triggers", "List stored named triggers with their AOM JSON actions and enabled state.", readOnly: true),
        tool("save_named_trigger", "Create or replace a native named trigger. Actions use AOM TriggerAction JSON. New or replaced triggers are disabled unless enabled is explicitly true.",
             ["name": string, "actions": ["type": "array", "items": ["type": "object"]], "enabled": ["type": "boolean"]], required: ["name", "actions"]),
        tool("run_named_trigger", "Queue an enabled stored named trigger. Its normal app conditions and execution policy apply. A queued response is not proof of successful completion.", ["name": string], required: ["name"]),
        tool("list_menus", "List reusable floating menus and their native JSON definitions.", readOnly: true),
        tool("save_menu", "Validate and save one native floating menu definition. Saving does not execute its actions.", ["menu": ["type": "object"]], required: ["menu"]),
        tool("show_menu", "Show a saved native floating menu by name or id.", ["name": string], required: ["name"]),
        tool("hide_menus", "Close all floating menus without executing their actions."),
    ]

    static func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        func requiredName() throws -> String {
            guard let raw = args["name"] as? String else { throw ClipboardMCPHandler.ToolError("name is required.") }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128 else { throw ClipboardMCPHandler.ToolError("Use a name of 1–128 characters.") }
            return name
        }
        func state() throws -> AppState {
            guard let state = (NSApplication.shared.delegate as? AppDelegate)?.appState else {
                throw ClipboardMCPHandler.ToolError("The main app is not ready.")
            }
            return state
        }
        switch name {
        case "automation_catalog":
            return ["actions": ActionType.allCases.map { ["name": $0.rawValue, "category": $0.category.rawValue] }]
        case "automation_list_triggers":
            let triggers = ActionExecutor.registeredTriggers.filter { if case .namedTrigger = $0.input { return true }; return false }
            return ["triggers": try object(triggers)]
        case "automation_save_named_trigger":
            let name = try requiredName()
            guard let actionsJSON = args["actions"] as? [[String: Any]] else { throw ClipboardMCPHandler.ToolError("actions must be a JSON array.") }
            let data = try JSONSerialization.data(withJSONObject: actionsJSON)
            guard data.count <= 1_000_000 else { throw ClipboardMCPHandler.ToolError("Actions exceed 1 MB.") }
            let actions = try JSONDecoder().decode([TriggerAction].self, from: data)
            if let problem = ActionTree.problem(actions) { throw ClipboardMCPHandler.ToolError(problem) }
            for row in ActionTree.rows(actions) {
                if let problem = ActionParameterValidation.problem(for: row.action) { throw ClipboardMCPHandler.ToolError(problem) }
            }
            let app = try state()
            let matches = app.currentPreset.triggers.filter { if case .namedTrigger(let existing) = $0.input { return existing == name }; return false }
            guard matches.count <= 1 else { throw ClipboardMCPHandler.ToolError("This name is ambiguous. Edit the app-specific triggers in the main window.") }
            var trigger = matches.first ?? Trigger(name: name, input: .namedTrigger(name))
            trigger.actions = actions
            trigger.isEnabled = args["enabled"] as? Bool ?? false
            if matches.isEmpty { app.addTrigger(trigger) } else { app.updateTrigger(trigger) }
            return ["trigger": try object(trigger), "saved": true]
        case "automation_run_named_trigger":
            let name = try requiredName()
            guard ActionExecutor.registeredTriggers.contains(where: { trigger in
                guard trigger.isEnabled, case .namedTrigger(let value) = trigger.input else { return false }; return value == name
            }) else { throw ClipboardMCPHandler.ToolError("No enabled named trigger matches this name.") }
            ActionExecutor.executeNamedTrigger(name)
            return ["queued": true, "name": name, "completion": "asynchronous; normal app and trigger conditions apply"]
        case "automation_list_menus": return ["menus": try object(FloatingMenuStore.shared.menus)]
        case "automation_save_menu":
            guard let value = args["menu"] as? [String: Any] else { throw ClipboardMCPHandler.ToolError("menu is required.") }
            let data = try JSONSerialization.data(withJSONObject: value)
            guard data.count <= 4_194_304 else { throw ClipboardMCPHandler.ToolError("Menu exceeds 4 MB.") }
            let menu = try JSONDecoder().decode(FloatingMenuDefinition.self, from: data)
            try FloatingMenuStore.shared.save(menu)
            return ["saved": true, "id": menu.id.uuidString]
        case "automation_show_menu":
            let name = try requiredName()
            guard FloatingMenuController.shared.show(name) else { throw ClipboardMCPHandler.ToolError("No floating menu matches this name.") }
            return ["shown": true, "name": name]
        case "automation_hide_menus": FloatingMenuController.shared.hideAll(); return ["closed": true]
        default: throw ClipboardMCPHandler.ToolError("Unknown automation tool.")
        }
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
