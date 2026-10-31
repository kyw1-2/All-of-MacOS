import AppKit
import Carbon

/// Keys pressed in the app that holds the selection, and the clipboard
/// borrowed for a moment: reading a selection with ⌘C or pasting a result
/// with ⌘V, then putting the person's clipboard back. AOM's clipboard
/// history is held meanwhile, so neither the borrowed copy nor the restore
/// lands in it (`ClipboardStore` skips every change while it is paused and
/// takes the pasteboard's count again when it resumes). The temporary item
/// AOM writes also carries the nspasteboard.org transient marker, which
/// other clipboard managers skip.
@MainActor
enum TextActionPasteboard {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// AOM's synthetic events carry this tag, so its own monitors ignore them.
    static let syntheticTag: Int64 = 0x475454

    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9
    static let keyX: CGKeyCode = 7

    /// Presses ⌘ and `key` in `app` only, never in whatever else is in front.
    /// Held modifiers do not leak in: the event carries ⌘ alone.
    static func press(_ key: CGKeyCode, in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            event.postToPid(app.processIdentifier)
        }
        return true
    }

    /// Holds AOM's clipboard history; call the returned closure to let it go.
    /// A pause the person set stays as it was.
    static func holdHistory() -> () -> Void {
        let store = ClipboardStore.shared
        guard !store.paused else { return {} }
        store.paused = true
        var released = false
        return {
            guard !released else { return }
            released = true
            if store.paused { store.paused = false }
        }
    }

    /// Calls `done` once the clipboard changes after `before` and has been
    /// still for a moment (some apps write in steps), or with false after
    /// `timeout`.
    static func waitForChange(from before: Int, timeout: TimeInterval = 0.6, _ done: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var seen: Int?
        func check() {
            let count = pasteboard.changeCount
            if count != before {
                if seen == count { done(true); return }
                seen = count
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                done(false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { check() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { check() } }
    }

    /// Reads the selection by pressing ⌘C in `app`, then puts the clipboard
    /// back. Returns the plain text, or nil when nothing text-like was copied
    /// (files from Finder, an image, nothing at all).
    static func readSelectionWithCopy(in app: NSRunningApplication, completion: @escaping (String?) -> Void) {
        guard !IsSecureEventInputEnabled() else { completion(nil); return }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = PasteboardSnapshot.capture(pasteboard)
        let release = holdHistory()
        guard press(keyC, in: app) else { release(); completion(nil); return }
        waitForChange(from: before) { changed in
            guard changed else { release(); completion(nil); return }
            let copied = pasteboard.changeCount
            let types = pasteboard.types?.map(\.rawValue) ?? []
            let string = pasteboard.string(forType: .string)
            // Put it back unless someone else wrote to the clipboard meanwhile.
            if pasteboard.changeCount == copied { saved.restore(to: pasteboard) }
            release()
            completion(TextActionsGate.copiedText(string: string, types: types))
        }
    }

    /// Puts `text` on the clipboard (marked transient), presses ⌘V in `app`
    /// and puts the clipboard back.
    static func paste(_ text: String, into app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty, !IsSecureEventInputEnabled() else { completion(false); return }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(pasteboard)
        let release = holdHistory()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        guard pasteboard.writeObjects([item]) else {
            saved.restore(to: pasteboard)
            release()
            completion(false)
            return
        }
        let ours = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard pasteboard.changeCount == ours, press(keyV, in: app) else {
                    if pasteboard.changeCount == ours { saved.restore(to: pasteboard) }
                    release()
                    completion(false)
                    return
                }
                // The app reads the clipboard when it handles ⌘V; wait before restoring.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        if pasteboard.changeCount == ours { saved.restore(to: pasteboard) }
                        release()
                        completion(true)
                    }
                }
            }
        }
    }

    /// A normal copy: the person asked for this text on the clipboard, so
    /// clipboard history keeps it like any copy.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Copies the selection the way the app would (keeping its formatting) by
    /// pressing ⌘C there; writes the plain text when the app does not respond.
    static func copySelection(_ selection: TextSelection, in app: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        guard let app, press(keyC, in: app) else { completion(copy(selection.text)); return }
        waitForChange(from: before, timeout: 0.5) { changed in
            if changed, pasteboard.string(forType: .string)?.isEmpty == false { completion(true); return }
            completion(copy(selection.text))
        }
    }

    /// The clipboard's web address, for a Markdown link around the selection.
    static func clipboardURL() -> URL? {
        guard let string = NSPasteboard.general.string(forType: .string), string.count <= TextSelectionClassifier.tokenLimit else { return nil }
        return TextSelectionClassifier.link(in: string)?.url
    }
}
