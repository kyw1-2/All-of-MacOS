import AppKit
import Foundation
import CoreFoundation

/// Independently written, deliberately bounded adapter for documented BTT
/// selected-trigger JSON. This is not a .bttpreset archive/plugin interpreter.
enum BTTPresetImport {
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumTriggers = 500
    static let maximumActions = 64
    static let maximumDepth = 32
    struct Skipped: Equatable {
        let index: Int
        let name: String
        let reason: String
    }
    struct Report {
        let triggers: [Trigger]
        let skipped: [Skipped]
        let candidateCount: Int
        var reviewText: String {
            var lines = ["Supported subset: keyboard shortcuts and named triggers; maximize, left/right half, volume, mute, send shortcut and run named trigger.", "All added triggers are global and stay disabled until you enable them. Your current preset is retained.", "Named-trigger calls keep their names. Review missing targets and duplicate names before enabling.", "", "Ready to add: \(triggers.count) of \(candidateCount)"]
            lines += triggers.map { "• \($0.displayName) — \($0.actions.count) action(s), disabled" }
            if !skipped.isEmpty {
                lines += ["", "Skipped whole triggers: \(skipped.count)"]
                lines += skipped.map { "• #\($0.index + 1) \($0.name): \($0.reason)" }
            }
            lines += ["", "BTT archives, plugins, application scopes, conditions and unlisted action/event parameters are unsupported. Nothing is executed during import."]
            return lines.joined(separator: "\n")
        }
    }
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw ImportError.invalid("JSON import is limited to 4 MB.")
    }

    static func parse(_ data: Data) throws -> Report {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ImportError.invalid("BTT JSON must be nonempty and at most 4 MB.") }
        // Bound depth before JSONSerialization allocates nested containers.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= maximumDepth else { throw ImportError.invalid("BTT JSON nesting exceeds 32 levels.") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ImportError.invalid("The file is not valid JSON.") }
        let candidates: [Any]
        if let array = root as? [Any] { candidates = array }
        else if let object = root as? [String: Any], object["BTTTriggerClass"] != nil { candidates = [object] }
        else { throw ImportError.invalid("Expected a flat BTT trigger object or array. BTT preset archives and wrappers are unsupported.") }
        guard !candidates.isEmpty, candidates.count <= maximumTriggers else { throw ImportError.invalid("Import between 1 and 500 BTT triggers at a time.") }
        var nodeCount = 0
        try validateTree(root, nodes: &nodeCount)
        var triggers: [Trigger] = [], skipped: [Skipped] = []
        for (index, candidate) in candidates.enumerated() {
            let object = candidate as? [String: Any]
            let name = (object?["BTTTriggerName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Trigger \(index + 1)"
            do {
                guard let object else { throw ImportError.invalid("Trigger must be a JSON object.") }
                triggers.append(try trigger(object))
            } catch {
                skipped.append(Skipped(index: index, name: String(name.prefix(256)), reason: error.localizedDescription))
            }
        }
        return Report(triggers: triggers, skipped: skipped, candidateCount: candidates.count)
    }

    private static func validateTree(_ value: Any, nodes: inout Int) throws {
        nodes += 1
        guard nodes <= 30_000 else { throw ImportError.invalid("BTT JSON exceeds the 30,000-value limit.") }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                guard key.utf8.count <= 256 else { throw ImportError.invalid("JSON field name exceeds 256 bytes.") }
                try validateTree(child, nodes: &nodes)
            }
        } else if let array = value as? [Any] {
            for child in array { try validateTree(child, nodes: &nodes) }
        } else if let text = value as? String, text.utf8.count > 16_384 {
            throw ImportError.invalid("JSON string exceeds 16 KB.")
        }
    }

    private static let metadata: Set<String> = ["BTTUUID", "BTTOrder", "BTTTriggerTypeDescription"]
    private static let enabledKeys: Set<String> = ["BTTEnabled", "BTTEnabled2"]
    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else { throw ImportError.invalid("Unsupported field(s): " + unknown.joined(separator: ", ") + ".") }
        for key in enabledKeys where object[key] != nil { _ = try flag(object, key: key) }
        if let value = object["BTTUUID"], !(value is String) { throw ImportError.invalid("BTTUUID must be a string.") }
        if object["BTTOrder"] != nil { _ = try integer(object, key: "BTTOrder", range: 0...Int.max) }
        if let value = object["BTTTriggerTypeDescription"], !(value is String) { throw ImportError.invalid("BTTTriggerTypeDescription must be text.") }
    }
    private static func integer(_ object: [String: Any], key: String, range: ClosedRange<Int>) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let value = Int(number.stringValue), range.contains(value) else {
            throw ImportError.invalid("\(key) must be an integer in \(range).")
        }
        return value
    }
    private static func flag(_ object: [String: Any], key: String) throws -> Bool {
        try integer(object, key: key, range: 0...1) == 1
    }
    private static func label(_ value: Any?, field: String, required: Bool = true) throws -> String {
        guard let text = value as? String else {
            if !required && value == nil { return "" }
            throw ImportError.invalid("\(field) must be text.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!required || !trimmed.isEmpty), trimmed.count <= 256,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportError.invalid("\(field) must contain 1–256 characters without control characters.")
        }
        return trimmed
    }
    private static let modifierMask: UInt = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue
    private static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static func keyCode(_ value: Int) throws -> UInt16 {
        guard (0...127).contains(value), !modifierKeyCodes.contains(value) else { throw ImportError.invalid("Only non-modifier macOS virtual keycodes 0–127 are supported.") }
        return UInt16(value)
    }
    private static func trigger(_ object: [String: Any]) throws -> Trigger {
        let common = metadata.union(enabledKeys).union(["BTTTriggerClass", "BTTTriggerType", "BTTTriggerName", "BTTActionsToExecute"])
        let input: TriggerInput
        var phase: KeyboardPhase = .keyDown
        switch object["BTTTriggerClass"] as? String {
        case "BTTTriggerTypeKeyboardShortcut":
            try checkKeys(object, allowed: common.union(["BTTShortcutKeyCode", "BTTShortcutModifierKeys", "BTTTriggerOnDown"]))
            guard try integer(object, key: "BTTTriggerType", range: 0...Int.max) == 0 else { throw ImportError.invalid("Only keyboard shortcut trigger type 0 is supported.") }
            let key = try keyCode(integer(object, key: "BTTShortcutKeyCode", range: 0...127))
            let raw = try integer(object, key: "BTTShortcutModifierKeys", range: 0...Int.max)
            guard UInt(raw) & ~modifierMask == 0 else { throw ImportError.invalid("Unsupported keyboard modifier bits.") }
            if object["BTTTriggerOnDown"] != nil { phase = try flag(object, key: "BTTTriggerOnDown") ? .keyDown : .keyUp }
            input = .keyboardShortcut(KeyboardShortcut(keyCode: key, modifiers: NSEvent.ModifierFlags(rawValue: UInt(raw))))
        case "BTTTriggerTypeOtherTriggers":
            try checkKeys(object, allowed: common)
            guard try integer(object, key: "BTTTriggerType", range: 0...Int.max) == 643 else { throw ImportError.invalid("Only named Other trigger type 643 is supported.") }
            input = .namedTrigger(try label(object["BTTTriggerName"], field: "BTTTriggerName"))
        default: throw ImportError.invalid("Unsupported BTT trigger class.")
        }
        guard let actions = object["BTTActionsToExecute"] as? [[String: Any]], !actions.isEmpty, actions.count <= maximumActions else {
            throw ImportError.invalid("BTTActionsToExecute must contain 1–64 action objects.")
        }
        let name = try label(object["BTTTriggerName"], field: "BTTTriggerName", required: false)
        var result = Trigger(name: name.isEmpty ? input.displayName : name, input: input)
        // Map every step before returning. One unsupported action rejects its
        // complete trigger; the importer never makes a partial action sequence.
        result.actions = try actions.map(action)
        result.keyboardPhase = phase
        result.isEnabled = false
        result.notes = "Imported from the supported BTT JSON subset. Review before enabling."
        return result
    }
    private static func action(_ object: [String: Any]) throws -> TriggerAction {
        let id = try integer(object, key: "BTTPredefinedActionType", range: 0...Int.max)
        let allowed = Set(["BTTPredefinedActionType", "BTTPredefinedActionName", "BTTUUID", "BTTOrder", "BTTAdditionalActionData"]).union(enabledKeys)
        if let additional = object["BTTAdditionalActionData"] {
            guard let fields = additional as? [String: Any] else { throw ImportError.invalid("BTTAdditionalActionData must be a JSON object.") }
            if id == 264 {
                let supported = Set(["BTTActionSendKeyboardShortcutIncludeCurrentModifiers", "BTTActionSendKeyboardShortcutLowLevel"])
                guard Set(fields.keys).isSubset(of: supported) else { throw ImportError.invalid("Unsupported shortcut action additional data.") }
                for (key, value) in fields {
                    guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else {
                        throw ImportError.invalid("\(key) must be false; including current modifiers and low-level injection are unsupported.")
                    }
                }
            } else if !fields.isEmpty { throw ImportError.invalid("Nonempty action additional data is unsupported (including named-trigger variables).") }
        }
        let simple: [Int: ActionType] = [21: .maximizeWindow, 19: .snapWindowLeft, 20: .snapWindowRight, 24: .volumeUp, 25: .volumeDown, 22: .muteVolume]
        var result: TriggerAction
        if let type = simple[id] {
            try checkKeys(object, allowed: allowed)
            result = TriggerAction(actionType: type)
        } else if id == 264 {
            try checkKeys(object, allowed: allowed.union(["BTTShortcutToSend"]))
            guard let text = object["BTTShortcutToSend"] as? String else { throw ImportError.invalid("BTTShortcutToSend must be comma-separated keycodes.") }
            let components = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let codes = components.compactMap(Int.init)
            guard !codes.isEmpty, codes.count <= 6, codes.count == components.count else { throw ImportError.invalid("Invalid BTTShortcutToSend keycodes.") }
            let modifiers = codes.dropLast()
            let mapping: [Int: NSEvent.ModifierFlags] = [55: .command, 56: .shift, 58: .option, 59: .control, 63: .function]
            guard Set(modifiers).count == modifiers.count, Array(modifiers) == modifiers.sorted(by: >), modifiers.allSatisfy({ mapping[$0] != nil }) else {
                throw ImportError.invalid("Shortcut modifiers must be supported left modifier keycodes in descending order; side-specific/right modifiers are unsupported.")
            }
            var parameters = ActionParameters()
            parameters.shortcutKeyCode = try keyCode(codes.last!)
            parameters.shortcutModifiers = modifiers.reduce(UInt(0)) { $0 | mapping[$1]!.rawValue }
            result = TriggerAction(actionType: .sendKeyStroke, parameters: parameters)
        } else if id == 248 {
            try checkKeys(object, allowed: allowed.union(["BTTNamedTriggerToTrigger"]))
            var parameters = ActionParameters()
            parameters.namedTriggerName = try label(object["BTTNamedTriggerToTrigger"], field: "BTTNamedTriggerToTrigger")
            result = TriggerAction(actionType: .triggerNamedTrigger, parameters: parameters)
        } else { throw ImportError.invalid("Unsupported BTT action ID \(id).") }
        if let name = object["BTTPredefinedActionName"], !(name is String) { throw ImportError.invalid("BTTPredefinedActionName must be text.") }
        let enabled = try enabledKeys.filter { object[$0] != nil }.map { try flag(object, key: $0) }
        if Set(enabled).count > 1 { throw ImportError.invalid("Conflicting BTTEnabled/BTTEnabled2 action flags.") }
        result.isEnabled = enabled.first ?? true
        return result
    }
}

@MainActor
extension AppState {
    /// Existing Import Preset entry point auto-detects native AOM or the
    /// documented flat BTT subset. Only an explicit Add merges BTT triggers.
    func reviewCompatiblePresetImport(from url: URL) {
        do {
            let data = try BTTPresetImport.read(url)
            if (try? PresetCodec.decode(data)) != nil {
                importPreset(from: url)
                return
            }
            let report = try BTTPresetImport.parse(data)
            let alert = NSAlert()
            alert.messageText = "Review BTT JSON Import"
            alert.informativeText = "\(report.triggers.count) supported trigger(s), \(report.skipped.count) skipped. Added triggers will be disabled."
            alert.addButton(withTitle: report.triggers.isEmpty ? "Close" : "Add Disabled Triggers")
            if !report.triggers.isEmpty { alert.addButton(withTitle: "Cancel") }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 330))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            let existingNames = Set(currentPreset.triggers.compactMap { trigger -> String? in if case .namedTrigger(let name) = trigger.input { return name }; return nil })
            let collisions = report.triggers.compactMap { trigger -> String? in if case .namedTrigger(let name) = trigger.input, existingNames.contains(name) { return name }; return nil }
            text.string = report.reviewText + (collisions.isEmpty ? "" : "\n\nExisting named-trigger collisions: " + collisions.joined(separator: ", ") + ". Rename or remove duplicates before enabling.")
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; alert.accessoryView = scroll
            guard alert.runModal() == .alertFirstButtonReturn, !report.triggers.isEmpty else { return }
            addDisabledBTTTriggers(report.triggers)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could Not Import JSON"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    func addDisabledBTTTriggers(_ triggers: [Trigger]) {
        for var trigger in triggers {
            trigger.isEnabled = false
            currentPreset.addTrigger(trigger)
        }
        selectedTrigger = nil; selectedAction = nil
        save()
    }
}
