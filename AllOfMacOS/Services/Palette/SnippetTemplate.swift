import AppKit
import ApplicationServices
import Carbon
import Foundation

// AOM 7.3: snippet placeholders (DeepSeek design v2 §4, Codex 7.2.3 report
// p. 6; Espanso's clipboard and date extensions, preserve_clipboard).
//
// A snippet saved with placeholders (TypedStringSpec.syntax == 2) may hold
// {clipboard}, {date}, {date:yyyy.MM.dd}, {time}, {time:HH:mm:ss},
// {cursor} (once) and {arg:name} (asked once per name), with {{ and }} for
// literal braces. Snippets from before 7.3 stay literal text, so code or
// prose with braces types exactly as saved. The launcher and the typed
// abbreviation use the same renderer and the same three ways to insert:
// short text is typed; a short line after {cursor} is typed and the caret
// walked back; anything longer is pasted with the clipboard put back
// afterwards — unless something else was copied meanwhile.

// 7.5 (Codex F02, TextExpander's popup menus and optional sections):
// {choice:Delivery|Courier|*Visit} asks to pick one option (the one marked
// * is the default, else the first), and {optional:Signature} … {/optional}
// (or {optional:Signature|off}) asks whether to put the text between in.
// A section tag alone on its line takes the line with it, so a section left
// out leaves no empty line. A field with the same name is asked once.

indirect enum SnippetToken: Equatable {
    case text(String)
    case clipboard
    case date(String?)
    case time(String?)
    case cursor
    case arg(String)
    /// Name, options, the default's index.
    case choice(String, [String], Int)
    /// Name, in by default, what it holds.
    case section(String, Bool, [SnippetToken])
    /// Last token of a template that uses sections and doesn't end with a
    /// line break: the text comes out without one at its end either, so a
    /// section left out (or a section's last line) never types a Return.
    case trimEnd
}

/// One question the snippet asks before it goes in.
struct SnippetField: Equatable {
    enum Kind: Equatable {
        case text
        case choice([String], defaultIndex: Int)
        case optional(defaultOn: Bool)
    }
    let name: String
    let kind: Kind
    /// The optional sections it sits in (empty when it's also used outside
    /// any): asked unless every one of them was left out.
    let sections: [String]

    /// The one section it sits in, if it sits in exactly one.
    var section: String? { sections.count == 1 ? sections[0] : nil }

    static let on = "1", off = "0"
    /// Pure: an optional section's answer.
    static func isOn(_ value: String?, default defaultOn: Bool) -> Bool {
        guard let value else { return defaultOn }
        return ["1", "on", "yes", "true"].contains(value.lowercased())
    }
}

struct SnippetTemplateError: Error, Equatable {
    /// Character offset of the problem in the template.
    let offset: Int
    let message: String
}

struct SnippetRender: Equatable {
    var text: String
    /// Characters after {cursor} (nil: the caret stays at the end).
    var charactersAfterCursor: Int?
    /// UTF-16 offset of {cursor} from the start.
    var cursorUTF16: Int?
    /// Why a placeholder came out empty ("the clipboard looked like a password").
    var notes: [String] = []

    var suffix: String {
        guard let after = charactersAfterCursor else { return "" }
        return String(text.suffix(after))
    }
}

enum SnippetTemplate {
    static let currentSyntax = 2
    static let sizeLimit = 100_000

    /// Pure: the tokens of a template, or where it goes wrong.
    static func parse(_ template: String) -> Result<[SnippetToken], SnippetTemplateError> {
        var tokens: [SnippetToken] = []
        var literal = ""
        var cursors = 0
        let characters = Array(template)
        var index = 0
        /// The open optional section: its name, default, where it began and the tokens outside it.
        var open: (name: String, on: Bool, offset: Int, outside: [SnippetToken])?
        /// Each field name's kind, so one name is one question.
        var kinds: [String: SnippetField.Kind] = [:]
        func flush() { if !literal.isEmpty { tokens.append(.text(literal)); literal = "" } }
        func register(_ name: String, _ kind: SnippetField.Kind, at offset: Int) -> SnippetTemplateError? {
            if let known = kinds[name], known != kind {
                return SnippetTemplateError(offset: offset, message: "“\(name)” is already a different field; give this one another name")
            }
            kinds[name] = kind
            return nil
        }
        /// A section tag alone on its line takes the line (its indent and line break) with it.
        func standalone(from start: Int, to end: Int) -> Bool {
            var before = start - 1
            while before >= 0, characters[before] == " " || characters[before] == "\t" { before -= 1 }
            // "\r\n" is one Character, so line breaks are matched with isNewline.
            guard before < 0 || characters[before].isNewline else { return false }
            var after = end + 1
            while after < characters.count, characters[after] == " " || characters[after] == "\t" { after += 1 }
            return after == characters.count || characters[after].isNewline
        }
        func skipLine(after close: Int) -> Int {
            var next = close + 1
            while next < characters.count, characters[next] == " " || characters[next] == "\t" { next += 1 }
            return next < characters.count ? next + 1 : next
        }
        while index < characters.count {
            let character = characters[index]
            if character == "{" {
                if index + 1 < characters.count, characters[index + 1] == "{" { literal.append("{"); index += 2; continue }
                guard let close = characters[(index + 1)...].firstIndex(of: "}") else {
                    return .failure(SnippetTemplateError(offset: index, message: "This { isn't closed; write {{ for a brace"))
                }
                let body = String(characters[(index + 1)..<close]).trimmingCharacters(in: .whitespaces)
                if body.contains("{") {
                    return .failure(SnippetTemplateError(offset: index, message: "This { isn't closed before the next one"))
                }
                let name = body.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                let argument = body.contains(":") ? String(body[body.index(after: body.firstIndex(of: ":")!)...]) : nil
                // Optional sections open and close a level instead of making a token.
                if name == "optional" || name == "/optional" {
                    let alone = standalone(from: index, to: close)
                    if alone { while let last = literal.last, last == " " || last == "\t" { literal.removeLast() } }
                    flush()
                    if name == "optional" {
                        guard open == nil else {
                            return .failure(SnippetTemplateError(offset: index, message: "An optional section can't hold another; close the first with {/optional}"))
                        }
                        let parts = (argument ?? "").split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        let label = parts.first ?? ""
                        guard !label.isEmpty else {
                            return .failure(SnippetTemplateError(offset: index, message: "Name the section: {optional:name} … {/optional}"))
                        }
                        let flag = parts.count > 1 ? parts[1].lowercased() : "on"
                        guard ["on", "off"].contains(flag), parts.count <= 2 else {
                            return .failure(SnippetTemplateError(offset: index, message: "Write {optional:\(label)} (in by default) or {optional:\(label)|off}"))
                        }
                        if let problem = register(label, .optional(defaultOn: flag == "on"), at: index) { return .failure(problem) }
                        open = (label, flag == "on", index, tokens)
                        tokens = []
                    } else {
                        guard let section = open, argument == nil else {
                            return .failure(SnippetTemplateError(offset: index, message: "This {/optional} has no {optional:name} before it"))
                        }
                        let inside = tokens
                        tokens = section.outside + [.section(section.name, section.on, inside)]
                        open = nil
                    }
                    index = alone ? skipLine(after: close) : close + 1
                    continue
                }
                let token: SnippetToken
                switch name {
                case "clipboard" where argument == nil: token = .clipboard
                case "date": token = .date(argument.flatMap { $0.isEmpty ? nil : $0 })
                case "time": token = .time(argument.flatMap { $0.isEmpty ? nil : $0 })
                case "cursor" where argument == nil:
                    cursors += 1
                    guard cursors == 1 else { return .failure(SnippetTemplateError(offset: index, message: "Only one {cursor} per snippet")) }
                    token = .cursor
                case "arg":
                    let label = (argument ?? "").trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return .failure(SnippetTemplateError(offset: index, message: "Name the field: {arg:name}")) }
                    if let problem = register(label, .text, at: index) { return .failure(problem) }
                    token = .arg(label)
                case "choice":
                    let parts = (argument ?? "").split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    let label = parts.first ?? ""
                    var options = Array(parts.dropFirst())
                    guard !label.isEmpty, options.count >= 2 else {
                        return .failure(SnippetTemplateError(offset: index, message: "A choice needs a name and two or more options: {choice:name|First|Second}"))
                    }
                    var defaultIndex = 0
                    if let marked = options.firstIndex(where: { $0.hasPrefix("*") }) {
                        defaultIndex = marked
                        options[marked] = String(options[marked].dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                    guard options.filter({ $0.hasPrefix("*") }).isEmpty else {
                        return .failure(SnippetTemplateError(offset: index, message: "Mark only one option with * as the default"))
                    }
                    if let problem = register(label, .choice(options, defaultIndex: defaultIndex), at: index) { return .failure(problem) }
                    token = .choice(label, options, defaultIndex)
                default:
                    return .failure(SnippetTemplateError(offset: index, message: "Unknown placeholder {\(body)}; use {clipboard}, {date}, {time}, {cursor}, {arg:name}, {choice:name|A|B} or {optional:name} … {/optional}, and {{ for a brace"))
                }
                flush()
                tokens.append(token)
                index = close + 1
                continue
            }
            if character == "}" {
                if index + 1 < characters.count, characters[index + 1] == "}" { literal.append("}"); index += 2; continue }
                return .failure(SnippetTemplateError(offset: index, message: "This } has no {; write }} for a brace"))
            }
            literal.append(character)
            index += 1
        }
        flush()
        if let section = open {
            return .failure(SnippetTemplateError(offset: section.offset, message: "{optional:\(section.name)} isn't closed; end the section with {/optional}"))
        }
        let usesSections = kinds.values.contains { if case .optional = $0 { return true }; return false }
        if usesSections, !(template.last?.isNewline ?? false) { tokens.append(.trimEnd) }
        return .success(tokens)
    }

    /// Pure: the template uses any placeholder (not only {{ and }}).
    static func hasPlaceholders(_ template: String) -> Bool {
        guard case .success(let tokens) = parse(template) else { return false }
        return tokens.contains { if case .text = $0 { return false }; return true }
    }

    /// Pure: the {arg:…} names in order, each once.
    static func argumentNames(_ tokens: [SnippetToken]) -> [String] {
        fields(tokens).compactMap { $0.kind == .text ? $0.name : nil }
    }

    /// Pure: every question in order of first use, each name once. A field
    /// used both inside and outside a section is always asked.
    static func fields(_ tokens: [SnippetToken]) -> [SnippetField] {
        var order: [String] = []
        var kinds: [String: SnippetField.Kind] = [:]
        var sections: [String: Set<String?>] = [:]
        func walk(_ tokens: [SnippetToken], in section: String?) {
            for token in tokens {
                let found: (String, SnippetField.Kind)?
                switch token {
                case .arg(let name): found = (name, .text)
                case .choice(let name, let options, let index): found = (name, .choice(options, defaultIndex: index))
                case .section(let name, let on, _): found = (name, .optional(defaultOn: on))
                default: found = nil
                }
                if let (name, kind) = found {
                    if kinds[name] == nil { order.append(name); kinds[name] = kind }
                    sections[name, default: []].insert(section)
                }
                if case .section(let name, _, let inner) = token { walk(inner, in: name) }
            }
        }
        walk(tokens, in: nil)
        return order.map { name in
            let places = sections[name] ?? []
            let inside = places.contains(nil) ? [] : places.compactMap { $0 }.sorted()
            return SnippetField(name: name, kind: kinds[name] ?? .text, sections: inside)
        }
    }

    struct Context {
        var now: Date = Date()
        var clipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
        var arguments: [String: String] = [:]
        var locale = Locale(identifier: "en_US_POSIX")
        var timeZone = TimeZone.current
    }

    /// Pure apart from `context`: the text to insert.
    static func render(_ tokens: [SnippetToken], context: Context = Context()) -> SnippetRender {
        var text = ""
        var cursorCharacters: Int?
        var cursorUTF16: Int?
        var notes: [String] = []
        var clipboardText: String??
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.timeZone = context.timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: context.now)
        }
        func append(_ tokens: [SnippetToken]) {
        for token in tokens {
            switch token {
            case .section(let name, let on, let inner):
                if SnippetField.isOn(context.arguments[name], default: on) { append(inner) }
            case .choice(let name, let options, let index): text += context.arguments[name] ?? options[index]
            case .text(let literal): text += literal
            case .clipboard:
                if clipboardText == nil { clipboardText = .some(context.clipboard()) }
                let clip = clipboardText!.flatMap { $0 } ?? ""
                if clip.isEmpty { notes.append("The clipboard had no text") }
                else if ClipboardSecretScanner.containsSecret(inText: clip) { notes.append("The clipboard looked like a password, so {clipboard} was left empty") }
                else { text += clip }
            case .date(let pattern): text += format(pattern ?? "yyyy-MM-dd")
            case .time(let pattern): text += format(pattern ?? "HH:mm")
            case .cursor:
                cursorCharacters = text.count
                cursorUTF16 = text.utf16.count
            case .arg(let name): text += context.arguments[name] ?? ""
            case .trimEnd: break
            }
        }
        }
        append(tokens)
        if tokens.last == .trimEnd {
            var trimmed = 0
            while let last = text.last, last.isNewline { text.removeLast(); trimmed += 1 }
            if let at = cursorCharacters, at > text.count, trimmed > 0 { cursorCharacters = text.count; cursorUTF16 = text.utf16.count }
        }
        let after = cursorCharacters.map { text.count - $0 }
        return SnippetRender(text: text, charactersAfterCursor: after == 0 ? nil : after, cursorUTF16: after == 0 ? nil : cursorUTF16, notes: notes)
    }

    /// Renders a snippet's text by its syntax: a literal one comes back as is.
    static func render(text: String, syntax: Int?, context: Context = Context()) -> Result<SnippetRender, SnippetTemplateError> {
        guard syntax == currentSyntax else { return .success(SnippetRender(text: text)) }
        return parse(text).map { render($0, context: context) }
    }

    // MARK: Inserting

    enum Route: Equatable {
        /// Type it (short, one line, no cursor).
        case type
        /// Type it, then ← this many times.
        case typeWithCaret(Int)
        /// Paste it (⌘V) and put the clipboard back.
        case paste
    }

    /// Pure (DeepSeek v2 §4.3): which way to insert.
    /// The most ← presses AOM sends to place the caret.
    static let caretWalkLimit = 200

    static func route(for render: SnippetRender, canRestoreClipboard: Bool = true) -> Route {
        let singleLine = !render.text.contains("\n")
        let suffix = render.suffix
        if render.charactersAfterCursor == nil, render.text.count <= 40, singleLine { return .type }
        if let after = render.charactersAfterCursor, after <= 24, singleLine, render.text.count <= 200 || !canRestoreClipboard {
            return .typeWithCaret(after)
        }
        if !canRestoreClipboard {
            // Typing is slower but never loses what is on the clipboard. The
            // caret walks back over a short line only (← is capped at 200;
            // 7.3, Codex probe: a 601-character suffix stopped at 400).
            guard render.charactersAfterCursor != nil, !suffix.contains("\n"), suffix.count <= caretWalkLimit else { return .type }
            return .typeWithCaret(suffix.count)
        }
        return .paste
    }
}

extension PasteboardSnapshot {
    /// The clipboard's items as they are, or nil when an item can't be
    /// copied whole (a promised or lazily provided type), so putting it
    /// back would lose something (Codex: check before writing).
    static func whole(_ pasteboard: NSPasteboard = .general) -> PasteboardSnapshot? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types where item.data(forType: type) == nil { return nil }
        }
        return capture(pasteboard)
    }
}

/// Pure part of SnippetInserter's check (tests).
enum SnippetInserterRefusal {
    static func check(_ render: SnippetRender) -> String? {
        if render.text.count > SnippetTemplate.sizeLimit { return "The snippet is over 100,000 characters" }
        if render.text.isEmpty { return render.notes.first ?? "The snippet came out empty" }
        return nil
    }
}

@MainActor
enum SnippetInserter {
    /// Why `render` can't be inserted now, checked before anything is
    /// erased or typed; nil when it can.
    static func refusal(for render: SnippetRender) -> String? {
        if let reason = SnippetInserterRefusal.check(render) { return reason }
        if IsSecureEventInputEnabled() { return "Not in a password field" }
        if ScreenLock.isLocked { return "Not on the lock screen" }
        if !AXIsProcessTrusted() { return "All of MacOS needs Accessibility to type" }
        return nil
    }

    /// Inserts `render` into the app in front, which must be `target`
    /// (checked again right before any key goes out). The note carries the
    /// render's own notes too (a {clipboard} left empty because it looked
    /// like a password).
    static func insert(_ render: SnippetRender, into target: NSRunningApplication?, completion: @escaping (Bool, String?) -> Void) {
        if let refusal = refusal(for: render) { completion(false, refusal); return }
        let done: (Bool, String?) -> Void = { inserted, note in
            let notes = render.notes + [note].compactMap { $0 }
            completion(inserted, notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
        let snapshot = PasteboardSnapshot.whole()
        switch SnippetTemplate.route(for: render, canRestoreClipboard: snapshot != nil) {
        case .type:
            let caretNote = render.charactersAfterCursor == nil ? nil : "The cursor stayed at the end: the text after {cursor} is too long to walk back over"
            ActionExecutor.typeReplacementText(render.text) { typed in
                DispatchQueue.main.async { done(typed, typed ? caretNote : "Couldn't type it") }
            }
        case .typeWithCaret(let back):
            ActionExecutor.typeReplacementText(render.text) { typed in
                DispatchQueue.main.async {
                    guard typed else { done(false, "Couldn't type it"); return }
                    // Give the app a moment to take the typed text first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        guard frontIs(target) else { done(true, "The cursor stayed at the end: the app changed"); return }
                        pressLeftInBackground(back) { done(true, nil) }
                    }
                }
            }
        case .paste:
            guard let snapshot, let target else { done(false, "Couldn't paste"); return }
            let start = focusedSelectionLocation()
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(render.text, forType: .string)
            let written = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                guard frontIs(target) else {
                    if board.changeCount == written { snapshot.restore(to: board) }
                    done(false, "The app in front changed, so nothing was pasted")
                    return
                }
                let sent = ClipboardStackPasteMonitor.sendPaste(to: target)
                // The clipboard comes back only if nothing was copied since (Codex: ownership change count).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if board.changeCount == written { snapshot.restore(to: board) }
                    guard sent else { done(false, "The paste couldn't be sent"); return }
                    guard let cursor = render.cursorUTF16 else { done(true, nil); return }
                    if let start, setFocusedSelection(start + cursor) {
                        done(true, nil)
                    } else if !render.suffix.contains("\n"), render.suffix.count <= 200 {
                        pressLeftInBackground(render.suffix.count) { done(true, nil) }
                    } else {
                        done(true, "The cursor stayed at the end: this app doesn't let AOM place it")
                    }
                }
            }
        }
    }

    /// ← presses posted off the main thread (up to 400 take ~0.6 s), then `then` on main.
    static func pressLeftInBackground(_ count: Int, then: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            pressLeft(count)
            DispatchQueue.main.async(execute: then)
        }
    }

    static func frontIs(_ target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    /// ← presses tagged as AOM's own, so the typed-string matcher skips them.
    nonisolated static func pressLeft(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<min(count, SnippetTemplate.caretWalkLimit) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
                event.post(tap: .cghidEventTap)
            }
            usleep(1500)
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }

    /// Where the insertion point is (UTF-16), if the app says.
    static func focusedSelectionLocation() -> Int? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Puts the insertion point at `location`; false when the app refuses.
    static func setFocusedSelection(_ location: Int) -> Bool {
        guard let element = focusedElement() else { return false }
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        // Some apps accept the call and ignore it; read it back.
        return focusedSelectionLocation() == location
    }
}

/// 7.3: a snippet's {arg:…} fields asked in the launcher, one per ↩
/// (7.5: and its choices and optional sections, picked from rows).
/// From a typed abbreviation, the abbreviation stays as typed until the
/// last field is confirmed, and is replaced only if the same app is still
/// in front; Esc leaves the text exactly as it was (Codex 7.2.3 report).
@MainActor
final class PaletteSnippetForm: ObservableObject {
    static let shared = PaletteSnippetForm()

    struct Request: Equatable {
        var snippetID: UUID
        /// 7.5: text fields, choices and optional sections, in order.
        var fields: [SnippetField]
        var values: [String: String] = [:]
        var index = 0
        /// Characters of the typed abbreviation to erase first (0: from the launcher).
        var erase = 0
        var targetPID: pid_t?
        /// The abbreviation as typed (put back if the insert fails after the erase).
        var typed = ""
        /// 7.12 (Codex UX-1): the questions shown before this one, newest last,
        /// so ⌘[ / Previous goes back to the one actually asked.
        var history: [Int] = []
        /// 7.12: what was typed into a text question that was left with ⌘[.
        var drafts: [String: String] = [:]

        var canGoBack: Bool { !history.isEmpty }

        var names: [String] { fields.map(\.name) }
        var currentField: SnippetField? { fields.indices.contains(index) ? fields[index] : nil }
        var currentName: String? { currentField?.name }
        var isComplete: Bool { index >= fields.count }
        /// The questions left to ask, counting this one (a section left out skips its fields).
        var remaining: Int { fields[index...].filter { !skips($0) }.count }
        var isLast: Bool { remaining <= 1 }
        /// Step numbers for the header: this one of all that will be asked.
        var step: (Int, Int) {
            let asked = fields[..<min(index, fields.count)].filter { values[$0.name] != nil }.count
            return (asked + 1, asked + remaining)
        }

        /// Pure: a field whose every section was answered “leave out”.
        func skips(_ field: SnippetField) -> Bool {
            guard !field.sections.isEmpty else { return false }
            return field.sections.allSatisfy { section in
                guard let outer = fields.first(where: { $0.name == section }), case .optional(let on) = outer.kind,
                      values[section] != nil else { return false }
                return !SnippetField.isOn(values[section], default: on)
            }
        }

        /// Takes the answer for the current field and moves to the next one asked.
        mutating func answer(_ value: String) {
            guard let field = currentField else { return }
            values[field.name] = value
            drafts[field.name] = nil
            history.append(index)
            index += 1
            while let next = currentField, skips(next) { index += 1 }
        }

        /// 7.12 (UX-1): back to the question asked before this one, keeping
        /// what was typed here as its draft. Answers stay (a section turned
        /// off later leaves its fields out of the text, as before).
        mutating func back(draft: String) {
            guard let previous = history.popLast() else { return }
            if let name = currentName, case .text = currentField?.kind, !draft.isEmpty { drafts[name] = draft }
            index = previous
        }

        /// The text a text question starts with: its draft, else its earlier answer.
        var restoredText: String {
            guard let field = currentField, case .text = field.kind else { return "" }
            return drafts[field.name] ?? values[field.name] ?? ""
        }
    }

    @Published private(set) var request: Request?

    func begin(_ request: Request) { self.request = request }

    /// Takes the answer for the current field; true when every field is answered.
    func submit(_ value: String) -> Bool {
        guard var current = request, current.currentField != nil else { return true }
        current.answer(value)
        request = current
        return current.isComplete
    }

    /// 7.12 (UX-1): ⌘[ / Previous. False on the first question (⌘[ then goes back a screen).
    func back(draft: String) -> Bool {
        guard var current = request, current.canGoBack else { return false }
        current.back(draft: draft)
        request = current
        return true
    }

    func cancel() { request = nil }
    func finish() -> Request? { defer { request = nil }; return request }

    /// From a typed abbreviation (KeyboardMonitor): opens the launcher on the form.
    static func askFromTyping(snippetID: UUID, fields: [SnippetField], erase: Int, target: NSRunningApplication?, typed: String = "") {
        shared.begin(Request(snippetID: snippetID, fields: fields, erase: erase, targetPID: target?.processIdentifier, typed: typed))
        AOMLauncherController.shared.show(route: .snippetArguments(snippetID))
    }
}
