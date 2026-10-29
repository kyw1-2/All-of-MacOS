import AppKit
import Foundation
import CoreFoundation

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
        tool("list_audio_apps", "List apps the per-app audio engine can control, with gain, balance (-1 left … 0 centre … 1 right), mute, tap and routing state. Requires macOS 14.2 or later.", readOnly: true),
        tool("set_app_volume", "Set one app's mixer gain from 0 to 2 (1 = unity). Pass pid or bundleID. Changing the gain does not change mute.",
             ["pid": ["type": "integer"], "bundleID": string, "volume": ["type": "number"]], required: ["volume"]),
        tool("set_app_mute", "Mute or unmute one app without changing its gain. Pass pid or bundleID.",
             ["pid": ["type": "integer"], "bundleID": string, "muted": ["type": "boolean"]], required: ["muted"]),
        tool("route_app_audio", "Send one app's audio to a specific output device UID, or back to the system default with an empty uid.",
             ["bundleID": string, "uid": string], required: ["bundleID", "uid"]),
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
            return ["triggers": redactingSecrets(try object(triggers))]
        case "automation_save_named_trigger":
            let name = try requiredName()
            guard let actionsJSON = args["actions"] as? [[String: Any]] else { throw ClipboardMCPHandler.ToolError("actions must be a JSON array.") }
            try rejectRedactedValues(actionsJSON)
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
            // "saved" means on disk: the debounced save is flushed and its
            // result checked, instead of reporting a write that failed.
            app.flushPendingWrites()
            if let failure = app.lastPresetSaveError {
                throw ClipboardMCPHandler.ToolError("The trigger is active but could not be saved: \(failure)")
            }
            return ["trigger": redactingSecrets(try object(trigger)), "saved": true]
        case "automation_run_named_trigger":
            let name = try requiredName()
            guard ActionExecutor.registeredTriggers.contains(where: { trigger in
                guard trigger.isEnabled, case .namedTrigger(let value) = trigger.input else { return false }; return value == name
            }) else { throw ClipboardMCPHandler.ToolError("No enabled named trigger matches this name.") }
            ActionExecutor.executeNamedTrigger(name)
            return ["queued": true, "name": name, "completion": "asynchronous; normal app and trigger conditions apply"]
        case "automation_list_menus": return ["menus": redactingSecrets(try object(FloatingMenuStore.shared.menus))]
        case "automation_save_menu":
            guard let value = args["menu"] as? [String: Any] else { throw ClipboardMCPHandler.ToolError("menu is required.") }
            try rejectRedactedValues(value)
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
        case "automation_list_audio_apps":
            guard #available(macOS 14.2, *) else { throw ClipboardMCPHandler.ToolError("Per-app audio needs macOS 14.2 or later.") }
            return ["apps": AppAudioEngine.shared.runningAudioApps().map(audioSnapshot)]
        case "automation_set_app_volume":
            guard #available(macOS 14.2, *) else { throw ClipboardMCPHandler.ToolError("Per-app audio needs macOS 14.2 or later.") }
            let target = try audioTarget(args)
            guard let raw = args["volume"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else { throw ClipboardMCPHandler.ToolError("volume is required.") }
            let volume = raw.floatValue
            guard volume.isFinite, volume >= 0, volume <= 2 else {
                throw ClipboardMCPHandler.ToolError("volume must be between 0 and 2 (1 = unity).")
            }
            guard AppAudioEngine.shared.setGain(volume, muted: target.muted, pid: target.pid) else {
                throw ClipboardMCPHandler.ToolError("The audio engine could not retune that app. Check its error in list_audio_apps.")
            }
            return ["updated": audioSnapshot(of: target.pid)]
        case "automation_set_app_mute":
            guard #available(macOS 14.2, *) else { throw ClipboardMCPHandler.ToolError("Per-app audio needs macOS 14.2 or later.") }
            let target = try audioTarget(args)
            guard let muted = args["muted"] as? Bool else { throw ClipboardMCPHandler.ToolError("muted is required.") }
            guard AppAudioEngine.shared.setGain(target.gain, muted: muted, pid: target.pid) else {
                throw ClipboardMCPHandler.ToolError("The audio engine could not retune that app. Check its error in list_audio_apps.")
            }
            return ["updated": audioSnapshot(of: target.pid)]
        case "automation_route_app_audio":
            guard #available(macOS 14.2, *) else { throw ClipboardMCPHandler.ToolError("Per-app audio needs macOS 14.2 or later.") }
            let bundleID = try requiredBundleID(args)
            guard let uid = args["uid"] as? String else { throw ClipboardMCPHandler.ToolError("uid is required; use an empty string for the system default.") }
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 255 else { throw ClipboardMCPHandler.ToolError("uid is too long.") }
            guard trimmed.isEmpty || AudioOutputService.devices().contains(where: { $0.uid == trimmed }) else {
                throw ClipboardMCPHandler.ToolError("The requested output is not connected. Refresh the device list first.")
            }
            AppAudioEngine.shared.addCustomApp(bundleID: bundleID)
            AppAudioEngine.shared.setRoute(uid: trimmed.isEmpty ? nil : trimmed, bundleID: bundleID)
            let apps = AppAudioEngine.shared.runningAudioApps()
            guard let updated = apps.first(where: { $0.bundleID == bundleID }) else {
                // Stored for later; nothing is playing through it yet.
                return ["routed": true, "applied": false, "bundleID": bundleID, "uid": trimmed,
                        "note": "Saved. It applies when the app next plays audio."]
            }
            return ["routed": true, "applied": true, "updated": audioSnapshot(updated)]
        default: throw ClipboardMCPHandler.ToolError("Unknown automation tool.")
        }
    }

    /// Resolves the app named by `pid` or `bundleID`. A pid is exact, so it wins
    /// when both are supplied; bundle identifiers can repeat across helper
    /// processes, which is why the pid form exists at all.
    @available(macOS 14.2, *)
    private static func audioTarget(_ args: [String: Any]) throws -> AppAudioEngine.AppState {
        let requestedPID = try validatedAudioPID(args["pid"])
        let requestedBundle = (args["bundleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apps = AppAudioEngine.shared.runningAudioApps()
        if let requestedPID {
            guard requestedPID != ProcessInfo.processInfo.processIdentifier else {
                throw ClipboardMCPHandler.ToolError("AOM does not mix its own audio.")
            }
            guard let match = apps.first(where: { $0.pid == requestedPID }) else {
                throw ClipboardMCPHandler.ToolError("No tappable audio app has that pid. Run list_audio_apps first.")
            }
            return match
        }
        guard !requestedBundle.isEmpty, requestedBundle.count <= 255 else {
            throw ClipboardMCPHandler.ToolError("Pass pid or bundleID to choose an app.")
        }
        guard let match = apps.first(where: { $0.bundleID == requestedBundle }) else {
            throw ClipboardMCPHandler.ToolError("No tappable audio app has that bundle identifier. Run list_audio_apps first.")
        }
        return match
    }

    /// JSON booleans, fractions and oversized integers must never truncate to
    /// an unrelated live PID (or silently fall back to a supplied bundle ID).
    static func validatedAudioPID(_ value: Any?) throws -> pid_t? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ClipboardMCPHandler.ToolError("pid must be a positive 32-bit integer.")
        }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 1, raw <= Double(Int32.max), raw.rounded(.towardZero) == raw else {
            throw ClipboardMCPHandler.ToolError("pid must be a positive 32-bit integer.")
        }
        return pid_t(raw)
    }

    private static func requiredBundleID(_ args: [String: Any]) throws -> String {
        guard let raw = args["bundleID"] as? String else { throw ClipboardMCPHandler.ToolError("bundleID is required.") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 255 else { throw ClipboardMCPHandler.ToolError("Use a bundle identifier of 1–255 characters.") }
        return value
    }

    @available(macOS 14.2, *)
    private static func audioSnapshot(_ state: AppAudioEngine.AppState) -> [String: Any] {
        audioSnapshot(of: state.pid, fallback: state)
    }

    @available(macOS 14.2, *)
    private static func audioSnapshot(of pid: pid_t, fallback: AppAudioEngine.AppState? = nil) -> [String: Any] {
        let state = AppAudioEngine.shared.runningAudioApps().first(where: { $0.pid == pid }) ?? fallback
        guard let state else { return ["pid": Int(pid)] }
        return [
            "pid": Int(state.pid),
            "name": state.name,
            "bundleID": state.bundleID,
            "gain": Double(state.gain),
            "balance": Double(state.balance),
            "muted": state.muted,
            "tapped": state.tapped,
            "outputDeviceUID": state.outputDeviceUID ?? "",
            "status": state.processingStatus,
            "error": state.error ?? "",
            "appEQGainsDB": AppAudioEngine.appEQ(bundleID: state.bundleID).gains.map(Double.init),
            "masterEQGainsDB": AppAudioEngine.masterEQ().gains.map(Double.init),
            "captureRecent": AppAudioEngine.shared.session(pid: pid)?.transport?.activity.recent ?? false,
            "renderRecent": AppAudioEngine.shared.session(pid: pid)?.transport?.activity.rendering ?? false
        ]
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    // MARK: Secret blocking (audit 2026-10-29, PA-03)

    /// Automation clients see trigger and menu definitions, but never a
    /// credential typed into one: such strings come back as the placeholder.
    static func redactingSecrets(_ value: Any) -> Any {
        ClipboardSecretScanner.redactingSecrets(in: value).value
    }

    /// A definition read back with placeholders must not overwrite the real
    /// secret when it is saved again.
    static func rejectRedactedValues(_ value: Any) throws {
        guard ClipboardSecretScanner.containsPlaceholder(value) else { return }
        throw ClipboardMCPHandler.ToolError("This definition contains a value that AOM hid from AI tools. Edit that secret in All of MacOS instead.")
    }
}
