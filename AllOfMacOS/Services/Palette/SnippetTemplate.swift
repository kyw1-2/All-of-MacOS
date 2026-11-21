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

enum SnippetToken: Equatable {
    case text(String)
    case clipboard
    case date(String?)
    case time(String?)
    case cursor
    case arg(String)
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
        func flush() { if !literal.isEmpty { tokens.append(.text(literal)); literal = "" } }
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
                    token = .arg(label)
                default:
                    return .failure(SnippetTemplateError(offset: index, message: "Unknown placeholder {\(body)}; use {clipboard}, {date}, {time}, {cursor} or {arg:name}, and {{ for a brace"))
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
        return .success(tokens)
    }

    /// Pure: the template uses any placeholder (not only {{ and }}).
    static func hasPlaceholders(_ template: String) -> Bool {
        guard case .success(let tokens) = parse(template) else { return false }
        return tokens.contains { if case .text = $0 { return false }; return true }
    }

    /// Pure: the {arg:…} names in order, each once.
    static func argumentNames(_ tokens: [SnippetToken]) -> [String] {
        var names: [String] = []
        for case .arg(let name) in tokens where !names.contains(name) { names.append(name) }
        return names
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
        for token in tokens {
            switch token {
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
            }
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

/// 7.3: a snippet's {arg:…} fields asked in the launcher, one per ↩.
/// From a typed abbreviation, the abbreviation stays as typed until the
/// last field is confirmed, and is replaced only if the same app is still
/// in front; Esc leaves the text exactly as it was (Codex 7.2.3 report).
@MainActor
final class PaletteSnippetForm: ObservableObject {
    static let shared = PaletteSnippetForm()

    struct Request: Equatable {
        var snippetID: UUID
        var names: [String]
        var values: [String: String] = [:]
        var index = 0
        /// Characters of the typed abbreviation to erase first (0: from the launcher).
        var erase = 0
        var targetPID: pid_t?
        /// The abbreviation as typed (put back if the insert fails after the erase).
        var typed = ""

        var currentName: String? { names.indices.contains(index) ? names[index] : nil }
        var isComplete: Bool { index >= names.count }
    }

    @Published private(set) var request: Request?

    func begin(_ request: Request) { self.request = request }

    /// Takes the field's text for the current name; true when every field is filled.
    func submit(_ value: String) -> Bool {
        guard var current = request, let name = current.currentName else { return true }
        current.values[name] = value
        current.index += 1
        request = current
        return current.isComplete
    }

    func cancel() { request = nil }
    func finish() -> Request? { defer { request = nil }; return request }

    /// From a typed abbreviation (KeyboardMonitor): opens the launcher on the form.
    static func askFromTyping(snippetID: UUID, names: [String], erase: Int, target: NSRunningApplication?, typed: String = "") {
        shared.begin(Request(snippetID: snippetID, names: names, erase: erase, targetPID: target?.processIdentifier, typed: typed))
        AOMLauncherController.shared.show(route: .snippetArguments(snippetID))
    }
}
