import AppKit
import Carbon.HIToolbox

/// Delivers text into controls that suppress synthetic keyboard events.
///
/// macOS enables Secure Event Input while a password field is focused, which
/// drops every CGEvent posted from another process — keycodes included. Paste
/// is the one delivery path those controls still accept, so this helper writes
/// the payload to the general pasteboard, posts ⌘V, then restores the previous
/// clipboard. The temporary item is marked concealed and transient so it never
/// enters AOM's own clipboard history or another manager's.
enum SecureTextPaste {
    private static let vKey: CGKeyCode = 9
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Restores the clipboard `restoreDelay` after the paste. The payload is
    /// never logged, and the restore is skipped if another app wrote to the
    /// pasteboard in the meantime.
    static func deliver(_ text: String,
                        restoreDelay: TimeInterval = 0.7,
                        completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { completion(true); return }
        guard AXIsProcessTrusted() else { completion(false); return }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: concealed)
        item.setData(Data(), forType: transient)
        guard pasteboard.writeObjects([item]) else { completion(false); return }
        let written = pasteboard.changeCount

        guard postCommandV() else {
            restore(saved, into: pasteboard, expectedChange: written)
            completion(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, into: pasteboard, expectedChange: written)
            completion(true)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]],
                                into pasteboard: NSPasteboard,
                                expectedChange: Int) {
        guard pasteboard.changeCount == expectedChange else { return }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.writeObjects(saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        })
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
