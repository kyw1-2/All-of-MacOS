import AppKit

/// Runs one action on the selection and reports how it went. Each result is
/// real: a failure says why, nothing claims success it did not have.
@MainActor
enum TextActionPerformer {
    enum Outcome: Equatable {
        /// Done; the bar can go.
        case done
        /// Done, with a word the bar flashes ("Copied").
        case confirmed(String)
        case failed(title: String, detail: String)
    }

    /// The ChatGPT app: the classic one, or the current one that ships as
    /// "ChatGPT" with the `com.openai.codex` identifier.
    static let chatGPTBundleIDs = ["com.openai.chat", "com.openai.codex"]
    static let pinboardName = "Text Actions"

    /// Mirrors PopClip's configurable action payload without running scripts
    /// or sending selected text automatically to an external service.
    /// The user deliberately invokes the action and pastes after review.
    static func preparedChatGPTPrompt(template: String, selection: String) -> String {
        let prompt = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return selection }
        if prompt.contains("{text}") {
            return prompt.replacingOccurrences(of: "{text}", with: selection)
        }
        return prompt + "\n\n" + selection
    }

    private static var chatGPTCache: (url: URL?, checked: TimeInterval)?

    static func chatGPTApplicationURL() -> URL? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = chatGPTCache, now - cache.checked < 60 { return cache.url }
        let url = chatGPTBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        chatGPTCache = (url, now)
        return url
    }

    /// Actions that put text into the app hide the bar first, so nothing of
    /// AOM's sits over the field while the app takes the change.
    static func hidesBarFirst(_ item: TextActionBarItem, variant: TextTransformVariant?, alternate: Bool,
                              editability: TextEditability) -> Bool {
        switch item.id {
        case .cut, .paste: return true
        case .calculate: return alternate && editability != .readOnly
        default: return item.id.isTransform && !alternate && editability != .readOnly
        }
    }

    static func perform(_ item: TextActionBarItem, variant: TextTransformVariant?, alternate: Bool,
                        selection: TextSelection, context: TextActionContext, settings: TextActionsSettings,
                        completion: @escaping (Outcome) -> Void) {
        let app = NSRunningApplication(processIdentifier: selection.pid)
        let text = selection.text
        let traits = selection.traits
        switch item.id {
        case .copy:
            TextActionPasteboard.copySelection(selection, in: app) { ok in
                completion(ok ? .confirmed("Copied") : .failed(title: "Could Not Copy", detail: "The clipboard did not accept the text."))
            }
        case .cut:
            cut(selection, app: app, completion: completion)
        case .paste:
            guard let app, TextActionPasteboard.press(TextActionPasteboard.keyV, in: app) else {
                completion(.failed(title: "Could Not Paste", detail: "The app is no longer in front."))
                return
            }
            completion(.done)
        case .search:
            open(TextActionURLs.search(text, engine: settings.searchEngine, customTemplate: settings.customSearchURL),
                 failure: settings.searchEngine == .custom ? "The custom search address needs {query}." : "The search could not be opened.",
                 completion)
        case .githubSearch:
            open(TextActionURLs.gitHubSearch(text), failure: "The search could not be opened.", completion)
        case .openLink:
            open(traits.link, failure: "No app opens this link.", completion)
        case .newEmail:
            open(traits.email.flatMap(TextActionURLs.mail(to:)), failure: "No mail app is set up.", completion)
        case .lookUp:
            open(TextActionURLs.lookUp(text), failure: "Dictionary could not open the word.", completion)
        case .translate:
            let target = TextActionURLs.targetLanguage(for: text, from: settings.translateFrom, to: settings.translateTo)
            let sent = TextActionURLs.translationText(text)
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            open(TextActionURLs.translate(text, translator: settings.translator, from: settings.translateFrom, to: target),
                 failure: "The translator could not be opened.") { outcome in
                // A link holds only so much: say so rather than drop text silently.
                if outcome == .done, sent.count < whole.count {
                    GestureHUD.shared.show(title: "Translating Part of the Text",
                                           detail: "The first \(sent.count.formatted()) of \(whole.count.formatted()) characters fit in the link.")
                }
                completion(outcome)
            }
        case .calculate:
            guard let result = TextActionApplicability.calculation(context.calculation, for: traits) else {
                completion(.failed(title: "Nothing to Calculate", detail: "The selection is not a sum."))
                return
            }
            if alternate && selection.editability != .readOnly {
                replace(result.display, in: selection, app: app, completion: completion)
            } else {
                completion(TextActionPasteboard.copy(result.display) ? .confirmed("Copied")
                           : .failed(title: "Could Not Copy", detail: "The clipboard did not accept the result."))
            }
        case .count:
            completion(.done)
        case .speak:
            TextCaptureSpeech.shared.toggle(String(text.prefix(TextActionApplicability.speakLimit)))
            completion(.done)
        case .pinToClipboard:
            pin(selection, settings: settings, completion: completion)
        case .askChatGPT:
            guard let url = chatGPTApplicationURL() else {
                completion(.failed(title: "ChatGPT Is Not Installed", detail: "Install the ChatGPT app to use Ask ChatGPT."))
                return
            }
            let payload = preparedChatGPTPrompt(template: settings.customChatGPTPrompt, selection: text)
            guard TextActionPasteboard.copy(payload) else {
                completion(.failed(title: "Could Not Copy", detail: "The clipboard did not accept the text."))
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let reason = error?.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let reason {
                            completion(.failed(title: "Could Not Open ChatGPT", detail: reason))
                        } else {
                            GestureHUD.shared.show(title: "AI Prompt Ready", detail: "Review and press ⌘V in ChatGPT. Nothing was sent automatically.")
                            completion(.done)
                        }
                    }
                }
            }
        case .changeCase, .formatJSON, .urlCoding, .base64, .markdown:
            guard let variant else {
                completion(.failed(title: "Choose a Change", detail: "Pick one of the options on the bar."))
                return
            }
            let clipboardURL = variant == .markdown(.link) ? TextActionPasteboard.clipboardURL() : nil
            guard let result = TextActionTransforms.apply(variant, to: text, clipboardURL: clipboardURL) else {
                completion(.failed(title: "Could Not Change the Text", detail: variant == .formatJSON
                                   ? "The selection is not valid JSON." : "The selection cannot be changed this way."))
                return
            }
            if alternate || selection.editability == .readOnly {
                completion(TextActionPasteboard.copy(result) ? .confirmed("Copied")
                           : .failed(title: "Could Not Copy", detail: "The clipboard did not accept the result."))
            } else {
                replace(result, in: selection, app: app, completion: completion)
            }
        }
    }

    private static func open(_ url: URL?, failure: String, _ completion: @escaping (Outcome) -> Void) {
        guard let url else { completion(.failed(title: "Could Not Open", detail: failure)); return }
        completion(NSWorkspace.shared.open(url) ? .done : .failed(title: "Could Not Open", detail: failure))
    }

    /// Puts `text` in place of the selection: through Accessibility when the
    /// field allows it, otherwise by pasting (the clipboard is put back).
    static func replace(_ text: String, in selection: TextSelection, app: NSRunningApplication?,
                        completion: @escaping (Outcome) -> Void) {
        guard let app, !app.isTerminated else {
            completion(.failed(title: "Could Not Replace the Text", detail: "The app is no longer running."))
            return
        }
        let paste = {
            TextActionPasteboard.paste(text, into: app) { ok in
                completion(ok ? .done : .failed(title: "Could Not Replace the Text",
                                               detail: "\(selection.appName ?? "The app") did not accept the change."))
            }
        }
        guard selection.editability == .editable, let element = selection.element else { paste(); return }
        let original = selection.text
        TextSelectionReader.queue.async {
            let ok = TextSelectionReader.setSelectedText(text, in: element, replacing: original)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { completion(.done) } else { paste() }
                }
            }
        }
    }

    /// ⌘X in the app; when it does not respond, copy and remove the text
    /// through Accessibility.
    private static func cut(_ selection: TextSelection, app: NSRunningApplication?, completion: @escaping (Outcome) -> Void) {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let failed = Outcome.failed(title: "Could Not Cut", detail: "\(selection.appName ?? "The app") did not take the cut.")
        guard let app, TextActionPasteboard.press(TextActionPasteboard.keyX, in: app) else { completion(failed); return }
        TextActionPasteboard.waitForChange(from: before, timeout: 0.5) { changed in
            if changed { completion(.done); return }
            guard let element = selection.element, selection.editability == .editable,
                  TextActionPasteboard.copy(selection.text) else { completion(failed); return }
            let original = selection.text
            TextSelectionReader.queue.async {
                let ok = TextSelectionReader.setSelectedText("", in: element, replacing: original)
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok ? .done : failed) } }
            }
        }
    }

    /// A text item on a Clipboard pinboard: the one chosen on the page, else
    /// "Text Actions" (made when missing). The same text already in history
    /// is pinned rather than added again. Apps Clipboard never records stay
    /// unrecorded here too.
    private static func pin(_ selection: TextSelection, settings: TextActionsSettings, completion: @escaping (Outcome) -> Void) {
        let store = ClipboardStore.shared
        if store.settings.excludes(selection.bundleID) {
            completion(.failed(title: "Not Pinned", detail: "Clipboard history never records \(selection.appName ?? "this app")."))
            return
        }
        Task { @MainActor in
            await store.ready()
            guard let board = pinboard(in: store, preferred: settings.pinboardID) else {
                completion(.failed(title: "Not Pinned", detail: "Clipboard could not make a pinboard (it holds at most 100)."))
                return
            }
            let existing = store.entries.first { $0.text == selection.text && ($0.kind == .text || $0.kind == .link) }
            // Already on a pinboard: keep it where the person put it.
            if let existing, !existing.pinboardIDs.isEmpty {
                completion(.confirmed("Pinned"))
                return
            }
            guard let entry = existing ?? store.createTextItem(selection.text) else {
                completion(.failed(title: "Not Pinned", detail: store.lastError ?? "The text could not be saved."))
                return
            }
            store.pin(entryID: entry.id, boardID: board.id)
            let pinned = store.entries.first { $0.id == entry.id }?.pinboardIDs.contains(board.id) == true
            completion(pinned ? .confirmed("Pinned") : .failed(title: "Not Pinned", detail: "Clipboard did not keep the item."))
        }
    }

    static func pinboard(in store: ClipboardStore, preferred: UUID?) -> ClipboardPinboard? {
        if let preferred, let board = store.boards.first(where: { $0.id == preferred }) { return board }
        if let board = store.boards.first(where: { $0.name == pinboardName }) { return board }
        let made = store.createBoard(name: pinboardName, color: "orange")
        return store.boards.first { $0.id == made.id }
    }
}
