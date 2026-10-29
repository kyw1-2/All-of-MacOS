import AppKit
import CoreFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Independently written adapter for BetterTouchTool exports: copied triggers
/// (one object or an array) and plain-JSON `.bttpreset` files. Documented BTT
/// trigger and action IDs (see `BTTImportMappings`) map onto existing AOM
/// types. The report says what was imported exactly, approximately (and why)
/// or not at all. Nothing is executed during import, script steps arrive
/// disabled, and compressed presets, plugins and conditions are not imported.
enum BTTPresetImport {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumTriggers = 2_000
    static let maximumActions = 64
    static let maximumDepth = 32
    static let maximumValues = 250_000
    static let maximumStringBytes = 1_048_576
    static let maximumScriptBytes = 262_144
    static let maximumTextBytes = 65_536
    static let maximumGroups = 512

    /// File types the import panel offers: copied-trigger JSON and `.bttpreset`.
    static var openPanelContentTypes: [UTType] {
        [.json] + [UTType(filenameExtension: "bttpreset")].compactMap { $0 }
    }

    /// A whole BTT trigger that was not imported.
    struct Skipped: Equatable {
        let index: Int
        let name: String
        let reason: String
    }

    /// One line of the import report.
    struct Entry: Identifiable, Hashable {
        enum Group: String, CaseIterable, Identifiable {
            case imported = "Imported"
            case approximate = "Mapped Approximately"
            case skipped = "Skipped"
            var id: String { rawValue }
        }
        enum Kind: String { case trigger = "Trigger", action = "Action", scope = "App group" }
        let id: Int
        let group: Group
        let kind: Kind
        /// The name the user knows: the BTT label or the native trigger name.
        let title: String
        /// BTT's native name for the trigger or action type.
        let bttName: String
        /// BTT class and numeric ID, e.g. "TouchpadAll 102" or "action 249".
        let bttID: String
        let scope: String
        /// What it became in AOM.
        let detail: String
        let reasons: [String]
        let needsReview: Bool
    }

    struct Report {
        /// Staged triggers. Approximate ones and script steps are disabled.
        var triggers: [Trigger] = []
        /// App scopes the staged triggers need.
        var appTargets: [AppTarget] = []
        var entries: [Entry] = []
        var skipped: [Skipped] = []
        var candidateCount = 0
        var presetName: String?

        func entries(in group: Entry.Group) -> [Entry] { entries.filter { $0.group == group } }
        var reviewCount: Int { entries.filter(\.needsReview).count }
        var enabledCount: Int { triggers.filter(\.isEnabled).count }
        var triggerEntryCount: (imported: Int, approximate: Int, skipped: Int) {
            let triggers = entries.filter { $0.kind == .trigger }
            return (triggers.filter { $0.group == .imported }.count,
                    triggers.filter { $0.group == .approximate }.count,
                    triggers.filter { $0.group == .skipped }.count)
        }
        var summary: String {
            let counts = triggerEntryCount
            return "\(counts.imported) imported, \(counts.approximate) mapped approximately, \(counts.skipped) skipped of \(candidateCount) BTT trigger(s)."
        }
        var reviewText: String {
            var lines = [summary,
                         "Exact matches keep their BTT enabled state. Approximate matches and every script step are added disabled for review.",
                         "Named-trigger calls keep their names. Review missing targets and duplicate names before enabling.",
                         "Nothing is executed during import. Your current preset is kept."]
            for group in Entry.Group.allCases {
                let items = entries(in: group)
                guard !items.isEmpty else { continue }
                lines += ["", "\(group.rawValue) (\(items.count))"]
                for item in items {
                    lines.append("• \(item.title) — BTT \(item.bttName) [\(item.bttID)] · \(item.scope)\(item.detail.isEmpty ? "" : " · " + item.detail)")
                    lines += item.reasons.map { "    – \($0)" }
                }
            }
            if !skipped.isEmpty { lines += ["", "Skipped whole triggers: \(skipped.count)"] }
            return lines.joined(separator: "\n")
        }
    }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    static let compressedMessage = "This BetterTouchTool preset is compressed (.bttpresetzip or .bttpresetcompressed). Export it again as a plain .bttpreset, or copy the triggers in BetterTouchTool with ⌘C and import that JSON."

    // MARK: Reading

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw ImportError.invalid("BTT import is limited to \(maximumBytes / 1_048_576) MB.")
    }

    /// Parses BTT JSON into a report. `appBundleID` resolves app file URLs
    /// found in BTT settings; tests pass a fixed table instead of the disk.
    static func parse(_ data: Data, appBundleID: @escaping (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) throws -> Report {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ImportError.invalid("BTT JSON must be nonempty and at most \(maximumBytes / 1_048_576) MB.")
        }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            throw ImportError.invalid(compressedMessage)
        }
        try checkDepth(data)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ImportError.invalid("The file is not valid JSON.") }
        var nodes = 0
        try validateTree(root, nodes: &nodes)

        var report = Report()
        var candidates: [Candidate] = []
        var scopeEntries: [(title: String, scope: String, reason: String)] = []
        if let array = root as? [Any] {
            candidates = array.map { Candidate(value: $0, scope: flatScope($0)) }
        } else if let object = root as? [String: Any], object["BTTPresetContent"] != nil {
            report.presetName = (object["BTTPresetName"] as? String).map(cleanLabel).flatMap { $0.isEmpty ? nil : $0 }
            guard let groups = object["BTTPresetContent"] as? [Any], groups.count <= maximumGroups else {
                throw ImportError.invalid("BTTPresetContent must be a list of at most \(maximumGroups) app groups.")
            }
            for group in groups {
                guard let group = group as? [String: Any] else { throw ImportError.invalid("Each BTT app group must be a JSON object.") }
                let scope = groupScope(group)
                if case .app(_, let name) = scope, let settings = group["BTTAppSpecificSettings"] as? [String: Any],
                   (settings["BTTDisableGlobalTriggers"] as? NSNumber)?.boolValue == true {
                    scopeEntries.append((name, scope.label, "BTT turned off global triggers in this app; AOM keeps global triggers active there. Use a Conditional Activation Group with “Disable global triggers” if you need that."))
                }
                guard let triggers = group["BTTTriggers"] else { continue }
                guard let list = triggers as? [Any] else { throw ImportError.invalid("BTTTriggers must be a list.") }
                candidates += list.map { Candidate(value: $0, scope: scope) }
            }
            guard !candidates.isEmpty else { throw ImportError.invalid("The preset contains no triggers.") }
        } else if let object = root as? [String: Any], object["BTTTriggerClass"] != nil {
            candidates = [Candidate(value: object, scope: flatScope(object))]
        } else {
            throw ImportError.invalid("Expected a BTT trigger, a list of copied BTT triggers, or a plain .bttpreset file. Other BTT archives and wrappers are not supported.")
        }
        guard !candidates.isEmpty, candidates.count <= maximumTriggers else {
            throw ImportError.invalid("Import between 1 and \(maximumTriggers) BTT triggers at a time.")
        }
        report.candidateCount = candidates.count

        var nextID = 0
        func add(_ group: Entry.Group, _ kind: Entry.Kind, title: String, bttName: String, bttID: String,
                 scope: String, detail: String = "", reasons: [String], review: Bool = false) {
            report.entries.append(Entry(id: nextID, group: group, kind: kind, title: title, bttName: bttName, bttID: bttID,
                                        scope: scope, detail: detail, reasons: reasons, needsReview: review))
            nextID += 1
        }
        for item in scopeEntries {
            add(.approximate, .scope, title: item.title, bttName: "App-specific settings", bttID: "BTTDisableGlobalTriggers", scope: item.scope, reasons: [item.reason])
        }
        var targets: [String: AppTarget] = [:]
        // BTTOrder keeps the BTT list order within each scope; scopes keep
        // the order in which they first appear.
        var scopeRank: [String: Int] = [:]
        for candidate in candidates where scopeRank[candidate.scope.label] == nil { scopeRank[candidate.scope.label] = scopeRank.count }
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let a = (scopeRank[lhs.element.scope.label] ?? 0, order(lhs.element.value), lhs.offset)
            let b = (scopeRank[rhs.element.scope.label] ?? 0, order(rhs.element.value), rhs.offset)
            return a < b
        }
        let context = Context(appBundleID: appBundleID)
        for (index, candidate) in ordered {
            let identity = Identity(candidate.value)
            let scopeLabel = candidate.scope.label
            do {
                if case .unsupported(let id, let name) = candidate.scope {
                    throw ImportError.invalid("BTT special group “\(name)” (\(id)) has no AOM scope.")
                }
                guard let object = candidate.value as? [String: Any] else { throw ImportError.invalid("Trigger must be a JSON object.") }
                let converted = try convert(object, scope: candidate.scope, identity: identity, context: context)
                // Review flags do not make a mapping approximate: the step is
                // the same, it is only switched off until someone reads it.
                let exact = converted.approximations.isEmpty && converted.dropped.isEmpty
                var reasons = converted.approximations
                reasons += converted.dropped.map { "Not imported: \($0.name) (BTT action \($0.id)) — \($0.reason)" }
                reasons += converted.review.map { "Review: " + $0 }
                if !exact && converted.bttEnabled { reasons.append("Added disabled for review; it was enabled in BTT.") }
                if !converted.bttEnabled { reasons.append("Disabled in BTT, so it stays disabled.") }
                for var trigger in converted.triggers {
                    trigger.isEnabled = converted.bttEnabled && exact
                    trigger.notes = notes(converted.notes, identity: identity, reasons: reasons)
                    report.triggers.append(trigger)
                }
                if case .app(let bundleID, let name) = candidate.scope, targets[bundleID] == nil {
                    targets[bundleID] = AppTarget(id: UUID(), bundleID: bundleID, name: name, iconPath: nil)
                }
                let detail = converted.triggers.map { trigger in
                    let phase = trigger.input.category == .keyboard && trigger.keyboardPhase != .keyDown ? " (\(trigger.keyboardPhase.rawValue.lowercased()))" : ""
                    return "→ \(trigger.input.displayName)\(phase), \(trigger.actions.count) step(s)"
                }.joined(separator: "; ")
                add(exact ? .imported : .approximate, .trigger, title: identity.title, bttName: identity.name, bttID: identity.id,
                    scope: scopeLabel, detail: detail + (exact && converted.bttEnabled ? ", enabled" : ", disabled"),
                    reasons: reasons, review: !converted.review.isEmpty)
                for dropped in converted.dropped {
                    add(.skipped, .action, title: dropped.name, bttName: dropped.name, bttID: "action \(dropped.id)", scope: scopeLabel,
                        detail: "in “\(identity.title)”", reasons: [dropped.reason])
                }
            } catch {
                let reason = error.localizedDescription
                report.skipped.append(Skipped(index: index, name: String(identity.title.prefix(256)), reason: reason))
                add(.skipped, .trigger, title: identity.title, bttName: identity.name, bttID: identity.id, scope: scopeLabel, reasons: [reason])
            }
        }
        report.appTargets = targets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        report.skipped.sort { $0.index < $1.index }
        return report
    }

    // MARK: Containers and scopes

    enum Scope: Equatable {
        case global
        case app(bundleID: String, name: String)
        case unsupported(id: String, name: String)
        var label: String {
            switch self {
            case .global: return "All Apps"
            case .app(let id, let name): return name == id ? id : "\(name) (\(id))"
            case .unsupported(let id, let name): return "\(name) (\(id))"
            }
        }
    }
    private struct Candidate {
        let value: Any
        let scope: Scope
    }

    static func isBundleIdentifier(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return (1...255).contains(text.utf8.count) && text.unicodeScalars.allSatisfy(allowed.contains)
            && !text.hasPrefix(".") && !text.hasSuffix(".") && !text.contains("..")
    }
    private static func groupScope(_ group: [String: Any]) -> Scope {
        guard let id = group["BTTAppBundleIdentifier"] as? String, isBundleIdentifier(id) else {
            return .unsupported(id: "invalid", name: "App group without a valid bundle identifier")
        }
        let name = (group["BTTAppName"] as? String).map(cleanLabel).flatMap { $0.isEmpty ? nil : $0 } ?? id
        if id == "BT.G" { return .global }
        if id.hasPrefix("BT.") { return .unsupported(id: id, name: name) }
        return .app(bundleID: id, name: name)
    }
    /// Copied triggers carry no app group; an explicit identifier is honored.
    private static func flatScope(_ value: Any) -> Scope {
        guard let object = value as? [String: Any], let raw = object["BTTAppBundleIdentifier"] else { return .global }
        guard let id = raw as? String, isBundleIdentifier(id) else {
            return .unsupported(id: "invalid", name: "Invalid BTTAppBundleIdentifier")
        }
        if id == "BT.G" { return .global }
        if id.hasPrefix("BT.") { return .unsupported(id: id, name: id) }
        let name = (object["BTTAppName"] as? String).map(cleanLabel).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return .app(bundleID: id, name: name)
    }
    private static func order(_ value: Any) -> Int {
        guard let number = (value as? [String: Any])?["BTTOrder"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) < 1e9 else { return 0 }
        return number.intValue
    }

    // MARK: Structural limits

    private static func checkDepth(_ data: Data) throws {
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
                guard depth <= maximumDepth else { throw ImportError.invalid("BTT JSON nesting exceeds \(maximumDepth) levels.") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }
    private static func validateTree(_ value: Any, nodes: inout Int) throws {
        nodes += 1
        guard nodes <= maximumValues else { throw ImportError.invalid("BTT JSON exceeds the \(maximumValues) value limit.") }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                guard key.utf8.count <= 256 else { throw ImportError.invalid("JSON field name exceeds 256 bytes.") }
                try validateTree(child, nodes: &nodes)
            }
        } else if let array = value as? [Any] {
            for child in array { try validateTree(child, nodes: &nodes) }
        } else if let text = value as? String, text.utf8.count > maximumStringBytes {
            throw ImportError.invalid("A JSON string exceeds 1 MB.")
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !number.doubleValue.isFinite {
            throw ImportError.invalid("JSON numbers must be finite.")
        }
    }

    // MARK: Field access with validation

    /// A JSON object that remembers which keys were read, so settings the
    /// importer does not understand are reported instead of dropped silently.
    final class Fields {
        let raw: [String: Any]
        private(set) var used = Set<String>()
        init(_ raw: [String: Any]) { self.raw = raw }
        func has(_ key: String) -> Bool { raw[key] != nil }
        func touch(_ keys: [String]) { used.formUnion(keys) }
        func value(_ key: String) -> Any? { used.insert(key); return raw[key] }
        func unused(ignoring benign: Set<String>) -> [String] {
            raw.keys.filter { !used.contains($0) && !benign.contains($0) }.sorted()
        }
        func integer(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            try value(key).map { try BTTPresetImport.integer($0, key: key, range: range) }
        }
        /// Numbers, or decimal strings such as BTT's "1.0".
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let value = value(key) else { return nil }
            let number: Double?
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { number = n.doubleValue }
            else if let text = value as? String { number = Double(text.trimmingCharacters(in: .whitespaces)) }
            else { number = nil }
            guard let number, number.isFinite, range.contains(number) else { throw ImportError.invalid("\(key) must be a number in \(range.lowerBound)…\(range.upperBound).") }
            return number
        }
        func flag(_ key: String) throws -> Bool? {
            guard let value = value(key) else { return nil }
            guard let n = value as? NSNumber else { throw ImportError.invalid("\(key) must be 0 or 1.") }
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return try BTTPresetImport.integer(n, key: key, range: 0...1) == 1
        }
        func text(_ key: String, maxBytes: Int = 1_024, multiline: Bool = false) throws -> String? {
            guard let value = value(key) else { return nil }
            guard let text = value as? String else { throw ImportError.invalid("\(key) must be text.") }
            try BTTPresetImport.checkText(text, key: key, maxBytes: maxBytes, multiline: multiline)
            return text
        }
        /// A JSON object, or a string holding one (BTT writes both forms).
        func object(_ key: String) throws -> [String: Any]? {
            guard let value = value(key) else { return nil }
            if let object = value as? [String: Any] { return object }
            if let text = value as? String {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
                return try BTTPresetImport.embeddedObject(text, key: key)
            }
            throw ImportError.invalid("\(key) must be a JSON object.")
        }
        func list(_ key: String) throws -> [Any]? {
            guard let value = value(key) else { return nil }
            guard let list = value as? [Any] else { throw ImportError.invalid("\(key) must be a list.") }
            return list
        }
    }

    static func integer(_ value: Any, key: String, range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let result = Int(exactly: number.doubleValue), range.contains(result) else {
            throw ImportError.invalid("\(key) must be an integer in \(range.lowerBound)…\(range.upperBound).")
        }
        return result
    }
    static func checkText(_ text: String, key: String, maxBytes: Int, multiline: Bool) throws {
        guard text.utf8.count <= maxBytes else { throw ImportError.invalid("\(key) is longer than \(maxBytes) bytes.") }
        let allowed: Set<Unicode.Scalar> = multiline ? ["\n", "\r", "\t"] : []
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !allowed.contains($0) }) else {
            throw ImportError.invalid("\(key) contains control characters.")
        }
    }
    static func embeddedObject(_ text: String, key: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { throw ImportError.invalid("\(key) is too large.") }
        try checkDepth(data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalid("\(key) must contain a JSON object.")
        }
        var nodes = 0
        try validateTree(object, nodes: &nodes)
        return object
    }
    /// Display text: control characters become spaces, at most 256 characters.
    static func cleanLabel(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        return String(String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    }
    /// Identifiers such as named-trigger names must be clean, never repaired.
    static func strictLabel(_ value: Any?, field: String) throws -> String {
        guard let text = value as? String else { throw ImportError.invalid("\(field) must be text.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportError.invalid("\(field) must contain 1–256 characters without control characters.")
        }
        return trimmed
    }
    static func isAOMVariableName(_ name: String, maximum: Int) -> Bool {
        !name.isEmpty && ActionParameterValidation.isVariableName(name, maximum: maximum)
    }
    /// Absolute or home-relative local path, without NUL or other controls.
    static func localPath(_ raw: String, field: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { text = url.path }
        if text.hasPrefix("~") { text = (text as NSString).expandingTildeInPath }
        guard text.hasPrefix("/"), text.utf8.count <= 1_024,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportError.invalid("\(field) must be an absolute file path.")
        }
        return (text as NSString).standardizingPath
    }

    // MARK: Identity (for the report, never throws)

    struct Identity {
        let name: String
        let id: String
        let title: String
        init(_ value: Any) {
            let object = value as? [String: Any] ?? [:]
            let cls = object["BTTTriggerClass"] as? String ?? "unknown class"
            let number = object["BTTTriggerType"] as? NSNumber
            let type = number.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : Int(exactly: $0.doubleValue) }
            let short = cls.hasPrefix("BTTTriggerType") ? String(cls.dropFirst("BTTTriggerType".count)) : cls
            id = "\(BTTPresetImport.cleanLabel(short).prefix(48)) \(type.map(String.init) ?? "?")"
            let native = BTTPresetImport.nativeName(cls: cls, type: type)
                ?? (object["BTTTriggerTypeDescriptionReadOnly"] as? String).map(BTTPresetImport.cleanLabel)
            let fallback = native ?? (object["BTTTriggerTypeDescription"] as? String).map(BTTPresetImport.cleanLabel) ?? "Unknown trigger"
            name = fallback.isEmpty ? "Unknown trigger" : fallback
            let custom = ((cls == "BTTTriggerTypeOtherTriggers" && type == 643 ? object["BTTTriggerName"] : object["BTTTriggerTypeDescription"]) as? String)
                .map(BTTPresetImport.cleanLabel) ?? ""
            title = custom.isEmpty ? name : custom
        }
    }
    static func nativeName(cls: String, type: Int?) -> String? {
        guard let type else { return BTTImportMappings.unsupportedClasses[cls]?.name }
        if BTTImportMappings.trackpadClasses[cls] != nil { return BTTImportMappings.trackpad[type]?.name ?? "Trackpad gesture \(type)" }
        switch cls {
        case "BTTTriggerTypeMagicMouse": return "Magic Mouse " + (BTTImportMappings.magicMouse[type] ?? "gesture \(type)")
        case "BTTTriggerTypeKeyboardShortcut": return type == 624 ? "Key Sequence" : [0, -1].contains(type) ? "Keyboard Shortcut" : "Keyboard trigger \(type)"
        case "BTTTriggerTypeKeySequence": return "Key Sequence"
        case "BTTTriggerTypeNormalMouse": return mouseName(type)
        case "BTTTriggerTypeOtherTriggers": return BTTImportMappings.otherTriggerNames[type] ?? "Other trigger \(type)"
        default: return BTTImportMappings.unsupportedClasses[cls]?.name
        }
    }
    static func mouseName(_ type: Int) -> String {
        switch type {
        case 996: return "Scroll Down"
        case 997: return "Scroll Up"
        case 998: return "Scroll Left"
        case 999: return "Scroll Right"
        case 1324: return "Logitech Mouse Configuration"
        case 1347: return "Razer Mouse Configuration"
        case 1050, 1150, 1250, 1350: return "Logitech Thumb Wheel Touch"
        case 1000...1399:
            let clicks = ["Click", "Double Click", "Triple Click", "Quadruple Click"][(type - 1000) / 100]
            return "\(MouseTriggerSpec.buttonName((type - 1000) % 100)) \(clicks)"
        default: return "Mouse trigger \(type)"
        }
    }

    // MARK: Trigger conversion

    struct Context {
        let appBundleID: (URL) -> String?
    }
    struct Dropped: Equatable {
        let name: String
        let id: Int
        let reason: String
    }
    private struct Converted {
        var triggers: [Trigger] = []
        var approximations: [String] = []
        var review: [String] = []
        var dropped: [Dropped] = []
        var notes = ""
        var bttEnabled = true
    }
    /// Keys that only describe, order or identify a trigger.
    private static let benignTriggerKeys: Set<String> = [
        "BTTTriggerClass", "BTTTriggerType", "BTTTriggerTypeDescription", "BTTTriggerTypeDescriptionReadOnly", "BTTUUID",
        "BTTOrder", "BTTLastUpdatedAt", "BTTNotesInsteadOfDescription", "BTTDisplayOrder", "BTTMergeIntoTouchBarGroups",
        "BTTTriggerParentUUID", "BTTIsPureAction", "BTTKeyboardShortcutKeyboardType", "BTTLayoutIndependentChar",
        "BTTShortcutAdvancedModifierKeys", "BTTTriggerConfig", "BTTPredefinedActionName", "BTTAppName", "BTTIconData",
        "BTTAppBundleIdentifier", // consumed as the trigger's app scope
        "BTTEnabled", "BTTEnabled2", "BTTGestureNotes", "BTTTriggerName", "BTTKeyboardShortcutPerformDefaultOnAdvancedConditionMismatch"
    ]
    private static let benignActionKeys: Set<String> = [
        "BTTPredefinedActionType", "BTTPredefinedActionName", "BTTUUID", "BTTOrder", "BTTEnabled", "BTTEnabled2",
        "BTTLastUpdatedAt", "BTTTriggerParentUUID", "BTTIsPureAction", "BTTTriggerClass", "BTTTriggerType",
        "BTTTriggerTypeDescription", "BTTTriggerTypeDescriptionReadOnly", "BTTDisplayOrder", "BTTMergeIntoTouchBarGroups",
        "BTTActionCategory", "BTTLayoutIndependentActionChar", "BTTIconData", "BTTNotesInsteadOfDescription", "BTTGestureNotes"
    ]
    private static let conditionKeys: Set<String> = [
        "BTTTriggerConditions", "BTTTriggerConditionsData", "BTTConditionName", "BTTConditionalActivationGroup",
        "BTTAdvancedTriggerCondition", "BTTActivationGroupCondition"
    ]
    /// Dedicated action-category arrays and their BTTActionCategory numbers.
    static let categoryKeys: [String: Int] = [
        "BTTActionCategoryHover": 1, "BTTActionCategoryLongPress": 2, "BTTActionCategoryTouchRelease": 3,
        "BTTActionCategoryHoverEnd": 4, "BTTActionCategoryHyperKeyRelease": 5, "BTTActionCategoryRightClick": 6,
        "BTTActionCategoryPressDown": 17, "BTTActionCategoryDragDown": 21, "BTTActionCategoryDragUp": 22,
        "BTTActionCategoryDragLeft": 23, "BTTActionCategoryDragRight": 24, "BTTActionCategoryDragDownContinuous": 25,
        "BTTActionCategoryDragUpContinuous": 26, "BTTActionCategoryDragLeftContinuous": 27, "BTTActionCategoryDragRightContinuous": 28,
        "BTTActionCategoryButtonRelease": 31, "BTTActionCategoryButtonQuickRelease": 32, "BTTActionCategoryButtonReleaseAfterLongPress": 33,
        "BTTActionCategoryKeyRelease": 35, "BTTActionCategoryKeyQuickRelease": 36, "BTTActionCategoryKeyReleaseAfterLongPress": 37,
        "BTTActionCategoryKeyLongPress": 38, "BTTActionCategoryFirstScroll": 39, "BTTActionCategoryKeyReleaseAfterAllModifiersReleased": 47,
        "BTTActionCategoryDoubleClick": 59, "BTTActionCategoryButtonReleaseAfterDrag": 60, "BTTActionCategoryDragContinuous": 61
    ]
    static func categoryName(_ category: Int) -> String {
        categoryKeys.first { $0.value == category }.map { String($0.key.dropFirst("BTTActionCategory".count)) } ?? "category \(category)"
    }

    private static func convert(_ object: [String: Any], scope: Scope, identity: Identity, context: Context) throws -> Converted {
        let f = Fields(object)
        var out = Converted()
        guard let cls = try f.text("BTTTriggerClass", maxBytes: 128) else { throw ImportError.invalid("BTTTriggerClass is missing.") }
        guard let type = try f.integer("BTTTriggerType", -1...100_000) else { throw ImportError.invalid("BTTTriggerType is missing.") }
        out.bttEnabled = try (f.flag("BTTEnabled") ?? true) && (f.flag("BTTEnabled2") ?? true)
        if let uuid = f.value("BTTUUID"), !(uuid is String) { throw ImportError.invalid("BTTUUID must be text.") }
        if f.has("BTTOrder") { _ = try f.integer("BTTOrder", Int(Int32.min)...Int(Int32.max)) }
        let description = try f.text("BTTTriggerTypeDescription", maxBytes: 4_096).map(cleanLabel) ?? ""
        out.notes = try f.text("BTTGestureNotes", maxBytes: 16_384, multiline: true) ?? ""
        if let unsupported = BTTImportMappings.unsupportedClasses[cls] { throw ImportError.invalid(unsupported.gap) }

        var template = Trigger(name: "", input: .namedTrigger("_"))
        if case .app(let bundleID, _) = scope { template.appBundleID = bundleID }
        if f.has("BTTRequiredModifierKeys") {
            let mods = try modifiers(try f.integer("BTTRequiredModifierKeys", 0...0xFF_FFFF) ?? 0, field: "BTTRequiredModifierKeys")
            template.requiredModifiers = mods.flags.rawValue
            out.approximations += mods.notes
        }
        if let delay = try f.number("BTTDelayBeforeTriggering", 0...60) { template.delayBeforeTriggeringMs = Int((delay * 1_000).rounded()) }
        let conditions = conditionKeys.filter(f.has)
        f.touch(Array(conditions))
        if !conditions.isEmpty { out.approximations.append("BTT conditions (\(conditions.sorted().joined(separator: ", "))) were not imported; the trigger would fire without them.") }

        // Inputs. Each kind says which action categories it can express.
        enum Shape { case trackpad, keyboard(KeyboardShortcut, onDown: Bool), sequence, mouse(MouseTriggerSpec), other }
        let shape: Shape
        var input: TriggerInput
        if let classNote = BTTImportMappings.trackpadClasses[cls] {
            guard let gesture = BTTImportMappings.trackpad[type] else { throw ImportError.invalid("Unknown BTT trackpad gesture \(type).") }
            guard let aom = gesture.aom else { throw ImportError.invalid(gesture.gap ?? "AOM has no matching gesture.") }
            if !classNote.isEmpty { out.approximations.append(classNote) }
            if let near = gesture.approximation { out.approximations.append(near) }
            input = .trackpadGesture(aom)
            if aom.isLongTouch, let seconds = try f.number("BTTAdditionalConfiguration", 0.1...5) {
                template.longTouchDurationMs = Int((seconds * 1_000).rounded())
            } else if [.circleClockwise, .circleCounterClockwise].contains(aom), let circles = try f.number("BTTAdditionalConfiguration", 0.5...20),
                      abs(circles - 0.9) > 0.001 {
                out.approximations.append("BTT required \(circles) circle(s); AOM uses its own circle threshold.")
            }
            if aom.isTrackpadScroll, template.requiredModifiers == nil {
                throw ImportError.invalid("BTT scroll gestures need a modifier key, and this one has none.")
            }
            shape = .trackpad
        } else {
            switch cls {
            case "BTTTriggerTypeKeyboardShortcut" where type == 0 || type == -1:
                let shortcut = try keyboardShortcut(f, notes: &out.approximations)
                input = .keyboardShortcut(shortcut)
                shape = .keyboard(shortcut, onDown: try f.flag("BTTTriggerOnDown") ?? true)
                let minimum = try f.number("BTTKeyboardShortcutMinTime", 0...60) ?? 0
                let maximum = try f.number("BTTKeyboardShortcutMaxTime", 0...60) ?? 0
                template.minHoldMs = Int((minimum * 1_000).rounded()); template.maxHoldMs = Int((maximum * 1_000).rounded())
                if template.maxHoldMs > 0 && template.minHoldMs > template.maxHoldMs { throw ImportError.invalid("The minimum hold time exceeds the maximum.") }
            case "BTTTriggerTypeKeySequence" where type == 624, "BTTTriggerTypeKeyboardShortcut" where type == 624:
                input = try keySequence(f, trigger: &template, notes: &out.approximations)
                shape = .sequence
            case "BTTTriggerTypeKeyboardShortcut", "BTTTriggerTypeKeySequence":
                throw ImportError.invalid("BTT keyboard trigger \(type) (\(identity.name)) has no AOM equivalent.")
            case "BTTTriggerTypeNormalMouse":
                let spec = try mouseSpec(type: type)
                input = .mouse(spec)
                shape = .mouse(spec)
                if try f.flag("BTTTriggerOnDown") == true, spec.kind.clickCount != nil {
                    out.approximations.append("BTT fired on mouse up; AOM decides when a click counts.")
                }
                if let device = try f.text("BTTAdditionalConfiguration", maxBytes: 128), device.hasPrefix("Vendor:") {
                    out.approximations.append("BTT limited this to one Logitech mouse (\(cleanLabel(device))); AOM matches any mouse.")
                }
            case "BTTTriggerTypeOtherTriggers":
                input = try otherTrigger(type: type, f, name: identity.name, context: context, notes: &out.approximations)
                shape = .other
            default:
                throw ImportError.invalid("Unknown BTT trigger class \(cleanLabel(cls)).")
            }
        }
        if case .keyboard = shape {} else {
            // These keys only mean something for keyboard shortcuts.
            f.touch(["BTTTriggerOnDown"])
        }
        if case .namedTrigger = input { template.name = "" }
        else { template.name = description == identity.name ? "" : description }

        // Actions: the legacy single action on the trigger, BTTAdditionalActions,
        // BTTActionsToExecute, and dedicated category arrays.
        var groups: [Int: [TriggerAction]] = [:]
        var order: [Int] = []
        var mappedCount = 0, total = 0
        func append(_ category: Int, _ result: ActionResult) throws {
            total += 1
            guard total <= maximumActions else { throw ImportError.invalid("A trigger can hold at most \(maximumActions) actions.") }
            switch result {
            case .nothing: return
            case .controlFlow(let name, let id):
                throw ImportError.invalid("Uses BTT control flow (\(name), action \(id)). A flat AOM action list cannot keep that structure, so nothing was imported.")
            case .dropped(let dropped):
                out.dropped.append(dropped)
                if !order.contains(category) { order.append(category) }
                groups[category, default: []].append(placeholder(dropped))
            case .mapped(let action, let notes, let review):
                mappedCount += 1
                out.approximations += notes
                if let review { out.review.append(review) }
                if !order.contains(category) { order.append(category) }
                groups[category, default: []].append(action)
            }
        }
        let legacyType = try f.integer("BTTPredefinedActionType", -1...100_000)
        if (legacyType != nil && ![-1, 366].contains(legacyType!)) || (f.has("BTTShortcutToSend") && [nil, -1].contains(legacyType)) {
            try append(0, try action(f, context: context, legacy: true))
        }
        for key in ["BTTAdditionalActions", "BTTActionsToExecute"] {
            for item in try f.list(key) ?? [] {
                guard let raw = item as? [String: Any] else { throw ImportError.invalid("\(key) must contain action objects.") }
                let child = Fields(raw)
                let category = try child.integer("BTTActionCategory", 0...1_000) ?? 0
                try append(category, try action(child, context: context, legacy: false))
            }
        }
        for (key, category) in categoryKeys.sorted(by: { $0.value < $1.value }) {
            for item in try f.list(key) ?? [] {
                guard let raw = item as? [String: Any] else { throw ImportError.invalid("\(key) must contain action objects.") }
                try append(category, try action(Fields(raw), context: context, legacy: false))
            }
        }
        guard mappedCount > 0 else {
            if out.dropped.isEmpty { throw ImportError.invalid("The trigger has no actions.") }
            throw ImportError.invalid("No action could be imported: " + out.dropped.map { "\($0.name) (action \($0.id))" }.joined(separator: ", ") + ".")
        }

        // One AOM trigger per BTT action category that AOM can express.
        for category in order {
            guard let actions = groups[category], actions.contains(where: { !$0.isPlaceholder }) else {
                continue
            }
            var trigger = template
            trigger.id = UUID()
            trigger.actions = actions
            switch (shape, category) {
            case (.keyboard(_, let onDown), 0): trigger.input = input; trigger.keyboardPhase = onDown ? .keyDown : .keyUp
            case (.keyboard, 35): trigger.input = input; trigger.keyboardPhase = .keyUp
            case (.keyboard, 36): trigger.input = input; trigger.keyboardPhase = .quickRelease
            case (.keyboard, 38): trigger.input = input; trigger.keyboardPhase = .longPress
            case (.mouse(let spec), 2) where spec.kind == .click:
                trigger.input = .mouse(MouseTriggerSpec(button: spec.button, kind: .longPress))
            case (.mouse(let spec), 21...24) where spec.kind == .click:
                let kinds: [Int: MouseTriggerKind] = [21: .dragDown, 22: .dragUp, 23: .dragLeft, 24: .dragRight]
                trigger.input = .mouse(MouseTriggerSpec(button: spec.button, kind: kinds[category]!))
            case (_, 0): trigger.input = input
            default:
                out.approximations.append("Actions in BTT's “\(categoryName(category))” category were not imported; AOM has no matching phase for this trigger.")
                continue
            }
            if let problem = TriggerValidation.problem(for: trigger) { throw ImportError.invalid(problem) }
            if let problem = ActionTree.problem(trigger.actions) { throw ImportError.invalid(problem) }
            // Merge categories that land on the same AOM phase (e.g. key up twice).
            if let index = out.triggers.firstIndex(where: { $0.input == trigger.input && $0.keyboardPhase == trigger.keyboardPhase }) {
                out.triggers[index].actions += trigger.actions
            } else {
                out.triggers.append(trigger)
            }
        }
        guard !out.triggers.isEmpty else { throw ImportError.invalid("None of the BTT action categories has an AOM equivalent for this trigger.") }
        for trigger in out.triggers {
            // The same validation the preset store applies on save.
            var probe = Preset(name: "BTT import probe")
            probe.triggers = [trigger]
            do { _ = try PresetCodec.decode(PresetCodec.encode(probe)) }
            catch { throw ImportError.invalid("The converted trigger failed AOM validation.") }
        }
        let unknown = f.unused(ignoring: benignTriggerKeys)
        if !unknown.isEmpty { out.approximations.append("BTT setting(s) not imported: \(unknown.joined(separator: ", ")).") }
        return out
    }

    private static func notes(_ original: String, identity: Identity, reasons: [String]) -> String {
        var lines: [String] = []
        if !original.isEmpty { lines += [original, ""] }
        lines.append("Imported from BetterTouchTool: \(identity.name) [\(identity.id)].")
        lines += reasons.map { "• \($0)" }
        return lines.joined(separator: "\n")
    }

    /// BTT modifier flags: generic NSEvent bits plus device bits that tell
    /// left from right. AOM matches modifiers without a side.
    static func modifiers(_ raw: Int, field: String) throws -> (flags: NSEvent.ModifierFlags, notes: [String]) {
        let generic: [UInt: (left: UInt, right: UInt)] = [
            NSEvent.ModifierFlags.control.rawValue: (0x1, 0x2000), NSEvent.ModifierFlags.shift.rawValue: (0x2, 0x4),
            NSEvent.ModifierFlags.command.rawValue: (0x8, 0x10), NSEvent.ModifierFlags.option.rawValue: (0x20, 0x40)
        ]
        let value = UInt(raw)
        let keep = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue
        let implied = NSEvent.ModifierFlags.numericPad.rawValue | NSEvent.ModifierFlags.help.rawValue | 0x100
        let device = generic.values.reduce(UInt(0)) { $0 | $1.left | $1.right }
        let known = keep | implied | device | NSEvent.ModifierFlags.capsLock.rawValue
        guard value & ~known == 0 else { throw ImportError.invalid("\(field) has unknown modifier bits.") }
        var notes: [String] = []
        for (flag, sides) in generic where value & (sides.left | sides.right) != 0 && value & flag == 0 {
            throw ImportError.invalid("\(field) names a left/right modifier without the modifier itself.")
        }
        if value & device != 0 { notes.append("BTT required a specific left or right modifier key; AOM matches either side.") }
        if value & NSEvent.ModifierFlags.capsLock.rawValue != 0 { notes.append("BTT required Caps Lock; AOM ignores Caps Lock.") }
        return (NSEvent.ModifierFlags(rawValue: value & keep), notes)
    }

    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static func keyboardShortcut(_ f: Fields, notes: inout [String]) throws -> KeyboardShortcut {
        let code = try f.integer("BTTShortcutKeyCode", -1...2_000) ?? -1
        if code >= 1_000 { throw ImportError.invalid("BTT special key \(code) (media, volume, brightness or Caps Lock key) has no AOM keyboard trigger.") }
        guard (0...127).contains(code) else { throw ImportError.invalid("The shortcut has no key (BTTShortcutKeyCode \(code)).") }
        guard !modifierKeyCodes.contains(code) else { throw ImportError.invalid("Modifier-only shortcuts have no AOM keyboard trigger.") }
        let raw = try f.integer("BTTShortcutModifierKeys", -1...0xFF_FFFF) ?? 0
        let mods = try modifiers(max(raw, 0), field: "BTTShortcutModifierKeys")
        notes += mods.notes
        if let mode = try f.integer("BTTModifierMode", 0...16), mode != 0 {
            notes.append("BTT used its advanced modifier mode (\(mode)); AOM matches the plain modifier set.")
        }
        if try f.flag("BTTAutoAdaptToKeyboardLayout") == true {
            notes.append("BTT followed the keyboard layout; AOM matches the physical key.")
        }
        if let keyboard = try f.integer("BTTShortcutKeyboardType", Int(Int32.min)...Int(Int32.max)), keyboard != 0 {
            notes.append("BTT limited this shortcut to one keyboard; AOM matches every keyboard.")
        }
        if let scope = try f.integer("BTTShortcutScope", 0...100), scope != 0 {
            notes.append("BTT shortcut scope \(scope) was not imported.")
        }
        f.touch(["BTTAdditionalConfiguration"])
        return KeyboardShortcut(keyCode: UInt16(code), modifiers: mods.flags)
    }

    private static func keySequence(_ f: Fields, trigger: inout Trigger, notes: inout [String]) throws -> TriggerInput {
        guard let sequence = try f.object("BTTKeySequence") else { throw ImportError.invalid("BTTKeySequence is missing.") }
        let s = Fields(sequence)
        func keys(_ key: String) throws -> [Fields] {
            guard let list = try s.list(key) else { return [] }
            guard list.count <= 128 else { throw ImportError.invalid("\(key) is too long.") }
            return try list.map {
                guard let item = $0 as? [String: Any] else { throw ImportError.invalid("\(key) must contain key objects.") }
                return Fields(item)
            }
        }
        let down = try keys("BTTKeySequenceDownKeys")
        let mixed = try keys("BTTKeySequenceMixedKeys")
        _ = try keys("BTTKeySequenceUpKeys")
        let flags: [Int: NSEvent.ModifierFlags] = [54: .command, 55: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control, 62: .control, 63: .function]
        var strokes: [KeySequenceStroke] = []
        var orderFlags = Set<Bool>()
        var held: [Int: NSEvent.ModifierFlags] = [:]
        for key in mixed.isEmpty ? down : mixed {
            let code = try key.integer("BTTKEYCode", 0...127) ?? -1
            guard code >= 0 else { throw ImportError.invalid("Each sequence key needs a BTTKEYCode.") }
            let isDown: Bool
            if mixed.isEmpty { isDown = true } else { isDown = try key.flag("BTTKEYDown") ?? false }
            let required = try key.flag("BTTKEYRequired") ?? true
            _ = try key.text("BTTKEYCharacter", maxBytes: 64)
            _ = try key.number("BTTKEYTime", -1e12...1e12)
            if !isDown { held[code] = nil; continue }
            if let ordered = try key.flag("BTTKEYOrderRelevant") { orderFlags.insert(ordered) }
            let modifiers = modifierKeyCodes.contains(code) ? 0 : held.values.reduce(NSEvent.ModifierFlags()) { $0.union($1) }.rawValue
            strokes.append(KeySequenceStroke(keyCode: UInt16(code), modifiers: modifiers, isRequired: required))
            if let flag = flags[code] { held[code] = flag }
        }
        guard (1...6).contains(strokes.count) else {
            throw ImportError.invalid("AOM key sequences have 1–6 key presses; this one has \(strokes.count).")
        }
        guard strokes.contains(where: \.isRequired) else { throw ImportError.invalid("Every key of this sequence is optional.") }
        trigger.sequenceOrderRelevant = !orderFlags.contains(false) || orderFlags.contains(true)
        if orderFlags.count > 1 { notes.append("BTT mixed ordered and unordered keys; AOM keeps the order for the whole sequence.") }
        if let pause = try s.number("BTTPauseBetween", 0...600) {
            let ms = Int((pause * 1_000).rounded())
            trigger.sequenceMaxGapMs = min(max(ms, 100), 2_000)
            if trigger.sequenceMaxGapMs != ms { notes.append("BTT allowed \(ms) ms between keys; AOM allows \(trigger.sequenceMaxGapMs) ms.") }
        }
        _ = try s.integer("BTTKeyCount", 0...1_000)
        _ = try s.integer("BTTKeyboardType", Int(Int32.min)...Int(Int32.max))
        let unknown = s.unused(ignoring: [])
        if !unknown.isEmpty { notes.append("Key sequence setting(s) not imported: \(unknown.joined(separator: ", ")).") }
        if let count = try f.integer("BTTCharactersToDeleteAfterwards", 0...1_000), count > 0 {
            notes.append("BTT deleted the \(count) typed character(s) afterwards; AOM does not.")
        }
        _ = try f.number("BTTKeySequenceDeleteAfterwardsDelay", 0...60)
        f.touch(["BTTShortcutKeyCode", "BTTShortcutModifierKeys", "BTTAutoAdaptToKeyboardLayout", "BTTModifierMode", "BTTAdditionalConfiguration"])
        return .keySequence(strokes)
    }

    private static func mouseSpec(type: Int) throws -> MouseTriggerSpec {
        switch type {
        case 996: return MouseTriggerSpec(button: 0, kind: .scrollDown)
        case 997: return MouseTriggerSpec(button: 0, kind: .scrollUp)
        case 998: return MouseTriggerSpec(button: 0, kind: .scrollLeft)
        case 999: return MouseTriggerSpec(button: 0, kind: .scrollRight)
        case 1324, 1347: throw ImportError.invalid("BTT mouse device configurations have no AOM equivalent.")
        case 1050, 1150, 1250, 1350: throw ImportError.invalid("AOM has no Logitech thumb wheel touch trigger.")
        case 1300...1399: throw ImportError.invalid("AOM recognizes up to triple clicks.")
        case 1000...1299:
            let button = (type - 1000) % 100
            guard button <= MouseTriggerSpec.maxButton else { throw ImportError.invalid("AOM supports mouse buttons 1–\(MouseTriggerSpec.maxButton + 1).") }
            let kinds: [MouseTriggerKind] = [.click, .doubleClick, .tripleClick]
            return MouseTriggerSpec(button: button, kind: kinds[(type - 1000) / 100])
        default: throw ImportError.invalid("Unknown BTT mouse trigger \(type).")
        }
    }

    private static func otherTrigger(type: Int, _ f: Fields, name: String, context: Context, notes: inout [String]) throws -> TriggerInput {
        if let event = BTTImportMappings.simpleSystemEvents[type] { return .systemEvent(event) }
        func appID() throws -> String? {
            guard let raw = try f.text("BTTAdditionalConfiguration", maxBytes: 1_024)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            if !raw.contains("/"), isBundleIdentifier(raw) { return raw }
            let path = try localPath(raw, field: "BTTAdditionalConfiguration")
            guard let id = context.appBundleID(URL(fileURLWithPath: path)), isBundleIdentifier(id) else {
                throw ImportError.invalid("The app \((path as NSString).lastPathComponent) is not installed, so its bundle identifier is unknown.")
            }
            return id
        }
        func filter(_ key: String) throws -> String {
            guard let raw = try f.text(key, maxBytes: 256)?.trimmingCharacters(in: .whitespaces), raw != "*" else { return "" }
            return cleanLabel(raw)
        }
        switch type {
        case 643:
            let named = try strictLabel(f.value("BTTTriggerName"), field: "BTTTriggerName")
            if f.has("BTTCustomContextMenuItemConfig") {
                _ = try f.object("BTTCustomContextMenuItemConfig")
                notes.append("Named-trigger variables are not imported; AOM named triggers take no parameters.")
            }
            _ = try f.text("BTTNamedTriggerAIDescription", maxBytes: 4_096, multiline: true)
            _ = try f.flag("BTTNamedTriggerAIAllow")
            return .namedTrigger(named)
        case 706, 707:
            guard let text = try f.text("BTTAdditionalConfiguration", maxBytes: 16), let percent = Int(text.trimmingCharacters(in: .whitespaces)),
                  (1...99).contains(percent) else { throw ImportError.invalid("The battery threshold must be 1–99 %.") }
            return .systemEvent(type == 706 ? .batteryBelow(percent) : .batteryAbove(percent))
        case 688, 689:
            let ssid = try filter("BTTWifiName")
            return .systemEvent(type == 688 ? .wifiConnected(ssid: ssid) : .wifiDisconnected(ssid: ssid))
        case 789:
            let variable = try f.text("BTTAdditionalConfiguration", maxBytes: 256)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard variable.isEmpty || isAOMVariableName(variable, maximum: 64) else {
                throw ImportError.invalid("AOM variable names use letters, digits and underscores only.")
            }
            return .systemEvent(.variableChanged(name: variable))
        case 687:
            if try !filter("BTTInputSourceName").isEmpty { notes.append("BTT watched one input source; AOM fires on every input source change.") }
            return .systemEvent(.inputSourceChanged)
        case 785, 786, 787, 788:
            var pattern = try f.text("BTTUSBDeviceName", maxBytes: 256)?.trimmingCharacters(in: .whitespaces) ?? ""
            let original = pattern
            for prefix in ["^", ".*"] where pattern.hasPrefix(prefix) { pattern.removeFirst(prefix.count) }
            for suffix in ["$", ".*"] where pattern.hasSuffix(suffix) { pattern.removeLast(suffix.count) }
            if pattern.contains(where: { "\\^$.*+?()[]{}|".contains($0) }) {
                throw ImportError.invalid("BTT matched the device with a regular expression that AOM's name filter cannot express.")
            }
            if pattern != original { notes.append("BTT matched “\(original)” as a regular expression; AOM matches the name “\(pattern)” as plain text.") }
            if ["BTTUSBDeviceSerial", "BTTUSBDeviceVendorID", "BTTUSBDeviceProductID"].contains(where: f.has) {
                f.touch(["BTTUSBDeviceSerial", "BTTUSBDeviceVendorID", "BTTUSBDeviceProductID"])
                notes.append("BTT also matched serial number or vendor/product ID; AOM matches the device name only.")
            }
            let name = cleanLabel(pattern)
            switch type {
            case 785: return .systemEvent(.usbConnected(name: name))
            case 786: return .systemEvent(.usbDisconnected(name: name))
            case 787: return .systemEvent(.bluetoothConnected(name: name))
            default: return .systemEvent(.bluetoothDisconnected(name: name))
            }
        case 792, 793:
            f.touch(["BTTAdditionalConfiguration"])
            notes.append("AOM fires when any display connects or disconnects.")
            return .systemEvent(.displayChanged)
        case 609, 610, 611, 612:
            let corners: [Int: ScreenCorner] = [609: .topLeft, 610: .topRight, 611: .bottomLeft, 612: .bottomRight]
            return .systemEvent(.screenCornerHover(corner: corners[type]!, dwellMs: try dwell(f, notes: &notes)))
        case 768, 770, 660, 661:
            let edges: [Int: (ScreenEdge, String)] = [768: (.left, "Left"), 770: (.right, "Right"), 660: (.bottom, "Bottom"), 661: (.top, "Top")]
            let edge = edges[type]!
            let distance = try f.integer("BTTMoveTo\(edge.1)ScreenEdgeMinDistance", 0...500) ?? SystemTriggerKind.defaultEdgeDistancePx
            return .systemEvent(.screenEdgeHover(edge: edge.0, dwellMs: try dwell(f, notes: &notes), minDistance: distance))
        case 670, 673:
            guard let id = try appID() else { throw ImportError.invalid("AOM app launch and quit triggers need one specific app.") }
            return .systemEvent(type == 670 ? .appLaunched(id) : .appQuit(id))
        case 671, 672:
            let id = try appID() ?? ""
            return .systemEvent(type == 671 ? .appActivated(id) : .appDeactivated(id))
        case 807:
            guard let raw = try f.text("BTTGenericActionConfig", maxBytes: 4_096) else { throw ImportError.invalid("The watched path is missing.") }
            let paths = raw.components(separatedBy: ";;").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard paths.count == 1 else { throw ImportError.invalid("AOM watches one file or folder per trigger; BTT watched \(paths.count).") }
            let path = try localPath(paths[0], field: "BTTGenericActionConfig")
            if let change = try f.integer("BTTFileChangeType", 0...9), change != 0 {
                notes.append("BTT watched one kind of change (\(change)); AOM fires on every change.")
            }
            return .systemEvent(.fileDidChange(path: path))
        case 678:
            return .systemEvent(try timed(f))
        default:
            throw ImportError.invalid("AOM has no trigger like BTT's “\(name)”.")
        }
    }
    private static func dwell(_ f: Fields, notes: inout [String]) throws -> Int {
        if try f.flag("BTTAllowDragging") == true { notes.append("BTT also fired while a mouse button was held; AOM's behavior while dragging may differ.") }
        guard let seconds = try f.number("BTTRepeatDelay", 0...10) else {
            notes.append("BTT set no delay; AOM waits \(SystemTriggerKind.defaultHoverDwellMs) ms.")
            return SystemTriggerKind.defaultHoverDwellMs
        }
        return Int((seconds * 1_000).rounded())
    }
    /// Date/Time Based triggers: a whole-minute interval, or a fixed hour and
    /// minute (second 0) on every day or on listed weekdays.
    private static func timed(_ f: Fields) throws -> SystemTriggerKind {
        guard let config = try f.object("BTTAdditionalConfiguration") else { throw ImportError.invalid("The time settings are missing.") }
        let t = Fields(config)
        let mode = try t.integer("BTTTimedWhenToTrigger", 0...1) ?? 0
        if mode == 0 {
            let seconds = try t.number("BTTTimedRepeatEveryXSeconds", 0.3...31_536_000) ?? 0
            guard seconds.truncatingRemainder(dividingBy: 60) == 0, (1...1_440).contains(Int(seconds) / 60) else {
                throw ImportError.invalid("AOM repeats in whole minutes (1–1440); BTT repeated every \(seconds) s.")
            }
            return .everyMinutes(Int(seconds) / 60)
        }
        func field(_ key: String) throws -> String? {
            guard let value = t.value(key) else { return nil }
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
            guard let text = value as? String, text.utf8.count <= 64 else { throw ImportError.invalid("\(key) must be a number or a short pattern.") }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed == "*" ? nil : trimmed
        }
        guard let hourText = try field("BTTTimedHour"), let hour = Int(hourText), (0...23).contains(hour),
              let minuteText = try field("BTTTimedMinute"), let minute = Int(minuteText), (0...59).contains(minute),
              let secondText = try field("BTTTimedSecond"), Int(secondText) == 0 else {
            throw ImportError.invalid("AOM schedules need one fixed hour, minute and second 0.")
        }
        for key in ["BTTTimedDay", "BTTTimedMonth", "BTTTimedYear"] {
            if try field(key) != nil { throw ImportError.invalid("AOM schedules repeat daily or weekly; BTT limited the day, month or year.") }
        }
        guard let weekdays = try field("BTTTimedWeekday") else { return .daily(hour: hour, minute: minute) }
        var days = Set<Int>()
        for part in weekdays.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(bounds.count), bounds.allSatisfy({ (0...6).contains($0) }), bounds.first! <= bounds.last! else {
                throw ImportError.invalid("Unsupported weekday pattern “\(cleanLabel(weekdays))”.")
            }
            days.formUnion((bounds.first!...bounds.last!).map { $0 + 1 }) // BTT 0 = Sunday, AOM 1 = Sunday.
        }
        return .weekly(days: days.sorted(), hour: hour, minute: minute)
    }

    // MARK: Action conversion

    private enum ActionResult {
        case mapped(TriggerAction, notes: [String], review: String?)
        case dropped(Dropped)
        case nothing
        case controlFlow(name: String, id: Int)
    }
    static let placeholderPrefix = "Not imported from BetterTouchTool: "
    /// A disabled, harmless step that marks where a BTT action was.
    private static func placeholder(_ dropped: Dropped) -> TriggerAction {
        var parameters = ActionParameters()
        parameters.hudText = placeholderPrefix + "\(dropped.name) (action \(dropped.id))"
        parameters.label = "Not imported: \(dropped.name) (BTT \(dropped.id))"
        parameters.notes = dropped.reason
        var action = TriggerAction(actionType: .showHUD, parameters: parameters)
        action.isEnabled = false
        return action
    }

    private static func action(_ f: Fields, context: Context, legacy: Bool) throws -> ActionResult {
        let rawType = try f.integer("BTTPredefinedActionType", -1...100_000)
        let id = rawType ?? -1
        let givenName = try f.text("BTTPredefinedActionName", maxBytes: 1_024).map(cleanLabel).flatMap { $0.isEmpty ? nil : $0 }
        let enabled = try (f.flag("BTTEnabled") ?? true) && (f.flag("BTTEnabled2") ?? true)
        if !legacy { _ = try f.integer("BTTActionCategory", 0...1_000) }
        let name = (BTTImportMappings.actions[id].map(\.name) ?? givenName) ?? BTTImportMappings.actionName(id)
        var notes: [String] = []
        var review: String?
        func drop(_ reason: String) -> ActionResult { .dropped(Dropped(name: givenName ?? name, id: id, reason: reason)) }

        let built: TriggerAction?
        if id == -1, f.has("BTTShortcutToSend") {
            built = try shortcutAction(f, notes: &notes)
        } else if let rule = BTTImportMappings.actions[id]?.rule {
            switch rule {
            case .noOp: return .nothing
            case .controlFlow: return .controlFlow(name: name, id: id)
            case .unsupported(let why): return drop(why)
            case .exact(let type): built = TriggerAction(actionType: type)
            case .approximate(let type, let why): notes.append("\(name): \(why)"); built = TriggerAction(actionType: type)
            case .custom:
                switch try customAction(id, name: name, f, context: context, notes: &notes, review: &review) {
                case .some(let action): built = action
                case .none: return drop(notes.popLast() ?? BTTImportMappings.noAction)
                }
            }
        } else if let key = BTTImportMappings.functionKeys[id] {
            var p = ActionParameters(); p.functionKeyNumber = key
            built = TriggerAction(actionType: .pressFunctionKey, parameters: p)
        } else if let modifier = BTTImportMappings.modifierKeyActions[id] {
            var p = ActionParameters(); p.modifierKey = modifier.key
            built = TriggerAction(actionType: modifier.down ? .modifierKeyDown : .modifierKeyUp, parameters: p)
        } else if let desktop = BTTImportMappings.desktopSwitch[id] {
            var p = ActionParameters(); p.desktopNumber = desktop
            built = TriggerAction(actionType: .switchToDesktop, parameters: p)
        } else if (226...235).contains(id) {
            return drop("AOM switches to Desktops 1–9 only.")
        } else if (305...308).contains(id) {
            return drop("AOM presses F1–F20 only.")
        } else if BTTImportMappings.moveToDesktop(id) != nil {
            return drop("AOM moves windows to the next or previous Space only, not to Desktop N.")
        } else {
            return drop(rawType == nil ? "The action has no BTTPredefinedActionType." : "Unknown or unsupported BTT action.")
        }
        guard var result = built else { return drop(notes.popLast() ?? BTTImportMappings.noAction) }
        if let delay = try (id == 129 || id == 345) ? nil : f.number("BTTDelayNextActionBy", 0...86_400), delay > 0 {
            let ms = Int((delay * 1_000).rounded())
            result.parameters.delayAfterMs = min(ms, 60_000)
            if ms > 60_000 { notes.append("\(name): BTT waited \(ms / 1_000) s afterwards; AOM waits at most 60 s.") }
        }
        if !legacy {
            let unknown = f.unused(ignoring: benignActionKeys)
            if !unknown.isEmpty { notes.append("\(name): BTT setting(s) not imported: \(unknown.joined(separator: ", ")).") }
        }
        if let problem = ActionParameterValidation.problem(for: result) { throw ImportError.invalid("\(name): \(problem)") }
        result.isEnabled = enabled && review == nil
        return .mapped(result, notes: notes, review: review)
    }

    /// `BTTShortcutToSend`: descending modifier key codes, then one key code.
    private static func shortcutAction(_ f: Fields, notes: inout [String]) throws -> TriggerAction? {
        guard let text = try f.text("BTTShortcutToSend", maxBytes: 64) else { throw ImportError.invalid("BTTShortcutToSend must be comma-separated key codes.") }
        let components = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let codes = components.compactMap(Int.init)
        guard !codes.isEmpty, codes.count <= 6, codes.count == components.count, codes.allSatisfy({ (0...127).contains($0) }) else {
            throw ImportError.invalid("Invalid BTTShortcutToSend key codes.")
        }
        let mapping: [Int: NSEvent.ModifierFlags] = [55: .command, 54: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control, 62: .control, 63: .function]
        let mods = Array(codes.dropLast())
        guard Set(mods).count == mods.count, mods == mods.sorted(by: >), mods.allSatisfy({ mapping[$0] != nil }) else {
            throw ImportError.invalid("Shortcut modifiers must be modifier key codes in descending order.")
        }
        guard !modifierKeyCodes.contains(codes.last!) else {
            notes.append("AOM cannot send a modifier key on its own.")
            return nil
        }
        if mods.contains(where: { [54, 60, 61, 62].contains($0) }) { notes.append("BTT sent a right-side modifier; AOM sends the plain modifier.") }
        if let upDown = try f.text("BTTShortcutUpDown", maxBytes: 32), !upDown.isEmpty {
            notes.append("AOM always sends the full key press; BTT sent \(upDown == "onlyDown" ? "only the key down" : upDown == "onlyUp" ? "only the key up" : "a partial key press").")
            return nil
        }
        if let data = try f.object("BTTAdditionalActionData") {
            let extra = Fields(data)
            if try extra.flag("BTTActionSendKeyboardShortcutIncludeCurrentModifiers") == true {
                notes.append("BTT added the modifier keys you were holding; AOM sends exactly the recorded shortcut.")
            }
            if try extra.flag("BTTActionSendKeyboardShortcutLowLevel") == true {
                notes.append("BTT sent the shortcut at the HID level; AOM posts it at the session level.")
            }
            let unknown = extra.unused(ignoring: [])
            if !unknown.isEmpty { notes.append("Shortcut setting(s) not imported: \(unknown.joined(separator: ", ")).") }
        }
        if try f.flag("BTTAutoAdaptActionToKeyboardLayout") == true { notes.append("BTT adapted the sent key to the keyboard layout; AOM sends the key code.") }
        f.touch(["BTTShortcutModifierKeys", "BTTLayoutIndependentActionChar"])
        var p = ActionParameters()
        p.shortcutKeyCode = UInt16(codes.last!)
        p.shortcutModifiers = mods.reduce(UInt(0)) { $0 | mapping[$1]!.rawValue }
        return TriggerAction(actionType: .sendKeyStroke, parameters: p)
    }

    private static func script(_ f: Fields, kind expected: Int) throws -> String? {
        let data = try f.object("BTTAdditionalActionData")
        let extra = data.map(Fields.init)
        if let extra {
            if try extra.flag("BTTAppleScriptUsePath") == true { return nil }
            if let location = try extra.integer("BTTScriptLocation", 0...10), location != 0 { return nil }
            if let type = try extra.integer("BTTScriptType", 0...10), type != expected { return nil }
            _ = try extra.flag("BTTAppleScriptRunInBackground")
            _ = try extra.text("BTTScriptFunctionToCall", maxBytes: 256)
        }
        let source = try extra?.text("BTTAppleScriptString", maxBytes: maximumScriptBytes, multiline: true)
            ?? f.text("BTTInlineAppleScript", maxBytes: maximumScriptBytes, multiline: true)
            ?? f.text("BTTAppleScriptString", maxBytes: maximumScriptBytes, multiline: true)
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return source
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func customAction(_ id: Int, name: String, _ f: Fields, context: Context,
                                     notes: inout [String], review: inout String?) throws -> TriggerAction? {
        var p = ActionParameters()
        func make(_ type: ActionType) -> TriggerAction { TriggerAction(actionType: type, parameters: p) }
        func level(_ key: String) throws -> Double {
            guard let value = try f.number(key, 0...100) else { throw ImportError.invalid("\(name): \(key) must be 0–100.") }
            return value
        }
        switch id {
        case 111:
            p.clickButton = 0; p.clickCount = 1; p.clickModifiers = NSEvent.ModifierFlags([.command, .shift]).rawValue
            return make(.customClick)
        case 193, 118:
            guard let text = try f.text("BTTStringToType", maxBytes: maximumTextBytes, multiline: true), !text.isEmpty else {
                throw ImportError.invalid("\(name): BTTStringToType is missing.")
            }
            p.text = text
            if let move = try f.integer("BTTMoveCursorLeftBy", 0...10_000), move > 0 { notes.append("\(name): BTT moved the cursor back \(move) character(s); AOM does not.") }
            if text.contains("{date:") || text.contains("(BTT)@dateformat:") { notes.append("\(name): AOM types BTT date placeholders literally.") }
            return make(id == 193 ? .typeText : .pasteString)
        case 264:
            return try shortcutAction(f, notes: &notes)
        case 128:
            guard var action = try shortcutAction(f, notes: &notes) else { return nil }
            let target = try f.text("BTTShortcutAppUnderCursor", maxBytes: 256)?.trimmingCharacters(in: .whitespaces)
            if target == "app under mouse cursor" {
                notes.append("AOM cannot send a shortcut to the app under the pointer."); return nil
            } else if target == "active app" {
                _ = try f.text("BTTShortcutApp", maxBytes: 1_024)
            } else if let target, !target.isEmpty {
                guard isBundleIdentifier(target) else { throw ImportError.invalid("\(name): invalid target app.") }
                action.parameters.targetApplicationBundleID = target
            } else if let path = try f.text("BTTShortcutApp", maxBytes: 1_024), !path.isEmpty, path != "active app" {
                let resolved = try localPath(path, field: "BTTShortcutApp")
                guard let bundle = context.appBundleID(URL(fileURLWithPath: resolved)) else {
                    notes.append("The target app \((resolved as NSString).lastPathComponent) is not installed."); return nil
                }
                action.parameters.targetApplicationBundleID = bundle
            }
            if try f.flag("BTTShortcutSwitchToAppFirst") == true, action.parameters.targetApplicationBundleID != nil {
                notes.append("\(name): BTT switched to the app first; AOM sends the shortcut without bringing the app forward.")
            }
            return action
        case 189: p.shortcutKeyCode = 53; p.shortcutModifiers = 0; return make(.sendKeyStroke)
        case 64: p.shortcutKeyCode = 117; p.shortcutModifiers = 0; return make(.sendKeyStroke)
        case 107: p.windowTarget = "underCursor"; return make(.zoomWindow)
        case 112: p.windowTarget = "focused"; return make(.toggleFullscreenWindow)
        case 58: p.url = TextActionSupport.defaultSearchURL; return make(.searchSelectedText)
        case 10: p.applicationName = "com.apple.finder"; return make(.launchApplication)
        case 49:
            guard let raw = try f.text("BTTLaunchPath", maxBytes: 1_024)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                throw ImportError.invalid("\(name): BTTLaunchPath is missing.")
            }
            if !raw.contains("/"), isBundleIdentifier(raw) { p.applicationName = raw; return make(.launchApplication) }
            let path = try localPath(raw, field: "BTTLaunchPath")
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "app" { p.applicationPath = path; return make(.launchApplication) }
            p.filePath = path
            let runnable: Set<String> = ["command", "sh", "zsh", "bash", "tool", "scpt", "scptd", "applescript", "workflow",
                                         "terminal", "py", "rb", "pl", "js", "jxa", "pkg", "mpkg", "shortcut", "action"]
            if runnable.contains(ext) || ext.isEmpty {
                review = "\(name) opens “\((path as NSString).lastPathComponent)”, which can run code. Imported disabled — check it before enabling."
            }
            return make(.openFileOrFolder)
        case 177:
            guard let app = try f.text("BTTAppToShowOrHide", maxBytes: 1_024)?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
                throw ImportError.invalid("\(name): BTTAppToShowOrHide is missing.")
            }
            if app.contains("/") { p.applicationName = try localPath(app, field: "BTTAppToShowOrHide") } else { p.applicationName = app }
            if let config = try f.object("BTTGenericActionConfig2") {
                let c = Fields(config)
                if try c.flag("showIfHidden") == false || c.flag("hideIfVisible") == false {
                    notes.append("\(name): AOM always toggles between showing and hiding.")
                }
            }
            _ = try f.text("BTTShowHideAppConfig", maxBytes: 4_096)
            return make(.toggleApplication)
        case 592:
            guard let app = try f.text("BTTAppToQuit", maxBytes: 1_024)?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
                throw ImportError.invalid("\(name): BTTAppToQuit is missing.")
            }
            if app.contains("/") { p.applicationName = try localPath(app, field: "BTTAppToQuit") } else { p.applicationName = app }
            if let config = try f.object("BTTQuitAppConfig") {
                let c = Fields(config)
                if try c.flag("BTTQuitAppForceQuit") == true {
                    guard isBundleIdentifier(app) else { notes.append("AOM force quits apps by bundle identifier only."); return nil }
                    notes.append("\(name): AOM asks for confirmation before force quitting.")
                    return make(.forceQuitApplication)
                }
                if let timeout = try c.number("BTTQuitAppForceQuitTimeout", 0...3_600), timeout > 0 {
                    notes.append("\(name): AOM does not force quit after a timeout.")
                }
            }
            return make(.quitApplication)
        case 198, 199:
            p.volumeStepPercent = 1.5625
            notes.append("\(name): AOM uses a 1.5625-point volume step.")
            return make(id == 198 ? .volumeUp : .volumeDown)
        case 373: p.levelPercent = try level("BTTGenericActionConfig"); return make(.setVolume)
        case 370: p.levelPercent = try level("BTTGenericActionConfig"); return make(.setBrightness)
        case 583, 584:
            let c = Fields(try f.object("BTTAdditionalActionData") ?? [:])
            if let mode = try c.integer("BTTAudioDeviceSwitchMode", 0...1), mode == 1 { notes.append("AOM cannot cycle through a device list."); return nil }
            _ = try c.text("BTTAudioDeviceCycleList", maxBytes: 4_096, multiline: true)
            let deviceName = try c.text("BTTAudioDeviceName", maxBytes: 256)
            let uid = try c.text("BTTAudioDeviceUID", maxBytes: 512)
            if let pin = try c.integer("BTTAudioDevicePinMode", 0...1), pin == 1 { notes.append("\(name): AOM does not pin the device as default.") }
            if id == 583 {
                guard deviceName?.isEmpty == false || uid?.isEmpty == false else { throw ImportError.invalid("\(name): no device given.") }
                p.audioOutputName = deviceName.map(cleanLabel); p.audioOutputUID = uid
                return make(.setSoundOutput)
            }
            guard let uid, !uid.isEmpty else { notes.append("AOM selects input devices by UID, and none was given."); return nil }
            p.audioInputUID = uid
            return make(.setSoundInput)
        case 582:
            let extra = Fields(try f.object("BTTAdditionalActionData") ?? [:])
            guard let raw = try extra.text("BTTPlaySoundCustomPath", maxBytes: 1_024) ?? f.text("BTTGenericActionConfig", maxBytes: 1_024), !raw.isEmpty else {
                throw ImportError.invalid("\(name): the sound file path is missing.")
            }
            p.filePath = try localPath(raw, field: "BTTGenericActionConfig"); p.levelPercent = 100
            return make(.playSoundFile)
        case 480:
            if let data = try f.object("BTTAdditionalActionData"), !data.isEmpty { notes.append("\(name): BTT clipboard manager options were not imported.") }
            return make(.showClipboardHistory)
        case 529:
            let c = Fields(try f.object("BTTAdditionalActionData") ?? [:])
            guard (try c.text("BTTActionSetClipboardContentsFormat", maxBytes: 8) ?? "0") == "0" else { notes.append("AOM copies plain text only, not BTT rich text."); return nil }
            guard let text = try c.text("BTTActionSetClipboardContentsAttributedString", maxBytes: maximumTextBytes, multiline: true) else {
                throw ImportError.invalid("\(name): no text given.")
            }
            p.text = text
            return make(.copyTextToClipboard)
        case 256:
            guard let variable = try f.text("BTTVariableName", maxBytes: 256), isAOMVariableName(variable, maximum: 58) else {
                throw ImportError.invalid("\(name): AOM variable names use up to 58 letters, digits and underscores.")
            }
            p.variableName = variable
            return make(.saveSelectedText)
        case 292:
            guard let variable = try f.text("BTTVariableName", maxBytes: 256), isAOMVariableName(variable, maximum: 64) else {
                throw ImportError.invalid("\(name): AOM variable names use up to 64 letters, digits and underscores.")
            }
            p.variableName = variable
            p.variableValue = try f.text("BTTVariableValue", maxBytes: 16_384, multiline: true) ?? ""
            if try f.flag("BTTVariablePersist") == true { notes.append("\(name): BTT kept the variable across restarts; check that the AOM workflow variable is kept the way you need.") }
            if try f.flag("BTTVariableOnlySetIfNotYetDefined") == true { notes.append("\(name): AOM always sets the value.") }
            _ = try f.integer("BTTVariableType", 0...1)
            return make(.setVariable)
        case 172, 195:
            guard let source = try script(f, kind: 0) else { notes.append("The AppleScript is stored in a file or uses another language."); return nil }
            p.scriptContent = source; p.scriptTimeoutSeconds = 30
            if id == 195 { notes.append("\(name): AOM waits for the script to finish (up to 30 s).") }
            review = "\(name) imported disabled. Read the AppleScript before enabling it."
            return make(.runAppleScript)
        case 252, 253:
            guard let source = try script(f, kind: 1) else { notes.append("The JavaScript is stored in a file or uses another language."); return nil }
            p.scriptContent = source; p.scriptTimeoutSeconds = 30
            notes.append("\(name): AOM runs it as JavaScript for Automation; BTT-only functions such as returnToBTT are not available.")
            review = "\(name) imported disabled. Read the script before enabling it."
            return make(.runJavaScript)
        case 246, 137:
            guard let command = try f.text("BTTTerminalCommand", maxBytes: maximumScriptBytes, multiline: true),
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.invalid("\(name): BTTTerminalCommand is missing.") }
            p.scriptContent = command; p.scriptTimeoutSeconds = 30
            notes.append("\(name): AOM runs the command with /bin/zsh\(id == 137 ? " and waits for it to finish (up to 30 s)" : "").")
            review = "\(name) imported disabled. Read the shell command before enabling it."
            return make(.runShellScript)
        case 206:
            guard let source = try f.text("BTTShellTaskActionScript", maxBytes: maximumScriptBytes, multiline: true),
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.invalid("\(name): BTTShellTaskActionScript is missing.") }
            let config = (try f.text("BTTShellTaskActionConfig", maxBytes: 4_096, multiline: true) ?? "/bin/bash:::-c:::-:::").components(separatedBy: ":::")
            let launch = config.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let arguments = config.count > 1 ? config[1].trimmingCharacters(in: .whitespaces) : ""
            let environment = config.count > 3 ? config[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard ["/bin/bash", "/bin/zsh", "/bin/sh"].contains(launch), ["", "-c"].contains(arguments) else {
                notes.append("AOM runs shell scripts with /bin/zsh only; BTT used “\(cleanLabel(launch)) \(cleanLabel(arguments))”."); return nil
            }
            p.scriptContent = source; p.scriptTimeoutSeconds = 30
            if launch != "/bin/zsh" { notes.append("\(name): AOM runs it with /bin/zsh instead of \(launch).") }
            if !environment.isEmpty { notes.append("\(name): BTT environment variables were not imported.") }
            review = "\(name) imported disabled. Read the shell script before enabling it."
            return make(.runShellScript)
        case 295:
            let c = Fields(try f.object("BTTAdditionalActionData") ?? [:])
            guard let shortcut = try c.text("BTTFormAppleShortcutName", maxBytes: 512), !shortcut.isEmpty else { throw ImportError.invalid("\(name): no shortcut name.") }
            p.shortcutName = cleanLabel(shortcut); p.scriptTimeoutSeconds = 60
            if let input = try c.text("BTTShortcutInput", maxBytes: maximumTextBytes, multiline: true), !input.isEmpty { notes.append("\(name): the shortcut input was not imported.") }
            review = "\(name) imported disabled. A Shortcut can run any action; check “\(p.shortcutName!)” before enabling."
            return make(.runAppleShortcut)
        case 248:
            p.namedTriggerName = try strictLabel(f.value("BTTNamedTriggerToTrigger"), field: "BTTNamedTriggerToTrigger")
            if let data = try f.object("BTTAdditionalActionData"), !data.isEmpty {
                notes.append("\(name) “\(p.namedTriggerName!)”: variables passed to the named trigger were not imported.")
            }
            return make(.triggerNamedTrigger)
        case 502:
            if let uuid = try f.text("BTTDisableTriggerForUUID", maxBytes: 64), !uuid.isEmpty { notes.append("AOM pauses all triggers, not one BTT trigger UUID."); return nil }
            guard let seconds = try f.number("BTTDisableTriggerForXSeconds", 0.1...86_400) else { throw ImportError.invalid("\(name): the duration is missing.") }
            p.pauseSeconds = seconds
            return make(.disableTriggersForSeconds)
        case 129, 345:
            let seconds = try f.number("BTTDelayNextActionBy", 0...86_400) ?? 0
            guard seconds <= 60 else { notes.append("AOM waits at most 60 s; BTT waited \(Int(seconds)) s."); return nil }
            p.waitMs = Int((seconds * 1_000).rounded())
            return make(.wait)
        case 254:
            let data = try f.object("BTTAdditionalActionData") ?? f.object("BTTHUDActionConfiguration") ?? [:]
            let c = Fields(data)
            let title = try c.text("BTTActionHUDTitle", maxBytes: 4_096, multiline: true) ?? ""
            let detail = try c.text("BTTActionHUDDetail", maxBytes: 4_096, multiline: true) ?? ""
            _ = try c.text("BTTActionHUDAttributedTitle", maxBytes: maximumTextBytes, multiline: true)
            guard !(title + detail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.invalid("\(name): the HUD has no text.") }
            p.hudText = [title, detail].filter { !$0.isEmpty }.joined(separator: " — ")
            if !c.unused(ignoring: []).isEmpty { notes.append("\(name): BTT HUD style, position and duration were not imported.") }
            return make(.showHUD)
        case 371:
            let c = Fields(try f.object("BTTAdditionalActionData") ?? [:])
            p.notificationTitle = try c.text("BTTActionSendNotificationTitle", maxBytes: 1_024).map(cleanLabel) ?? "BetterTouchTool"
            p.text = try c.text("BTTActionSendNotificationMessage", maxBytes: 16_384, multiline: true) ?? ""
            for key in ["BTTActionSendNotificationSubTitle", "BTTActionSendNotificationSound", "BTTActionSendNotificationAttachment"] {
                if let value = try c.text(key, maxBytes: 1_024), !value.isEmpty { notes.append("\(name): \(key.dropFirst("BTTActionSendNotification".count).lowercased()) was not imported.") }
            }
            return make(.showNotification)
        case 136:
            guard let notification = try f.text("BTTPostDistributedNotificationName", maxBytes: 200), !notification.isEmpty else {
                throw ImportError.invalid("\(name): the notification name is missing.")
            }
            p.notificationName = notification
            if f.has("BTTActionUserInfo") { f.touch(["BTTActionUserInfo"]); notes.append("\(name): the notification user info was not imported.") }
            return make(.postDistributedNotification)
        case 124:
            guard let path = try f.text("BTTMenubarPath", maxBytes: 300), !path.isEmpty else { throw ImportError.invalid("\(name): BTTMenubarPath is missing.") }
            p.menuPath = path.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " > ")
            guard !MenuPath.components(p.menuPath!).isEmpty else { throw ImportError.invalid("\(name): invalid menu path.") }
            return make(.chooseMenuItem)
        case 59:
            guard let raw = try f.text("BTTOpenURL", maxBytes: 2_048)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let url = URL(string: raw), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
                throw ImportError.invalid("\(name): BTTOpenURL is not a valid URL.")
            }
            p.url = raw
            if !["http", "https", "mailto"].contains(scheme) {
                review = "\(name) opens a “\(scheme):” link, which can make another app act. Imported disabled — check it before enabling."
            }
            if let browser = try f.text("BTTOpenURLBrowser", maxBytes: 256), !["", "Default"].contains(browser) {
                notes.append("\(name): BTT opened it in \(cleanLabel(browser)); AOM uses the default browser.")
            }
            _ = try f.text("BTTOpenURLTerminalCommand", maxBytes: 4_096)
            return make(.openURL)
        default:
            return nil
        }
    }
}

private extension TriggerAction {
    var isPlaceholder: Bool { !isEnabled && actionType == .showHUD && (parameters.hudText ?? "").hasPrefix(BTTPresetImport.placeholderPrefix) }
}

// MARK: - Import flow

@MainActor
extension AppState {
    /// Open panel for BTT files. Settings › Import BTT Preset should call this
    /// so `.bttpreset` files can be chosen; it accepts plain JSON too.
    func presentBTTPresetImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BTTPresetImport.openPanelContentTypes
        panel.message = "Choose a BetterTouchTool preset (.bttpreset) or copied BTT trigger JSON"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.reviewCompatiblePresetImport(from: url) }
        }
    }

    /// Existing Import Preset entry point auto-detects native AOM or BTT JSON.
    /// Only an explicit Add merges the reviewed BTT triggers.
    func reviewCompatiblePresetImport(from url: URL) {
        do {
            let data = try BTTPresetImport.read(url)
            do {
                _ = try PresetCodec.decode(data)
                importPreset(from: url)
                return
            } catch PresetCodec.Failure.unsupportedVersion {
                // A newer AOM preset is not a BTT file; say so instead of
                // showing a BTT parse error.
                presetOperationReporter("Could Not Import the Preset",
                                        PresetCodec.Failure.unsupportedVersion.localizedDescription, .failure)
                return
            } catch {
                // Not a native preset: try BTT below.
            }
            let report = try BTTPresetImport.parse(data)
            let alert = NSAlert()
            alert.messageText = "Review BetterTouchTool Import"
            alert.informativeText = report.summary
            let count = report.triggers.count
            alert.addButton(withTitle: count == 0 ? "Close" : "Add \(count) Trigger\(count == 1 ? "" : "s")")
            if count > 0 { alert.addButton(withTitle: "Cancel") }
            let host = NSHostingView(rootView: BTTImportReportView(report: report, namedTriggerCollisions: bttNamedTriggerCollisions(report)))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
            alert.accessoryView = host
            guard alert.runModal() == .alertFirstButtonReturn, count > 0 else { return }
            addReviewedBTTImport(report)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could Not Import BTT JSON"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    /// Named triggers in the import whose names already exist in the preset.
    func bttNamedTriggerCollisions(_ report: BTTPresetImport.Report) -> [String] {
        let existing = Set(currentPreset.triggers.compactMap { trigger -> String? in
            if case .namedTrigger(let name) = trigger.input { return name }; return nil
        })
        return report.triggers.compactMap { trigger -> String? in
            if case .namedTrigger(let name) = trigger.input, existing.contains(name) { return name }; return nil
        }
    }

    /// Adds the reviewed import to the current preset: missing app scopes
    /// first, then the staged triggers with the enabled state the report gave.
    func addReviewedBTTImport(_ report: BTTPresetImport.Report) {
        for target in report.appTargets where !currentPreset.appTargets.contains(where: { $0.bundleID == target.bundleID }) {
            currentPreset.appTargets.append(target)
        }
        for trigger in report.triggers { currentPreset.addTrigger(trigger) }
        selectedTrigger = nil; selectedAction = nil
        save()
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
